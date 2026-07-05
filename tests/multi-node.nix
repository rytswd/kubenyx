# Multi-node: 1 server + 1 agent on a shared L2, etcd backend, host DNS.
# The test driver's shared 9p directory stands in for the operator's secret
# channel when shipping the agent's credential directory.
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
  # agent -> 192.168.1.1, server -> 192.168.1.2. The declared addresses
  # must match or the agent dials itself.
  members = {
    server = {
      index = 0;
      address = "192.168.1.2";
    };
    agent = {
      index = 1;
      address = "192.168.1.1";
    };
  };
in
{
  name = "kubenyx-multi-node";

  nodes = {
    server = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        datastore.backend = "etcd"; # kine is single-node by assertion
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members;
      };
    };

    agent = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        role = "agent";
        controlPlaneEndpoint = "192.168.1.2";
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
        nodes = members;
      };
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("kube-apiserver.service", timeout=1800)
    server.wait_for_unit("kubenyx-pki.service", timeout=300)

    # Ship the agent's packaged credential directory (operator channel).
    server.succeed("cp -r /var/lib/kubenyx/pki/nodes/agent /tmp/shared/agent-pki")
    # Deliberately no chmod: the 9p copy lands 0644 and the module must
    # enforce 0600 itself. The path unit re-triggers the renderer on arrival.
    agent.succeed(
        "mkdir -p /var/lib/kubenyx/pki && cp /tmp/shared/agent-pki/* /var/lib/kubenyx/pki/"
    )
    # Operator flow: ship, then start the renderer (the path unit also
    # catches later re-ships, but an explicit start is deterministic).
    agent.succeed("systemctl start kubenyx-pki.service")
    agent.wait_until_succeeds("test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600)
    agent.succeed("stat -c %a /var/lib/kubenyx/pki/kubelet.key | grep -q 600")

    for n in ("server", "agent"):
        server.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # Pod admission needs the default ServiceAccount, created async by kcm.
    server.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)

    # One pod pinned to each node (bypasses the scheduler deliberately —
    # this is a network test, and nodeName pinning removes flake surface).
    server.succeed(
        "kubectl run web1 --image=kubenyx.local/test:1 --restart=Never"
        " --overrides='{\"spec\":{\"nodeName\":\"server\"}}'"
    )
    server.succeed(
        "kubectl run web2 --image=kubenyx.local/test:1 --restart=Never"
        " --overrides='{\"spec\":{\"nodeName\":\"agent\"}}'"
    )
    for p in ("web1", "web2"):
        server.wait_until_succeeds(
            f"kubectl get pod {p} -o jsonpath='{{.status.phase}}' | grep -q Running",
            timeout=900,
        )

    # Cross-node pod-to-pod over the static host-gw routes (no daemons).
    web1_ip = server.succeed("kubectl get pod web1 -o jsonpath='{.status.podIP}'").strip()
    server.wait_until_succeeds(
        f"kubectl exec web2 -- /bin/busybox wget -qO- http://{web1_ip}:8080 | grep -q kubenyx-ok",
        timeout=300,
    )

    # Full service path from the agent side: DNS (agent's host CoreDNS) ->
    # VIP (agent's kube-proxy) -> cross-node DNAT to the server-side pod.
    server.succeed("kubectl expose pod web1 --port=80 --target-port=8080 --name=websvc")
    server.wait_until_succeeds(
        "kubectl exec web2 -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )

    # node.spec.podCIDR is intentionally unset (allocator disabled); the
    # datapath must still be the Nix-computed subnets.
    server.succeed("kubectl get pod web2 -o jsonpath='{.status.podIP}' | grep -q '^10\\.244\\.1\\.'")
  '';
}
