//! Standalone smoke: two dummy TCP backends behind a real kubenyx-lb
//! process, kill one, traffic moves. Runs under plain `cargo test` (and the
//! nix checkPhase) — the backends speak plaintext HTTP, so the LB gets
//! --probe-http (the probe transport is the only difference from
//! production; eviction, readmission, forwarding and drain are the real
//! code paths).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};

struct DummyBackend {
    port: u16,
    stop: Arc<AtomicBool>,
}

impl DummyBackend {
    /// Serve "HTTP 200, body = id" to every request (probe or proxied).
    fn start(id: &'static str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind backend");
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            loop {
                if stop2.load(Ordering::SeqCst) {
                    return; // drops the listener: port turns connection-refused
                }
                match listener.accept() {
                    Ok((mut s, _)) => {
                        let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
                        // Drain the request head so close() cannot RST the
                        // response tail (the mesh's serve-script bug).
                        let mut req = Vec::new();
                        let mut buf = [0u8; 1024];
                        loop {
                            match s.read(&mut buf) {
                                Ok(0) => break,
                                Ok(n) => {
                                    req.extend_from_slice(&buf[..n]);
                                    if req.windows(4).any(|w| w == b"\r\n\r\n") {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        let _ = write!(
                            s,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                            id.len(),
                            id
                        );
                        let _ = s.flush();
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
        });
        DummyBackend { port, stop }
    }

    fn kill(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

/// One request through the LB; returns the response body (backend id).
fn get_via(lb_addr: &str) -> Option<String> {
    let mut s = TcpStream::connect(lb_addr).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    write!(s, "GET / HTTP/1.1\r\nHost: lb\r\nConnection: close\r\n\r\n").ok()?;
    let mut out = String::new();
    // read_to_string until EOF exercises the LB's per-direction shutdown
    // propagation: the backend's close must reach us as EOF, not a hang.
    s.read_to_string(&mut out).ok()?;
    if !out.starts_with("HTTP/1.1 200") {
        return None;
    }
    out.split("\r\n\r\n").nth(1).map(str::to_string)
}

fn wait_for_line(rx: &Receiver<String>, prefix: &str, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            panic!("timed out waiting for stderr line starting with {prefix:?}");
        }
        match rx.recv_timeout(left) {
            Ok(line) if line.starts_with(prefix) => return line,
            Ok(_) => continue,
            Err(_) => panic!("LB stderr closed while waiting for {prefix:?}"),
        }
    }
}

#[test]
fn failover_and_drain() {
    let b1 = DummyBackend::start("b1");
    let b2 = DummyBackend::start("b2");

    let mut lb = Command::new(env!("CARGO_BIN_EXE_kubenyx-lb"))
        .args([
            "--listen", "127.0.0.1:0",
            "--backend", &format!("127.0.0.1:{}", b1.port),
            "--backend", &format!("127.0.0.1:{}", b2.port),
            "--probe-interval-ms", "50",
            "--fail-threshold", "2",
            "--drain-timeout-ms", "2000",
            "--probe-http",
        ])
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn kubenyx-lb");

    let (tx, rx) = channel::<String>();
    let stderr = lb.stderr.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            eprintln!("[lb] {line}");
            if tx.send(line).is_err() {
                return;
            }
        }
    });

    let listen = wait_for_line(&rx, "KUBENYX-LB-LISTEN ", Duration::from_secs(5));
    let lb_addr = listen.trim_start_matches("KUBENYX-LB-LISTEN ").trim().to_string();
    wait_for_line(&rx, "KUBENYX-LB-READY", Duration::from_secs(5));

    // Both backends serve; round-robin should hit each within a few tries.
    let mut seen = std::collections::BTreeSet::new();
    for _ in 0..8 {
        let body = get_via(&lb_addr).expect("request through LB");
        seen.insert(body);
    }
    assert!(
        seen.contains("b1") && seen.contains("b2"),
        "round-robin should reach both backends, saw {seen:?}"
    );

    // Kill b1: probes fail, eviction fires, traffic moves without errors
    // (pre-eviction dials to the dead port fall through to the next
    // backend, so every request keeps succeeding).
    b1.kill();
    wait_for_line(&rx, "KUBENYX-LB-EVICT ", Duration::from_secs(5));
    for _ in 0..5 {
        let body = get_via(&lb_addr).expect("request after failover");
        assert_eq!(body, "b2", "all traffic must move to the surviving backend");
    }

    // SIGTERM: drain and exit 0 within the drain window.
    unsafe {
        libc::kill(lb.id() as i32, libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(st) = lb.try_wait().expect("try_wait") {
            break st;
        }
        assert!(Instant::now() < deadline, "LB did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(status.success(), "drain must exit 0, got {status:?}");
}
