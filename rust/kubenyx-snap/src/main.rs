//! Firecracker snapshot/restore for Kubenyx microVMs (third boot-path tool,
//! air/v0.2/snapshot-restore.org). Snapshot a cluster-ready guest once, then
//! recreate a live cluster in ~75ms — cheaper than any cold boot can get.
//!
//!   kubenyx-snap take   --runner <microvm-run> --out DIR
//!   kubenyx-snap resume --snapshot DIR [--firecracker BIN] [--cpu-template T]
//!   kubenyx-snap cycle  --snapshot DIR [-n N] [--cpu-template T]
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
//! The mesh verbs handle multi-server quorums too (quorum-mesh.org §D8):
//! mesh-take refuses non-volatile multi-server meshes (posture proven by
//! the launcher's run-dir manifest), and mesh-resume/mesh-cycle report the
//! first committed quorum WRITE next to the TLS-answer time — a 401 proves
//! serving, not raft.
//!
//! Gotchas encoded from the validation session: API socket paths must stay
//! under SUN_LEN=108 (always pass a relative path and spawn from a short
//! CWD if needed); the restore VMM's --enable-pci must match the snapshot;
//! the snapshot must be taken with the snapshot-safe kernel params (AMX/CET
//! masked) or the restored guest #GPs in XRSTORS on AMX hosts.
//!
//! Snapshots carry an identity triple in the snapshot-dir manifest (node
//! closure, VMM store path, host CPU fingerprint — test-amplification.org
//! §D3); resume/mesh-resume refuse a mismatching host or VMM before any
//! process is spawned. --allow-identity-mismatch overrides, loudly. Old
//! snapshots without identity fields warn and proceed.
//!
//! CPU templates (portable-snapshots.org §D3): a snapshot minted under a
//! firecracker custom CPU template records `identity cpu
//! template:sha256:<hash of canonicalized cpu-config JSON>` instead of the
//! host fingerprint (detected from the live VMM's --config-file, never
//! declared by the caller), plus an advisory `identity cpu-host` line.
//! resume/mesh-resume gain --cpu-template <path|literal>; the gate is
//! exact-string — wrong template refuses, a templated artifact without the
//! flag refuses, --cpu-template against an untemplated artifact refuses.
//! When templates match, a differing host fingerprint warns but does not
//! refuse (that is the whole point of the template). Template-less
//! manifests keep the v0.8 host-keyed refusal byte-for-byte.

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
        if slot
            .compare_exchange(0, pid, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
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
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, on_signal as *const () as libc::sighandler_t);
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
            k.eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse().ok())?
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
/// 401 is a healthy answer for an unauthenticated client) — hence the
/// shared kubenyx-tls NoVerify builder.
fn tls_probe_config() -> Arc<rustls::ClientConfig> {
    Arc::new(kubenyx_tls::insecure_client_builder().with_no_client_auth())
}

fn probe_once(config: &Arc<rustls::ClientConfig>, addr: &str, host: &str) -> bool {
    let sockaddr: std::net::SocketAddr = match addr.parse() {
        Ok(a) => a,
        Err(_) => die(&format!("bad probe address {addr}")),
    };
    let Ok(stream) = TcpStream::connect_timeout(&sockaddr, Duration::from_millis(150)) else {
        return false;
    };
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .ok();
    stream
        .set_write_timeout(Some(Duration::from_millis(500)))
        .ok();
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

// ---- quorum-write probe (multi-server mesh only) ---------------------------
//
// A TLS answer proves ONE apiserver is serving — a 401 passes — but says
// nothing about raft. The honest "mesh usable" number for a real quorum is
// the first WRITE the apiserver commits, which requires a live etcd
// majority (quorum-mesh.org §D8). Mechanism: fetch the admin kubeconfig
// the server already serves on :10124 (kubenyx-pki's own fixed template,
// system:masters client cert inline), then PATCH a per-attempt-unique
// annotation onto the default namespace over rustls with that cert. The
// value changes every attempt so the apiserver can never short-circuit an
// unchanged update without touching etcd. Server identity IS verified
// here (unlike the liveness probe): the kubeconfig hands us the run's CA,
// so NoVerify would be an unforced dishonesty.

/// One-shot HTTP/1.0 GET, close-delimited — the guest's kubeconfig handoff
/// serves exactly this shape. Returns the body on a 200.
fn http_get_body(addr: &str, timeout: Duration) -> Option<String> {
    let sockaddr: std::net::SocketAddr = addr.parse().ok()?;
    let mut s = TcpStream::connect_timeout(&sockaddr, Duration::from_millis(300)).ok()?;
    s.set_read_timeout(Some(timeout)).ok();
    s.set_write_timeout(Some(timeout)).ok();
    s.set_nodelay(true).ok();
    s.write_all(format!("GET / HTTP/1.0\r\nHost: {addr}\r\nConnection: close\r\n\r\n").as_bytes())
        .ok()?;
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).ok()?;
    let text = String::from_utf8_lossy(&raw);
    let (headers, body) = text.split_once("\r\n\r\n")?;
    headers
        .split_whitespace()
        .nth(1)
        .filter(|c| c.starts_with('2'))?;
    Some(body.to_string())
}

/// `key: value` lookup in kubenyx-pki's fixed kubeconfig template — our own
/// writer (rust/kubenyx-pki write_kubeconfig), so line-prefix matching is
/// exact, not a YAML parser cosplay.
fn kubeconfig_value(kc: &str, key: &str) -> Option<String> {
    let pat = format!("{key}: ");
    kc.lines().find_map(|l| {
        l.trim_start()
            .strip_prefix(&pat)
            .map(|v| v.trim().to_string())
    })
}

/// Client config + endpoint from the served kubeconfig: verifying roots
/// from certificate-authority-data, client auth from the admin cert.
fn quorum_client(kc: &str) -> (Arc<rustls::ClientConfig>, String, String) {
    use base64::Engine as _;
    let field =
        |k: &str| kubeconfig_value(kc, k).unwrap_or_else(|| die(&format!("kubeconfig has no {k}")));
    let pem = |k: &str| {
        base64::engine::general_purpose::STANDARD
            .decode(field(k))
            .unwrap_or_else(|e| die(&format!("kubeconfig {k}: bad base64: {e}")))
    };
    let mut roots = rustls::RootCertStore::empty();
    for c in rustls_pemfile::certs(&mut pem("certificate-authority-data").as_slice()) {
        let c = c.unwrap_or_else(|e| die(&format!("kubeconfig CA: {e}")));
        roots
            .add(c)
            .unwrap_or_else(|e| die(&format!("kubeconfig CA rejected: {e}")));
    }
    let certs: Vec<_> = rustls_pemfile::certs(&mut pem("client-certificate-data").as_slice())
        .collect::<Result<_, _>>()
        .unwrap_or_else(|e| die(&format!("kubeconfig client cert: {e}")));
    let key = rustls_pemfile::private_key(&mut pem("client-key-data").as_slice())
        .ok()
        .flatten()
        .unwrap_or_else(|| die("kubeconfig has no client key"));
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("tls versions")
    .with_root_certificates(roots)
    .with_client_auth_cert(certs, key)
    .unwrap_or_else(|e| die(&format!("client auth config: {e}")));
    // server: https://<node-address>:6443 — the handoff rewrote loopback to
    // the declared address, which is in the apiserver cert SANs.
    let url = field("server");
    let hostport = url
        .strip_prefix("https://")
        .unwrap_or_else(|| die(&format!("kubeconfig server URL not https: {url}")));
    let host = hostport.split(':').next().unwrap_or(hostport).to_string();
    (Arc::new(config), host, hostport.to_string())
}

fn quorum_write_once(config: &Arc<rustls::ClientConfig>, addr: &str, host: &str) -> bool {
    let sockaddr: std::net::SocketAddr = match addr.parse() {
        Ok(a) => a,
        Err(_) => die(&format!("bad quorum probe address {addr}")),
    };
    let Ok(stream) = TcpStream::connect_timeout(&sockaddr, Duration::from_millis(300)) else {
        return false;
    };
    // Read window longer than the liveness probe's: the response arrives
    // only after the raft commit, not after the route match.
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(1))).ok();
    stream.set_nodelay(true).ok();
    let name = rustls::pki_types::ServerName::try_from(host.to_string())
        .unwrap_or_else(|_| die("bad quorum probe host"));
    let Ok(conn) = rustls::ClientConnection::new(config.clone(), name) else {
        return false;
    };
    let mut tls = rustls::StreamOwned::new(conn, stream);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let body =
        format!(r#"{{"metadata":{{"annotations":{{"kubenyx.io/snap-quorum-probe":"{stamp}"}}}}}}"#);
    let req = format!(
        "PATCH /api/v1/namespaces/default HTTP/1.1\r\nHost: {host}\r\n\
         Content-Type: application/strategic-merge-patch+json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    if tls.write_all(req.as_bytes()).is_err() {
        return false;
    }
    // Only the status line matters; 2xx means the write committed.
    let mut raw = Vec::with_capacity(64);
    let mut chunk = [0u8; 64];
    while !raw.windows(2).any(|w| w == b"\r\n") {
        match tls.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => raw.extend_from_slice(&chunk[..n]),
        }
    }
    raw.starts_with(b"HTTP/") && raw.get(9).is_some_and(|b| *b == b'2')
}

/// True once an authenticated write commits; the kubeconfig fetch is INSIDE
/// the window because it is part of the honest wall from "restored" to
/// "a client could write".
fn wait_quorum_write(kubeconfig_addr: &str, deadline: Duration) -> bool {
    let start = Instant::now();
    let kc = loop {
        if let Some(body) = http_get_body(kubeconfig_addr, Duration::from_secs(2)) {
            break body;
        }
        if start.elapsed() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    let (config, host, addr) = quorum_client(&kc);
    while start.elapsed() < deadline {
        if quorum_write_once(&config, &addr, &host) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    false
}

// ---- snapshot identity (test-amplification.org §D3) -------------------------
//
// A snapshot is a serialized xsave area, TSC state, and CPUID-shaped kernel
// structures, written by one exact VMM build. Restoring it under a different
// CPU feature set has a measured history of guest kernel panics (XRSTORS #GP
// in restore_fpregs_from_fpstate on AMX hosts, air/v0.2), and a different
// firecracker build may misparse or refuse the vmstate. take/mesh-take record
// an identity triple in the snapshot-dir manifest; resume/mesh-resume compare
// what the live side can know (VMM binary, CPU fingerprint) BEFORE any VMM is
// spawned and refuse loudly on mismatch. Exact string match on purpose:
// computing true cross-CPU compatibility is the CPU-template problem (§D4),
// and a half-right subset check fails exactly like no check — with a guest
// panic instead of an error message.

/// Feature bits that change the xstate/CPUID shape a snapshot freezes.
/// Fixed order so the fingerprint is a stable string; presence/absence of
/// each bit is the lock (the AMX/CET set is the one with a panic history).
const CPU_FEATURE_WATCHLIST: &[&str] = &[
    "avx", "avx2", "avx512f", "amx_tile", "amx_bf16", "amx_int8", "xsave", "xsavec", "xsaves",
    "shstk", "ibt", "pku", "la57",
];

const IDENTITY_PREFIX: &str = "identity ";

/// What a snapshot is locked to. Fields are Options because not every take
/// mode can know every field (an attached take never sees the runner path),
/// and the comparison must skip what either side honestly does not know —
/// a fabricated "unknown" that string-compares would fake a lock.
#[derive(Clone, Debug, PartialEq)]
struct SnapIdentity {
    /// Node closure: the runner/toplevel store path the guest was built
    /// from. Recorded for the rebuild-on-drift harness above this tool;
    /// resume has no closure input of its own to compare against.
    closure: Option<String>,
    /// The VMM binary that wrote snap.vmstate (resolved via /proc, so it is
    /// the real store path, not whatever $PATH spelling spawned it).
    vmm: Option<String>,
    /// CPU identity, one of two spellings under the same manifest key
    /// (portable-snapshots.org §D3): `template:sha256:<hash>` /
    /// `template:<NAME>` when the take VMM ran under a CPU template, or
    /// the host fingerprint (vendor/family/model + watchlist bits) when
    /// not. Sharing the key is deliberate: a pre-template binary reading
    /// a templated manifest compares its host fingerprint against the
    /// `template:` string, always mismatches, and refuses — strictly
    /// more conservative than the new rule, never less.
    cpu: Option<String>,
    /// Advisory host fingerprint recorded NEXT TO a template-keyed cpu
    /// (new `cpu-host` key, ignored by old parsers): when templates
    /// match, a differing cpu-host prints a warn line — exactly the
    /// signal a future cross-host incident report needs — but does not
    /// refuse. Never written for host-keyed manifests.
    cpu_host: Option<String>,
}

impl SnapIdentity {
    fn is_empty(&self) -> bool {
        self.closure.is_none() && self.vmm.is_none() && self.cpu.is_none() && self.cpu_host.is_none()
    }
}

fn cpu_fingerprint_from(cpuinfo: &str) -> String {
    // First processor block only: family/model/flags are uniform across a
    // socket, and hybrid parts still report one vendor/family/model.
    let first = cpuinfo.split("\n\n").next().unwrap_or("");
    let field = |key: &str| -> String {
        first
            .lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                (k.trim() == key).then(|| v.trim().to_string())
            })
            .unwrap_or_else(|| "unknown".into())
    };
    let flags = field("flags");
    let set: std::collections::HashSet<&str> = flags.split_whitespace().collect();
    let have: Vec<&str> = CPU_FEATURE_WATCHLIST
        .iter()
        .copied()
        .filter(|f| set.contains(f))
        .collect();
    format!(
        "{}/{}/{}+{}",
        field("vendor_id"),
        field("cpu family"),
        field("model"),
        have.join(",")
    )
}

fn cpu_fingerprint() -> String {
    let raw = std::fs::read_to_string("/proc/cpuinfo")
        .unwrap_or_else(|e| die(&format!("read /proc/cpuinfo: {e}")));
    cpu_fingerprint_from(&raw)
}

/// Identity lines for the manifest: `identity <field> <value>`. Appended
/// after the node lines so pre-identity parsers of the node section (and
/// read_manifest itself) keep working on byte-identical prefixes.
fn identity_lines(id: &SnapIdentity) -> String {
    [
        ("closure", &id.closure),
        ("vmm", &id.vmm),
        ("cpu", &id.cpu),
        ("cpu-host", &id.cpu_host),
    ]
    .iter()
    .filter_map(|(k, v)| v.as_ref().map(|v| format!("{IDENTITY_PREFIX}{k} {v}\n")))
    .collect()
}

fn parse_identity(manifest: &str) -> SnapIdentity {
    let mut id = SnapIdentity {
        closure: None,
        vmm: None,
        cpu: None,
        cpu_host: None,
    };
    for line in manifest.lines() {
        let Some(rest) = line.strip_prefix(IDENTITY_PREFIX) else {
            continue;
        };
        let Some((key, value)) = rest.split_once(' ') else {
            continue;
        };
        let value = Some(value.trim().to_string());
        match key {
            "closure" => id.closure = value,
            "vmm" => id.vmm = value,
            "cpu" => id.cpu = value,
            "cpu-host" => id.cpu_host = value,
            // Future fields: this binary ignores them rather than refusing —
            // an unknown lock it cannot check is the legacy warning's job.
            _ => {}
        }
    }
    id
}

// ---- CPU templates (portable-snapshots.org §D3) ------------------------------

const TEMPLATE_PREFIX: &str = "template:";

/// Canonical JSON: the byte stream minus insignificant whitespace (outside
/// string literals). This is exactly the form `builtins.toJSON` emits (the
/// pinned microvm.nix rev renders the template as `writeText
/// (builtins.toJSON cpu)`), so hashing the canonicalized runner-side
/// cpu-config.json and the committed template file yields one identity for
/// one template. Key ORDER is not normalized — the committed template is
/// authored in toJSON's sorted-key form, and both sides of every compare
/// hash files that went through toJSON or are committed in that form.
fn canonicalize_json(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_str = false;
    let mut esc = false;
    for c in raw.chars() {
        if in_str {
            out.push(c);
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
        } else if c == '"' {
            in_str = true;
            out.push(c);
        } else if !c.is_whitespace() {
            out.push(c);
        }
    }
    out
}

/// `sha256:<hex>` of the canonicalized template JSON — the identity the
/// manifest records and --cpu-template resolves to.
fn template_hash(raw: &str) -> String {
    use sha2::{Digest as _, Sha256};
    let digest = Sha256::digest(canonicalize_json(raw).as_bytes());
    let mut hex = String::with_capacity(64);
    for b in digest {
        hex.push_str(&format!("{b:02x}"));
    }
    format!("sha256:{hex}")
}

/// The value after `"<key>":` in our own tooling's JSON (the microvm.nix
/// runner config, jq-pretty-printed): a quoted string is returned WITH its
/// quotes, an inline object as its balanced-brace slice. Same posture as
/// json_str_field on the launcher manifest — the writer is our pinned
/// runner, so a scan beats a JSON dependency, and anything unexpected
/// refuses loudly at the caller.
fn json_value_after_key<'a>(obj: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("\"{key}\"");
    let after_key = obj.find(&pat)? + pat.len();
    let rest = obj[after_key..]
        .trim_start()
        .strip_prefix(':')?
        .trim_start();
    let at = obj.len() - rest.len();
    match rest.as_bytes().first()? {
        b'"' => {
            // Store paths carry no escapes; a backslash here is not ours.
            let end = rest[1..].find('"')? + 2;
            Some(&obj[at..at + end])
        }
        b'{' => {
            let (mut depth, mut in_str, mut esc) = (0usize, false, false);
            for (i, c) in rest.char_indices() {
                if in_str {
                    if esc {
                        esc = false;
                    } else if c == '\\' {
                        esc = true;
                    } else if c == '"' {
                        in_str = false;
                    }
                } else if c == '"' {
                    in_str = true;
                } else if c == '{' {
                    depth += 1;
                } else if c == '}' {
                    depth -= 1;
                    if depth == 0 {
                        return Some(&obj[at..at + i + 1]);
                    }
                }
            }
            None
        }
        _ => None,
    }
}

/// The CPU template the VMM was ACTUALLY launched with, as an identity
/// spec ("sha256:<hex>"), read off /proc/<pid>/cmdline → --config-file →
/// the config's `cpu-config` key. Detected, never declared: a caller flag
/// could record a template the guest never ran under, which is exactly
/// the lie the identity manifest exists to prevent. The pinned microvm.nix
/// rev renders a store-path string (CustomCpuTemplateOrPath's Path
/// variant); an inline object (its other variant) hashes directly. No
/// --config-file or no key means no template — a host-keyed take.
fn vmm_cpu_template(pid: i32) -> Option<String> {
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let args: Vec<String> = raw
        .split(|b| *b == 0)
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    let cfg_path = args
        .windows(2)
        .find_map(|w| (w[0] == "--config-file").then(|| w[1].clone()))?;
    // From here on the VMM demonstrably ran with a config file: failing to
    // read it must not silently downgrade to "untemplated".
    let cfg = std::fs::read_to_string(&cfg_path)
        .unwrap_or_else(|e| die(&format!("read VMM config {cfg_path}: {e}")));
    let val = json_value_after_key(&cfg, "cpu-config")?;
    let template_json = if let Some(quoted) = val.strip_prefix('"') {
        let path = quoted.strip_suffix('"').unwrap_or(quoted);
        if path.contains('\\') {
            die(&format!("cpu-config path {path}: unexpected escape"));
        }
        std::fs::read_to_string(path)
            .unwrap_or_else(|e| die(&format!("read cpu-config {path}: {e}")))
    } else {
        val.to_string()
    };
    Some(template_hash(&template_json))
}

/// take-side cpu identity: template-keyed when the VMM ran under a
/// template (host fingerprint demoted to the advisory cpu-host line),
/// host-keyed exactly as v0.8 wrote it when not.
fn take_cpu_identity(template: Option<String>) -> (Option<String>, Option<String>) {
    match template {
        Some(t) => (
            Some(format!("{TEMPLATE_PREFIX}{t}")),
            Some(cpu_fingerprint()),
        ),
        None => (Some(cpu_fingerprint()), None),
    }
}

/// Resolve the --cpu-template argument to the identity spelling: an
/// existing file is canonicalized and hashed ("sha256:<hex>"); anything
/// else is taken literally (a static template NAME, or a precomputed
/// "sha256:..." string). A path-looking argument that does not exist dies
/// rather than string-comparing garbage into a refusal.
fn resolve_template_spec(arg: &str) -> String {
    let p = Path::new(arg);
    if p.is_file() {
        let raw = std::fs::read_to_string(p)
            .unwrap_or_else(|e| die(&format!("read --cpu-template {arg}: {e}")));
        template_hash(&raw)
    } else if arg.contains('/') {
        die(&format!(
            "--cpu-template {arg}: looks like a path but is not a readable file"
        ))
    } else {
        arg.to_string()
    }
}

struct IdentityMismatch {
    field: &'static str,
    recorded: String,
    live: String,
    why: &'static str,
}

const WHY_CLOSURE: &str = "the snapshot is a booted instance of one exact node closure; \
     a different closure means the guest inside is not the system being asked for (closure lock)";
const WHY_VMM: &str = "snap.vmstate is written by and locked to one exact firecracker build; \
     a different VMM misparses or refuses the device state (VMM version lock)";
const WHY_CPU: &str = "snap.mem freezes guest xstate/CPUID against the take host's CPU \
     features; restoring under a different feature set has a measured history of guest \
     XRSTORS #GP kernel panics (CPU-feature lock)";

const WHY_TEMPLATE: &str = "the snapshot's CPU identity is keyed to a firecracker CPU \
     template (portable-snapshots.org §D3); resume must present the same template via \
     --cpu-template — exact string, no subset logic, because a half-right compatibility \
     check fails as a guest panic instead of an error message (template lock)";

const WHY_NOT_TEMPLATED: &str = "--cpu-template was passed but this snapshot was minted \
     WITHOUT a template — its frozen xstate is keyed to the minting host, and claiming a \
     template it never ran under would fake portability the artifact does not have \
     (template lock)";

/// Field-by-field compare of the closure and VMM locks, skipping fields
/// either side does not know. The cpu lock has its own rule table —
/// cpu_identity_check below.
fn identity_mismatches(recorded: &SnapIdentity, live: &SnapIdentity) -> Vec<IdentityMismatch> {
    let mut out = Vec::new();
    let pairs = [
        ("closure", &recorded.closure, &live.closure, WHY_CLOSURE),
        ("vmm", &recorded.vmm, &live.vmm, WHY_VMM),
    ];
    for (field, rec, liv, why) in pairs {
        if let (Some(r), Some(l)) = (rec, liv) {
            if r != l {
                out.push(IdentityMismatch {
                    field,
                    recorded: r.clone(),
                    live: l.clone(),
                    why,
                });
            }
        }
    }
    out
}

/// The §D3 rule table for the cpu lock. `resume_template` is the RESOLVED
/// --cpu-template spec ("sha256:<hex>" or a static NAME), None when the
/// flag was not passed. Returns (fatal mismatches, warn-only lines):
///
///   minted without template  → host fingerprint exact-match (v0.8 rule,
///                              unchanged); a --cpu-template flag refuses
///   minted with template     → exact-string template compare; missing
///                              flag refuses; host fingerprint (cpu-host)
///                              demoted to a warn line when templates match
fn cpu_identity_check(
    recorded_cpu: Option<&str>,
    recorded_cpu_host: Option<&str>,
    live_cpu: &str,
    resume_template: Option<&str>,
) -> (Vec<IdentityMismatch>, Vec<String>) {
    let mut mismatches = Vec::new();
    let mut warnings = Vec::new();
    match recorded_cpu {
        None => {
            // No cpu lock recorded (partial manifest): nothing to enforce,
            // but a --cpu-template claim against it is unverifiable.
            if let Some(rt) = resume_template {
                mismatches.push(IdentityMismatch {
                    field: "cpu",
                    recorded: "(no cpu identity recorded)".into(),
                    live: format!("{TEMPLATE_PREFIX}{rt}"),
                    why: WHY_NOT_TEMPLATED,
                });
            }
        }
        Some(rc) => {
            if let Some(recorded_template) = rc.strip_prefix(TEMPLATE_PREFIX) {
                match resume_template {
                    None => mismatches.push(IdentityMismatch {
                        field: "cpu",
                        recorded: rc.into(),
                        live: "(resume passed no --cpu-template)".into(),
                        why: WHY_TEMPLATE,
                    }),
                    Some(rt) if rt != recorded_template => {
                        mismatches.push(IdentityMismatch {
                            field: "cpu",
                            recorded: rc.into(),
                            live: format!("{TEMPLATE_PREFIX}{rt}"),
                            why: WHY_TEMPLATE,
                        });
                    }
                    Some(_) => {
                        // Templates match: the host fingerprint is advisory
                        // (demoted, not deleted) — the warn line is the
                        // breadcrumb a cross-host incident report needs.
                        if let Some(rh) = recorded_cpu_host {
                            if rh != live_cpu {
                                warnings.push(format!(
                                    "template-keyed identities match but the host CPU \
                                     differs from the minting host\n  minted on: {rh}\n  \
                                     this host: {live_cpu}\n  proceeding — the template is \
                                     the lock; cross-host restore remains unproven \
                                     (portable-snapshots.org §D4)"
                                ));
                            }
                        }
                    }
                }
            } else if let Some(rt) = resume_template {
                mismatches.push(IdentityMismatch {
                    field: "cpu",
                    recorded: rc.into(),
                    live: format!("{TEMPLATE_PREFIX}{rt}"),
                    why: WHY_NOT_TEMPLATED,
                });
            } else if rc != live_cpu {
                mismatches.push(IdentityMismatch {
                    field: "cpu",
                    recorded: rc.into(),
                    live: live_cpu.into(),
                    why: WHY_CPU,
                });
            }
        }
    }
    (mismatches, warnings)
}

/// Resolve what `--firecracker` would actually execute: bare names walk
/// $PATH like the spawn will, then canonicalize so store-path symlink
/// spellings and the /proc/<pid>/exe form recorded at take compare equal.
fn resolve_exe(name: &str) -> Option<String> {
    let path = if name.contains('/') {
        PathBuf::from(name)
    } else {
        std::env::split_paths(&std::env::var_os("PATH")?)
            .map(|d| d.join(name))
            .find(|p| p.is_file())?
    };
    path.canonicalize().ok().map(|p| p.display().to_string())
}

/// The VMM's true binary via /proc/<pid>/exe — survives $PATH tricks and
/// wrapper scripts. Only trusted when it IS a firecracker (the runner may
/// wrap rather than exec-chain, leaving the runner's own pid here).
fn vmm_exe_of(pid: i32) -> Option<String> {
    let exe = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let s = exe.display().to_string();
    s.contains("firecracker").then_some(s)
}

/// Fallback for wrapped runners and attached/mesh takes: the firecracker
/// process is findable by its CWD (where its API socket lives), the same
/// handle kill_mesh_vmms uses on processes someone else spawned. Returns
/// (pid, exe): the pid is what template detection reads the cmdline from.
fn find_vmm_by_cwd(want: &Path) -> Option<(i32, String)> {
    // /proc/<pid>/cwd readlinks are absolute and resolved; match in kind.
    let want = want.canonicalize().ok()?;
    for entry in std::fs::read_dir("/proc").ok()?.filter_map(|e| e.ok()) {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if !comm.trim_end().ends_with("firecracker") {
            continue;
        }
        let Ok(cwd) = std::fs::read_link(format!("/proc/{pid}/cwd")) else {
            continue;
        };
        if cwd == want {
            return std::fs::read_link(format!("/proc/{pid}/exe"))
                .ok()
                .map(|p| (pid, p.display().to_string()));
        }
    }
    None
}

/// Identity the live host presents at resume time: no closure (resume has
/// no runner input; drift detection against the closure is the minting
/// harness's compare), the would-be VMM, this host's CPU.
fn live_identity(firecracker: &str) -> SnapIdentity {
    let vmm = resolve_exe(firecracker);
    if vmm.is_none() {
        eprintln!(
            "kubenyx-snap: warning: cannot resolve '{firecracker}' to a binary — \
             the VMM lock is not verifiable (the spawn below will fail anyway if it is absent)"
        );
    }
    SnapIdentity {
        closure: None,
        vmm,
        cpu: Some(cpu_fingerprint()),
        cpu_host: None,
    }
}

fn read_snapshot_identity(dir: &Path) -> Option<SnapIdentity> {
    let raw = std::fs::read_to_string(dir.join("manifest")).ok()?;
    let id = parse_identity(&raw);
    (!id.is_empty()).then_some(id)
}

/// The refusal gate, run before any VMM is spawned. Missing identity is a
/// warning, not an error: pre-identity snapshots keep resuming (compat),
/// they just do so unverified — unless the caller claims a template, which
/// an identity-less manifest can never back up.
fn enforce_identity(
    snapshot: &Path,
    firecracker: &str,
    cpu_template: Option<&str>,
    allow_mismatch: bool,
) {
    let Some(recorded) = read_snapshot_identity(snapshot) else {
        if cpu_template.is_some() && !allow_mismatch {
            die(&format!(
                "--cpu-template passed but {} has no identity fields in its \
                 manifest (pre-identity snapshot) — the template claim cannot \
                 be verified; drop the flag, or pass --allow-identity-mismatch",
                snapshot.display()
            ));
        }
        eprintln!(
            "kubenyx-snap: warning: {} has no identity fields in its manifest \
             (pre-identity snapshot) — the CPU-feature and VMM locks cannot be \
             verified; proceeding",
            snapshot.display()
        );
        return;
    };
    let live = live_identity(firecracker);
    let mut mismatches = identity_mismatches(&recorded, &live);
    let (cpu_mismatches, warnings) = cpu_identity_check(
        recorded.cpu.as_deref(),
        recorded.cpu_host.as_deref(),
        live.cpu.as_deref().unwrap_or(""),
        cpu_template,
    );
    mismatches.extend(cpu_mismatches);
    for w in &warnings {
        eprintln!("kubenyx-snap: warning: {w}");
    }
    if mismatches.is_empty() {
        return;
    }
    for m in &mismatches {
        eprintln!(
            "kubenyx-snap: identity mismatch: {}\n  recorded: {}\n  live:     {}\n  fatal because {}",
            m.field, m.recorded, m.live, m.why
        );
    }
    if allow_mismatch {
        eprintln!(
            "kubenyx-snap: WARNING: --allow-identity-mismatch set — proceeding against \
             {} identity mismatch(es); a guest kernel panic or silently corrupt restore \
             is the expected failure mode here, not a bug to report",
            mismatches.len()
        );
    } else {
        die(
            "snapshot identity mismatch (fields above) — snapshots never move between \
             hosts or VMM builds; mint a fresh snapshot on this host, or pass \
             --allow-identity-mismatch to proceed anyway",
        );
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
    let marker = flags
        .get("--marker")
        .unwrap_or_else(|| "KUBENYX-CLUSTER-READY".into());
    let wait_secs: u64 = flags
        .get("--wait-secs")
        .map(|v| v.parse().unwrap_or_else(|_| die("bad --wait-secs")))
        .unwrap_or(120);
    let settle_ms: u64 = flags
        .get("--settle-ms")
        .map(|v| v.parse().unwrap_or_else(|_| die("bad --settle-ms")))
        .unwrap_or(2000);

    std::fs::create_dir_all(&out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let out = out
        .canonicalize()
        .unwrap_or_else(|e| die(&format!("canonicalize: {e}")));
    let console = out.join("take-console.log");
    let sock = PathBuf::from("kubenyx.sock"); // dropped by the runner in CWD
    let _ = std::fs::remove_file(&sock);

    let log_file = std::fs::File::create(&console)
        .unwrap_or_else(|e| die(&format!("create console log: {e}")));
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
    eprintln!(
        "take: snapshot written in {:?} -> {}",
        t.elapsed(),
        out.display()
    );

    // Identity (§D3) while the VMM is still alive: the runner usually
    // exec-chains into firecracker (same pid), else find it by CWD (it
    // dropped kubenyx.sock here). The pid also carries the CPU-template
    // detection (--config-file off the live cmdline).
    let vm_pid = vm.id() as i32;
    let vmm = vmm_exe_of(vm_pid).map(|exe| (vm_pid, exe)).or_else(|| {
        std::env::current_dir()
            .ok()
            .and_then(|d| find_vmm_by_cwd(&d))
    });
    let template = vmm.as_ref().and_then(|(pid, _)| vmm_cpu_template(*pid));
    if let Some(t) = &template {
        eprintln!("take: CPU-template-keyed identity ({t})");
    }
    let (cpu, cpu_host) = take_cpu_identity(template);
    let identity = SnapIdentity {
        closure: PathBuf::from(&runner)
            .canonicalize()
            .ok()
            .map(|p| p.display().to_string()),
        vmm: vmm.map(|(_, exe)| exe),
        cpu,
        cpu_host,
    };
    if identity.vmm.is_none() {
        eprintln!(
            "take: warning: could not identify the VMM binary — resume will not \
             verify the VMM lock (nor detect a CPU template) for this snapshot"
        );
    }
    std::fs::write(out.join("manifest"), identity_lines(&identity))
        .unwrap_or_else(|e| die(&format!("write manifest: {e}")));

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
    let out = out
        .canonicalize()
        .unwrap_or_else(|e| die(&format!("canonicalize: {e}")));

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

    // Identity (§D3): the attached VM's closure is its operator's knowledge,
    // not ours (no runner path in sight) — record what this side can prove.
    // The VMM binds its API socket relative to its own CWD, so the socket's
    // directory is the CWD to scan for; the found pid also carries the
    // CPU-template detection.
    let vmm = sock
        .canonicalize()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .and_then(|d| find_vmm_by_cwd(&d));
    let template = vmm.as_ref().and_then(|(pid, _)| vmm_cpu_template(*pid));
    if let Some(t) = &template {
        eprintln!("take: CPU-template-keyed identity ({t})");
    }
    let (cpu, cpu_host) = take_cpu_identity(template);
    let identity = SnapIdentity {
        closure: None,
        vmm: vmm.map(|(_, exe)| exe),
        cpu,
        cpu_host,
    };
    if identity.vmm.is_none() {
        eprintln!(
            "take: warning: could not identify the VMM binary — resume will not \
             verify the VMM lock for this snapshot"
        );
    }
    std::fs::write(out.join("manifest"), identity_lines(&identity))
        .unwrap_or_else(|e| die(&format!("write manifest: {e}")));

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
    let poke_handle =
        std::thread::spawn(move || send_time_pokes(&poke_addr_owned, 3, Duration::from_millis(50)));

    let Some(load_to_api) = wait_api(config, probe_addr, Duration::from_secs(10)) else {
        die("apiserver did not answer within 10s of restore");
    };
    let _ = poke_handle.join();

    (
        child,
        ResumeTimings {
            spawn_to_sock,
            load,
            load_to_api,
        },
    )
}

fn resume_flags(flags: &Flags) -> (String, PathBuf, PathBuf, String, String, bool) {
    let snapshot = PathBuf::from(flags.get("--snapshot").unwrap_or_else(|| "snapshot".into()));
    if !snapshot.join("snap.vmstate").exists() {
        die(&format!("{}/snap.vmstate not found", snapshot.display()));
    }
    let firecracker = flags
        .get("--firecracker")
        .unwrap_or_else(|| "firecracker".into());
    // Relative by default: an absolute path under a deep workdir exceeds
    // SUN_LEN=108 and firecracker refuses to bind.
    let api_sock = PathBuf::from(
        flags
            .get("--api-sock")
            .unwrap_or_else(|| "kubenyx-resume.sock".into()),
    );
    let probe_addr = flags
        .get("--probe")
        .unwrap_or_else(|| "10.100.0.2:6443".into());
    let poke_addr = flags
        .get("--poke")
        .unwrap_or_else(|| "10.100.0.2:10123".into());
    let enable_pci = !flags.has("--no-pci");
    // Identity gate (§D3) before anything is spawned. --cpu-template is
    // resolved here (path → sha256:<hex>, literal kept) so the gate's
    // compare is a pure string rule.
    let cpu_template = flags.get("--cpu-template").map(|t| resolve_template_spec(&t));
    enforce_identity(
        &snapshot,
        &firecracker,
        cpu_template.as_deref(),
        flags.has("--allow-identity-mismatch"),
    );
    (
        firecracker,
        snapshot,
        api_sock,
        probe_addr,
        poke_addr,
        enable_pci,
    )
}

fn cmd_resume(flags: &Flags) {
    let (firecracker, snapshot, api_sock, probe_addr, poke_addr, enable_pci) = resume_flags(flags);
    let config = tls_probe_config();
    let (child, t) = resume_once(
        &firecracker,
        &snapshot,
        &api_sock,
        &probe_addr,
        &poke_addr,
        enable_pci,
        &config,
    );
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
    let n: u32 = flags
        .get("-n")
        .map(|v| v.parse().unwrap_or_else(|_| die("bad -n")))
        .unwrap_or(5);
    let config = tls_probe_config();

    let mut totals: Vec<f64> = Vec::with_capacity(n as usize);
    for round in 1..=n {
        let (mut child, t) = resume_once(
            &firecracker,
            &snapshot,
            &api_sock,
            &probe_addr,
            &poke_addr,
            enable_pci,
            &config,
        );
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

/// "serverN" -> N, "agentN" -> N; mkMembers ranges start at 1, so a 0 or
/// non-numeric suffix is not one of ours.
fn number_suffix(name: &str, prefix: &str) -> Option<u32> {
    name.strip_prefix(prefix)?
        .parse::<u32>()
        .ok()
        .filter(|n| *n >= 1)
}

fn is_server_name(name: &str) -> bool {
    name == "server" || number_suffix(name, "server").is_some()
}

/// Mesh addresses mirror lib/microvm.nix mkMembers exactly: the node index
/// derives the address, 10.100.0.(2+index). servers == 1 keeps the single
/// name "server" at index 0 (quorum-mesh.org §D5); servers > 1 names them
/// server1..serverN at indexes 0..N-1, and agents pack AFTER the servers
/// (agentN has index servers+N-1) — so an agent's address depends on the
/// mesh's server count, which a lone agent name cannot carry. Callers pass
/// the count they discovered (1 preserves the byte-stable single-server
/// convention). Anything else needs an explicit --node name=ip.
fn conventional_ip(name: &str, servers: u32) -> Option<String> {
    if name == "server" {
        return Some("10.100.0.2".into());
    }
    if let Some(n) = number_suffix(name, "server") {
        // serverN: index N-1 -> 10.100.0.(1+N)
        return Some(format!("10.100.0.{}", 1 + n));
    }
    // agentN: index servers+N-1 -> 10.100.0.(1+servers+N)
    number_suffix(name, "agent").map(|n| format!("10.100.0.{}", 1 + servers + n))
}

/// Sort key: servers before agents (the resume probe waits on nodes[0]'s
/// apiserver), numeric within each role so server2 sorts before server10 —
/// lexical name order would not. Unknown names sort last, by name.
fn mesh_order_key(name: &str) -> (u8, u32) {
    if name == "server" {
        return (0, 0);
    }
    if let Some(n) = number_suffix(name, "server") {
        return (0, n);
    }
    if let Some(n) = number_suffix(name, "agent") {
        return (1, n);
    }
    (2, 0)
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

// ---- launcher posture manifest (run dir, servers > 1 only) -----------------
//
// lib/microvm.nix writes $RUN/kubenyx-mesh.json at launch for multi-server
// meshes: this tool talks to firecracker APIs and run dirs, never guest
// config, so the launcher — which holds the eval — is the only honest
// source for posture and membership. Single-server run dirs never carry
// the manifest (writing it for every size would change the cp1w2/cp1w6
// launcher text, which is drv-gated byte-identical, §D5) and keep the
// address convention.

const RUN_MANIFEST: &str = "kubenyx-mesh.json";

struct RunManifest {
    posture: String,
    nodes: Vec<MeshNode>,
}

/// Scan for `"key":"value"` in our own launcher's fixed builtins.toJSON
/// output — the values are Nix-declared names/addresses with no escapes
/// possible, so a JSON dependency buys nothing over refusing loudly.
fn json_str_field(obj: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\":\"");
    let start = obj.find(&pat)? + pat.len();
    let end = obj[start..].find('"')? + start;
    Some(obj[start..end].to_string())
}

fn parse_run_manifest(json: &str) -> Result<RunManifest, String> {
    let posture = json_str_field(json, "posture").ok_or("no posture field")?;
    let arr = json.find("\"nodes\":[").ok_or("no nodes field")? + "\"nodes\":[".len();
    let arr_end = json[arr..].find(']').ok_or("unterminated nodes array")? + arr;
    let mut nodes = Vec::new();
    for obj in json[arr..arr_end]
        .split('{')
        .filter(|s| !s.trim().is_empty())
    {
        nodes.push(MeshNode {
            name: json_str_field(obj, "name").ok_or("node without name")?,
            ip: json_str_field(obj, "ip").ok_or("node without ip")?,
        });
    }
    if nodes.is_empty() {
        return Err("empty nodes array".into());
    }
    Ok(RunManifest { posture, nodes })
}

fn read_run_manifest(run_dir: &Path) -> Option<RunManifest> {
    let path = run_dir.join(RUN_MANIFEST);
    let raw = std::fs::read_to_string(&path).ok()?;
    Some(
        parse_run_manifest(&raw).unwrap_or_else(|e| die(&format!("parse {}: {e}", path.display()))),
    )
}

/// Multi-server snapshots are volatile-only: firecracker snapshots exclude
/// virtio disk contents, so resuming a DURABLE quorum against disks that
/// kept moving corrupts etcd — while tmpfs state rides inside snap.mem and
/// is exactly consistent (quorum-mesh.org §D8). The refusal is loud because
/// the failure it prevents surfaces as silent data corruption much later.
fn assert_volatile_mesh_take(
    server_count: usize,
    manifest: Option<&RunManifest>,
) -> Result<(), String> {
    if server_count <= 1 {
        return Ok(());
    }
    match manifest {
        None => Err(format!(
            "multi-server mesh-take needs the launcher posture manifest \
             ({RUN_MANIFEST} in the run dir) to prove the mesh is volatile — \
             relaunch with a quorum-mesh launcher (lib/microvm.nix writes it \
             for servers > 1)"
        )),
        Some(m) if m.posture != "volatile" => Err(format!(
            "refusing mesh-take: launcher manifest says posture={} — \
             firecracker snapshots exclude virtio disk contents, so resuming \
             a durable quorum against mutated disks corrupts etcd; only \
             volatile (tmpfs) meshes snapshot honestly",
            m.posture
        )),
        Some(_) => Ok(()),
    }
}

fn mesh_nodes(
    flags: &Flags,
    run_dir: Option<&Path>,
    manifest: Option<&RunManifest>,
) -> Vec<MeshNode> {
    // Explicit --node name=ip flags win; then the launcher manifest (exact
    // eval-time addresses, no convention guessing); otherwise discover the
    // node subdirs (mesh-take) and apply the address convention.
    let mut explicit: Vec<MeshNode> = Vec::new();
    let mut i = 0;
    while i < flags.0.len() {
        if flags.0[i] == "--node" {
            let v = flags
                .0
                .get(i + 1)
                .cloned()
                .unwrap_or_else(|| die("--node needs name=ip"));
            let (name, ip) = v
                .split_once('=')
                .unwrap_or_else(|| die(&format!("--node {v}: expected name=ip")));
            explicit.push(MeshNode {
                name: name.into(),
                ip: ip.into(),
            });
            i += 2;
        } else {
            i += 1;
        }
    }
    let mut nodes = if !explicit.is_empty() {
        explicit
    } else if let Some(m) = manifest {
        m.nodes.clone()
    } else if let Some(dir) = run_dir {
        // Names first: agent addresses need the mesh's server count.
        let names: Vec<String> = std::fs::read_dir(dir)
            .unwrap_or_else(|e| die(&format!("read {}: {e}", dir.display())))
            .filter_map(|e| e.ok())
            .filter(|e| {
                let p = e.path();
                let n = e.file_name().to_string_lossy().into_owned();
                p.join(format!("{n}.sock")).exists() || p.join("kubenyx.sock").exists()
            })
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        let servers = names.iter().filter(|n| is_server_name(n)).count().max(1) as u32;
        names
            .into_iter()
            .map(|name| {
                let ip = conventional_ip(&name, servers).unwrap_or_else(|| {
                    die(&format!(
                        "cannot infer address for node '{name}' — pass --node {name}=<ip>"
                    ))
                });
                MeshNode { name, ip }
            })
            .collect()
    } else {
        Vec::new()
    };
    if nodes.is_empty() {
        die("no mesh nodes found (no --node flags and no node workdirs with kubenyx.sock)");
    }
    nodes.sort_by(|a, b| {
        mesh_order_key(&a.name)
            .cmp(&mesh_order_key(&b.name))
            .then_with(|| a.name.cmp(&b.name))
    });
    nodes
}

fn write_manifest(out: &Path, nodes: &[MeshNode], identity: &SnapIdentity) {
    // Node lines first, byte-identical to the pre-identity format; the
    // identity lines (§D3) append after them.
    let body: String = nodes
        .iter()
        .map(|n| format!("{} {}\n", n.name, n.ip))
        .chain(std::iter::once(identity_lines(identity)))
        .collect();
    std::fs::write(out.join("manifest"), body)
        .unwrap_or_else(|e| die(&format!("write manifest: {e}")));
}

fn read_manifest(dir: &Path) -> Vec<MeshNode> {
    let data = std::fs::read_to_string(dir.join("manifest"))
        .unwrap_or_else(|e| die(&format!("read {}/manifest: {e}", dir.display())));
    let nodes: Vec<MeshNode> = data
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with(IDENTITY_PREFIX))
        .map(|l| {
            let (name, ip) = l
                .split_once(' ')
                .unwrap_or_else(|| die(&format!("bad manifest line: {l}")));
            MeshNode {
                name: name.into(),
                ip: ip.into(),
            }
        })
        .collect();
    if nodes.is_empty() {
        // Single-VM snapshot dirs now carry an identity-only manifest; a
        // mesh verb pointed at one should say so, not index-panic later.
        die(&format!(
            "{}/manifest has no node lines — not a mesh snapshot",
            dir.display()
        ));
    }
    nodes
}

/// Kill the mesh's VMMs by workdir: each node's firecracker runs with
/// CWD $RUN/<node> (the launcher's layout), which is the only reliable
/// handle we have on processes someone else spawned.
fn kill_mesh_vmms(run_dir: &Path, nodes: &[MeshNode]) {
    let want: Vec<PathBuf> = nodes.iter().map(|n| run_dir.join(&n.name)).collect();
    let Ok(proc_dir) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in proc_dir.filter_map(|e| e.ok()) {
        let pid_str = entry.file_name().to_string_lossy().into_owned();
        let Ok(pid) = pid_str.parse::<i32>() else {
            continue;
        };
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if !comm.trim_end().ends_with("firecracker") && comm.trim_end() != "microvm@kubenyx" {
            continue;
        }
        let Ok(cwd) = std::fs::read_link(format!("/proc/{pid}/cwd")) else {
            continue;
        };
        if want.iter().any(|w| w == &cwd) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

fn cmd_mesh_take(flags: &Flags) {
    let run_dir = PathBuf::from(
        flags
            .get("--run-dir")
            .unwrap_or_else(|| "/tmp/kubenyx-cluster".into()),
    );
    let out = PathBuf::from(flags.get("--out").unwrap_or_else(|| "mesh-snapshot".into()));
    let run_manifest = read_run_manifest(&run_dir);
    let nodes = mesh_nodes(flags, Some(&run_dir), run_manifest.as_ref());
    let server_count = nodes.iter().filter(|n| is_server_name(&n.name)).count();
    if let Err(e) = assert_volatile_mesh_take(server_count, run_manifest.as_ref()) {
        die(&e);
    }
    std::fs::create_dir_all(&out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let out = out
        .canonicalize()
        .unwrap_or_else(|e| die(&format!("canonicalize: {e}")));

    // Pause EVERYTHING first: this is the consistent cut. Each PATCH is
    // ~1ms, so the pause skew across the mesh is a few ms of "network
    // delay" from the guests' point of view.
    let t_pause = Instant::now();
    for n in &nodes {
        api_expect(
            &node_sock(&run_dir, &n.name),
            "PATCH",
            "/vm",
            r#"{"state":"Paused"}"#,
        );
    }
    eprintln!(
        "mesh-take: {} nodes paused in {:.1}ms",
        nodes.len(),
        t_pause.elapsed().as_secs_f64() * 1e3
    );

    // Snapshot all nodes in parallel: each create writes its full mem file.
    let t_snap = Instant::now();
    let handles: Vec<_> = nodes
        .iter()
        .map(|n| {
            let sock = node_sock(&run_dir, &n.name);
            let node_out = out.join(&n.name);
            let name = n.name.clone();
            std::thread::spawn(move || {
                std::fs::create_dir_all(&node_out)
                    .unwrap_or_else(|e| die(&format!("mkdir {}: {e}", node_out.display())));
                let body = format!(
                    r#"{{"snapshot_type":"Full","snapshot_path":"{}","mem_file_path":"{}"}}"#,
                    node_out.join("snap.vmstate").display(),
                    node_out.join("snap.mem").display()
                );
                let t = Instant::now();
                api_expect(&sock, "PUT", "/snapshot/create", &body);
                eprintln!(
                    "mesh-take: {name} snapshot in {:.1}s",
                    t.elapsed().as_secs_f64()
                );
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap_or_else(|_| die("snapshot thread panicked"));
    }
    // Identity (§D3) before the kill below erases the evidence: the
    // launcher spawned every node from one eval, so the first node's VMM
    // speaks for the mesh (one cpuTemplate flows to every node from the
    // same mkCluster argument). Closure stays unknown — the launcher holds
    // the eval, this tool only sees run dirs and API sockets.
    let vmm = nodes
        .iter()
        .find_map(|n| find_vmm_by_cwd(&run_dir.join(&n.name)));
    let template = vmm.as_ref().and_then(|(pid, _)| vmm_cpu_template(*pid));
    if let Some(t) = &template {
        eprintln!("mesh-take: CPU-template-keyed identity ({t})");
    }
    let (cpu, cpu_host) = take_cpu_identity(template);
    let identity = SnapIdentity {
        closure: None,
        vmm: vmm.map(|(_, exe)| exe),
        cpu,
        cpu_host,
    };
    if identity.vmm.is_none() {
        eprintln!(
            "mesh-take: warning: could not identify the VMM binary — mesh-resume \
             will not verify the VMM lock for this snapshot"
        );
    }
    write_manifest(&out, &nodes, &identity);
    eprintln!(
        "mesh-take: all snapshots written in {:.1}s",
        t_snap.elapsed().as_secs_f64()
    );

    kill_mesh_vmms(&run_dir, &nodes); // frees the taps for mesh-resume
    println!("{}", out.display());
}

struct MeshResume {
    children: Vec<(String, Child)>,
    all_loaded_ms: f64,
    api_ms: f64,
    /// First committed authenticated write, same origin as api_ms so the
    /// two are directly comparable. None on single-server meshes: their
    /// resume output is parsed by existing scripts and a one-member
    /// "quorum" write proves nothing a TLS answer doesn't.
    quorum_write_ms: Option<f64>,
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
                // Pokes happen off the measured path, post-join (below).
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

    // "Mesh usable" (weak form) = the first server's apiserver answers TLS;
    // agents carry no API. nodes[0] is server/server1 by mesh_order_key.
    let server_ip = &nodes[0].ip;
    let t_api = Instant::now();
    let Some(_) = wait_api(
        config,
        &format!("{server_ip}:6443"),
        Duration::from_secs(10),
    ) else {
        die("server apiserver did not answer within 10s of mesh restore");
    };
    let api_ms = t_api.elapsed().as_secs_f64() * 1e3;

    // "Mesh usable" (honest form, multi-server only): first committed
    // write. Same t_api origin, so quorum_write_ms - api_ms is the raft
    // tax on top of the TLS answer. Runs BEFORE the poke joins — like the
    // TLS probe it overlaps the poke window; joining first would bill the
    // pokes' sleep tail to the quorum number.
    let servers = nodes.iter().filter(|n| is_server_name(&n.name)).count();
    let quorum_write_ms = (servers > 1).then(|| {
        if !wait_quorum_write(&format!("{server_ip}:10124"), Duration::from_secs(20)) {
            die(
                "no quorum write committed within 20s of mesh restore — the \
                 apiserver answers TLS but raft has no majority; the mesh is \
                 not honestly usable",
            );
        }
        t_api.elapsed().as_secs_f64() * 1e3
    });
    for h in poke_handles {
        let _ = h.join();
    }

    MeshResume {
        children,
        all_loaded_ms,
        api_ms,
        quorum_write_ms,
    }
}

fn mesh_resume_flags(flags: &Flags) -> (PathBuf, Vec<MeshNode>, String, bool) {
    let snapshot = PathBuf::from(
        flags
            .get("--snapshot")
            .unwrap_or_else(|| "mesh-snapshot".into()),
    );
    let nodes = read_manifest(&snapshot);
    let firecracker = flags
        .get("--firecracker")
        .unwrap_or_else(|| "firecracker".into());
    let enable_pci = !flags.has("--no-pci");
    // Identity gate (§D3) before anything is spawned; --cpu-template as in
    // resume_flags.
    let cpu_template = flags.get("--cpu-template").map(|t| resolve_template_spec(&t));
    enforce_identity(
        &snapshot,
        &firecracker,
        cpu_template.as_deref(),
        flags.has("--allow-identity-mismatch"),
    );
    (snapshot, nodes, firecracker, enable_pci)
}

/// Extra probe fields, appended AFTER the existing ones so scripts parsing
/// the single-server mesh line see byte-identical prefixes; tls_ms restates
/// api_ms under the quorum-mesh.org §D8 name so both probe numbers read as
/// the pair they are.
fn probe_fields(r: &MeshResume) -> String {
    r.quorum_write_ms
        .map(|q| format!(" tls_ms={:.1} quorum_write_ms={q:.1}", r.api_ms))
        .unwrap_or_default()
}

fn cmd_mesh_resume(flags: &Flags) {
    let (snapshot, nodes, firecracker, enable_pci) = mesh_resume_flags(flags);
    let config = tls_probe_config();
    let r = mesh_resume_once(&nodes, &snapshot, &firecracker, enable_pci, &config);
    println!(
        "nodes={} all_loaded_ms={:.1} api_ms={:.1} total_ms={:.1}{}",
        r.children.len(),
        r.all_loaded_ms,
        r.api_ms,
        r.all_loaded_ms + r.api_ms,
        probe_fields(&r),
    );
    let server_ip = &nodes[0].ip;
    eprintln!("cluster:    https://{server_ip}:6443");
    // One line per server (§D7): on server loss, re-curl a survivor.
    for n in nodes.iter().filter(|n| is_server_name(&n.name)) {
        eprintln!("kubeconfig: curl -s {}:10124 > kubenyx.kubeconfig && kubectl --kubeconfig kubenyx.kubeconfig get nodes", n.ip);
    }
    let pids: Vec<String> = r.children.iter().map(|(_, c)| c.id().to_string()).collect();
    eprintln!("stop:       kill {}", pids.join(" "));
    for (_, child) in r.children {
        disown_vmm(child.id() as i32);
        std::mem::forget(child);
    }
}

fn cmd_mesh_cycle(flags: &Flags) {
    let (snapshot, nodes, firecracker, enable_pci) = mesh_resume_flags(flags);
    let n: u32 = flags
        .get("-n")
        .map(|v| v.parse().unwrap_or_else(|_| die("bad -n")))
        .unwrap_or(5);
    let config = tls_probe_config();

    let mut totals: Vec<f64> = Vec::with_capacity(n as usize);
    let mut quorums: Vec<f64> = Vec::new();
    for round in 1..=n {
        let mut r = mesh_resume_once(&nodes, &snapshot, &firecracker, enable_pci, &config);
        let total_ms = r.all_loaded_ms + r.api_ms;
        println!(
            "round={round} nodes={} all_loaded_ms={:.1} api_ms={:.1} total_ms={total_ms:.1}{}",
            r.children.len(),
            r.all_loaded_ms,
            r.api_ms,
            probe_fields(&r),
        );
        totals.push(total_ms);
        if let Some(q) = r.quorum_write_ms {
            quorums.push(q);
        }
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
    // Same append-only rule as the round lines: the summary grows a quorum
    // median only when every round measured one.
    let quorum_summary = if quorums.len() == totals.len() {
        quorums.sort_by(|a, b| a.partial_cmp(b).unwrap());
        format!(" median_quorum_write_ms={:.1}", quorums[quorums.len() / 2])
    } else {
        String::new()
    };
    println!(
        "mesh_cycles={n} nodes={} median_total_ms={median:.1} min={:.1} max={:.1}{quorum_summary}",
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

#[cfg(test)]
mod tests {
    use super::*;

    // The single-server convention is parsed by nothing but relied on by
    // everything: cp1w2/cp1w6 run dirs must keep resolving byte-identically.
    #[test]
    fn single_server_convention_is_byte_stable() {
        assert_eq!(conventional_ip("server", 1).as_deref(), Some("10.100.0.2"));
        assert_eq!(conventional_ip("agent1", 1).as_deref(), Some("10.100.0.3"));
        assert_eq!(conventional_ip("agent6", 1).as_deref(), Some("10.100.0.8"));
    }

    // Mirror of lib/microvm.nix mkMembers: serverN at index N-1, agents
    // packed after the servers — cp3 (.2/.3/.4) and cp3w2 (agents .5/.6).
    #[test]
    fn server_n_addressing_mirrors_mk_members() {
        assert_eq!(conventional_ip("server1", 3).as_deref(), Some("10.100.0.2"));
        assert_eq!(conventional_ip("server2", 3).as_deref(), Some("10.100.0.3"));
        assert_eq!(conventional_ip("server3", 3).as_deref(), Some("10.100.0.4"));
        assert_eq!(conventional_ip("agent1", 3).as_deref(), Some("10.100.0.5"));
        assert_eq!(conventional_ip("agent2", 3).as_deref(), Some("10.100.0.6"));
    }

    #[test]
    fn junk_names_do_not_resolve() {
        // mkMembers ranges start at 1 and pad nothing.
        for name in ["server0", "agent0", "serverx", "agent", "gateway", ""] {
            assert_eq!(conventional_ip(name, 3), None, "{name} resolved");
        }
        assert!(!is_server_name("agent1"));
        assert!(!is_server_name("server0"));
        assert!(is_server_name("server"));
        assert!(is_server_name("server12"));
    }

    #[test]
    fn ordering_is_servers_first_then_numeric() {
        let mut names = vec![
            "agent2", "server2", "agent10", "server10", "server1", "agent1",
        ];
        names.sort_by(|a, b| {
            mesh_order_key(a)
                .cmp(&mesh_order_key(b))
                .then_with(|| a.cmp(b))
        });
        assert_eq!(
            names,
            ["server1", "server2", "server10", "agent1", "agent2", "agent10"]
        );
        // The lone single-server name still leads its agents.
        let mut single = vec!["agent1", "server"];
        single.sort_by_key(|n| mesh_order_key(n));
        assert_eq!(single, ["server", "agent1"]);
    }

    // Exactly the shape builtins.toJSON emits from the launcher (keys
    // sorted, no whitespace).
    const MANIFEST: &str = concat!(
        r#"{"nodes":[{"ip":"10.100.0.2","name":"server1","role":"server"},"#,
        r#"{"ip":"10.100.0.3","name":"server2","role":"server"},"#,
        r#"{"ip":"10.100.0.5","name":"agent1","role":"agent"}],"#,
        r#""posture":"volatile"}"#
    );

    #[test]
    fn run_manifest_parses_launcher_json() {
        let m = parse_run_manifest(MANIFEST).expect("parse");
        assert_eq!(m.posture, "volatile");
        let pairs: Vec<(String, String)> = m
            .nodes
            .iter()
            .map(|n| (n.name.clone(), n.ip.clone()))
            .collect();
        assert_eq!(
            pairs,
            [
                ("server1".into(), "10.100.0.2".into()),
                ("server2".into(), "10.100.0.3".into()),
                ("agent1".into(), "10.100.0.5".into()),
            ]
        );
    }

    #[test]
    fn run_manifest_rejects_garbage() {
        assert!(parse_run_manifest("{}").is_err());
        assert!(parse_run_manifest(r#"{"nodes":[],"posture":"volatile"}"#).is_err());
        assert!(parse_run_manifest(r#"{"nodes":[{"ip":"10.100.0.2"}],"posture":"v"}"#).is_err());
    }

    #[test]
    fn mesh_take_posture_gate() {
        let volatile = parse_run_manifest(MANIFEST).unwrap();
        let durable = RunManifest {
            posture: "durable".into(),
            nodes: volatile.nodes.clone(),
        };
        // Multi-server: manifest required, and it must say volatile.
        assert!(assert_volatile_mesh_take(2, Some(&volatile)).is_ok());
        assert!(assert_volatile_mesh_take(2, None).is_err());
        assert!(assert_volatile_mesh_take(3, Some(&durable)).is_err());
        // Single-server keeps today's behavior: no manifest, no gate.
        assert!(assert_volatile_mesh_take(1, None).is_ok());
        assert!(assert_volatile_mesh_take(0, None).is_ok());
    }

    // ---- snapshot identity (§D3) --------------------------------------------

    const CPUINFO: &str = "processor\t: 0\nvendor_id\t: GenuineIntel\ncpu family\t: 6\n\
        model\t\t: 143\nmodel name\t: Xeon\nflags\t\t: fpu avx xsave amx_tile avx2 la57\n\n\
        processor\t: 1\nvendor_id\t: GenuineIntel\n";

    #[test]
    fn cpu_fingerprint_is_stable_watchlist_order() {
        // Watchlist order, not /proc flag order (avx2 listed after amx_tile
        // in the input, before it in the fingerprint).
        assert_eq!(
            cpu_fingerprint_from(CPUINFO),
            "GenuineIntel/6/143+avx,avx2,amx_tile,xsave,la57"
        );
        // A feature-set delta IS an identity delta.
        let no_amx = CPUINFO.replace(" amx_tile", "");
        assert_eq!(
            cpu_fingerprint_from(&no_amx),
            "GenuineIntel/6/143+avx,avx2,xsave,la57"
        );
        // Degenerate input still yields a comparable string, not a panic.
        assert_eq!(cpu_fingerprint_from(""), "unknown/unknown/unknown+");
    }

    fn full_identity() -> SnapIdentity {
        SnapIdentity {
            closure: Some("/nix/store/aaa-microvm-run".into()),
            vmm: Some("/nix/store/bbb-firecracker/bin/firecracker".into()),
            cpu: Some("GenuineIntel/6/143+avx,avx2".into()),
            cpu_host: None,
        }
    }

    fn templated_identity() -> SnapIdentity {
        SnapIdentity {
            closure: None,
            vmm: Some("/nix/store/bbb-firecracker/bin/firecracker".into()),
            cpu: Some("template:sha256:5dd9".into()),
            cpu_host: Some("GenuineIntel/6/173+avx,avx2,amx_tile".into()),
        }
    }

    #[test]
    fn identity_round_trips_through_manifest_lines() {
        let id = full_identity();
        assert_eq!(parse_identity(&identity_lines(&id)), id);
        // Partial identity (attached take: no closure) round-trips too, and
        // absent fields stay absent rather than becoming empty strings.
        let partial = SnapIdentity {
            closure: None,
            ..full_identity()
        };
        let lines = identity_lines(&partial);
        assert!(!lines.contains("closure"));
        assert_eq!(parse_identity(&lines), partial);
    }

    #[test]
    fn legacy_manifest_has_no_identity() {
        // Pre-identity mesh manifest: node lines only -> warn-and-proceed
        // path (read_snapshot_identity returns None via is_empty).
        let legacy = "server1 10.100.0.2\nserver2 10.100.0.3\nagent1 10.100.0.5\n";
        assert!(parse_identity(legacy).is_empty());
        // Unknown future identity fields are ignored, not misparsed.
        assert!(parse_identity("identity tsc_khz 2100000\n").is_empty());
    }

    #[test]
    fn identity_match_and_mismatch() {
        let rec = full_identity();
        // Exact match: nothing to refuse.
        assert!(identity_mismatches(&rec, &rec).is_empty());
        // Resume's live identity never knows the closure: skipped, and the
        // live-comparable vmm lock passes.
        let live = SnapIdentity {
            closure: None,
            ..full_identity()
        };
        assert!(identity_mismatches(&rec, &live).is_empty());
        // VMM drift names the vmm field (version lock).
        let other_vmm = SnapIdentity {
            vmm: Some("/nix/store/ccc-firecracker/bin/firecracker".into()),
            ..live.clone()
        };
        let m = identity_mismatches(&rec, &other_vmm);
        let fields: Vec<&str> = m.iter().map(|x| x.field).collect();
        assert_eq!(fields, ["vmm"]);
        // A field the SNAPSHOT does not carry is not enforceable either.
        let rec_no_vmm = SnapIdentity {
            vmm: None,
            ..full_identity()
        };
        assert!(identity_mismatches(&rec_no_vmm, &other_vmm)
            .iter()
            .all(|x| x.field != "vmm"));
    }

    // ---- CPU templates (portable-snapshots.org §D3) ---------------------------

    #[test]
    fn canonicalize_strips_only_insignificant_whitespace() {
        // jq-pretty vs toJSON-minified: one canonical form.
        let pretty = "{\n  \"a\": \"x y\\\" z\",\n  \"b\": [ 1, 2 ]\n}\n";
        assert_eq!(canonicalize_json(pretty), r#"{"a":"x y\" z","b":[1,2]}"#);
        // Whitespace INSIDE strings survives, including after escapes.
        assert_eq!(canonicalize_json("\"a b\""), "\"a b\"");
    }

    #[test]
    fn template_hash_is_format_independent() {
        let minified = r#"{"cpuid_modifiers":[{"leaf":"0x7"}],"msr_modifiers":[]}"#;
        let pretty = "{\n  \"cpuid_modifiers\": [\n    { \"leaf\": \"0x7\" }\n  ],\n  \"msr_modifiers\": []\n}";
        assert_eq!(template_hash(minified), template_hash(pretty));
        assert!(template_hash(minified).starts_with("sha256:"));
        assert_eq!(template_hash(minified).len(), "sha256:".len() + 64);
        // Content changes change the hash.
        assert_ne!(
            template_hash(minified),
            template_hash(&minified.replace("0x7", "0xd"))
        );
    }

    #[test]
    fn json_value_extraction_from_runner_config() {
        // The two CustomCpuTemplateOrPath variants, in jq-pretty shape.
        let cfg = "{\n  \"boot-source\": { \"kernel_image_path\": \"/nix/store/k\" },\n  \
                   \"cpu-config\": \"/nix/store/abc-cpu-config.json\",\n  \"machine-config\": {}\n}";
        assert_eq!(
            json_value_after_key(cfg, "cpu-config"),
            Some("\"/nix/store/abc-cpu-config.json\"")
        );
        let inline = r#"{ "cpu-config": {"cpuid_modifiers":[{"leaf":"0x7","modifiers":[{"bitmap":"0bx{x"}]}]}, "x": 1 }"#;
        assert_eq!(
            json_value_after_key(inline, "cpu-config"),
            Some(r#"{"cpuid_modifiers":[{"leaf":"0x7","modifiers":[{"bitmap":"0bx{x"}]}]}"#)
        );
        // Absent key: None — an untemplated take, not an error.
        assert_eq!(json_value_after_key(cfg, "cpu-template"), None);
    }

    #[test]
    fn take_cpu_identity_spellings() {
        // Templated: cpu is the template spec, cpu-host carries the (real)
        // host fingerprint next to it.
        let (cpu, host) = take_cpu_identity(Some("sha256:5dd9".into()));
        assert_eq!(cpu.as_deref(), Some("template:sha256:5dd9"));
        assert!(host.is_some());
        // Untemplated: v0.8 spelling exactly — host-keyed cpu, no cpu-host.
        let (cpu, host) = take_cpu_identity(None);
        assert!(!cpu.unwrap().starts_with(TEMPLATE_PREFIX));
        assert!(host.is_none());
    }

    #[test]
    fn cpu_gate_host_keyed_unchanged() {
        let fp = "GenuineIntel/6/143+avx,avx2";
        // Match: no mismatch, no warning — byte-for-byte the v0.8 rule.
        let (m, w) = cpu_identity_check(Some(fp), None, fp, None);
        assert!(m.is_empty() && w.is_empty());
        // Host drift refuses.
        let (m, _) = cpu_identity_check(Some(fp), None, "GenuineIntel/6/173+avx", None);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].field, "cpu");
        // Claiming a template against an untemplated artifact refuses.
        let (m, _) = cpu_identity_check(Some(fp), None, fp, Some("sha256:5dd9"));
        assert_eq!(m.len(), 1);
        assert!(m[0].why.contains("WITHOUT a template"));
    }

    #[test]
    fn cpu_gate_template_keyed() {
        let rec = "template:sha256:5dd9";
        let host_a = "GenuineIntel/6/173+avx,amx_tile";
        let host_b = "GenuineIntel/6/143+avx";
        // Same template, same host: clean pass.
        let (m, w) = cpu_identity_check(Some(rec), Some(host_a), host_a, Some("sha256:5dd9"));
        assert!(m.is_empty() && w.is_empty());
        // Same template, DIFFERENT host: warn-only — the demotion §D3 made.
        let (m, w) = cpu_identity_check(Some(rec), Some(host_a), host_b, Some("sha256:5dd9"));
        assert!(m.is_empty());
        assert_eq!(w.len(), 1);
        assert!(w[0].contains(host_a) && w[0].contains(host_b));
        // Wrong template string: exact-string refusal.
        let (m, _) = cpu_identity_check(Some(rec), Some(host_a), host_a, Some("sha256:beef"));
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].field, "cpu");
        // Templated artifact without the flag: refusal, not fallback.
        let (m, _) = cpu_identity_check(Some(rec), Some(host_a), host_a, None);
        assert_eq!(m.len(), 1);
        assert!(m[0].live.contains("no --cpu-template"));
        // Static-name templates compare literally too.
        let (m, _) = cpu_identity_check(Some("template:T2S"), None, host_a, Some("T2S"));
        assert!(m.is_empty());
        let (m, _) = cpu_identity_check(Some("template:T2S"), None, host_a, Some("T2CL"));
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn cpu_gate_partial_manifest() {
        // No recorded cpu at all: nothing enforceable without a claim…
        let (m, w) = cpu_identity_check(None, None, "any", None);
        assert!(m.is_empty() && w.is_empty());
        // …but a --cpu-template claim against it is unverifiable: refuse.
        let (m, _) = cpu_identity_check(None, None, "any", Some("sha256:5dd9"));
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn templated_identity_round_trips_and_legacy_reads_conservatively() {
        let id = templated_identity();
        let lines = identity_lines(&id);
        // The cpu line carries the template spelling; cpu-host is its own key.
        assert!(lines.contains("identity cpu template:sha256:5dd9\n"));
        assert!(lines.contains("identity cpu-host GenuineIntel/6/173+avx,avx2,amx_tile\n"));
        assert_eq!(parse_identity(&lines), id);
        // A pre-template parser maps the cpu key to its host-fingerprint
        // gate: `template:...` never equals a live fingerprint, so an old
        // binary REFUSES templated snapshots — strictly conservative.
        assert_ne!(id.cpu.as_deref().unwrap(), "GenuineIntel/6/173+avx,avx2,amx_tile");
    }

    #[test]
    fn mesh_manifest_keeps_nodes_and_identity_apart() {
        let dir = std::env::temp_dir().join(format!("kubenyx-snap-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let nodes = vec![
            MeshNode {
                name: "server1".into(),
                ip: "10.100.0.2".into(),
            },
            MeshNode {
                name: "agent1".into(),
                ip: "10.100.0.5".into(),
            },
        ];
        write_manifest(&dir, &nodes, &full_identity());
        let raw = std::fs::read_to_string(dir.join("manifest")).unwrap();
        // Node section byte-identical to the pre-identity format, first.
        assert!(raw.starts_with("server1 10.100.0.2\nagent1 10.100.0.5\nidentity "));
        // Round trip: nodes unpolluted by identity lines, identity intact.
        let back = read_manifest(&dir);
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].name, "server1");
        assert_eq!(back[1].ip, "10.100.0.5");
        assert_eq!(read_snapshot_identity(&dir), Some(full_identity()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn kubeconfig_fields_from_pki_template() {
        // Trimmed shape of rust/kubenyx-pki write_kubeconfig's template.
        let kc = "apiVersion: v1\nclusters:\n- name: kubenyx\n  cluster:\n    \
                  certificate-authority-data: Q0E=\n    server: https://10.100.0.2:6443\n\
                  users:\n- name: kubenyx-admin\n  user:\n    \
                  client-certificate-data: Q0VSVA==\n    client-key-data: S0VZ\n";
        assert_eq!(
            kubeconfig_value(kc, "server").as_deref(),
            Some("https://10.100.0.2:6443")
        );
        assert_eq!(
            kubeconfig_value(kc, "certificate-authority-data").as_deref(),
            Some("Q0E=")
        );
        assert_eq!(
            kubeconfig_value(kc, "client-key-data").as_deref(),
            Some("S0VZ")
        );
        assert_eq!(kubeconfig_value(kc, "token"), None);
    }
}
