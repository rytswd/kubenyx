# External CNI (air/v0.1/hosts/byod.org §1): kubenyx.network.cni = "external"
# hands the pod dataplane to an operator-deployed CNI. The TEST plays that
# CNI's DaemonSet — it ships a bridge+host-local conflist at runtime
# (driver-mediated, like an agent's credential dir) — and kubenyx must
# have written nothing: no conflist, no kubenyx-routes, no NAT unit, no
# cni0. Firewall stays ON to prove the reworked (interface-free) accepts.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  # Stand-in for the external CNI's conflist. Deliberately NOT kubenyx's
  # name or bridge: a distinct file name, network name, and bridge device
  # prove the dataplane in use is the test-supplied one. The subnet sits
  # inside the default clusterCidr so the firewall's pod-source accepts
  # (and kube-proxy's clusterCIDR) describe it, exactly as an operator
  # would align a real CNI's IPAM.
  externalConflist = builtins.toJSON {
    cniVersion = "1.0.0";
    name = "external-test-cni";
    plugins = [
      {
        type = "bridge";
        bridge = "extcni0";
        isGateway = true;
        isDefaultGateway = true;
        hairpinMode = true;
        # External CNIs bring their own egress path; ipMasq here stands in
        # for that (kubenyx's NAT unit must be absent).
        ipMasq = true;
        ipam = {
          type = "host-local";
          ranges = [ [ { subnet = "10.244.0.0/24"; } ] ];
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  };
in
{
  name = "kubenyx-external-cni";

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

      kubenyx = {
        enable = true;
        network.cni = "external";
        dns.upstream = [ ]; # airgapped: no external forwarding
        node.seedImages = [ testImage ];
      };
    };

  testScript = ''
    import base64

    machine.start()

    machine.wait_for_unit("kube-apiserver.service", timeout=1800)
    machine.wait_for_unit("kubenyx.target", timeout=1800)

    # --- kubenyx wrote nothing, owns nothing --------------------------------
    # No conflist (ABSENT, not an empty stub: containerd loads the lexically
    # first conflist, so any kubenyx file would shadow the external CNI's).
    machine.succeed("test ! -e /etc/cni/net.d || [ -z \"$(ls -A /etc/cni/net.d)\" ]")
    # No bridge-mode units exist at all (not just inactive).
    machine.fail("systemctl cat kubenyx-nat.service")
    machine.fail("systemctl cat kubenyx-routes.service")
    # nft is reachable (kube-proxy's tables prove it), kubenyx-nat is not there.
    machine.succeed("${pkgs.nftables}/bin/nft list tables > /dev/null")
    machine.fail("${pkgs.nftables}/bin/nft list tables | grep -q kubenyx-nat")
    machine.fail("ip link show cni0")

    # --- the test now plays CNI DaemonSet ------------------------------------
    # Driver-mediated shipping (house style: no 9p for cross-VM files).
    conflist = ${builtins.toJSON externalConflist}
    blob = base64.b64encode(conflist.encode()).decode()
    machine.succeed(
        "mkdir -p /etc/cni/net.d"
        f" && echo '{blob}' | base64 -d > /etc/cni/net.d/05-external.conflist"
    )

    # containerd notices the conflist, runtime network goes Ready, node Ready.
    machine.wait_until_succeeds(
        "kubectl get node machine -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )

    # --- workload over the external dataplane --------------------------------
    machine.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    machine.succeed("kubectl run web --image=kubenyx.local/test:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod web -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # The pod runs on the test-supplied bridge, not anything of kubenyx's.
    machine.succeed("ip link show extcni0")
    machine.fail("ip link show cni0")
    machine.succeed("kubectl get pod web -o jsonpath='{.status.podIP}' | grep -q '^10\\.244\\.0\\.'")

    # Host DNS from the pod: pod -> 169.254.20.10 arrives on the external
    # CNI's interface and must pass the interface-free firewall accepts.
    machine.wait_until_succeeds(
        "kubectl exec web -- /bin/busybox nslookup kubernetes.default.svc.cluster.local", timeout=300
    )

    # --- /etc/cni/net.d contains ONLY the test's file -------------------------
    files = machine.succeed("ls -A /etc/cni/net.d").split()
    assert files == ["05-external.conflist"], f"unexpected CNI conf dir contents: {files}"
  '';
}
