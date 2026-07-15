# Volatile quorum (air/v0.1/quorum/quorum-mesh.org, work plan item 6): the cp3
# POSTURE — testing profile, tmpfs datastore, real 3-member etcd quorum —
# exercised as a NixOS test so the posture stays covered without firecracker.
# The driver host plays the cp3 LAUNCHER: it mints the per-run CA and lands
# the six custody files in every server's /var/lib/kubenyx/pki, mirroring the
# launcher's mint-ca + serve step (§D2). The microVM launcher itself stays
# host-tested via the bench; this leg pins the module-level contract.
#
# Asserts: the require-shipped-ca gate fires on multiServer alone (this is
# NOT the durable posture — a missing bundle must still fail the boot, or
# three silent self-mints split the trust root, §D2), the quorum forms on
# tmpfs (every member started, healthy endpoints over the wire), the join
# probe's D3 fast-exit actually fired (all-fresh peers actively refuse, so
# nobody burns the probe window), all 3 nodes go Ready, and a write through
# server3 is readable through server1 (quorum honesty, not 3 silos).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  # Same derivation the guests run as internal.tools; here it runs on the
  # DRIVER host as the launcher's mint CLI (multi-server.nix runs it as the
  # operator's — same binary, different custody story: this bundle is
  # per-run and dies with the test, never operator custody).
  kubenyxTools = pkgs.callPackage ../pkgs/kubenyx-tools.nix { };

  common = {
    imports = [ kubenyx.nixosModules.default ];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
    };
    networking.firewall.enable = true;
  };

  # The test driver assigns VLAN addresses by *alphabetical* node order:
  # server1..3 -> 192.168.1.1..3. The declared addresses must match or the
  # quorum dials the wrong peers.
  members = {
    server1 = {
      index = 0;
      address = "192.168.1.1";
      role = "server";
    };
    server2 = {
      index = 1;
      address = "192.168.1.2";
      role = "server";
    };
    server3 = {
      index = 2;
      address = "192.168.1.3";
      role = "server";
    };
  };

  serverConfig = lib.recursiveUpdate common {
    kubenyx = {
      enable = true;
      # The cp3 posture, spelled out: testing profile (the default — explicit
      # because it is the point: the CA gate below must fire WITHOUT the
      # durable posture) + tmpfs datastore + real etcd. multi-server.nix
      # covers balanced/persistent; this leg covers the disposable extreme.
      profile = "testing";
      datastore = {
        backend = "etcd";
        volatile = true;
        # cp3's measured window (§D3). The fast-exit is expected to shortcut
        # it entirely on this all-fresh boot — asserted below — but the leg
        # runs the same 3s the preset ships, not a test-only value.
        etcd.joinProbeSec = 3;
      };
      dns.upstream = [ ];
      nodes = members;
    };
  };
in
{
  name = "kubenyx-quorum-volatile";

  nodes = {
    server1 = serverConfig;
    server2 = serverConfig;
    server3 = serverConfig;
  };

  testScript = ''
    import base64
    import os
    import subprocess

    start_all()
    servers = [server1, server2, server3]

    # --- Launcher-shape CA mint (quorum-mesh.org §D2): the driver stands in
    # for the cp3 launcher — the trust root exists off-cluster, per run.
    bundle = os.path.join(os.environ.get("TMPDIR", "/tmp"), "kubenyx-ca-bundle")
    subprocess.run(
        ["${lib.getExe' kubenyxTools "kubenyx-pki"}", "mint-ca", "--out", bundle],
        check=True,
    )
    custody = ["ca.crt", "ca.key", "front-proxy-ca.crt", "front-proxy-ca.key", "sa.key", "sa.pub"]

    with subtest("require-shipped-ca fires on multiServer, not just durable posture"):
        # Negative gate: this is the testing/volatile posture, yet the PKI
        # unit must refuse to self-mint until the bundle lands. A silent
        # self-mint here is the fatal failure mode §D2 exists to prevent —
        # three trust roots, etcd peer TLS rejects every raft connection,
        # and it LOOKS like a hang instead of an error.
        for s in servers:
            s.wait_until_succeeds(
                "journalctl -u kubenyx-pki.service | grep -q 'requires an operator-shipped CA bundle'",
                timeout=300,
            )
            s.fail("test -e /var/lib/kubenyx/pki/ca.key")

    # Ship the SAME six files to every server (driver-mediated transfer —
    # the launcher channel; on cp3 this is kubenyx-pki serve over the
    # bridge, here the driver plays that wire).
    for s in servers:
        s.succeed("mkdir -p /var/lib/kubenyx/pki")
        for f in custody:
            with open(os.path.join(bundle, f), "rb") as fh:
                blob = base64.b64encode(fh.read()).decode()
            s.succeed(f"echo '{blob}' | base64 -d > /var/lib/kubenyx/pki/{f}")

    # Custody accepted: rerun the PKI (leaves cascade from the shipped CA),
    # clear the start-limit counters the pre-bundle crash loops earned, and
    # restart the chain. The serial per-server loop is also what makes the
    # fast-exit assertion below deterministic: the first server's probe runs
    # while its peers' etcd units are still down, so both peers actively
    # refuse and the all-fresh streak completes.
    for s in servers:
        s.succeed("systemctl restart kubenyx-pki.service")
        # Shipping transports rarely preserve modes; the tool enforces 0600.
        s.succeed("stat -c %a /var/lib/kubenyx/pki/ca.key | grep -q 600")
        s.succeed("systemctl reset-failed")
        s.succeed(
            "systemctl restart --no-block etcd.service kube-apiserver.service"
            " kube-controller-manager.service kube-scheduler.service"
            " kube-proxy.service kubelet.service kubenyx-addons.service"
        )

    with subtest("quorum forms on tmpfs"):
        etcdctl = (
            "${lib.getExe' pkgs.etcd_3_6 "etcdctl"}"
            " --endpoints=https://127.0.0.1:2379"
            " --cacert=/var/lib/kubenyx/pki/ca.crt"
            " --cert=/var/lib/kubenyx/pki/apiserver-etcd-client.crt"
            " --key=/var/lib/kubenyx/pki/apiserver-etcd-client.key"
        )
        # Every member started, every declared client endpoint healthy over
        # the wire — SANs and the 2379/2380 firewall openings included.
        server1.wait_until_succeeds(
            f'test "$({etcdctl} member list | grep -c started)" = 3', timeout=600
        )
        server1.wait_until_succeeds(f"{etcdctl} endpoint health --cluster", timeout=300)
        # Volatile means volatile: the member dir lives on the tmpfs
        # volatileDir, and no durable StateDirectory was ever created —
        # otherwise the "disposable" posture quietly accretes disk state.
        # Wait, don't race: the cluster-wide health answer needs only 2/3
        # members, so the last member's storage bootstrap (which creates
        # member/) can still be milliseconds in flight when health greens.
        for s in servers:
            s.wait_until_succeeds("test -e /run/kubenyx/volatile-state/member", timeout=120)
            s.fail("test -e /var/lib/etcd")

    with subtest("join-probe fast-exit fired (quorum-mesh.org D3)"):
        # The probe window is the single biggest cp3 cold-boot line item;
        # the fast-exit (every declared peer ACTIVELY refused across five
        # sweeps -> all fresh -> bootstrap now) is what deletes it. At least
        # the first-restarted server must have taken that path — its peers
        # had no listener yet. Late servers may legitimately hold the window
        # instead (a founder's bound-but-not-serving listener answers TCP),
        # so this is any-of, not all-of.
        fast_exit = (
            "journalctl -u etcd.service"
            " | grep -q 'bootstrapping the declared initial-cluster without waiting out the probe window'"
        )
        assert any(
            s.execute(fast_exit)[0] == 0 for s in servers
        ), "no server took the D3 fast-exit; every probe burned or timed out its window"

    with subtest("all 3 nodes Ready"):
        for n in ("server1", "server2", "server3"):
            server1.wait_until_succeeds(
                f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
                timeout=1800,
            )

    with subtest("cross-server write/read (quorum honesty)"):
        # Write through one apiserver, read through another: three API
        # endpoints over ONE replicated datastore, not three silos — the
        # same proof the live cp3 boots run (configmap via server3, read
        # via server1).
        server3.succeed("kubectl create configmap quorum-proof --from-literal=members=three")
        server1.wait_until_succeeds(
            "kubectl get configmap quorum-proof -o jsonpath='{.data.members}' | grep -q three",
            timeout=120,
        )

    # Addons applied from every server without leader-gating: server-side
    # apply is idempotent, all three appliers completed.
    for s in servers:
        s.wait_until_succeeds("systemctl is-active kubenyx-addons.service", timeout=600)
  '';
}
