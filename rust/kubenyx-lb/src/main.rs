//! kubenyx-lb: client-side apiserver load balancer (air/v0.3/durable-ha.org
//! §4, Decision 1). A local health-checking TCP forwarder on every agent of
//! a multi-server cluster: kubelet/kube-proxy/coredns dial
//! https://127.0.0.1:6444 and this process forwards to whichever declared
//! server currently answers /readyz. No VRRP, no floating IP — failover
//! time is pure health-check policy (probe interval × fail threshold).
//!
//! Decision 1's accepted cost is owning the proxy edge cases, so they are
//! first-class here, not afterthoughts:
//!   - half-open connections: each direction is pumped by its own thread;
//!     EOF on one side propagates as shutdown(Write) to the other while the
//!     reverse direction keeps flowing until its own EOF — apiserver
//!     watches with a half-closed request side stay alive;
//!   - stuck peers: reads poll on a short timeout (so threads notice the
//!     drain deadline), writes carry a hard timeout so a wedged receiver
//!     cannot pin a thread forever;
//!   - eviction/readmission: a probe thread reuses the kubenyx-ready rustls
//!     approach (insecure /readyz probe — identity is irrelevant, liveness
//!     is the signal); a backend evicts after --fail-threshold consecutive
//!     failures and readmits on the first success. With zero healthy
//!     backends, unhealthy ones are still tried last-resort — a lagging
//!     probe must not cause a self-inflicted blackout;
//!   - drain on SIGTERM: stop accepting, let in-flight connections finish
//!     within the drain deadline, exit 0;
//!   - sd_notify READY only after the first healthy backend, so units
//!     ordered after this one start against a live endpoint.
//!
//! Thread-per-connection with std is deliberate (Decision 1): dozens of
//! connections per node sit three orders of magnitude below any epoll
//! ceiling, and the dependency-light binary keeps the closure ~1-2MB.
//!
//! The backend list is argv, rendered from kubenyx.nodes at eval time and
//! re-read on every restart — a grown server set needs a rebuild, never an
//! LB redesign (Decision 3's open door).

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::os::unix::net::UnixDatagram;
use std::process::exit;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

static DRAINING: AtomicBool = AtomicBool::new(false);
static ACTIVE: AtomicUsize = AtomicUsize::new(0);
/// Drain deadline in ms since START; u64::MAX = no deadline yet.
static DRAIN_DEADLINE_MS: AtomicU64 = AtomicU64::new(u64::MAX);
static START: OnceLock<Instant> = OnceLock::new();

extern "C" fn on_drain_signal(_sig: libc::c_int) {
    // Only the atomic store is async-signal-safe; the accept loop notices
    // the flag and runs the actual drain.
    DRAINING.store(true, Ordering::SeqCst);
}

fn die(msg: &str) -> ! {
    eprintln!("kubenyx-lb: {msg}");
    exit(2);
}

fn elapsed_ms() -> u64 {
    START
        .get()
        .map(|s| s.elapsed().as_millis() as u64)
        .unwrap_or(0)
}

fn drain_expired() -> bool {
    DRAINING.load(Ordering::Relaxed) && elapsed_ms() >= DRAIN_DEADLINE_MS.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

struct Cfg {
    listen: String,
    backends: Vec<String>,
    probe_interval: Duration,
    fail_threshold: u32,
    drain_timeout: Duration,
    dial_timeout: Duration,
    /// Plaintext-HTTP probes instead of TLS. Test hook only: dummy smoke
    /// backends should not need certificates. Real apiservers are always
    /// probed over TLS.
    probe_http: bool,
    /// Client certificate for the /readyz probe. Kubenyx apiservers run
    /// --anonymous-auth=false, so an unauthenticated probe is answered 401
    /// by the auth filter regardless of readiness — only an authenticated
    /// request ever sees /readyz's real 200/500 (any authenticated subject
    /// is authorized: system:public-info-viewer covers /readyz). The agent's
    /// kubelet client cert is the natural identity here.
    probe_cert: Option<String>,
    probe_key: Option<String>,
}

fn parse_args(args: &[String]) -> Result<Cfg, String> {
    let mut cfg = Cfg {
        listen: "127.0.0.1:6444".into(),
        backends: vec![],
        probe_interval: Duration::from_millis(500),
        fail_threshold: 3,
        drain_timeout: Duration::from_millis(10_000),
        dial_timeout: Duration::from_millis(3_000),
        probe_http: false,
        probe_cert: None,
        probe_key: None,
    };
    let mut i = 0;
    while i < args.len() {
        let flag = args[i].as_str();
        let mut val = || -> Result<String, String> {
            i += 1;
            args.get(i)
                .cloned()
                .ok_or_else(|| format!("missing value for {flag}"))
        };
        let ms = |s: String, f: &str| -> Result<Duration, String> {
            s.parse::<u64>()
                .map(Duration::from_millis)
                .map_err(|_| format!("bad {f} value {s}"))
        };
        match flag {
            "--listen" => cfg.listen = val()?,
            "--backend" => cfg.backends.push(val()?),
            "--probe-interval-ms" => cfg.probe_interval = ms(val()?, flag)?,
            "--fail-threshold" => {
                let v = val()?;
                cfg.fail_threshold = v.parse().map_err(|_| format!("bad {flag} value {v}"))?;
            }
            "--drain-timeout-ms" => cfg.drain_timeout = ms(val()?, flag)?,
            "--dial-timeout-ms" => cfg.dial_timeout = ms(val()?, flag)?,
            "--probe-http" => cfg.probe_http = true,
            "--probe-cert" => cfg.probe_cert = Some(val()?),
            "--probe-key" => cfg.probe_key = Some(val()?),
            other => return Err(format!("unknown flag {other}")),
        }
        i += 1;
    }
    if cfg.backends.is_empty() {
        return Err("at least one --backend is required".into());
    }
    if cfg.fail_threshold == 0 {
        return Err("--fail-threshold must be >= 1".into());
    }
    if cfg.probe_cert.is_some() != cfg.probe_key.is_some() {
        return Err("--probe-cert and --probe-key must be given together".into());
    }
    Ok(cfg)
}

// ---------------------------------------------------------------------------
// Backends + selection
// ---------------------------------------------------------------------------

struct Backend {
    /// As given on the CLI — the name used in every log line.
    spec: String,
    /// Host part, for the probe's SNI / Host header.
    host: String,
    addr: SocketAddr,
    healthy: AtomicBool,
    fails: AtomicU32,
}

fn resolve_backend(spec: &str) -> Backend {
    let addr = spec
        .to_socket_addrs()
        .unwrap_or_else(|e| die(&format!("resolve backend {spec}: {e}")))
        .next()
        .unwrap_or_else(|| die(&format!("backend {spec} resolved to no address")));
    let host = spec.rsplit_once(':').map(|(h, _)| h).unwrap_or(spec);
    Backend {
        spec: spec.to_string(),
        host: host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_string(),
        addr,
        // Start unhealthy: READY must mean a probe actually succeeded. The
        // accept loop's last-resort pass still tries unprobed backends.
        healthy: AtomicBool::new(false),
        fails: AtomicU32::new(0),
    }
}

/// Dial order for one client connection: healthy backends first, rotated by
/// the round-robin cursor, then unhealthy ones as a last resort (probe lag
/// must not turn into a self-inflicted blackout when nothing is marked
/// healthy).
fn pick_order(healthy: &[bool], cursor: usize) -> Vec<usize> {
    let n = healthy.len();
    let rotated = |keep: bool| {
        (0..n)
            .map(move |i| (cursor + i) % n)
            .filter(move |&i| healthy[i] == keep)
    };
    rotated(true).chain(rotated(false)).collect()
}

// ---------------------------------------------------------------------------
// Health probing (kubenyx-ready's NoVerify approach: liveness, not identity)
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct NoVerify(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// Probe TLS config. With client_cert paths, returns None until BOTH files
/// exist and parse — the agent's credentials arrive over the operator
/// channel after this process starts, so the health loop retries the load
/// every round instead of dying at startup.
fn tls_probe_config(client_cert: Option<(&str, &str)>) -> Option<Arc<rustls::ClientConfig>> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("tls versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoVerify(provider)));
    let config = match client_cert {
        None => builder.with_no_client_auth(),
        Some((cert_path, key_path)) => {
            let cert_data = std::fs::read(cert_path).ok()?;
            let certs: Vec<rustls::pki_types::CertificateDer<'static>> =
                rustls_pemfile::certs(&mut cert_data.as_slice())
                    .collect::<Result<_, _>>()
                    .ok()?;
            if certs.is_empty() {
                return None;
            }
            let key_data = std::fs::read(key_path).ok()?;
            let key_der = rustls_pemfile::private_key(&mut key_data.as_slice()).ok()??;
            builder.with_client_auth_cert(certs, key_der).ok()?
        }
    };
    Some(Arc::new(config))
}

fn probe(b: &Backend, tls: Option<&Arc<rustls::ClientConfig>>, timeout: Duration) -> bool {
    let Ok(stream) = TcpStream::connect_timeout(&b.addr, timeout) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let req = format!(
        "GET /readyz HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
        b.host
    );
    let mut buf = [0u8; 64];
    let n = match tls {
        Some(config) => {
            let Ok(name) = rustls::pki_types::ServerName::try_from(b.host.clone()) else {
                return false;
            };
            let Ok(conn) = rustls::ClientConnection::new(config.clone(), name) else {
                return false;
            };
            let mut s = rustls::StreamOwned::new(conn, stream);
            if s.write_all(req.as_bytes()).is_err() {
                return false;
            }
            match s.read(&mut buf) {
                Ok(n) => n,
                Err(_) => return false,
            }
        }
        None => {
            let mut s = stream;
            if s.write_all(req.as_bytes()).is_err() {
                return false;
            }
            match s.read(&mut buf) {
                Ok(n) => n,
                Err(_) => return false,
            }
        }
    };
    // "HTTP/1.1 200 ..." — only 2xx counts as serving.
    n >= 12 && &buf[9..12] == b"200"
}

fn health_loop(backends: Arc<Vec<Backend>>, cfg: ProbePolicy) {
    // Anonymous base config: used until the client certificate (if any) is
    // loadable. Against a kubenyx apiserver it only ever earns a 401, so
    // backends stay unhealthy until the cert lands — which is correct: no
    // credentials means no kubelet either, so READY has nothing to gate yet.
    let base = if cfg.http {
        None
    } else {
        tls_probe_config(None)
    };
    let mut with_cert: Option<Arc<rustls::ClientConfig>> = None;
    // Probe timeout: never longer than 1.5s (kubenyx-ready's ceiling), never
    // longer than the interval says a whole round should take.
    let timeout = cfg
        .interval
        .max(Duration::from_millis(250))
        .min(Duration::from_millis(1500));
    let mut ever_ready = false;
    loop {
        if !cfg.http && with_cert.is_none() {
            if let Some((c, k)) = &cfg.client_cert {
                with_cert = tls_probe_config(Some((c, k)));
                if with_cert.is_some() {
                    eprintln!("kubenyx-lb: probe client certificate loaded from {c}");
                }
            }
        }
        let tls = with_cert.as_ref().or(base.as_ref());
        for b in backends.iter() {
            if probe(b, tls, timeout) {
                b.fails.store(0, Ordering::Relaxed);
                if !b.healthy.swap(true, Ordering::Relaxed) {
                    eprintln!("KUBENYX-LB-READMIT {}", b.spec);
                }
                if !ever_ready {
                    ever_ready = true;
                    sd_notify_ready();
                    eprintln!("KUBENYX-LB-READY first healthy backend {}", b.spec);
                }
            } else {
                let f = b.fails.fetch_add(1, Ordering::Relaxed).saturating_add(1);
                if f >= cfg.fail_threshold && b.healthy.swap(false, Ordering::Relaxed) {
                    eprintln!("KUBENYX-LB-EVICT {} after {f} failed probes", b.spec);
                }
            }
        }
        if DRAINING.load(Ordering::Relaxed) {
            return; // draining: routing decisions are over
        }
        std::thread::sleep(cfg.interval);
    }
}

struct ProbePolicy {
    interval: Duration,
    fail_threshold: u32,
    http: bool,
    /// (cert, key) PEM paths; loaded lazily by the health loop (see
    /// tls_probe_config). Renewal re-ships are picked up on the next
    /// service restart, same as the backend list.
    client_cert: Option<(String, String)>,
}

// ---------------------------------------------------------------------------
// Forwarding
// ---------------------------------------------------------------------------

/// Copy src → dst until EOF/error, then propagate the close per-direction:
/// shutdown(Write) on dst says "no more data will come" without touching
/// dst's read side, and shutdown(Read) on src unblocks any lingering sender.
/// The read timeout is a poll tick, not a connection deadline — idle watch
/// connections survive, but the thread notices the drain deadline.
fn pump(mut src: TcpStream, mut dst: TcpStream) {
    let _ = src.set_read_timeout(Some(Duration::from_millis(1000)));
    // A hard write timeout: a peer that stops reading (dead VM, full
    // window) kills the connection instead of pinning this thread.
    let _ = dst.set_write_timeout(Some(Duration::from_millis(30_000)));
    let mut buf = [0u8; 32 * 1024];
    loop {
        match src.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if dst.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::Interrupted
                ) =>
            {
                if drain_expired() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let _ = dst.shutdown(Shutdown::Write);
    let _ = src.shutdown(Shutdown::Read);
}

fn handle(
    client: TcpStream,
    backends: &Arc<Vec<Backend>>,
    cursor: &AtomicUsize,
    dial_timeout: Duration,
) {
    let healthy: Vec<bool> = backends
        .iter()
        .map(|b| b.healthy.load(Ordering::Relaxed))
        .collect();
    let start = cursor.fetch_add(1, Ordering::Relaxed) % backends.len();
    for i in pick_order(&healthy, start) {
        let b = &backends[i];
        let upstream = match TcpStream::connect_timeout(&b.addr, dial_timeout) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("kubenyx-lb: dial {} failed: {e}", b.spec);
                continue;
            }
        };
        let _ = client.set_nodelay(true);
        let _ = upstream.set_nodelay(true);
        let (Ok(client2), Ok(upstream2)) = (client.try_clone(), upstream.try_clone()) else {
            return;
        };
        let back = std::thread::spawn(move || pump(upstream2, client2));
        pump(client, upstream);
        let _ = back.join();
        return;
    }
    // Every backend refused: drop the client — its own retry loop (kubelet,
    // client-go) is the recovery path, and a hung socket would hide the
    // outage from it.
}

// ---------------------------------------------------------------------------
// sd_notify (same shape as kubenyx-ready)
// ---------------------------------------------------------------------------

fn sd_notify_ready() {
    let Ok(sock_path) = std::env::var("NOTIFY_SOCKET") else {
        return;
    };
    let Ok(sock) = UnixDatagram::unbound() else {
        return;
    };
    if let Some(abst) = sock_path.strip_prefix('@') {
        use std::os::linux::net::SocketAddrExt;
        if let Ok(addr) = std::os::unix::net::SocketAddr::from_abstract_name(abst.as_bytes()) {
            let _ = sock.send_to_addr(b"READY=1", &addr);
        }
    } else {
        let _ = sock.send_to(b"READY=1", sock_path);
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    START.set(Instant::now()).ok();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cfg = parse_args(&args).unwrap_or_else(|e| die(&e));

    let backends: Arc<Vec<Backend>> =
        Arc::new(cfg.backends.iter().map(|s| resolve_backend(s)).collect());

    unsafe {
        libc::signal(
            libc::SIGTERM,
            on_drain_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            on_drain_signal as *const () as libc::sighandler_t,
        );
        // A peer resetting mid-write must surface as EPIPE, not kill us.
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let listener = TcpListener::bind(&cfg.listen)
        .unwrap_or_else(|e| die(&format!("bind {}: {e}", cfg.listen)));
    listener
        .set_nonblocking(true)
        .unwrap_or_else(|e| die(&format!("nonblocking listener: {e}")));
    let local = listener
        .local_addr()
        .unwrap_or_else(|e| die(&format!("local_addr: {e}")));
    eprintln!("KUBENYX-LB-LISTEN {local}");
    eprintln!(
        "kubenyx-lb: {} backend(s), probe every {}ms, evict after {} failures",
        backends.len(),
        cfg.probe_interval.as_millis(),
        cfg.fail_threshold
    );

    {
        let backends = backends.clone();
        let policy = ProbePolicy {
            interval: cfg.probe_interval,
            fail_threshold: cfg.fail_threshold,
            http: cfg.probe_http,
            client_cert: cfg.probe_cert.clone().zip(cfg.probe_key.clone()),
        };
        std::thread::spawn(move || health_loop(backends, policy));
    }

    let cursor = Arc::new(AtomicUsize::new(0));
    while !DRAINING.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _peer)) => {
                ACTIVE.fetch_add(1, Ordering::SeqCst);
                let backends = backends.clone();
                let cursor = cursor.clone();
                let dial = cfg.dial_timeout;
                std::thread::spawn(move || {
                    handle(stream, &backends, &cursor, dial);
                    ACTIVE.fetch_sub(1, Ordering::SeqCst);
                });
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(e) => {
                // Transient accept errors (EMFILE under FD exhaustion,
                // ECONNABORTED): log, back off, keep serving — exiting here
                // would turn pressure into an outage.
                eprintln!("kubenyx-lb: accept: {e}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    // Drain: stop accepting (close the listener), give in-flight
    // connections until the deadline, then exit 0 — an orderly stop.
    drop(listener);
    DRAIN_DEADLINE_MS.store(
        elapsed_ms().saturating_add(cfg.drain_timeout.as_millis() as u64),
        Ordering::SeqCst,
    );
    eprintln!(
        "KUBENYX-LB-DRAIN in_flight={}",
        ACTIVE.load(Ordering::SeqCst)
    );
    while ACTIVE.load(Ordering::SeqCst) > 0 && !drain_expired() {
        std::thread::sleep(Duration::from_millis(50));
    }
    eprintln!(
        "kubenyx-lb: drained (in_flight={}), exiting",
        ACTIVE.load(Ordering::SeqCst)
    );
    exit(0);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn parse_defaults_and_backends() {
        let cfg = parse_args(&s(&[
            "--backend",
            "10.0.0.1:6443",
            "--backend",
            "10.0.0.2:6443",
        ]))
        .unwrap();
        assert_eq!(cfg.listen, "127.0.0.1:6444");
        assert_eq!(cfg.backends, vec!["10.0.0.1:6443", "10.0.0.2:6443"]);
        assert_eq!(cfg.probe_interval, Duration::from_millis(500));
        assert_eq!(cfg.fail_threshold, 3);
        assert!(!cfg.probe_http);
    }

    #[test]
    fn parse_overrides() {
        let cfg = parse_args(&s(&[
            "--listen",
            "127.0.0.1:0",
            "--backend",
            "a:1",
            "--probe-interval-ms",
            "50",
            "--fail-threshold",
            "2",
            "--drain-timeout-ms",
            "1000",
            "--probe-http",
        ]))
        .unwrap();
        assert_eq!(cfg.listen, "127.0.0.1:0");
        assert_eq!(cfg.probe_interval, Duration::from_millis(50));
        assert_eq!(cfg.fail_threshold, 2);
        assert_eq!(cfg.drain_timeout, Duration::from_millis(1000));
        assert!(cfg.probe_http);
    }

    #[test]
    fn parse_rejects_bad_input() {
        assert!(parse_args(&s(&[])).is_err(), "no backends");
        assert!(parse_args(&s(&["--backend"])).is_err(), "missing value");
        assert!(parse_args(&s(&["--backend", "a:1", "--fail-threshold", "0"])).is_err());
        assert!(parse_args(&s(&["--backend", "a:1", "--probe-interval-ms", "x"])).is_err());
        assert!(parse_args(&s(&["--frob"])).is_err(), "unknown flag");
        // Probe client-cert flags travel as a pair.
        assert!(parse_args(&s(&["--backend", "a:1", "--probe-cert", "/c.crt"])).is_err());
        assert!(parse_args(&s(&["--backend", "a:1", "--probe-key", "/c.key"])).is_err());
        assert!(parse_args(&s(&[
            "--backend",
            "a:1",
            "--probe-cert",
            "/c.crt",
            "--probe-key",
            "/c.key"
        ]))
        .is_ok());
    }

    #[test]
    fn pick_order_healthy_first_rotated() {
        // healthy: 0,2 — cursor 1 rotates to [1,2,0] then partitions.
        assert_eq!(pick_order(&[true, false, true], 1), vec![2, 0, 1]);
        // all healthy: pure rotation.
        assert_eq!(pick_order(&[true, true, true], 2), vec![2, 0, 1]);
        // none healthy: still tries everything (last-resort pass).
        assert_eq!(pick_order(&[false, false], 0), vec![0, 1]);
        // single backend.
        assert_eq!(pick_order(&[true], 7), vec![0]);
    }
}
