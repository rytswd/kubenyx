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

/// The VMMs we spawned and still own (single-VM verbs use one slot; the
/// mesh verbs use the table). Every exit path — die(), SIGINT, SIGTERM —
/// must kill them, or an interrupted `take` leaves a headless firecracker
/// squatting on the tap (found the hard way: Ctrl-C during take's silent
/// boot wait leaked the VM every time). Fixed-size atomics: the signal
/// handler may not allocate or lock.
const OWNED_MAX: usize = 16;
static OWNED_VMMS: [AtomicI32; OWNED_MAX] = [const { AtomicI32::new(0) }; OWNED_MAX];

fn own_vmm(pid: i32) {
    for slot in &OWNED_VMMS {
        if slot.compare_exchange(0, pid, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
            return;
        }
    }
    die("more than 16 owned VMMs — raise OWNED_MAX");
}

fn disown_vmm(pid: i32) {
    for slot in &OWNED_VMMS {
        let _ = slot.compare_exchange(pid, 0, Ordering::SeqCst, Ordering::SeqCst);
    }
}

fn kill_owned_vmm() {
    for slot in &OWNED_VMMS {
        let pid = slot.swap(0, Ordering::SeqCst);
        if pid > 0 {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
                libc::waitpid(pid, std::ptr::null_mut(), 0);
            }
        }
    }
}

extern "C" fn on_signal(_sig: libc::c_int) {
    // kill(2) and _exit(2) are async-signal-safe; nothing else here is
    // allowed to allocate or lock.
    for slot in &OWNED_VMMS {
        let pid = slot.swap(0, Ordering::SeqCst);
        if pid > 0 {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
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
    stream.set_nodelay(true).ok();
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
        std::thread::sleep(Duration::from_millis(1));
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
    // Two modes: --runner boots a fresh VM, snapshots it and tears it
    // down (a one-shot snapshot factory); --sock attaches to a VM that is
    // ALREADY running (e.g. `nix run .#microvm-firecracker` in another
    // terminal), snapshots it and resumes it in place.
    if flags.get("--runner").is_none() {
        return cmd_take_attached(flags);
    }
    let runner = flags.get("--runner").unwrap();
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
    own_vmm(vm.id() as i32);

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

    let vm_pid = vm.id() as i32;
    kill_wait(&mut vm); // frees the tap for future resumes
    disown_vmm(vm_pid);
    let _ = std::fs::remove_file(&sock);
    println!("{}", out.display());
}

fn cmd_take_attached(flags: &Flags) {
    let sock = PathBuf::from(flags.get("--sock").unwrap_or_else(|| "kubenyx.sock".into()));
    if !sock.exists() {
        die(&format!(
            "{} not found — either run from the directory the VM was started in, \
             pass --sock, or pass --runner to boot a fresh VM instead",
            sock.display()
        ));
    }
    let out = PathBuf::from(flags.get("--out").unwrap_or_else(|| "snapshot".into()));
    std::fs::create_dir_all(&out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let out = out.canonicalize().unwrap_or_else(|e| die(&format!("canonicalize: {e}")));

    // Pause -> snapshot -> resume: the source VM never observes the gap
    // (monotonic time stops with it) and keeps running afterwards.
    api_expect(&sock, "PATCH", "/vm", r#"{"state":"Paused"}"#);
    let body = format!(
        r#"{{"snapshot_type":"Full","snapshot_path":"{}","mem_file_path":"{}"}}"#,
        out.join("snap.vmstate").display(),
        out.join("snap.mem").display()
    );
    let t = Instant::now();
    api_expect(&sock, "PUT", "/snapshot/create", &body);
    api_expect(&sock, "PATCH", "/vm", r#"{"state":"Resumed"}"#);
    eprintln!(
        "take: snapshot written in {:?} -> {} (source VM resumed and still owns the tap; \
         stop it before `kubenyx-snap resume`)",
        t.elapsed(),
        out.display()
    );
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
    own_vmm(child.id() as i32);

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

    // Fix the guest's stale wall clock — off the measured path: the poke
    // thread overlaps the API probe and is joined before returning.
    let poke_addr_owned = poke_addr.to_string();
    let poke_handle = std::thread::spawn(move || {
        send_time_pokes(&poke_addr_owned, 3, Duration::from_millis(50))
    });

    let t_api = Instant::now();
    let Some(load_to_api) = wait_api(config, probe_addr, Duration::from_secs(10)) else {
        die("apiserver did not answer within 10s of restore");
    };
    let _ = t_api;
    let _ = poke_handle.join();

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
    // Machine-readable timings on stdout; the how-to-reach-it summary on
    // stderr so scripts can parse stdout undisturbed.
    println!(
        "spawn_to_sock_ms={:.1} load_ms={:.1} load_to_api_ms={:.1} total_ms={:.1} pid={} api_sock={}",
        t.spawn_to_sock.as_secs_f64() * 1e3,
        t.load.as_secs_f64() * 1e3,
        t.load_to_api.as_secs_f64() * 1e3,
        (t.load + t.load_to_api).as_secs_f64() * 1e3,
        child.id(),
        api_sock.display(),
    );
    let guest_ip = probe_addr.split(':').next().unwrap_or("10.100.0.2");
    eprintln!("cluster:    https://{probe_addr}");
    eprintln!("kubeconfig: curl -s {guest_ip}:10124 > kubenyx.kubeconfig && kubectl --kubeconfig kubenyx.kubeconfig get nodes");
    eprintln!("stop:       kill {}", child.id());
    // The VMM deliberately stays running (reparented to init when we
    // exit); killing the printed pid frees the tap. Disown it so the
    // exit paths don't reap it.
    disown_vmm(child.id() as i32);
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
            "round={round} spawn_to_sock_ms={:.1} load_ms={:.1} load_to_api_ms={:.1} total_ms={total_ms:.1}",
            t.spawn_to_sock.as_secs_f64() * 1e3,
            t.load.as_secs_f64() * 1e3,
            t.load_to_api.as_secs_f64() * 1e3,
        );
        totals.push(total_ms);
        let child_pid = child.id() as i32;
        kill_wait(&mut child);
        disown_vmm(child_pid);
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

// ---- mesh verbs --------------------------------------------------------------
//
// A microvm-cluster mesh is N firecrackers, one per node, each in its own
// $RUN/<node>/ workdir with `kubenyx.sock` (per-node taps on the shared
// bridge, so concurrent restores never collide). The consistency model:
// mesh-take pauses EVERY node before snapshotting ANY — monotonic clocks
// freeze together, so the guests never observe the cut, and inter-VM TCP
// survives restore (both endpoints resume; the pause is just delay to them).

#[derive(Clone)]
struct MeshNode {
    name: String,
    ip: String,
}

/// server=10.100.0.2, agentN=10.100.0.(2+N) — the microvm-cluster address
/// convention. Anything else needs an explicit --node name=ip.
fn conventional_ip(name: &str) -> Option<String> {
    if name == "server" {
        return Some("10.100.0.2".into());
    }
    name.strip_prefix("agent")
        .and_then(|n| n.parse::<u32>().ok())
        .map(|n| format!("10.100.0.{}", 2 + n))
}


/// The cluster launcher's per-node runners bind `<node>.sock`; the plain
/// single-VM runner binds `kubenyx.sock`. Accept either.
fn node_sock(run_dir: &Path, name: &str) -> PathBuf {
    let named = run_dir.join(name).join(format!("{name}.sock"));
    if named.exists() {
        return named;
    }
    run_dir.join(name).join("kubenyx.sock")
}

fn mesh_nodes(flags: &Flags, run_dir: Option<&Path>) -> Vec<MeshNode> {
    // Explicit --node name=ip flags win; otherwise discover the node
    // subdirs (mesh-take) and apply the address convention.
    let mut explicit: Vec<MeshNode> = Vec::new();
    let mut i = 0;
    while i < flags.0.len() {
        if flags.0[i] == "--node" {
            let v = flags.0.get(i + 1).cloned().unwrap_or_else(|| die("--node needs name=ip"));
            let (name, ip) = v.split_once('=').unwrap_or_else(|| die(&format!("--node {v}: expected name=ip")));
            explicit.push(MeshNode { name: name.into(), ip: ip.into() });
            i += 2;
        } else {
            i += 1;
        }
    }
    let mut nodes = if !explicit.is_empty() {
        explicit
    } else if let Some(dir) = run_dir {
        let mut found: Vec<MeshNode> = std::fs::read_dir(dir)
            .unwrap_or_else(|e| die(&format!("read {}: {e}", dir.display())))
            .filter_map(|e| e.ok())
            .filter(|e| {
                let p = e.path();
                let n = e.file_name().to_string_lossy().into_owned();
                p.join(format!("{n}.sock")).exists() || p.join("kubenyx.sock").exists()
            })
            .map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let ip = conventional_ip(&name)
                    .unwrap_or_else(|| die(&format!("cannot infer address for node '{name}' — pass --node {name}=<ip>")));
                MeshNode { name, ip }
            })
            .collect();
        found.sort_by(|a, b| a.name.cmp(&b.name));
        found
    } else {
        Vec::new()
    };
    if nodes.is_empty() {
        die("no mesh nodes found (no --node flags and no node workdirs with kubenyx.sock)");
    }
    // Server first: it is the API endpoint the resume probe waits on.
    nodes.sort_by_key(|n| n.name != "server");
    nodes
}

fn write_manifest(out: &Path, nodes: &[MeshNode]) {
    let body: String = nodes.iter().map(|n| format!("{} {}\n", n.name, n.ip)).collect();
    std::fs::write(out.join("manifest"), body)
        .unwrap_or_else(|e| die(&format!("write manifest: {e}")));
}

fn read_manifest(dir: &Path) -> Vec<MeshNode> {
    let data = std::fs::read_to_string(dir.join("manifest"))
        .unwrap_or_else(|e| die(&format!("read {}/manifest: {e}", dir.display())));
    data.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let (name, ip) = l.split_once(' ').unwrap_or_else(|| die(&format!("bad manifest line: {l}")));
            MeshNode { name: name.into(), ip: ip.into() }
        })
        .collect()
}

/// Kill the mesh's VMMs by workdir: each node's firecracker runs with
/// CWD $RUN/<node> (the launcher's layout), which is the only reliable
/// handle we have on processes someone else spawned.
fn kill_mesh_vmms(run_dir: &Path, nodes: &[MeshNode]) {
    let want: Vec<PathBuf> = nodes.iter().map(|n| run_dir.join(&n.name)).collect();
    let Ok(proc_dir) = std::fs::read_dir("/proc") else { return };
    for entry in proc_dir.filter_map(|e| e.ok()) {
        let pid_str = entry.file_name().to_string_lossy().into_owned();
        let Ok(pid) = pid_str.parse::<i32>() else { continue };
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if !comm.trim_end().ends_with("firecracker") && comm.trim_end() != "microvm@kubenyx" {
            continue;
        }
        let Ok(cwd) = std::fs::read_link(format!("/proc/{pid}/cwd")) else { continue };
        if want.iter().any(|w| w == &cwd) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

fn cmd_mesh_take(flags: &Flags) {
    let run_dir = PathBuf::from(flags.get("--run-dir").unwrap_or_else(|| "/tmp/kubenyx-cluster".into()));
    let out = PathBuf::from(flags.get("--out").unwrap_or_else(|| "mesh-snapshot".into()));
    let nodes = mesh_nodes(flags, Some(&run_dir));
    std::fs::create_dir_all(&out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let out = out.canonicalize().unwrap_or_else(|e| die(&format!("canonicalize: {e}")));

    // Pause EVERYTHING first: this is the consistent cut. Each PATCH is
    // ~1ms, so the pause skew across the mesh is a few ms of "network
    // delay" from the guests' point of view.
    let t_pause = Instant::now();
    for n in &nodes {
        api_expect(&node_sock(&run_dir, &n.name), "PATCH", "/vm", r#"{"state":"Paused"}"#);
    }
    eprintln!("mesh-take: {} nodes paused in {:.1}ms", nodes.len(), t_pause.elapsed().as_secs_f64() * 1e3);

    // Snapshot all nodes in parallel: each create writes its full mem file.
    let t_snap = Instant::now();
    let handles: Vec<_> = nodes
        .iter()
        .map(|n| {
            let sock = node_sock(&run_dir, &n.name);
            let node_out = out.join(&n.name);
            let name = n.name.clone();
            std::thread::spawn(move || {
                std::fs::create_dir_all(&node_out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", node_out.display())));
                let body = format!(
                    r#"{{"snapshot_type":"Full","snapshot_path":"{}","mem_file_path":"{}"}}"#,
                    node_out.join("snap.vmstate").display(),
                    node_out.join("snap.mem").display()
                );
                let t = Instant::now();
                api_expect(&sock, "PUT", "/snapshot/create", &body);
                eprintln!("mesh-take: {name} snapshot in {:.1}s", t.elapsed().as_secs_f64());
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap_or_else(|_| die("snapshot thread panicked"));
    }
    write_manifest(&out, &nodes);
    eprintln!("mesh-take: all snapshots written in {:.1}s", t_snap.elapsed().as_secs_f64());

    kill_mesh_vmms(&run_dir, &nodes); // frees the taps for mesh-resume
    println!("{}", out.display());
}

struct MeshResume {
    children: Vec<(String, Child)>,
    all_loaded_ms: f64,
    api_ms: f64,
}

fn mesh_resume_once(
    nodes: &[MeshNode],
    snapshot: &Path,
    firecracker: &str,
    enable_pci: bool,
    config: &Arc<rustls::ClientConfig>,
) -> MeshResume {
    let t0 = Instant::now();
    let handles: Vec<_> = nodes
        .iter()
        .map(|n| {
            let name = n.name.clone();
            let ip = n.ip.clone();
            let snap = snapshot.join(&n.name);
            let fc = firecracker.to_string();
            std::thread::spawn(move || {
                let sock = PathBuf::from(format!("{name}.sock"));
                let _ = std::fs::remove_file(&sock);
                let console = std::fs::File::create(format!("{name}-console.log"))
                    .unwrap_or_else(|e| die(&format!("create {name}-console.log: {e}")));
                let mut cmd = Command::new(&fc);
                cmd.arg("--api-sock").arg(&sock);
                if enable_pci {
                    cmd.arg("--enable-pci");
                }
                let child = cmd
                    .stdin(Stdio::null())
                    .stdout(Stdio::from(console.try_clone().expect("clone console fd")))
                    .stderr(Stdio::from(console))
                    .spawn()
                    .unwrap_or_else(|e| die(&format!("spawn {fc} for {name}: {e}")));
                own_vmm(child.id() as i32);
                let t_spawn = Instant::now();
                while !sock.exists() {
                    if t_spawn.elapsed() > Duration::from_secs(5) {
                        die(&format!("{name}: API socket did not appear within 5s"));
                    }
                    std::thread::sleep(Duration::from_micros(200));
                }
                let body = format!(
                    r#"{{"snapshot_path":"{}","mem_backend":{{"backend_type":"File","backend_path":"{}"}},"resume_vm":true}}"#,
                    snap.join("snap.vmstate").display(),
                    snap.join("snap.mem").display()
                );
                let t_load = Instant::now();
                api_expect(&sock, "PUT", "/snapshot/load", &body);
                let load_ms = t_load.elapsed().as_secs_f64() * 1e3;
                let _ = ip; // pokes happen off the measured path, post-join
                (name, child, load_ms)
            })
        })
        .collect();

    let mut children = Vec::new();
    for h in handles {
        let (name, child, load_ms) = h.join().unwrap_or_else(|_| die("resume thread panicked"));
        eprintln!("mesh-resume: {name} loaded in {load_ms:.1}ms");
        children.push((name, child));
    }
    let all_loaded_ms = t0.elapsed().as_secs_f64() * 1e3;

    // Clock pokes ride OFF the measured path: the guests are already
    // running (loads returned), the probe below overlaps the poke window,
    // and the joins before returning guarantee delivery.
    let poke_handles: Vec<_> = nodes
        .iter()
        .map(|n| {
            let addr = format!("{}:10123", n.ip);
            std::thread::spawn(move || send_time_pokes(&addr, 3, Duration::from_millis(50)))
        })
        .collect();

    // "Mesh usable" = the server apiserver answers; agents carry no API.
    let server_ip = &nodes[0].ip;
    let t_api = Instant::now();
    let Some(_) = wait_api(config, &format!("{server_ip}:6443"), Duration::from_secs(10)) else {
        die("server apiserver did not answer within 10s of mesh restore");
    };
    let api_ms = t_api.elapsed().as_secs_f64() * 1e3;
    for h in poke_handles {
        let _ = h.join();
    }

    MeshResume { children, all_loaded_ms, api_ms }
}

fn mesh_resume_flags(flags: &Flags) -> (PathBuf, Vec<MeshNode>, String, bool) {
    let snapshot = PathBuf::from(flags.get("--snapshot").unwrap_or_else(|| "mesh-snapshot".into()));
    let nodes = read_manifest(&snapshot);
    let firecracker = flags.get("--firecracker").unwrap_or_else(|| "firecracker".into());
    let enable_pci = !flags.has("--no-pci");
    (snapshot, nodes, firecracker, enable_pci)
}

fn cmd_mesh_resume(flags: &Flags) {
    let (snapshot, nodes, firecracker, enable_pci) = mesh_resume_flags(flags);
    let config = tls_probe_config();
    let r = mesh_resume_once(&nodes, &snapshot, &firecracker, enable_pci, &config);
    println!(
        "nodes={} all_loaded_ms={:.1} api_ms={:.1} total_ms={:.1}",
        r.children.len(),
        r.all_loaded_ms,
        r.api_ms,
        r.all_loaded_ms + r.api_ms,
    );
    let server_ip = &nodes[0].ip;
    eprintln!("cluster:    https://{server_ip}:6443");
    eprintln!("kubeconfig: curl -s {server_ip}:10124 > kubenyx.kubeconfig && kubectl --kubeconfig kubenyx.kubeconfig get nodes");
    let pids: Vec<String> = r.children.iter().map(|(_, c)| c.id().to_string()).collect();
    eprintln!("stop:       kill {}", pids.join(" "));
    for (_, child) in r.children {
        disown_vmm(child.id() as i32);
        std::mem::forget(child);
    }
}

fn cmd_mesh_cycle(flags: &Flags) {
    let (snapshot, nodes, firecracker, enable_pci) = mesh_resume_flags(flags);
    let n: u32 = flags.get("-n").map(|v| v.parse().unwrap_or_else(|_| die("bad -n"))).unwrap_or(5);
    let config = tls_probe_config();

    let mut totals: Vec<f64> = Vec::with_capacity(n as usize);
    for round in 1..=n {
        let mut r = mesh_resume_once(&nodes, &snapshot, &firecracker, enable_pci, &config);
        let total_ms = r.all_loaded_ms + r.api_ms;
        println!(
            "round={round} nodes={} all_loaded_ms={:.1} api_ms={:.1} total_ms={total_ms:.1}",
            r.children.len(),
            r.all_loaded_ms,
            r.api_ms,
        );
        totals.push(total_ms);
        for (name, child) in r.children.iter_mut() {
            let pid = child.id() as i32;
            kill_wait(child);
            disown_vmm(pid);
            let _ = std::fs::remove_file(format!("{name}.sock"));
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    totals.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = totals[totals.len() / 2];
    println!(
        "mesh_cycles={n} nodes={} median_total_ms={median:.1} min={:.1} max={:.1}",
        nodes.len(),
        totals.first().unwrap(),
        totals.last().unwrap()
    );
}

fn main() {
    install_signal_cleanup();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first().map(String::as_str) else {
        die("usage: kubenyx-snap take|resume|cycle|mesh-take|mesh-resume|mesh-cycle [flags]");
    };
    let flags = Flags(args[1..].to_vec());
    match cmd {
        "take" => cmd_take(&flags),
        "resume" => cmd_resume(&flags),
        "cycle" => cmd_cycle(&flags),
        "mesh-take" => cmd_mesh_take(&flags),
        "mesh-resume" => cmd_mesh_resume(&flags),
        "mesh-cycle" => cmd_mesh_cycle(&flags),
        other => die(&format!("unknown subcommand {other}")),
    }
}
