# Multi-server HA (air/v0.3/durable-ha.org, test matrix "multi-server"):
# 3 declared servers form an etcd quorum, 1 agent reaches the apiserver set
# through kubenyx-lb. The servers run the durable posture (balanced profile,
# persistent datastore), so the CA is operator custody: minted OFFLINE on
# the driver host with `kubenyx-pki mint-ca` and shipped to each server —
# the test driver is the operator channel, exactly as in multi-node.nix.
#
# Asserts: the custody gate refuses to self-mint, the quorum forms (every
# member started, every declared client endpoint healthy over the wire),
# all 4 nodes go Ready, and kubectl works against every server directly
# (write through one apiserver, read through the others).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  # Same derivation the guests run as internal.tools; here it runs on the
  # DRIVER host as the operator's offline mint CLI.
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
  # agent -> 192.168.1.1, server1..3 -> 192.168.1.2..4. The declared
  # addresses must match or the quorum dials the wrong peers.
  members = {
    server1 = {
      index = 0;
      address = "192.168.1.2";
      role = "server";
    };
    server2 = {
      index = 1;
      address = "192.168.1.3";
      role = "server";
    };
    server3 = {
      index = 2;
      address = "192.168.1.4";
      role = "server";
    };
    agent = {
      index = 3;
      address = "192.168.1.1";
      role = "agent";
    };
  };

  serverConfig = lib.recursiveUpdate common {
    kubenyx = {
      enable = true;
      # balanced + persistent datastore = durable posture: the PKI unit runs
      # --require-shipped-ca and a missing bundle is a hard boot error.
      profile = "balanced";
      datastore.backend = "etcd";
      dns.upstream = [ ];
      nodes = members;
    };
  };
in
{
  name = "kubenyx-multi-server";

  nodes = {
    server1 = serverConfig;
    server2 = serverConfig;
    server3 = serverConfig;
    agent = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        role = "agent";
        # Deliberately NO controlPlaneEndpoint: lb.enable's default turns
        # kubenyx-lb on (agent + >1 server + no endpoint) and every agent
        # kubeconfig dials https://127.0.0.1:6444.
        dns.upstream = [ ];
        nodes = members;
      };
    };
  };

  testScript = ''
    import base64
    import os
    import subprocess

    start_all()
    servers = [server1, server2, server3]

    # --- Offline CA mint (durable-ha.org §3, Decision 2). The driver host
    # stands in for the operator's workstation: the trust roots exist off-
    # cluster before any server ever sees them.
    bundle = os.path.join(os.environ.get("TMPDIR", "/tmp"), "kubenyx-ca-bundle")
    subprocess.run(
        ["${lib.getExe' kubenyxTools "kubenyx-pki"}", "mint-ca", "--out", bundle],
        check=True,
    )
    custody = ["ca.crt", "ca.key", "front-proxy-ca.crt", "front-proxy-ca.key", "sa.key", "sa.pub"]

    # Durable posture must have refused to boot without the bundle: the PKI
    # unit dies citing the mint-ca command, and no CA was self-minted.
    for s in servers:
        s.wait_until_succeeds(
            "journalctl -u kubenyx-pki.service | grep -q 'requires an operator-shipped CA bundle'",
            timeout=300,
        )
        s.fail("test -e /var/lib/kubenyx/pki/ca.key")

    # Ship the SAME six files to every server (driver-mediated transfer —
    # the operator channel; multi-node.nix records why never the 9p dir).
    for s in servers:
        s.succeed("mkdir -p /var/lib/kubenyx/pki")
        for f in custody:
            with open(os.path.join(bundle, f), "rb") as fh:
                blob = base64.b64encode(fh.read()).decode()
            s.succeed(f"echo '{blob}' | base64 -d > /var/lib/kubenyx/pki/{f}")

    # Operator flow: rerun the PKI (custody accepted, leaves cascade from
    # the shipped CA), then clear the start-limit counters the pre-bundle
    # crash loops earned and restart the chain as one ordered transaction.
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

    # --- Quorum forms (durable-ha.org §2): all three members started, and
    # every declared client endpoint answers over the wire — which proves
    # the extended cert SANs and the 2379/2380 firewall openings together.
    etcdctl = (
        "${lib.getExe' pkgs.etcd_3_6 "etcdctl"}"
        " --endpoints=https://127.0.0.1:2379"
        " --cacert=/var/lib/kubenyx/pki/ca.crt"
        " --cert=/var/lib/kubenyx/pki/apiserver-etcd-client.crt"
        " --key=/var/lib/kubenyx/pki/apiserver-etcd-client.key"
    )
    server1.wait_until_succeeds(
        f'test "$({etcdctl} member list | grep -c started)" = 3', timeout=600
    )
    server1.wait_until_succeeds(f"{etcdctl} endpoint health --cluster", timeout=300)

    # --- Agent credentials: any server can package them (every server mints
    # the same set from the shared CA); server1 plays operator source.
    pki_blob = server1.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent | base64 -w0"
    ).strip()
    agent.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && chmod 644 /tmp/agent/*"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent/* /var/lib/kubenyx/pki/"
    )
    agent.succeed("systemctl start kubenyx-pki.service")
    agent.wait_until_succeeds(
        "test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600
    )
    agent.succeed("stat -c %a /var/lib/kubenyx/pki/kubelet.key | grep -q 600")
    agent.succeed("systemctl reset-failed")
    agent.succeed("systemctl restart --no-block kubelet.service kube-proxy.service")

    # kubenyx-lb went READY: a probe authenticated (lazy-loaded kubelet
    # cert) and saw a real 200 from /readyz — not just a TCP connect.
    agent.wait_until_succeeds(
        "journalctl -u kubenyx-lb.service | grep -q KUBENYX-LB-READY", timeout=900
    )
    agent.wait_until_succeeds("systemctl is-active kubenyx-lb.service", timeout=900)

    # --- All four nodes Ready (the agent's kubelet only ever dialed
    # 127.0.0.1:6444, so its Ready is the LB datapath proof).
    for n in ("server1", "server2", "server3", "agent"):
        server1.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # --- kubectl works against every server directly: each admin
    # kubeconfig dials its own apiserver — three independent API endpoints
    # over one replicated datastore. Write through one, read via the rest.
    server2.succeed("kubectl create configmap ha-proof --from-literal=quorum=three")
    for s in servers:
        s.succeed("kubectl get nodes")
        s.wait_until_succeeds(
            "kubectl get configmap ha-proof -o jsonpath='{.data.quorum}' | grep -q three",
            timeout=120,
        )

    # Addons applied from every server without leader-gating (durable-ha.org
    # §5): server-side apply is idempotent, all three appliers completed.
    for s in servers:
        s.wait_until_succeeds("systemctl is-active kubenyx-addons.service", timeout=600)
  '';
}
