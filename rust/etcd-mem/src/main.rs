// etcd-mem: minimal in-memory etcd v3 gRPC server for kubenyx volatile clusters.
//
// Listens on a Unix domain socket (same security model as kine: directory
// permissions replace client-cert auth on loopback). Startup: <10ms vs
// kine/etcd's ~2s Go runtime + SQLite init.
//
// Usage: etcd-mem --listen-address unix:///run/kubenyx/etcd-mem/etcd-mem.sock

mod store;
mod svc;

// Include the protobuf-generated code.  The OUT_DIR is set by tonic-build.
pub mod etcd {
    tonic::include_proto!("etcdserverpb");
}

use std::path::PathBuf;
use std::time::Duration;
use tonic::transport::Server;

use etcd::cluster_server::ClusterServer;
use etcd::kv_server::KvServer;
use etcd::lease_server::LeaseServer;
use etcd::maintenance_server::MaintenanceServer;
use etcd::watch_server::WatchServer;

fn parse_socket_path(addr: &str) -> PathBuf {
    // Accept "unix:///absolute/path" or "/absolute/path"
    let path = addr
        .strip_prefix("unix://")
        .or_else(|| addr.strip_prefix("unix:"))
        .unwrap_or(addr);
    PathBuf::from(path)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse --listen-address (only flag we support)
    let mut listen = String::from("unix:///run/kubenyx/etcd-mem/etcd-mem.sock");
    let mut args = std::env::args().skip(1).peekable();
    while let Some(arg) = args.next() {
        if arg == "--listen-address" || arg == "--listen-addr" {
            if let Some(val) = args.next() {
                listen = val;
            }
        } else if let Some(val) = arg
            .strip_prefix("--listen-address=")
            .or_else(|| arg.strip_prefix("--listen-addr="))
        {
            listen = val.to_string();
        }
    }

    let sock_path = parse_socket_path(&listen);

    // Remove stale socket file.
    if sock_path.exists() {
        let _ = std::fs::remove_file(&sock_path);
    }

    // Create parent directory if missing.
    if let Some(parent) = sock_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let (shared, _initial_rx) = store::Store::new();

    // Lease expiry background task: evict expired leases every 500ms.
    let store_for_gc = shared.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(500));
        loop {
            interval.tick().await;
            let expired = {
                let store = store_for_gc.lock().await;
                store.expired_leases()
            };
            if !expired.is_empty() {
                let mut store = store_for_gc.lock().await;
                for id in expired {
                    store.lease_revoke(id);
                }
            }
        }
    });

    // gRPC health service (optional — apiserver may probe /health).
    let (mut health_reporter, health_svc) = tonic_health::server::health_reporter();
    health_reporter.set_serving::<KvServer<svc::KvSvc>>().await;
    health_reporter
        .set_serving::<WatchServer<svc::WatchSvc>>()
        .await;

    // Bind Unix domain socket listener.
    let uds = tokio::net::UnixListener::bind(&sock_path)?;
    let incoming = tokio_stream::wrappers::UnixListenerStream::new(uds);

    // Send sd_notify READY=1 so kubenyx-ready (the Type=notify wrapper) gets
    // the signal without needing to probe the socket.  If the env var isn't
    // set (i.e. not running under systemd), this is a no-op.
    notify_ready();

    eprintln!("etcd-mem: listening on {listen} (rev=0)");

    Server::builder()
        .add_service(health_svc)
        .add_service(KvServer::new(svc::KvSvc(shared.clone())))
        .add_service(WatchServer::new(svc::WatchSvc(shared.clone())))
        .add_service(LeaseServer::new(svc::LeaseSvc(shared.clone())))
        .add_service(ClusterServer::new(svc::ClusterSvc(shared.clone())))
        .add_service(MaintenanceServer::new(svc::MaintenanceSvc(shared.clone())))
        .serve_with_incoming_shutdown(incoming, shutdown_signal())
        .await?;

    // Clean up socket on orderly shutdown.
    let _ = std::fs::remove_file(&sock_path);

    Ok(())
}

fn notify_ready() {
    // Write to $NOTIFY_SOCKET if set (systemd sd_notify protocol).
    if let Ok(sock) = std::env::var("NOTIFY_SOCKET") {
        let path = if sock.starts_with('@') {
            // Abstract socket — we skip abstract sockets; kubenyx-ready probes the
            // Unix listen socket instead.
            return;
        } else {
            sock
        };
        use std::os::unix::net::UnixDatagram;
        if let Ok(uds) = UnixDatagram::unbound() {
            let _ = uds.send_to(b"READY=1", path);
        }
    }
}

async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = signal(SignalKind::terminate()).expect("SIGTERM handler");
    let mut sigint = signal(SignalKind::interrupt()).expect("SIGINT handler");
    tokio::select! {
        _ = sigterm.recv() => {}
        _ = sigint.recv()  => {}
    }
}
