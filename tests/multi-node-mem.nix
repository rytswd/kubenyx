# The etcd-mem relaxation leg: one server + one agent on the in-memory
# datastore. Only the apiserver talks to the datastore (local unix
# socket), so agents are irrelevant to it — this leg pins that claim as
# a regression test. Pod networking and the full credential flow are
# multi-node.nix's job; this asserts membership only: both nodes Ready
# on a volatile etcd-mem cluster.
{ kubenyx }:
{ lib, ... }:
let
  common = {
    imports = [ kubenyx.nixosModules.default ];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
    };
  };

  # Driver VLAN addresses assign alphabetically: agent -> .1, server -> .2.
  members = {
    server = {
      index = 0;
      address = "192.168.1.2";
      role = "server";
    };
    agent = {
      index = 1;
      address = "192.168.1.1";
      role = "agent";
    };
  };
in
{
  name = "kubenyx-multi-node-mem";

  nodes = {
    server = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        datastore.backend = "etcd-mem";
        datastore.volatile = true;
        dns.upstream = [ ];
        nodes = members;
      };
    };

    agent = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        role = "agent";
        controlPlaneEndpoint = "192.168.1.2";
        dns.upstream = [ ];
        nodes = members;
      };
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("kube-apiserver.service", timeout=1800)
    server.wait_for_unit("kubenyx-pki.service", timeout=300)

    # Operator channel (driver-mediated; see multi-node.nix for why not 9p).
    pki_blob = server.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent | base64 -w0"
    ).strip()
    agent.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent/* /var/lib/kubenyx/pki/"
    )
    agent.succeed("systemctl start kubenyx-pki.service")
    agent.wait_until_succeeds("test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600)

    for n in ("server", "agent"):
        server.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # The relaxation's negative space: no etcd, no kine — etcd-mem only.
    server.succeed("systemctl is-active etcd-mem.service")
    server.fail("systemctl is-active etcd.service")
    server.fail("systemctl is-active kine.service")
  '';
}
