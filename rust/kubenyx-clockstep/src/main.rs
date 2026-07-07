//! Post-restore wall-clock correction for snapshotted microVMs.
//!
//! A restored firecracker snapshot resumes with TSC/kvmclock state intact,
//! so CLOCK_MONOTONIC continues seamlessly — but CLOCK_REALTIME is stale by
//! exactly (restore − snapshot) wall time and nothing in the guest resyncs
//! it: firecracker 1.15 attaches no VMCLOCK ACPI device (verified on the
//! EC2 KVM session), there is no RTC, and the kernel reads KVM wallclock
//! only at boot. Instead, `kubenyx-snap resume` on the host sends a few
//! authenticated-by-network-position UDP time pokes right after
//! /snapshot/load; this daemon receives them and steps the clock.
//!
//! Protocol (one 17-byte datagram, little-endian):
//!   b"KNXT1" | i64 tv_sec | i32 tv_nsec
//!
//! Steps only when the offset exceeds the threshold (default 500ms), so
//! pokes to a fresh, correctly-clocked boot are no-ops. The tap network is
//! host↔guest only; packets are additionally filtered by source address.

use std::net::UdpSocket;
use std::process::exit;

const MAGIC: &[u8; 5] = b"KNXT1";

fn die(msg: &str) -> ! {
    eprintln!("kubenyx-clockstep: {msg}");
    exit(2);
}

fn console_log(msg: &str) {
    // The journal may be mid-rotation right after a restore; the console
    // marker is the interface the bench tooling greps either way.
    use std::io::Write;
    if let Ok(mut c) = std::fs::OpenOptions::new().write(true).open("/dev/console") {
        let _ = writeln!(c, "{msg}");
    }
    println!("{msg}");
}

fn main() {
    let mut listen = "0.0.0.0:10123".to_string();
    let mut allow_from: Option<String> = None;
    let mut min_step_ms: i64 = 500;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--listen" => {
                listen = args.get(i + 1).cloned().unwrap_or_else(|| die("--listen needs a value"));
                i += 2;
            }
            "--allow-from" => {
                allow_from = Some(args.get(i + 1).cloned().unwrap_or_else(|| die("--allow-from needs a value")));
                i += 2;
            }
            "--min-step-ms" => {
                min_step_ms = args
                    .get(i + 1)
                    .and_then(|v| v.parse().ok())
                    .unwrap_or_else(|| die("--min-step-ms needs an integer"));
                i += 2;
            }
            other => die(&format!("unknown flag {other}")),
        }
    }

    let sock = UdpSocket::bind(&listen).unwrap_or_else(|e| die(&format!("bind {listen}: {e}")));
    let mut buf = [0u8; 64];
    loop {
        let (n, src) = match sock.recv_from(&mut buf) {
            Ok(x) => x,
            Err(_) => continue,
        };
        if n < 17 || &buf[..5] != MAGIC {
            continue;
        }
        if let Some(ref allow) = allow_from {
            if src.ip().to_string() != *allow {
                continue;
            }
        }
        let sec = i64::from_le_bytes(buf[5..13].try_into().unwrap());
        let nsec = i64::from(i32::from_le_bytes(buf[13..17].try_into().unwrap()));
        if !(0..1_000_000_000).contains(&nsec) || sec <= 0 {
            continue;
        }

        let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut now) };
        let delta_ms = (sec - now.tv_sec) * 1000 + (nsec - now.tv_nsec) / 1_000_000;
        if delta_ms.abs() < min_step_ms {
            continue;
        }

        let ts = libc::timespec { tv_sec: sec, tv_nsec: nsec };
        let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) };
        if rc == 0 {
            console_log(&format!("KUBENYX-CLOCKSTEP stepped={delta_ms}ms from={src}"));
        } else {
            console_log(&format!(
                "KUBENYX-CLOCKSTEP failed delta={delta_ms}ms errno={}",
                std::io::Error::last_os_error()
            ));
        }
    }
}
