//! Kubenyx PKI generator: the entire cluster PKI — CAs, leaves, the
//! service-account keypair and every kubeconfig — in one process.
//!
//! Replaces the openssl-forking shell script: ~80 execs became zero, which
//! is the difference between ~530ms and ~30ms on the boot critical path
//! (and seconds under emulation). Semantics are identical to the shell
//! version: fingerprint files gate regeneration, leaves renew inside the
//! renew window, kubeconfigs re-render when their cert or the server URL
//! changes, and the agent mode renders from shipped material only.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::net::IpAddr;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::exit;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, Ia5String, IsCa, KeyPair, KeyUsagePurpose, SanType, SerialNumber,
    PKCS_ECDSA_P256_SHA256,
};
use time::{Duration, OffsetDateTime};

const DAY: i64 = 86_400;

struct Cfg {
    mode: String,
    pki: PathBuf,
    kc: PathBuf,
    node_name: String,
    node_address: Option<String>,
    api_url: String,
    cluster_domain: String,
    service_ip: String,
    extra_sans: Vec<String>,
    nodes: Vec<(String, Option<String>)>,
    leaf_days: i64,
    renew_days: i64,
    etcd: bool,
    etcd_sans: Vec<String>,
    out: PathBuf,
    require_shipped_ca: bool,
}

fn parse_args() -> Cfg {
    let mut cfg = Cfg {
        mode: "server".into(),
        pki: "/var/lib/kubenyx/pki".into(),
        kc: "/var/lib/kubenyx/kubeconfigs".into(),
        node_name: String::new(),
        node_address: None,
        api_url: "https://127.0.0.1:6443".into(),
        cluster_domain: "cluster.local".into(),
        service_ip: "10.96.0.1".into(),
        extra_sans: vec![],
        nodes: vec![],
        leaf_days: 365,
        renew_days: 30,
        etcd: false,
        etcd_sans: vec![],
        out: PathBuf::new(),
        require_shipped_ca: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut val = || it.next().unwrap_or_else(|| die(&format!("missing value for {a}")));
        match a.as_str() {
            // Subcommand form: `kubenyx-pki mint-ca --out DIR` (operator
            // CLI, durable-ha.org §3) rides the same parser as the flag
            // style the units use.
            "mint-ca" => cfg.mode = "mint-ca".into(),
            "--out" => cfg.out = val().into(),
            "--require-shipped-ca" => cfg.require_shipped_ca = true,
            "--mode" => cfg.mode = val(),
            "--pki-dir" => cfg.pki = val().into(),
            "--kubeconfig-dir" => cfg.kc = val().into(),
            "--node-name" => cfg.node_name = val(),
            "--node-address" => cfg.node_address = Some(val()),
            "--api-url" => cfg.api_url = val(),
            "--cluster-domain" => cfg.cluster_domain = val(),
            "--service-ip" => cfg.service_ip = val(),
            "--extra-san" => cfg.extra_sans.push(val()),
            "--node" => {
                let v = val();
                let (n, addr) = v.split_once('=').unwrap_or((v.as_str(), ""));
                cfg.nodes.push((
                    n.to_string(),
                    if addr.is_empty() { None } else { Some(addr.to_string()) },
                ));
            }
            "--leaf-days" => cfg.leaf_days = val().parse().unwrap_or(365),
            "--renew-days" => cfg.renew_days = val().parse().unwrap_or(30),
            "--etcd" => cfg.etcd = true,
            "--etcd-san" => cfg.etcd_sans.push(val()),
            other => die(&format!("unknown flag {other}")),
        }
    }
    if cfg.node_name.is_empty() && cfg.mode != "mint-ca" {
        die("--node-name is required");
    }
    cfg
}

fn die(msg: &str) -> ! {
    eprintln!("kubenyx-pki: {msg}");
    exit(1);
}

fn main() {
    let cfg = parse_args();
    if cfg.mode == "mint-ca" {
        mint_ca(&cfg);
        return;
    }
    fs::create_dir_all(&cfg.pki).unwrap_or_else(|e| die(&format!("mkdir pki: {e}")));
    fs::create_dir_all(&cfg.kc).unwrap_or_else(|e| die(&format!("mkdir kubeconfigs: {e}")));
    for d in [&cfg.pki, &cfg.kc] {
        let _ = fs::set_permissions(d, fs::Permissions::from_mode(0o700));
    }
    match cfg.mode.as_str() {
        "server" => server(&cfg),
        "agent" => agent(&cfg),
        m => die(&format!("unknown mode {m}")),
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn write_private(path: &Path, data: &str) {
    // Full-name suffix (not with_extension) so foo.crt and foo.key never
    // share a temp file; fsync before rename so a crash can't commit the
    // rename ahead of the data and leave a zero-length CA behind.
    let tmp = PathBuf::from(format!("{}.tmp", path.display()));
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .unwrap_or_else(|e| die(&format!("open {}: {e}", tmp.display())));
    f.write_all(data.as_bytes())
        .unwrap_or_else(|e| die(&format!("write {}: {e}", tmp.display())));
    f.sync_all()
        .unwrap_or_else(|e| die(&format!("fsync {}: {e}", tmp.display())));
    fs::rename(&tmp, path).unwrap_or_else(|e| die(&format!("rename {}: {e}", path.display())));
}

fn non_empty(path: &Path) -> bool {
    fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false)
}

/// Cheap change-detection digest (FNV-1a); not security-relevant — it only
/// decides whether regeneration is needed.
fn fnv1a(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in data {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn not_after_ts(pem: &str) -> Option<i64> {
    let der = x509_parser::pem::parse_x509_pem(pem.as_bytes()).ok()?.1;
    let cert = der.parse_x509().ok()?;
    Some(cert.validity().not_after.timestamp())
}

fn now() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}

fn random_serial() -> SerialNumber {
    let mut b = [0u8; 16];
    getrandom::getrandom(&mut b).expect("getrandom");
    b[0] &= 0x7f; // keep it positive
    SerialNumber::from_slice(&b)
}

/// Rebuild an in-memory issuer (Certificate + KeyPair + on-disk PEM) from
/// disk. The PEM rides along so fingerprints can bind to the CA identity.
fn load_issuer(pki: &Path, name: &str) -> (Certificate, KeyPair, String) {
    let crt = fs::read_to_string(pki.join(format!("{name}.crt")))
        .unwrap_or_else(|e| die(&format!("read {name}.crt: {e}")));
    let key = fs::read_to_string(pki.join(format!("{name}.key")))
        .unwrap_or_else(|e| die(&format!("read {name}.key: {e}")));
    let kp = KeyPair::from_pem(&key).unwrap_or_else(|e| die(&format!("parse {name}.key: {e}")));
    let params = CertificateParams::from_ca_cert_pem(&crt)
        .unwrap_or_else(|e| die(&format!("parse {name}.crt: {e}")));
    let cert = params
        .self_signed(&kp)
        .unwrap_or_else(|e| die(&format!("rebuild issuer {name}: {e}")));
    (cert, kp, crt)
}

fn ensure_ca(pki: &Path, name: &str, cn: &str) {
    let crt = pki.join(format!("{name}.crt"));
    let key = pki.join(format!("{name}.key"));
    if non_empty(&crt) && non_empty(&key) {
        return;
    }
    let kp = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).expect("keygen");
    let mut params = CertificateParams::default();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.serial_number = Some(random_serial());
    params.not_before = OffsetDateTime::now_utc() - Duration::minutes(5);
    params.not_after = OffsetDateTime::now_utc() + Duration::days(3650);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, cn);
    params.distinguished_name = dn;
    let cert = params.self_signed(&kp).expect("self-sign CA");
    write_private(&key, &kp.serialize_pem());
    write_private(&crt, &cert.pem());
    eprintln!("kubenyx-pki: issued CA {name}");
}

/// Service-account signing keypair (ECDSA -> ES256 tokens). Present-file
/// gated like the CAs: never regenerated once it exists.
fn ensure_sa(pki: &Path) {
    if pki.join("sa.key").exists() {
        return;
    }
    use p256::pkcs8::{EncodePrivateKey, EncodePublicKey};
    let sk = p256::SecretKey::random(&mut rand_core::OsRng);
    let pk = sk.public_key();
    write_private(&pki.join("sa.key"), sk.to_pkcs8_pem(Default::default()).expect("sa pem").as_str());
    write_private(&pki.join("sa.pub"), &pk.to_public_key_pem(Default::default()).expect("sa pub"));
}

/// The operator-custody trust roots (durable-ha.org §3): both CAs and the
/// SA keypair. Every server of an HA set must hold the SAME six files —
/// a diverged CA partitions trust, a diverged SA key partitions token
/// verification across apiservers.
const CUSTODY_FILES: [&str; 6] = [
    "ca.crt",
    "ca.key",
    "front-proxy-ca.crt",
    "front-proxy-ca.key",
    "sa.key",
    "sa.pub",
];

struct Issue<'a> {
    pki: &'a Path,
    renew_secs: i64,
    leaf_days: i64,
}

impl<'a> Issue<'a> {
    /// Regenerate when missing, when the recorded generation parameters
    /// changed, or when inside the renewal window. `san` entries use the
    /// "DNS:x" / "IP:1.2.3.4" convention.
    fn ensure(
        &self,
        issuer: &(Certificate, KeyPair, String),
        ca_name: &str,
        name: &str,
        cn: &str,
        org: Option<&str>,
        ekus: &[ExtendedKeyUsagePurpose],
        san: &[String],
    ) {
        let dir = self.pki.join(name).parent().map(Path::to_path_buf).unwrap();
        fs::create_dir_all(&dir).ok();
        let crt_p = self.pki.join(format!("{name}.crt"));
        let key_p = self.pki.join(format!("{name}.key"));
        let fp_p = self.pki.join(format!(".fp.{}", name.replace('/', "_")));

        let subject = match org {
            Some(o) => format!("/O={o}/CN={cn}"),
            None => format!("/CN={cn}"),
        };
        let eku_s = ekus
            .iter()
            .map(|e| match e {
                ExtendedKeyUsagePurpose::ServerAuth => "serverAuth",
                ExtendedKeyUsagePurpose::ClientAuth => "clientAuth",
                _ => "other",
            })
            .collect::<Vec<_>>()
            .join(",");
        // The CA digest ties leaves to the actual CA identity: rotating or
        // restoring a different CA must cascade into leaf reissuance.
        let ca_digest = fnv1a(issuer.2.as_bytes());
        let want = format!("{subject}|{eku_s}|{}|{ca_name}:{ca_digest:016x}", san.join(","));

        if let (Ok(crt_pem), true, Ok(prev)) = (
            fs::read_to_string(&crt_p),
            key_p.exists(),
            fs::read_to_string(&fp_p),
        ) {
            if prev.trim_end() == want {
                if let Some(na) = not_after_ts(&crt_pem) {
                    if na > now() + self.renew_secs {
                        return;
                    }
                }
            }
        }

        eprintln!("kubenyx-pki: issuing {name}");
        let kp = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).expect("keygen");
        let mut params = CertificateParams::default();
        params.serial_number = Some(random_serial());
        params.not_before = OffsetDateTime::now_utc() - Duration::minutes(5);
        params.not_after = OffsetDateTime::now_utc() + Duration::days(self.leaf_days);
        params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyEncipherment,
        ];
        params.extended_key_usages = ekus.to_vec();
        let mut dn = DistinguishedName::new();
        if let Some(o) = org {
            dn.push(DnType::OrganizationName, o);
        }
        dn.push(DnType::CommonName, cn);
        params.distinguished_name = dn;
        for s in san {
            if let Some(d) = s.strip_prefix("DNS:") {
                params
                    .subject_alt_names
                    .push(SanType::DnsName(Ia5String::try_from(d.to_string()).expect("dns san")));
            } else if let Some(ip) = s.strip_prefix("IP:") {
                let addr: IpAddr = ip.parse().unwrap_or_else(|_| die(&format!("bad IP SAN {ip}")));
                params.subject_alt_names.push(SanType::IpAddress(addr));
            } else {
                die(&format!("bad SAN {s} (want DNS:/IP: prefix)"));
            }
        }
        let cert = params
            .signed_by(&kp, &issuer.0, &issuer.1)
            .unwrap_or_else(|e| die(&format!("sign {name}: {e}")));
        write_private(&key_p, &kp.serialize_pem());
        write_private(&crt_p, &cert.pem());
        write_private(&fp_p, &want);
    }
}

fn write_kubeconfig(kc: &Path, out: &str, api_url: &str, user: &str, ca_pem: &str, crt: &Path, key: &Path) {
    let out_p = kc.join(out);
    let crt_pem = fs::read_to_string(crt).unwrap_or_else(|e| die(&format!("read {}: {e}", crt.display())));
    let key_pem = fs::read_to_string(key).unwrap_or_else(|e| die(&format!("read {}: {e}", key.display())));
    // Content equality, not mtimes: mtime-preserving transports (tar, rsync
    // -a) would otherwise leave stale embedded certs after a re-ship.
    if let Ok(body) = fs::read_to_string(&out_p) {
        if body.contains(&format!("server: {api_url}\n"))
            && body.contains(&B64.encode(crt_pem.as_bytes()))
            && body.contains(&B64.encode(ca_pem.as_bytes()))
        {
            return;
        }
    }
    let cfg = format!(
        "apiVersion: v1\nkind: Config\nclusters:\n- name: kubenyx\n  cluster:\n    certificate-authority-data: {}\n    server: {}\nusers:\n- name: {}\n  user:\n    client-certificate-data: {}\n    client-key-data: {}\ncontexts:\n- name: default\n  context:\n    cluster: kubenyx\n    user: {}\ncurrent-context: default\n",
        B64.encode(ca_pem.as_bytes()),
        api_url,
        user,
        B64.encode(crt_pem.as_bytes()),
        B64.encode(key_pem.as_bytes()),
        user,
    );
    write_private(&out_p, &cfg);
}

fn detect_node_ip() -> String {
    // Default-route trick first: a UDP connect sends no packets but binds
    // the source address the kernel would route with. v4, then v6.
    for (bind, target) in [("0.0.0.0:0", "1.1.1.1:53"), ("[::]:0", "[2606:4700:4700::1111]:53")] {
        if let Ok(sock) = std::net::UdpSocket::bind(bind) {
            if sock.connect(target).is_ok() {
                if let Ok(addr) = sock.local_addr() {
                    let ip = addr.ip();
                    if !ip.is_loopback() {
                        return ip.to_string();
                    }
                }
            }
        }
    }
    // No default route (isolated test VMs): first global address, v4 first.
    if let Ok(ifs) = if_addrs::get_if_addrs() {
        for i in &ifs {
            if let IpAddr::V4(v4) = i.addr.ip() {
                if !v4.is_loopback() && !v4.is_link_local() {
                    return v4.to_string();
                }
            }
        }
        for i in &ifs {
            if let IpAddr::V6(v6) = i.addr.ip() {
                if !v6.is_loopback() && (v6.segments()[0] & 0xffc0) != 0xfe80 {
                    return v6.to_string();
                }
            }
        }
    }
    eprintln!("kubenyx-pki: WARNING: no routable address detected; using 127.0.0.1 — declare kubenyx.nodes.<name>.address for anything reachable remotely");
    "127.0.0.1".into()
}

// ---------------------------------------------------------------------------
// Server mode
// ---------------------------------------------------------------------------

fn server(cfg: &Cfg) {
    let pki = cfg.pki.as_path();
    let node_ip = cfg
        .node_address
        .clone()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(detect_node_ip);

    if cfg.require_shipped_ca {
        // Durable posture (durable-ha.org §3, Decision 2): the trust roots
        // are operator custody. Any missing piece is a hard boot error —
        // never a silent re-mint, which would partition the cluster's
        // trust (and a partially-present set regenerating BOTH halves of a
        // CA is exactly the silent-re-mint hazard this closes).
        let missing: Vec<&str> = CUSTODY_FILES
            .iter()
            .filter(|f| !non_empty(&pki.join(f)))
            .copied()
            .collect();
        if !missing.is_empty() {
            die(&format!(
                "durable posture (balanced profile + persistent datastore) requires an operator-shipped CA bundle, but {} is missing: {}. Mint it offline with `kubenyx-pki mint-ca --out ca-bundle/`, ship the bundle's files into this directory over the operator channel, and keep the original wherever secrets live. Refusing to self-mint: a re-minted CA would partition the cluster's trust.",
                pki.display(),
                missing.join(" ")
            ));
        }
        // Shipping transports rarely preserve modes; enforce ours.
        for f in CUSTODY_FILES {
            let _ = fs::set_permissions(pki.join(f), fs::Permissions::from_mode(0o600));
        }
    } else {
        // Volatile/testing posture: per-boot self-mint stays the behavior.
        ensure_ca(pki, "ca", "kubenyx-ca");
        // Distinct front-proxy CA (must never be the client CA — spoofing risk).
        ensure_ca(pki, "front-proxy-ca", "kubenyx-front-proxy-ca");
        ensure_sa(pki);
    }

    let ca = load_issuer(pki, "ca");
    let fp_ca = load_issuer(pki, "front-proxy-ca");
    let issue = Issue {
        pki,
        renew_secs: cfg.renew_days * DAY,
        leaf_days: cfg.leaf_days,
    };
    use ExtendedKeyUsagePurpose::{ClientAuth, ServerAuth};

    let mut api_san: Vec<String> = vec![
        "DNS:kubernetes".into(),
        "DNS:kubernetes.default".into(),
        "DNS:kubernetes.default.svc".into(),
        format!("DNS:kubernetes.default.svc.{}", cfg.cluster_domain),
        format!("DNS:{}", cfg.node_name),
        "DNS:localhost".into(),
        "IP:127.0.0.1".into(),
        format!("IP:{}", cfg.service_ip),
        format!("IP:{node_ip}"),
    ];
    api_san.extend(cfg.extra_sans.iter().cloned());

    issue.ensure(&ca, "ca", "apiserver", "kube-apiserver", None, &[ServerAuth], &api_san);
    issue.ensure(&ca, "ca", "apiserver-kubelet-client", "kube-apiserver-kubelet-client", None, &[ClientAuth], &[]);
    issue.ensure(&fp_ca, "front-proxy-ca", "front-proxy-client", "front-proxy-client", None, &[ClientAuth], &[]);
    issue.ensure(&ca, "ca", "admin", "kubenyx-admin", Some("kubenyx:cluster-admins"), &[ClientAuth], &[]);
    // Bootstrap identity for the addon applier: the one deliberate
    // system:masters cert (kubeadm's super-admin analog).
    issue.ensure(&ca, "ca", "bootstrap", "kubenyx-bootstrap", Some("system:masters"), &[ClientAuth], &[]);
    issue.ensure(&ca, "ca", "controller-manager", "system:kube-controller-manager", None, &[ClientAuth], &[]);
    issue.ensure(&ca, "ca", "scheduler", "system:kube-scheduler", None, &[ClientAuth], &[]);
    issue.ensure(&ca, "ca", "kube-proxy", "system:kube-proxy", None, &[ClientAuth], &[]);
    issue.ensure(&ca, "ca", "coredns", "system:coredns", None, &[ClientAuth], &[]);
    // Authenticated-but-unprivileged identity for health probes.
    issue.ensure(&ca, "ca", "healthz", "kubenyx-healthz", None, &[ClientAuth], &[]);

    if cfg.etcd {
        // Multi-server quorum (durable-ha.org §2): the declared server
        // addresses ride in as --etcd-san entries, extending the loopback
        // SANs the single-server path keeps — same pattern as the apiserver
        // SAN list above. One cert serves both the client and peer ports
        // (ServerAuth + ClientAuth), so peer TLS verifies in both
        // directions against the peer URLs' IPs.
        let mut etcd_san: Vec<String> = vec!["DNS:localhost".into(), "IP:127.0.0.1".into()];
        etcd_san.extend(cfg.etcd_sans.iter().cloned());
        issue.ensure(&ca, "ca", "etcd-server", "kube-etcd", None, &[ServerAuth, ClientAuth],
            &etcd_san);
        issue.ensure(&ca, "ca", "apiserver-etcd-client", "kube-apiserver-etcd-client", None, &[ClientAuth], &[]);
    }

    // Kubelet material for every declared node.
    for (name, addr) in &cfg.nodes {
        let mut san = vec![format!("DNS:{name}"), "IP:127.0.0.1".into()];
        match addr {
            Some(a) => san.push(format!("IP:{a}")),
            None if name == &cfg.node_name => san.push(format!("IP:{node_ip}")),
            None => {}
        }
        issue.ensure(&ca, "ca", &format!("nodes/{name}/kubelet"),
            &format!("system:node:{name}"), Some("system:nodes"), &[ClientAuth], &[]);
        issue.ensure(&ca, "ca", &format!("nodes/{name}/kubelet-server"),
            &format!("system:node:{name}"), None, &[ServerAuth], &san);
    }

    // Package a one-stop credential directory per remote worker; the CA key
    // never leaves this node.
    for (name, _) in &cfg.nodes {
        if name == &cfg.node_name {
            continue;
        }
        let dir = pki.join("nodes").join(name);
        for f in ["ca.crt", "kube-proxy.crt", "kube-proxy.key", "coredns.crt", "coredns.key"] {
            fs::copy(pki.join(f), dir.join(f))
                .unwrap_or_else(|e| die(&format!("package {name}/{f}: {e}")));
        }
    }

    let ca_pem = fs::read_to_string(pki.join("ca.crt")).expect("ca.crt");
    let kc = cfg.kc.as_path();
    let mut kcs: BTreeMap<&str, (&str, String)> = BTreeMap::new();
    kcs.insert("admin.kubeconfig", ("kubenyx-admin", "admin".into()));
    kcs.insert("bootstrap.kubeconfig", ("kubenyx-bootstrap", "bootstrap".into()));
    kcs.insert("controller-manager.kubeconfig", ("system:kube-controller-manager", "controller-manager".into()));
    kcs.insert("scheduler.kubeconfig", ("system:kube-scheduler", "scheduler".into()));
    kcs.insert("kube-proxy.kubeconfig", ("system:kube-proxy", "kube-proxy".into()));
    kcs.insert("coredns.kubeconfig", ("system:coredns", "coredns".into()));
    for (out, (user, base)) in &kcs {
        write_kubeconfig(kc, out, &cfg.api_url, user, &ca_pem,
            &pki.join(format!("{base}.crt")), &pki.join(format!("{base}.key")));
    }
    let kubelet_base = format!("nodes/{}/kubelet", cfg.node_name);
    write_kubeconfig(kc, "kubelet.kubeconfig", &cfg.api_url,
        &format!("system:node:{}", cfg.node_name), &ca_pem,
        &pki.join(format!("{kubelet_base}.crt")), &pki.join(format!("{kubelet_base}.key")));
}

// ---------------------------------------------------------------------------
// Agent mode
// ---------------------------------------------------------------------------

fn agent(cfg: &Cfg) {
    let pki = cfg.pki.as_path();
    let needed = [
        "ca.crt", "kubelet.crt", "kubelet.key", "kubelet-server.crt", "kubelet-server.key",
        "kube-proxy.crt", "kube-proxy.key", "coredns.crt", "coredns.key",
    ];
    let missing: Vec<&str> = needed
        .iter()
        .filter(|f| fs::metadata(pki.join(f)).map(|m| m.len() == 0).unwrap_or(true))
        .copied()
        .collect();
    if !missing.is_empty() {
        eprintln!(
            "kubenyx-pki: waiting for PKI material in {} (missing: {})",
            pki.display(),
            missing.join(" ")
        );
        eprintln!(
            "kubenyx-pki: on the server, ship its pki/nodes/{}/ directory here",
            cfg.node_name
        );
        return; // exit 0: a path unit re-runs us on arrival
    }
    // Shipped transports rarely preserve modes; enforce ours.
    for f in needed {
        let _ = fs::set_permissions(pki.join(f), fs::Permissions::from_mode(0o600));
    }
    // Renewal is re-shipping; surface approaching expiry loudly.
    if let Ok(pem) = fs::read_to_string(pki.join("kubelet.crt")) {
        if let Some(na) = not_after_ts(&pem) {
            if na < now() + 14 * DAY {
                eprintln!("kubenyx-pki: WARNING: kubelet.crt expires within 14 days — re-ship this node's credentials from the server");
            }
        }
    }
    let ca_pem = fs::read_to_string(pki.join("ca.crt")).expect("ca.crt");
    let kc = cfg.kc.as_path();
    write_kubeconfig(kc, "kubelet.kubeconfig", &cfg.api_url,
        &format!("system:node:{}", cfg.node_name), &ca_pem,
        &pki.join("kubelet.crt"), &pki.join("kubelet.key"));
    write_kubeconfig(kc, "kube-proxy.kubeconfig", &cfg.api_url, "system:kube-proxy", &ca_pem,
        &pki.join("kube-proxy.crt"), &pki.join("kube-proxy.key"));
    write_kubeconfig(kc, "coredns.kubeconfig", &cfg.api_url, "system:coredns", &ca_pem,
        &pki.join("coredns.crt"), &pki.join("coredns.key"));
}

// ---------------------------------------------------------------------------
// mint-ca: offline operator custody (durable-ha.org §3, Decision 2)
// ---------------------------------------------------------------------------

/// Mint the durable trust roots off-cluster: cluster CA, front-proxy CA and
/// the service-account keypair, to --out DIR. Reuses the exact issuance code
/// the server boot path runs, so a shipped bundle is indistinguishable from
/// a self-minted one — only the custody changes. Idempotent: existing files
/// are never overwritten, so re-running against the operator's bundle
/// directory is safe.
fn mint_ca(cfg: &Cfg) {
    if cfg.out.as_os_str().is_empty() {
        die("mint-ca requires --out DIR");
    }
    let out = cfg.out.as_path();
    fs::create_dir_all(out).unwrap_or_else(|e| die(&format!("mkdir {}: {e}", out.display())));
    let _ = fs::set_permissions(out, fs::Permissions::from_mode(0o700));
    ensure_ca(out, "ca", "kubenyx-ca");
    ensure_ca(out, "front-proxy-ca", "kubenyx-front-proxy-ca");
    ensure_sa(out);
    eprintln!("kubenyx-pki: CA bundle ready in {}:", out.display());
    for f in CUSTODY_FILES {
        eprintln!("kubenyx-pki:   {f}");
    }
    eprintln!("kubenyx-pki: ship these files into each durable server's pki directory (default /var/lib/kubenyx/pki) over the operator channel, and keep this directory wherever secrets live — the fingerprint gate cascades leaf reissuance from the shipped CA automatically");
}
