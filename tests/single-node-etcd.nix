# The alternate-backend matrix leg: same cluster, etcd instead of kine.
# Focused on what the backend changes — datastore auth, apiserver wiring,
# reboot persistence — not a full repeat of the happy path.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };
in
{
  name = "kubenyx-single-node-etcd";

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
        datastore.backend = "etcd";
        dns.upstream = [ ];
        node.seedImages = [ testImage ];
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("kubenyx.target", timeout=1800)
    machine.wait_until_succeeds(
        "kubectl get node machine -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )

    # etcd must reject unauthenticated local clients (security review):
    # a plain HTTPS probe without a client cert gets a TLS failure, not data.
    machine.fail("curl -ks --max-time 5 https://127.0.0.1:2379/version")
    machine.succeed("pgrep -x etcd")
    machine.fail("pgrep -f 'kine'")

    machine.succeed("kubectl run web --image=kubenyx.local/test:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod web -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # Datastore state survives a reboot.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("kubenyx.target", timeout=1800)
    machine.wait_until_succeeds("kubectl get pod web", timeout=900)
    machine.wait_until_succeeds(
        "kubectl get node machine -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )
  '';
}
