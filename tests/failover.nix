# Failover (air/v0.3/durable-ha.org, test matrix "failover"): extends the
# multi-server topology — same 3 servers + 1 agent, same offline-CA custody
# bootstrap — then proves the two HA claims live:
#
#   1. Server loss: crash the first server (hard power loss, driver crash()).
#      The agent's kubenyx-lb evicts the dead backend and the API keeps
#      answering THROUGH THE LB PATH within 15s — including reading an
#      object written before the crash — and writes still land on the 2/3
#      quorum.
#   2. Datastore member loss: kill -9 etcd on a surviving member. systemd
#      restarts it, the member rejoins (fsync is on: the balanced profile's
#      durable posture), and nothing written before the kill is lost.
#
# The agent-side proof deliberately uses an admin kubeconfig shipped from a
# server (driver-mediated, like every credential here) with --server
# overridden to https://127.0.0.1:6444: the kubelet identity cannot read
# arbitrary configmaps (Node authorizer), and the apiserver certs carry
# IP:127.0.0.1 exactly so TLS verification holds through the forwarder.
{ kubenyx }:
args@{ pkgs, lib, ... }:
let
  base = import ./multi-server.nix { inherit kubenyx; } args;
in
base
// {
  name = "kubenyx-failover";

  # The whole multi-server bootstrap runs first (offline mint, custody gate,
  # quorum, LB READY, all nodes Ready) — its variables (servers, etcdctl)
  # stay in scope for the failover phases appended below.
  testScript = base.testScript + ''
    import time

    # --- Failover phase 1: lose a server (durable-ha.org Goals: "lose any
    # one server of 3 with zero data loss and continued API service").
    # Ship an admin kubeconfig to the agent while every server is alive;
    # kubectl on the agent then dials the LB, never a server directly.
    admin_blob = server1.succeed(
        "base64 -w0 /var/lib/kubenyx/kubeconfigs/admin.kubeconfig"
    ).strip()
    agent.succeed(f"echo '{admin_blob}' | base64 -d > /root/admin-via-lb.kubeconfig")
    via_lb = "kubectl --kubeconfig=/root/admin-via-lb.kubeconfig --server=https://127.0.0.1:6444"
    agent.succeed(f"timeout 30 {via_lb} get nodes")

    # The object that must survive: written through the LB before the crash.
    agent.succeed(
        f"timeout 30 {via_lb} create configmap failover-proof --from-literal=phase=pre-crash"
    )

    # Hard power loss on the first server — no shutdown, no goodbyes.
    server1.crash()

    # API answers through the agent's LB path within 15s, object intact.
    # Failover budget: probe 500ms x threshold 3 evicts in ~3s; a request
    # racing the eviction burns one 3s dial timeout then moves on — so a
    # single attempt stays under the 8s wrapper and the loop under 15s.
    t0 = time.monotonic()
    agent.wait_until_succeeds(
        f"timeout 8 {via_lb} get configmap failover-proof"
        " -o jsonpath='{.data.phase}' | grep -q pre-crash",
        timeout=15,
    )
    elapsed = time.monotonic() - t0
    assert elapsed <= 15, f"API unavailable through kubenyx-lb for {elapsed:.1f}s (budget 15s)"

    # The LB noticed, not just the retry loop: the dead backend was evicted.
    agent.wait_until_succeeds(
        "journalctl -u kubenyx-lb.service | grep -q 'KUBENYX-LB-EVICT 192.168.1.2:6443'",
        timeout=60,
    )

    # Writes still land on the 2/3 quorum — through the LB, of course.
    agent.succeed(
        f"timeout 30 {via_lb} create configmap failover-post --from-literal=phase=post-crash"
    )

    # --- Failover phase 2: kill -9 etcd on a surviving member. fsync is on
    # (balanced profile), so nothing acknowledged may be lost; systemd
    # restarts the member (Restart=always) and it rejoins the quorum — the
    # member-set guard must recognize the unchanged initial-cluster and
    # NEVER re-bootstrap over the existing data dir.
    apiserver_restarts = server2.succeed(
        "systemctl show -p NRestarts --value kube-apiserver.service"
    ).strip()
    server2.succeed("systemctl kill --signal=SIGKILL etcd.service")
    server2.wait_until_succeeds("systemctl is-active etcd.service", timeout=120)

    # The collocated API replica RODE THROUGH the local etcd death: on a
    # multi-server node the datastore dependency is Wants, so the failure
    # never stop-propagated (a propagated stop is "deliberate" to systemd —
    # Restart=always would not have fired and the replica would be dead for
    # good; the first run of this leg caught exactly that, plus the etcd
    # restart job queuing ~90s behind the hung propagated stop). Same
    # restart count means it never even exited.
    server2.succeed("systemctl is-active kube-apiserver.service")
    server2.succeed(
        "test \"$(systemctl show -p NRestarts --value kube-apiserver.service)\""
        f" = '{apiserver_restarts}'"
    )

    surv_etcdctl = (
        "${lib.getExe' pkgs.etcd_3_6 "etcdctl"}"
        " --endpoints=https://192.168.1.3:2379,https://192.168.1.4:2379"
        " --cacert=/var/lib/kubenyx/pki/ca.crt"
        " --cert=/var/lib/kubenyx/pki/apiserver-etcd-client.crt"
        " --key=/var/lib/kubenyx/pki/apiserver-etcd-client.key"
    )
    server3.wait_until_succeeds(f"{surv_etcdctl} endpoint health", timeout=300)

    # No data loss: everything written before the kill is readable after
    # recovery — via a surviving server directly AND via the agent LB path.
    for cm, want in (("failover-proof", "pre-crash"), ("failover-post", "post-crash")):
        server3.wait_until_succeeds(
            f"kubectl get configmap {cm} -o jsonpath='{{.data.phase}}' | grep -q {want}",
            timeout=300,
        )
        agent.wait_until_succeeds(
            f"timeout 15 {via_lb} get configmap {cm}"
            f" -o jsonpath='{{.data.phase}}' | grep -q {want}",
            timeout=120,
        )

    # The restarted member is a clean rejoin, not a crash loop.
    server2.succeed("systemctl is-active etcd.service")
    server2.fail("journalctl -u etcd.service | grep -q 'member set changed'")
  '';
}
