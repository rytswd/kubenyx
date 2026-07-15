# IPv6 single-stack, single node (air/v0.1/network/ipv6.org acceptance): ULA node
# address, v6 cluster/service CIDRs, bridge CNI. Node Ready, pod Running
# with an IP inside the carved /64, service VIP reachable from a pod, DNS
# via the v6 DNS VIP. Same airgapped sandbox as single-node.nix.
#
# dns.address is deliberately its OWN ULA prefix, not a serviceCidr
# member — the exact analogue of the v4 default (169.254.20.10, outside
# 10.96.0.0/16): the nftables kube-proxy drops traffic to unallocated
# ClusterIPs inside the service CIDR, and "DNS off the service dataplane"
# is the dns.nix design (dns-addons.org) in both families.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  clusterCidr = "fd42:dead:beef::/56";
  serviceCidr = "fd43::/112";
  dnsVip = "fd44::a";
  nodeAddress = "fd00:1::2";
in
{
  name = "kubenyx-ipv6";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ kubenyx.nixosModules.default ];

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 8192;
      };

      networking.firewall.enable = true;

      # The driver's own v4 VLAN addressing on eth1 coexists; the cluster
      # only ever uses this declared ULA.
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = nodeAddress;
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
        # Explicit membership: entries default to role = "agent", and the
        # declared address is what makes this an all-v6 cluster.
        nodes.machine = {
          index = 0;
          address = nodeAddress;
          role = "server";
        };
      };
    };

  # Function form: the nft/ip6tables assertions need store paths (neither
  # is on the interactive PATH), and ip6tables must be the firewall's own
  # variant or the listing sees a different kernel table view.
  testScript =
    { nodes, ... }:
    let
      nft = "${pkgs.nftables}/bin/nft";
      ip6tables = "${nodes.machine.networking.firewall.package}/bin/ip6tables";
    in
    ''
    machine.start()

    machine.wait_for_unit("kube-apiserver.service", timeout=1800)
    machine.wait_for_unit("kubenyx.target", timeout=1800)

    machine.wait_until_succeeds(
        "kubectl get node machine -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )

    # All-v6 wiring, asserted at the API: the node reports the ULA and the
    # kubernetes service VIP is host 1 of the v6 service CIDR.
    machine.succeed(
        "kubectl get node machine -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'"
        " | grep -qx '${nodeAddress}'"
    )
    machine.succeed(
        "kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -qx 'fd43::1'"
    )

    # v6 NAT66 table and ip6tables pod accepts are the live dataplane.
    machine.succeed("${nft} list table ip6 kubenyx-nat | grep -q masquerade")
    machine.succeed("${ip6tables} -S nixos-fw | grep -q 'cni0'")

    # --- workload --------------------------------------------------------------
    machine.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    machine.succeed("kubectl run web --image=kubenyx.local/test:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod web -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # Pod IP must come from the carved /64: node 0 owns fd42:dead:beef::/64.
    pod_ip = machine.succeed("kubectl get pod web -o jsonpath='{.status.podIP}'").strip()
    assert pod_ip.startswith("fd42:dead:beef:"), f"pod IP {pod_ip} outside the carved /64"
    assert ":" in pod_ip and "." not in pod_ip, f"pod IP {pod_ip} is not v6"

    # --- service VIP + DNS via the v6 VIPs --------------------------------------
    machine.succeed("kubectl expose pod web --port=80 --target-port=8080 --name=websvc")
    machine.succeed(
        "kubectl run client --image=kubenyx.local/test:1 --restart=Never --command -- /bin/busybox sleep 3600"
    )
    machine.wait_until_succeeds(
        "kubectl get pod client -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # DNS from a pod through the v6 DNS VIP (kubelet clusterDNS = ${dnsVip}).
    machine.succeed(
        "kubectl exec client -- /bin/busybox grep -q '${dnsVip}' /etc/resolv.conf"
    )
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox nslookup kubernetes.default.svc.cluster.local", timeout=300
    )
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox nslookup websvc.default.svc.cluster.local", timeout=300
    )

    # Service VIP path through the nftables kube-proxy: by v6 literal...
    vip = machine.succeed("kubectl get svc websvc -o jsonpath='{.spec.clusterIP}'").strip()
    assert vip.startswith("fd43::"), f"service VIP {vip} outside ${serviceCidr}"
    machine.wait_until_succeeds(
        f"kubectl exec client -- /bin/busybox wget -qO- 'http://[{vip}]' | grep -q kubenyx-ok",
        timeout=300,
    )
    # ...and by name (DNS AAAA -> VIP -> DNAT to the pod).
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )

    # Hairpin: the pod reaches itself through its own service VIP.
    machine.wait_until_succeeds(
        "kubectl exec web -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )
  '';
}
