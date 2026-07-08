//! Firecracker snapshot/restore for Kubenyx microVMs (third boot-path tool,
//! air/v0.2/snapshot-restore.org). Snapshot a cluster-ready guest once, then
//! recreate a live cluster in ~75ms — cheaper than any cold boot can get.
//!
//!   kubenyx-snap take   --runner <microvm-run> --out DIR
//!   kubenyx-snap resume --snapshot DIR [--firecracker BIN]
//!   kubenyx-snap cycle  --snapshot DIR [-n N]
//!
//! `take` spawns the stock microvm.nix runner (which already passes
//! `--api-sock kubenyx.sock` in CWD), waits for the KUBENYX-CLUSTER-READY
//! console marker, pauses the VM and writes snap.vmstate + snap.mem, then
//! kills the VMM to free the tap. `resume` starts a fresh firecracker with
//! only an API socket, loads the snapshot, sends UDP time pokes so the
//! in-guest kubenyx-clockstep daemon can fix the stale wall clock, and
//! reports milliseconds to the first apiserver TLS response. `cycle` is the
//! recreation benchmark: N consecutive resume→verify→kill rounds.
//!
//! Gotchas encoded from the validation session: API socket paths must stay
//! under SUN_LEN=108 (always pass a relative path and spawn from a short
//! CWD if needed); the restore VMM's --enable-pci must match the snapshot;
//! the snapshot must be taken with the snapshot-safe kernel params (AMX/CET
//! masked) or the restored guest #GPs in XRSTORS on AMX hosts.

use std::io::{Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{exit, Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The VMM we spawned and still own. Every exit path — die(), SIGINT,
/// SIGTERM — must kill it, or an interrupted `take` leaves a headless
/// firecracker squatting on the tap (found the hard way: Ctrl-C during
/// take's silent boot wait leaked the VM every time).
static OWNED_VMM: AtomicI32 = AtomicI32::new(0);

fn kill_owned_vmm() {
    let pid = OWNED_VMM.swap(0, Ordering::SeqCst);
    if pid > 0 {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
            libc::waitpid(pid, std::ptr::null_mut(), 0);
        }
    }
}

extern "C" fn on_signal(_sig: libc::c_int) {
    // kill(2) and _exit(2) are async-signal-safe; nothing else here is
    // allowed to allocate or lock.
    let pid = OWNED_VMM.swap(0, Ordering::SeqCst);
    if pid > 0 {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    unsafe { libc::_exit(130) }
}

fn install_signal_cleanup() {
    unsafe {
        libc::signal(libc::SIGINT, on_signal as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as libc::sighandler_t);
        libc::signal(libc::SIGHUP, on_signal as libc::sighandler_t);
    }
}

fn die(msg: &str) -> ! {
    kill_owned_vmm();
    eprintln!("kubenyx-snap: {msg}");
    exit(2);
}

// ---- minimal HTTP/1.1 over the firecracker unix API socket -----------------

fn api(sock: &Path, method: &str, path: &str, body: &str) -> (u16, String) {
    let mut s = UnixStream::connect(sock)
        .unwrap_or_else(|e| die(&format!("connect {}: {e}", sock.display())));
    // Long ceiling: /snapshot/create writes the full mem file inside this
    // request. Never rely on EOF though — firecracker's HTTP server ignores
    // Connection: close and keeps the socket open, so reading to EOF would
    // stall every call until this timeout. Read exactly Content-Length.
    s.set_read_timeout(Some(Duration::from_secs(60))).ok();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes())
        .unwrap_or_else(|e| die(&format!("API write: {e}")));

    let mut raw = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    let header_end = loop {
        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
        match s.read(&mut chunk) {
            Ok(0) => break raw.len(),
            Ok(n) => raw.extend_from_slice(&chunk[..n]),
            Err(e) => die(&format!("API read: {e}")),
        }
    };
    let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let content_length: usize = headers
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok())?
        })
        .unwrap_or(0);
    while raw.len() < header_end + content_length {
        match s.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => raw.extend_from_slice(&chunk[..n]),
            Err(e) => die(&format!("API read: {e}")),
        }
    }
    let status: u16 = headers
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or_else(|| die(&format!("bad API response: {headers:.120}")));
    let resp_body = String::from_utf8_lossy(&raw[header_end..]).to_string();
    (status, resp_body)
}

fn api_expect(sock: &Path, method: &str, path: &str, body: &str) {
    let (status, resp) = api(sock, method, path, body);
    if !(200..300).contains(&status) {
        die(&format!("{method} {path} -> {status}: {resp:.300}"));
    }
}

// ---- apiserver liveness probe (any TLS-authenticated HTTP answer counts) ---

/// The guest CA lives in the guest's tmpfs and is unreachable from the host
/// by design; the probe only proves the apiserver is serving TLS+HTTP (a
/// 401 is a healthy answer for an unauthenticated client).
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

fn tls_probe_config() -> Arc<rustls::ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    Arc::new(
        rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .expect("tls versions")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerify(provider)))
            .with_no_client_auth(),
    )
}

fn probe_once(config: &Arc<rustls::ClientConfig>, addr: &str, host: &str) -> bool {
    let sockaddr: std::net::SocketAddr = match addr.parse() {
        Ok(a) => a,
        Err(_) => die(&format!("bad probe address {addr}")),
    };
    let Ok(stream) = TcpStream::connect_timeout(&sockaddr, Duration::from_millis(150)) else {
        return false;
    };
    stream.set_read_timeout(Some(Duration::from_millis(500))).ok();
    stream.set_write_timeout(Some(Duration::from_millis(500))).ok();
    let name = rustls::pki_types::ServerName::try_from(host.to_string())
        .unwrap_or_else(|_| die("bad probe host"));
    let Ok(conn) = rustls::ClientConnection::new(config.clone(), name) else {
        return false;
    };
    let mut tls = rustls::StreamOwned::new(conn, stream);
    let req = format!("GET /livez HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    if tls.write_all(req.as_bytes()).is_err() {
        return false;
    }
    let mut buf = [0u8; 16];
    matches!(tls.read(&mut buf), Ok(n) if n >= 12 && buf.starts_with(b"HTTP/"))
}

fn wait_api(config: &Arc<rustls::ClientConfig>, addr: &str, timeout: Duration) -> Option<Duration> {
    let host = addr.split(':').next().unwrap_or(addr).to_string();
    let start = Instant::now();
    while start.elapsed() < timeout {
        if probe_once(config, addr, &host) {
            return Some(start.elapsed());
        }
        std::thread::sleep(Duration::from_millis(3));
    }
    None
}

// ---- time pokes (see kubenyx-clockstep for the datagram format) ------------

fn send_time_pokes(addr: &str, count: u32, interval: Duration) {
    let Ok(sock) = UdpSocket::bind("0.0.0.0:0") else {
        eprintln!("kubenyx-snap: warning: cannot bind poke socket");
        return;
    };
    for i in 0..count {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).expect("clock");
        let mut pkt = Vec::with_capacity(17);
        pkt.extend_from_slice(b"KNXT1");
        pkt.extend_from_slice(&(now.as_secs() as i64).to_le_bytes());
        pkt.extend_from_slice(&(now.subsec_nanos() as i32).to_le_bytes());
        let _ = sock.send_to(&pkt, addr);
        if i + 1 < count {
            std::thread::sleep(interval);
        }
    }
}

// ---- subcommands ------------------------------------------------------------

struct Flags(Vec<String>);

impl Flags {
    fn get(&self, name: &str) -> Option<String> {
        self.0.iter().position(|a| a == name).map(|i| {
            self.0
                .get(i + 1)
                .cloned()
                .unwrap_or_else(|| die(&format!("{name} needs a value")))
        })
    }
    fn has(&self, name: &str) -> bool {
        self.0.iter().any(|a| a == name)
    }
}

fn wait_marker(log: &Path, marker: &str, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Ok(data) = std::fs::read(log) {
            // The console stream interleaves ANSI escapes; a plain bytes
            // search still matches the marker itself.
            if data.windows(marker.len()).any(|w| w == marker.as_bytes()) {
                return true;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn kill_wait(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn cmd_take(flags: &Flags) {
    let runner = flags.get("--runner").unwrap_or_else(|| die("take requires --runner <microvm-run>"));
    let out = PathBuf::from(flags.get("--out").unwrap_or_else(|| "snapshot".into()));
    let marker = flags.get("--marker").unwrap_or_else(|| "KUBENYX-CLUSTER-READY".into());
    let wait_secs: u64 = flags.get("--wait-secs").map(|v| v.parse().unwrap_or_else(|_| die("bad --wait-secs"))).unwrap_or(120);
    let settle_ms: u64 = flags.get("--settle-ms").map(|v| v.parse().unwrap_or_else(|_| die("bad --settle-ms"))).unwrap_or(2000);

    std::fs::create_dir_all(&out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let out = out.canonicalize().unwrap_or_else(|e| die(&format!("canonicalize: {e}")));
    let console = out.join("take-console.log");
    let sock = PathBuf::from("kubenyx.sock"); // dropped by the runner in CWD
    let _ = std::fs::remove_file(&sock);

    let log_file = std::fs::File::create(&console).unwrap_or_else(|e| die(&format!("create console log: {e}")));
    let mut vm = Command::new(&runner)
        .stdout(Stdio::from(log_file.try_clone().expect("clone log fd")))
        .stderr(Stdio::from(log_file))
        .stdin(Stdio::null())
        .spawn()
        .unwrap_or_else(|e| die(&format!("spawn {runner}: {e}")));
    OWNED_VMM.store(vm.id() as i32, Ordering::SeqCst);

    eprintln!(
        "take: booting (~10s), waiting for '{marker}' (console: {})",
        console.display()
    );
    if !wait_marker(&console, &marker, Duration::from_secs(wait_secs)) {
        die(&format!("'{marker}' not seen within {wait_secs}s"));
    }
    // Let trailing addons (coredns) settle so restored clones are fully idle.
    std::thread::sleep(Duration::from_millis(settle_ms));

    api_expect(&sock, "PATCH", "/vm", r#"{"state":"Paused"}"#);
    let body = format!(
        r#"{{"snapshot_type":"Full","snapshot_path":"{}","mem_file_path":"{}"}}"#,
        out.join("snap.vmstate").display(),
        out.join("snap.mem").display()
    );
    let t = Instant::now();
    api_expect(&sock, "PUT", "/snapshot/create", &body);
    eprintln!("take: snapshot written in {:?} -> {}", t.elapsed(), out.display());

    kill_wait(&mut vm); // frees the tap for future resumes
    OWNED_VMM.store(0, Ordering::SeqCst);
    let _ = std::fs::remove_file(&sock);
    println!("{}", out.display());
}

struct ResumeTimings {
    spawn_to_sock: Duration,
    load: Duration,
    load_to_api: Duration,
}

fn resume_once(
    firecracker: &str,
    snapshot: &Path,
    api_sock: &Path,
    probe_addr: &str,
    poke_addr: &str,
    enable_pci: bool,
    config: &Arc<rustls::ClientConfig>,
) -> (Child, ResumeTimings) {
    let _ = std::fs::remove_file(api_sock);
    let t_spawn = Instant::now();
    let mut cmd = Command::new(firecracker);
    cmd.arg("--api-sock").arg(api_sock);
    if enable_pci {
        cmd.arg("--enable-pci");
    }
    // Keep the restored guest's serial console: post-restore markers
    // (KUBENYX-CLOCKSTEP, crng reseed) land here.
    let console = std::fs::File::create("resume-console.log")
        .unwrap_or_else(|e| die(&format!("create resume-console.log: {e}")));
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::from(console.try_clone().expect("clone console fd")))
        .stderr(Stdio::from(console))
        .spawn()
        .unwrap_or_else(|e| die(&format!("spawn {firecracker}: {e}")));
    OWNED_VMM.store(child.id() as i32, Ordering::SeqCst);

    while !api_sock.exists() {
        if t_spawn.elapsed() > Duration::from_secs(5) {
            die("API socket did not appear within 5s");
        }
        std::thread::sleep(Duration::from_micros(200));
    }
    let spawn_to_sock = t_spawn.elapsed();

    let body = format!(
        r#"{{"snapshot_path":"{}","mem_backend":{{"backend_type":"File","backend_path":"{}"}},"resume_vm":true}}"#,
        snapshot.join("snap.vmstate").display(),
        snapshot.join("snap.mem").display()
    );
    let t_load = Instant::now();
    api_expect(api_sock, "PUT", "/snapshot/load", &body);
    let load = t_load.elapsed();

    // Fix the guest's stale wall clock the moment it is running again.
    send_time_pokes(poke_addr, 5, Duration::from_millis(100));

    let t_api = Instant::now();
    let Some(load_to_api) = wait_api(config, probe_addr, Duration::from_secs(10)) else {
        die("apiserver did not answer within 10s of restore");
    };
    let _ = t_api;

    (child, ResumeTimings { spawn_to_sock, load, load_to_api })
}

fn resume_flags(flags: &Flags) -> (String, PathBuf, PathBuf, String, String, bool) {
    let snapshot = PathBuf::from(flags.get("--snapshot").unwrap_or_else(|| "snapshot".into()));
    if !snapshot.join("snap.vmstate").exists() {
        die(&format!("{}/snap.vmstate not found", snapshot.display()));
    }
    let firecracker = flags.get("--firecracker").unwrap_or_else(|| "firecracker".into());
    // Relative by default: an absolute path under a deep workdir exceeds
    // SUN_LEN=108 and firecracker refuses to bind.
    let api_sock = PathBuf::from(flags.get("--api-sock").unwrap_or_else(|| "kubenyx-resume.sock".into()));
    let probe_addr = flags.get("--probe").unwrap_or_else(|| "10.100.0.2:6443".into());
    let poke_addr = flags.get("--poke").unwrap_or_else(|| "10.100.0.2:10123".into());
    let enable_pci = !flags.has("--no-pci");
    (firecracker, snapshot, api_sock, probe_addr, poke_addr, enable_pci)
}

fn cmd_resume(flags: &Flags) {
    let (firecracker, snapshot, api_sock, probe_addr, poke_addr, enable_pci) = resume_flags(flags);
    let config = tls_probe_config();
    let (child, t) = resume_once(&firecracker, &snapshot, &api_sock, &probe_addr, &poke_addr, enable_pci, &config);
    println!(
        "spawn_to_sock_ms={:.1} load_ms={:.1} load_to_api_ms={:.1} total_ms={:.1} pid={} api_sock={}",
        t.spawn_to_sock.as_secs_f64() * 1e3,
        t.load.as_secs_f64() * 1e3,
        t.load_to_api.as_secs_f64() * 1e3,
        (t.load + t.load_to_api).as_secs_f64() * 1e3,
        child.id(),
        api_sock.display(),
    );
    // The VMM deliberately stays running (reparented to init when we
    // exit); killing the printed pid frees the tap. Disown it so the
    // exit paths don't reap it.
    OWNED_VMM.store(0, Ordering::SeqCst);
    std::mem::forget(child);
}

fn cmd_cycle(flags: &Flags) {
    let (firecracker, snapshot, api_sock, probe_addr, poke_addr, enable_pci) = resume_flags(flags);
    let n: u32 = flags.get("-n").map(|v| v.parse().unwrap_or_else(|_| die("bad -n"))).unwrap_or(5);
    let config = tls_probe_config();

    let mut totals: Vec<f64> = Vec::with_capacity(n as usize);
    for round in 1..=n {
        let (mut child, t) = resume_once(&firecracker, &snapshot, &api_sock, &probe_addr, &poke_addr, enable_pci, &config);
        let total_ms = (t.load + t.load_to_api).as_secs_f64() * 1e3;
        println!(
            "round={round} load_ms={:.1} load_to_api_ms={:.1} total_ms={total_ms:.1}",
            t.load.as_secs_f64() * 1e3,
            t.load_to_api.as_secs_f64() * 1e3,
        );
        totals.push(total_ms);
        kill_wait(&mut child);
        OWNED_VMM.store(0, Ordering::SeqCst);
        let _ = std::fs::remove_file(&api_sock);
        // Give the kernel a beat to tear the tap attachment down.
        std::thread::sleep(Duration::from_millis(200));
    }
    totals.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = totals[totals.len() / 2];
    println!(
        "cycles={n} median_total_ms={median:.1} min={:.1} max={:.1}",
        totals.first().unwrap(),
        totals.last().unwrap()
    );
}

fn main() {
    install_signal_cleanup();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first().map(String::as_str) else {
        die("usage: kubenyx-snap take|resume|cycle [flags]");
    };
    let flags = Flags(args[1..].to_vec());
    match cmd {
        "take" => cmd_take(&flags),
        "resume" => cmd_resume(&flags),
        "cycle" => cmd_cycle(&flags),
        other => die(&format!("unknown subcommand {other}")),
    }
}
