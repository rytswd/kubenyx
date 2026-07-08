# Agent scale-out (air/v0.3/durable-ha.org §6, test matrix "agent-add"):
# a running 1-server + 1-agent cluster gains a declared agent2 with ZERO
# disruption. Both configurations are built in this derivation — the
# (N+1)-node config rides along as a NixOS specialisation of the running
# nodes, so "activate the new declaration" is exactly
# `specialisation/add-agent2/bin/switch-to-configuration test` on live
# machines, no rebuild inside the VM.
#
# The hitless proof (treat ANY restart as failure):
# - a workload pod pinned to agent1 runs across the whole scale-out and must
#   keep its UID, containerID and restartCount=0;
# - every control-plane unit on the server (etcd, apiserver, kcm, scheduler)
#   keeps its InvocationID across the switch AND shows NRestarts=0 —
#   InvocationID catches deliberate switch-triggered restarts that NRestarts
#   (which only counts Restart= firings) would miss;
# - node-plane units on both running machines (containerd, kubelet,
#   kube-proxy) keep their InvocationIDs too.
# Expected switch delta is exactly: kubenyx-pki on the server (additive,
# fingerprint-gated — mints agent2's leaves, Wants-not-Requires so nothing
# bounces) and kubenyx-routes on both (one more static route). Then agent2
# boots, gets its credentials over the operator channel, and joins Ready.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

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
  # agent1 -> 192.168.1.1, agent2 -> 192.168.1.2, server -> 192.168.1.3.
  # The declared addresses must match or the nodes dial the wrong peers.
  # N-node membership: what the cluster boots with.
  members = {
    server = {
      index = 0;
      address = "192.168.1.3";
      role = "server";
    };
    agent1 = {
      index = 1;
      address = "192.168.1.1";
      role = "agent";
    };
  };
  # The declared add: agent2 appended with a fresh index (§6 index
  # discipline — indices are append-only, never reused).
  newAgent = {
    agent2 = {
      index = 2;
      address = "192.168.1.2";
      role = "agent";
    };
  };

  # The (N+1)-node configuration, PRE-BUILT into the running nodes' system
  # closures as a specialisation. The only delta versus the base config is
  # the one new kubenyx.nodes entry (attrsOf merges it into the base
  # membership) — exactly what a real operator's rebuild would change.
  withNewAgent = {
    add-agent2.configuration = {
      kubenyx.nodes = newAgent;
    };
  };
in
{
  name = "kubenyx-agent-add";

  nodes = {
    server = lib.recursiveUpdate common {
      specialisation = withNewAgent;
      kubenyx = {
        enable = true;
        datastore.backend = "etcd"; # kine is single-node by assertion
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members;
      };
    };

    agent1 = lib.recursiveUpdate common {
      specialisation = withNewAgent;
      kubenyx = {
        enable = true;
        role = "agent";
        controlPlaneEndpoint = "192.168.1.3";
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members;
      };
    };

    # The new node is born knowing the full (N+1) membership — it never
    # existed under the old declaration. NOT started by the test until the
    # running cluster has activated the grown configuration.
    agent2 = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        role = "agent";
        controlPlaneEndpoint = "192.168.1.3";
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members // newAgent;
      };
    };
  };

  testScript = ''
    # Deliberately NOT start_all(): agent2 stays down until the running
    # cluster has switched to the (N+1)-node configuration.
    server.start()
    agent1.start()

    server.wait_for_unit("kube-apiserver.service", timeout=1800)
    server.wait_for_unit("kubenyx-pki.service", timeout=300)

    # Ship agent1's packaged credentials (driver-mediated operator channel;
    # multi-node.nix records why never the 9p shared dir).
    pki_blob = server.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent1 | base64 -w0"
    ).strip()
    agent1.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && chmod 644 /tmp/agent1/*"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent1/* /var/lib/kubenyx/pki/"
    )
    agent1.succeed("systemctl start kubenyx-pki.service")
    agent1.wait_until_succeeds(
        "test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600
    )

    for n in ("server", "agent1"):
        server.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # --- The workload that must survive the scale-out untouched: pinned to
    # agent1 (nodeName bypasses the scheduler — this is a disruption test,
    # not a scheduling test).
    server.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    server.succeed(
        "kubectl run steady --image=kubenyx.local/test:1 --restart=Never"
        " --overrides='{\"spec\":{\"nodeName\":\"agent1\"}}'"
    )
    server.wait_until_succeeds(
        "kubectl get pod steady -o jsonpath='{.status.phase}' | grep -q Running",
        timeout=900,
    )

    def pod_fingerprint():
        # "|" separator: containerID values contain "/" (containerd://...).
        fp = server.succeed(
            "kubectl get pod steady -o jsonpath="
            "'{.metadata.uid}|{.status.containerStatuses[0].containerID}"
            "|{.status.containerStatuses[0].restartCount}'"
        ).strip()
        uid, cid, restarts = fp.split("|", 2)
        assert uid and cid, f"incomplete pod fingerprint: {fp!r}"
        assert restarts == "0", f"workload pod restarted: restartCount={restarts}"
        return fp

    # InvocationID changes on ANY unit restart — including the deliberate
    # ones switch-to-configuration issues, which NRestarts never counts.
    CP_UNITS = [
        "etcd.service",
        "kube-apiserver.service",
        "kube-controller-manager.service",
        "kube-scheduler.service",
    ]
    NODE_UNITS = ["containerd.service", "kubelet.service", "kube-proxy.service"]

    def unit_ids(machine, units):
        return {
            u: machine.succeed(f"systemctl show -p InvocationID --value {u}").strip()
            for u in units
        }

    def assert_untouched(machine, units, before):
        after = unit_ids(machine, units)
        for u in units:
            assert before[u], f"{machine.name}: no InvocationID for {u} before the switch"
            assert after[u] == before[u], (
                f"{machine.name}: {u} was restarted across the switch"
                f" (InvocationID {before[u]} -> {after[u]})"
            )

    steady_fp = pod_fingerprint()
    server_ids = unit_ids(server, CP_UNITS + NODE_UNITS)
    agent1_ids = unit_ids(agent1, NODE_UNITS)

    # --- Activate the PRE-BUILT (N+1)-node configuration on the RUNNING
    # nodes — the declared add, no runtime discovery, no join tokens. Server
    # first: its PKI rerun mints agent2's credential package.
    for m in (server, agent1):
        m.succeed(
            "/run/current-system/specialisation/add-agent2/bin/switch-to-configuration test"
        )

    # The server's PKI rerun was additive: agent2's leaves exist, and the
    # trust roots were NOT re-minted (fingerprint gate).
    server.wait_until_succeeds(
        "test -s /var/lib/kubenyx/pki/nodes/agent2/kubelet.crt", timeout=300
    )
    # Both running nodes now route agent2's pod /24 (index 2) to its address.
    for m in (server, agent1):
        m.wait_until_succeeds(
            "ip route | grep -q '10.244.2.0/24 via 192.168.1.2'", timeout=120
        )

    # --- HITLESS: the switch restarted nothing that matters. Control-plane
    # units kept their invocations and show zero Restart= firings; the
    # workload pod is the same container it was before the switch.
    assert_untouched(server, CP_UNITS + NODE_UNITS, server_ids)
    assert_untouched(agent1, NODE_UNITS, agent1_ids)
    for u in CP_UNITS:
        n = server.succeed(f"systemctl show -p NRestarts --value {u}").strip()
        assert n == "0", f"server: {u} NRestarts={n} after the switch (hitless violated)"
    assert pod_fingerprint() == steady_fp, "workload pod changed across the switch"

    # --- Boot the new agent and ship its credentials (operator channel).
    agent2.start()
    agent2.wait_for_unit("multi-user.target", timeout=1800)
    pki_blob = server.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent2 | base64 -w0"
    ).strip()
    agent2.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && chmod 644 /tmp/agent2/*"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent2/* /var/lib/kubenyx/pki/"
    )
    agent2.succeed("systemctl start kubenyx-pki.service")
    agent2.wait_until_succeeds(
        "test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600
    )
    agent2.succeed("stat -c %a /var/lib/kubenyx/pki/kubelet.key | grep -q 600")

    server.wait_until_succeeds(
        "kubectl get node agent2 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )

    # The join itself was also hitless: same invocations, zero restarts,
    # same workload container — end to end.
    assert_untouched(server, CP_UNITS + NODE_UNITS, server_ids)
    assert_untouched(agent1, NODE_UNITS, agent1_ids)
    for u in CP_UNITS:
        n = server.succeed(f"systemctl show -p NRestarts --value {u}").strip()
        assert n == "0", f"server: {u} NRestarts={n} after agent2 joined"
    assert pod_fingerprint() == steady_fp, "workload pod changed while agent2 joined"

    # The new node actually carries workload: a pod pinned to agent2 runs
    # and is reachable cross-node from the steady pod (host-gw datapath).
    server.succeed(
        "kubectl run web2 --image=kubenyx.local/test:1 --restart=Never"
        " --overrides='{\"spec\":{\"nodeName\":\"agent2\"}}'"
    )
    server.wait_until_succeeds(
        "kubectl get pod web2 -o jsonpath='{.status.phase}' | grep -q Running",
        timeout=900,
    )
    server.succeed("kubectl get pod web2 -o jsonpath='{.status.podIP}' | grep -q '^10\\.244\\.2\\.'")
    web2_ip = server.succeed("kubectl get pod web2 -o jsonpath='{.status.podIP}'").strip()
    server.wait_until_succeeds(
        f"kubectl exec steady -- /bin/busybox wget -qO- http://{web2_ip}:8080 | grep -q kubenyx-ok",
        timeout=300,
    )
  '';
}
