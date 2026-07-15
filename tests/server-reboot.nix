# Server reboot (air/v0.1/quorum/durable-ha.org, test matrix "server-reboot"):
# extends the multi-server topology — same 3 servers + 1 agent, same
# offline-CA custody bootstrap — then proves the durability claim the
# failover leg deliberately does not: a FULL VM reboot (not a crash-and-
# stay-down, not a process kill) of one server, after which it rejoins
# the quorum with its persistent state intact.
#
# What this adds over failover.nix: the rebooted member comes back with
# its on-disk etcd data (fsync on, StateDirectory persistent — the
# balanced posture) and its operator-shipped CA still in place from the
# original custody ship (PKI is persistent state too; nothing re-mints).
# During the reboot window the surviving 2/3 quorum keeps serving.
{ kubenyx }:
args@{ pkgs, lib, ... }:
let
  base = import ./multi-server.nix { inherit kubenyx; } args;
in
base
// {
  name = "kubenyx-server-reboot";

  # The whole multi-server bootstrap runs first (offline mint, custody
  # gate, quorum, LB READY, all nodes Ready) — its variables (servers,
  # etcdctl) stay in scope below.
  testScript = base.testScript + ''
    # --- Pre-reboot: state that must survive.
    server1.succeed("kubectl create configmap reboot-proof --from-literal=survives=reboot")
    server1.wait_until_succeeds(
        "kubectl get configmap reboot-proof -o jsonpath='{.data.survives}' | grep -q reboot",
        timeout=120,
    )

    # --- Reboot server3 (a follower or the leader — either must work).
    # Explicit shutdown + start, not machine.reboot(): the driver runs QEMU
    # with -no-reboot unless the machine was started with allow_reboot, so
    # a guest-initiated reboot exits the VMM and the shell never returns.
    # shutdown()+start() is the same OS-upgrade shape — clean poweroff,
    # fresh boot from the same persistent disk.
    server3.shutdown()

    # The surviving quorum serves throughout: reads AND writes on 2/3.
    server1.succeed("kubectl get configmap reboot-proof")
    server1.succeed("kubectl create configmap during-reboot --from-literal=written=while-down")

    server3.start()

    # --- Rejoin: the member comes back started with its persistent data —
    # no re-bootstrap (the member-set fingerprint in the data dir survived
    # the reboot and matched), no re-mint (custody CA still on disk).
    server3.wait_for_unit("multi-user.target", timeout=600)
    server3.succeed("test -e /var/lib/kubenyx/pki/ca.key")
    server3.fail(
        "journalctl -b -u etcd.service | grep -q 'member set changed'"
    )
    server1.wait_until_succeeds(
        f'test "$({etcdctl} member list | grep -c started)" = 3', timeout=600
    )
    server1.wait_until_succeeds(f"{etcdctl} endpoint health --cluster", timeout=300)

    # The rebooted server serves API again and sees BOTH objects — the one
    # written before its reboot and the one written while it was away.
    server3.wait_until_succeeds("kubectl get nodes", timeout=600)
    for cm, key, val in (
        ("reboot-proof", "survives", "reboot"),
        ("during-reboot", "written", "while-down"),
    ):
        server3.wait_until_succeeds(
            f"kubectl get configmap {cm} -o jsonpath='{{.data.{key}}}' | grep -q {val}",
            timeout=300,
        )

    # And it converges back to Ready as a node.
    server1.wait_until_succeeds(
        "kubectl get node server3 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=900,
    )
  '';
}
