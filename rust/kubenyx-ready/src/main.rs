//! Kubernetes control-plane binaries have no sd_notify support
//! (kubernetes/kubernetes#8311). This wrapper supplies it: exec the
//! component, probe its health endpoint every 10ms with a persistent-config
//! TLS client, then signal READY=1.
//!
//! Replaces the shell/curl version: 200ms poll granularity and a fork per
//! probe became 10ms and zero forks — readiness is detected within
//! milliseconds of the endpoint turning healthy, which compounds across
//! every ordered unit on the boot path.
//!
//! `--wait` (no `--` command) turns the wrapper into a blocking probe:
//! poll the URL every 10ms, exit 0 on the first 2xx. Built for
//! ExecStartPre= gates where the needed predicate is an API response,
//! not a unit state — e.g. "the RBAC authorizer's informers have caught
//! up far enough to admit THIS principal to THIS resource", which no
//! amount of After= ordering can express. The caller's TimeoutStartSec
//! bounds the wait.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixDatagram;
use std::process::{exit, Command};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::time::Duration;

static CHILD_PID: AtomicI32 = AtomicI32::new(0);

extern "C" fn forward_signal(sig: libc::c_int) {
    let pid = CHILD_PID.load(Ordering::SeqCst);
    if pid > 0 {
        unsafe {
            libc::kill(pid, sig);
        }
    }
}

struct Probe {
    host: String,
    port: u16,
    path: String,
    tls: bool,
    tls_config: Option<Arc<rustls::ClientConfig>>,
}

fn die(msg: &str) -> ! {
    eprintln!("kubenyx-ready: {msg}");
    exit(2);
}

/// Accepts "no client verification" — probes may target self-signed
/// component endpoints (kcm/scheduler healthz) where the identity is
/// irrelevant: only liveness of the port matters.
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
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

fn load_pem_certs(path: &str) -> Vec<rustls::pki_types::CertificateDer<'static>> {
    let data = std::fs::read(path).unwrap_or_else(|e| die(&format!("read {path}: {e}")));
    rustls_pemfile::certs(&mut data.as_slice())
        .collect::<Result<Vec<_>, _>>()
        .unwrap_or_else(|e| die(&format!("parse {path}: {e}")))
}

fn build_probe(url: &str, cacert: Option<&str>, cert: Option<&str>, key: Option<&str>, insecure: bool) -> Probe {
    if let Some(path) = url.strip_prefix("unix://") {
        // Socket-connectable probe: gRPC servers (kine, etcd shims) have no
        // HTTP health endpoint on the socket; accepting a connection is the
        // readiness signal that matters to the apiserver.
        return Probe {
            host: path.to_string(),
            port: 0,
            path: String::new(),
            tls: false,
            tls_config: None,
        };
    }
    let (tls, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        die(&format!("unsupported URL {url}"));
    };
    let (hostport, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let (host, port) = hostport
        .rsplit_once(':')
        .map(|(h, p)| (h.to_string(), p.parse::<u16>().unwrap_or_else(|_| die("bad port"))))
        .unwrap_or_else(|| (hostport.to_string(), if tls { 443 } else { 80 }));

    let tls_config = if tls {
        let provider = rustls::crypto::ring::default_provider();
        let provider = Arc::new(provider);
        let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .expect("tls versions");
        let builder = if insecure {
            builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(NoVerify(provider)))
        } else if let Some(ca) = cacert {
            let mut roots = rustls::RootCertStore::empty();
            for c in load_pem_certs(ca) {
                roots.add(c).unwrap_or_else(|e| die(&format!("bad CA cert: {e}")));
            }
            builder.with_root_certificates(roots)
        } else {
            // A silent NoVerify fallback would let future call sites skip
            // verification by accident.
            die("https probe requires --cacert or --insecure")
        };
        let config = match (cert, key) {
            (Some(c), Some(k)) => {
                let certs = load_pem_certs(c);
                let key_data = std::fs::read(k).unwrap_or_else(|e| die(&format!("read {k}: {e}")));
                let key_der = rustls_pemfile::private_key(&mut key_data.as_slice())
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| die(&format!("no private key in {k}")));
                builder
                    .with_client_auth_cert(certs, key_der)
                    .unwrap_or_else(|e| die(&format!("client auth: {e}")))
            }
            _ => builder.with_no_client_auth(),
        };
        Some(Arc::new(config))
    } else {
        None
    };

    Probe { host, port, path, tls, tls_config }
}

impl Probe {
    fn check(&self) -> bool {
        if self.port == 0 {
            return std::os::unix::net::UnixStream::connect(&self.host).is_ok();
        }
        let addr = format!("{}:{}", self.host, self.port);
        let Ok(stream) = TcpStream::connect(&addr) else {
            return false;
        };
        stream.set_read_timeout(Some(Duration::from_millis(1500))).ok();
        stream.set_write_timeout(Some(Duration::from_millis(1500))).ok();
        let req = format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
            self.path, self.host
        );
        let mut buf = [0u8; 64];
        let n = if self.tls {
            let config = self.tls_config.as_ref().unwrap().clone();
            let name = rustls::pki_types::ServerName::try_from(self.host.clone())
                .unwrap_or_else(|_| die("bad server name"));
            let Ok(conn) = rustls::ClientConnection::new(config, name) else {
                return false;
            };
            let mut tls = rustls::StreamOwned::new(conn, stream);
            if tls.write_all(req.as_bytes()).is_err() {
                return false;
            }
            match tls.read(&mut buf) {
                Ok(n) => n,
                Err(_) => return false,
            }
        } else {
            let mut s = stream;
            if s.write_all(req.as_bytes()).is_err() {
                return false;
            }
            match s.read(&mut buf) {
                Ok(n) => n,
                Err(_) => return false,
            }
        };
        // "HTTP/1.1 200 ..." — only 2xx counts as ready.
        n >= 12 && &buf[9..12] == b"200"
    }
}

fn sd_notify_ready() {
    let Ok(sock_path) = std::env::var("NOTIFY_SOCKET") else {
        return;
    };
    let Ok(sock) = UnixDatagram::unbound() else {
        return;
    };
    if let Some(abst) = sock_path.strip_prefix('@') {
        // Abstract namespace: std rejects NUL bytes in Path-based addresses,
        // so this needs the explicit abstract-address API.
        use std::os::linux::net::SocketAddrExt;
        if let Ok(addr) = std::os::unix::net::SocketAddr::from_abstract_name(abst.as_bytes()) {
            let _ = sock.send_to_addr(b"READY=1", &addr);
        }
    } else {
        let _ = sock.send_to(b"READY=1", sock_path);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut url = None;
    let mut cacert = None;
    let mut cert = None;
    let mut key = None;
    let mut insecure = false;
    let mut wait_only = false;
    let mut cmd_at = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--url" => {
                url = Some(args.get(i + 1).cloned().unwrap_or_else(|| die("--url needs a value")));
                i += 2;
            }
            "--cacert" => {
                cacert = Some(args.get(i + 1).cloned().unwrap_or_else(|| die("--cacert needs a value")));
                i += 2;
            }
            "--cert" => {
                cert = Some(args.get(i + 1).cloned().unwrap_or_else(|| die("--cert needs a value")));
                i += 2;
            }
            "--key" => {
                key = Some(args.get(i + 1).cloned().unwrap_or_else(|| die("--key needs a value")));
                i += 2;
            }
            "--insecure" => {
                insecure = true;
                i += 1;
            }
            "--wait" => {
                wait_only = true;
                i += 1;
            }
            "--" => {
                cmd_at = Some(i + 1);
                break;
            }
            other => die(&format!("unknown flag {other}")),
        }
    }
    let url = url.unwrap_or_else(|| die("--url is required"));
    if wait_only {
        if cmd_at.is_some() {
            die("--wait takes no -- command");
        }
        let probe = build_probe(&url, cacert.as_deref(), cert.as_deref(), key.as_deref(), insecure);
        while !probe.check() {
            std::thread::sleep(Duration::from_millis(10));
        }
        exit(0);
    }
    let cmd_at = cmd_at.unwrap_or_else(|| die("missing -- command"));
    if cmd_at >= args.len() {
        die("empty command after --");
    }

    let probe = build_probe(&url, cacert.as_deref(), cert.as_deref(), key.as_deref(), insecure);

    let mut child = Command::new(&args[cmd_at])
        .args(&args[cmd_at + 1..])
        .spawn()
        .unwrap_or_else(|e| die(&format!("spawn {}: {e}", args[cmd_at])));
    CHILD_PID.store(child.id() as i32, Ordering::SeqCst);

    unsafe {
        libc::signal(libc::SIGTERM, forward_signal as libc::sighandler_t);
        libc::signal(libc::SIGINT, forward_signal as libc::sighandler_t);
    }

    let mut notified = false;
    loop {
        if let Some(status) = child.try_wait().unwrap_or(None) {
            // Child gone: propagate its exit semantics.
            exit(exit_code(status));
        }
        if !notified && probe.check() {
            sd_notify_ready();
            notified = true;
        }
        if notified {
            // Ready: block on the child instead of spinning.
            let status = child.wait().unwrap_or_else(|e| die(&format!("wait: {e}")));
            exit(exit_code(status));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn exit_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1))
}
