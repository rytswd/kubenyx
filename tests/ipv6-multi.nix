# IPv6 single-stack, multi-node (air/v0.4/ipv6.org acceptance leg two):
# 1 server + 1 agent, every address v6 — ULA node addresses on the shared
# VLAN, v6 cluster/service CIDRs, etcd backend, the agent joining through
# the BRACKETED v6 controlPlaneEndpoint (klib.hostPort renders
# https://[fd00:1::2]:6443 into every agent kubeconfig). Credential ship is
# driver-mediated, same as multi-node.nix and for the same 9p
# negative-dentry reason. dns.address keeps its own ULA off the service
# dataplane (see tests/ipv6.nix header for why it must not sit inside
# serviceCidr).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  clusterCidr = "fd42:dead:beef::/56";
  serviceCidr = "fd43::/112";
  dnsVip = "fd44::a";
  serverAddress = "fd00:1::2";
  agentAddress = "fd00:1::1";

  common = {
    imports = [ kubenyx.nixosModules.default ];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
    };
    networking.firewall.enable = true;
  };

  # The driver's own v4 VLAN addressing on eth1 coexists (alphabetical:
  # agent 192.168.1.1, server 192.168.1.2); the cluster only ever uses
  # these declared ULAs, added statically on the same interface.
  members = {
    server = {
      index = 0;
      address = serverAddress;
      role = "server";
    };
    agent = {
      index = 1;
      address = agentAddress;
      role = "agent";
    };
  };

  mkNode =
    address: kubenyxExtra:
    lib.recursiveUpdate common {
      networking.interfaces.eth1.ipv6.addresses = [
        {
          inherit address;
          prefixLength = 64;
        }
      ];
      kubenyx = {
        enable = true;
        dns.upstream = [ ]; # airgapped: no external forwarding
        dns.address = dnsVip;
        node.seedImages = [ testImage ];
        network = {
          inherit clusterCidr serviceCidr;
        };
        nodes = members;
      }
      // kubenyxExtra;
    };
in
{
  name = "kubenyx-ipv6-multi";

  nodes = {
    server = mkNode serverAddress {
      datastore.backend = "etcd"; # kine is single-node by assertion
    };
    agent = mkNode agentAddress {
      role = "agent";
      # Bare v6 literal on purpose: klib.hostPort owns the brackets, so the
      # option stays family-symmetric with the v4 tests.
      controlPlaneEndpoint = serverAddress;
    };
  };

  testScript = ''
    start_all()

    server.wait_for_unit("kube-apiserver.service", timeout=1800)
    server.wait_for_unit("kubenyx-pki.service", timeout=300)

    # Ship the agent's packaged credential directory (operator channel),
    # driver-mediated — see tests/multi-node.nix for the 9p negative-dentry
    # story. chmod 644 so the module proves it enforces 0600 itself.
    pki_blob = server.succeed(
        "tar c -C /var/lib/kubenyx/pki/nodes agent | base64 -w0"
    ).strip()
    agent.succeed(
        f"echo '{pki_blob}' | base64 -d | tar x -C /tmp"
        " && chmod 644 /tmp/agent/*"
        " && mkdir -p /var/lib/kubenyx/pki && cp /tmp/agent/* /var/lib/kubenyx/pki/"
    )
    agent.succeed("systemctl start kubenyx-pki.service")
    agent.wait_until_succeeds("test -s /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig", timeout=600)
    agent.succeed("stat -c %a /var/lib/kubenyx/pki/kubelet.key | grep -q 600")

    # The join really went through the BRACKETED v6 endpoint: every agent
    # kubeconfig carries https://[${serverAddress}]:6443.
    agent.succeed(
        "grep -q 'https://\\[${serverAddress}\\]:6443' /var/lib/kubenyx/kubeconfigs/kubelet.kubeconfig"
    )

    for n in ("server", "agent"):
        server.wait_until_succeeds(
            f"kubectl get node {n} -o jsonpath='{{.status.conditions[?(@.type==\"Ready\")].status}}' | grep -q True",
            timeout=1800,
        )

    # Both nodes report their declared ULA as InternalIP (kubelet --node-ip).
    for n, addr in (("server", "${serverAddress}"), ("agent", "${agentAddress}")):
        server.succeed(
            f"kubectl get node {n} -o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}'"
            f" | grep -qx '{addr}'"
        )

    # host-gw datapath: each node holds an `ip -6 route` for the peer's
    # carved /64 via the peer's ULA (kubenyx-routes, family-switched).
    for machine, peer_cidr, peer_addr in (
        (server, "fd42:dead:beef:1::/64", "${agentAddress}"),
        (agent, "fd42:dead:beef::/64", "${serverAddress}"),
    ):
        machine.wait_for_unit("kubenyx-routes.service", timeout=300)
        machine.succeed(f"ip -6 route show | grep -q '{peer_cidr} via {peer_addr}'")

    # Pod admission needs the default ServiceAccount, created async by kcm.
    server.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)

    # One pod pinned to each node (nodeName pinning, no scheduler flake).
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

    # Each pod's IP sits in its node's carved /64 (allocator disabled; the
    # datapath must be the Nix-computed subnets).
    web1_ip = server.succeed("kubectl get pod web1 -o jsonpath='{.status.podIP}'").strip()
    web2_ip = server.succeed("kubectl get pod web2 -o jsonpath='{.status.podIP}'").strip()
    assert web1_ip.startswith("fd42:dead:beef:") and not web1_ip.startswith(
        "fd42:dead:beef:1:"
    ), f"web1 IP {web1_ip} outside the server /64"
    assert web2_ip.startswith("fd42:dead:beef:1:"), f"web2 IP {web2_ip} outside the agent /64"

    # Cross-node pod-to-pod over the v6 static routes, both directions.
    server.wait_until_succeeds(
        f"kubectl exec web2 -- /bin/busybox wget -qO- 'http://[{web1_ip}]:8080' | grep -q kubenyx-ok",
        timeout=300,
    )
    server.wait_until_succeeds(
        f"kubectl exec web1 -- /bin/busybox wget -qO- 'http://[{web2_ip}]:8080' | grep -q kubenyx-ok",
        timeout=300,
    )

    # Full service path from the agent side: DNS (agent's host CoreDNS on
    # the v6 VIP) -> service VIP (agent's kube-proxy) -> cross-node DNAT to
    # the server-side pod.
    server.succeed("kubectl expose pod web1 --port=80 --target-port=8080 --name=websvc")
    vip = server.succeed("kubectl get svc websvc -o jsonpath='{.spec.clusterIP}'").strip()
    assert vip.startswith("fd43::"), f"service VIP {vip} outside ${serviceCidr}"
    server.wait_until_succeeds(
        "kubectl exec web2 -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )
  '';
}
