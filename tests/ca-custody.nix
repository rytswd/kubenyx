# CA custody gate (air/v0.1/quorum/durable-ha.org §3, test matrix "ca-custody"):
# a durable-posture server (balanced profile + persistent datastore) must
# REFUSE to boot its PKI without an operator-shipped CA bundle — hard error
# naming the mint-ca command, never a silent self-mint (a re-minted CA would
# partition the cluster's trust). Shipping the bundle over the operator
# channel (the test driver, exactly as in multi-node.nix) then boots it to
# Ready on the shipped trust roots. A volatile/testing guest boots alongside
# and still self-mints per-boot, proving the gate is posture-scoped: the
# single-node testing path gains no operator ceremony.
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
in
{
  name = "kubenyx-ca-custody";

  nodes = {
    # Durable posture: balanced + persistent etcd = the PKI unit runs
    # --require-shipped-ca and a missing bundle is a hard boot error.
    durable = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        profile = "balanced";
        datastore.backend = "etcd";
        dns.upstream = [ ];
      };
    };
    # Testing profile (every default): per-boot self-mint must survive the
    # custody work untouched — this guest never sees an operator.
    volatile = lib.recursiveUpdate common {
      kubenyx = {
        enable = true;
        dns.upstream = [ ];
      };
    };
  };

  testScript = ''
    import base64
    import hashlib
    import os
    import subprocess

    start_all()

    # --- Volatile/testing guest: self-mint, zero ceremony. Its PKI unit
    # completes on its own and the trust roots exist without any shipping.
    volatile.wait_for_unit("kubenyx-pki.service", timeout=600)
    volatile.succeed("test -s /var/lib/kubenyx/pki/ca.key")
    volatile.succeed("test -s /var/lib/kubenyx/pki/sa.key")
    volatile.fail(
        "journalctl -u kubenyx-pki.service | grep -q 'operator-shipped CA bundle'"
    )
    # ...and the cluster actually boots on the self-minted roots.
    volatile.wait_for_unit("kube-apiserver.service", timeout=1800)

    # --- Durable server without a shipped bundle: the PKI unit must FAIL
    # with the documented error naming the mint-ca command...
    durable.wait_until_succeeds(
        "journalctl -u kubenyx-pki.service | grep -q 'requires an operator-shipped CA bundle'",
        timeout=300,
    )
    durable.wait_until_succeeds(
        "journalctl -u kubenyx-pki.service | grep -q 'kubenyx-pki mint-ca --out'",
        timeout=60,
    )
    durable.wait_until_succeeds(
        'test "$(systemctl is-failed kubenyx-pki.service)" = failed', timeout=60
    )
    # ...and it must NOT have self-minted anything: no trust root, no leaf,
    # no apiserver.
    durable.fail("test -e /var/lib/kubenyx/pki/ca.key")
    durable.fail("test -e /var/lib/kubenyx/pki/apiserver.crt")
    durable.fail("systemctl is-active kube-apiserver.service")

    # --- Offline mint on the driver host (the operator's workstation), then
    # ship the six-file custody bundle over the driver channel — never a 9p
    # share (multi-node.nix records why).
    bundle = os.path.join(os.environ.get("TMPDIR", "/tmp"), "kubenyx-ca-bundle")
    subprocess.run(
        ["${lib.getExe' kubenyxTools "kubenyx-pki"}", "mint-ca", "--out", bundle],
        check=True,
    )
    custody = ["ca.crt", "ca.key", "front-proxy-ca.crt", "front-proxy-ca.key", "sa.key", "sa.pub"]
    durable.succeed("mkdir -p /var/lib/kubenyx/pki")
    for f in custody:
        with open(os.path.join(bundle, f), "rb") as fh:
            blob = base64.b64encode(fh.read()).decode()
        durable.succeed(f"echo '{blob}' | base64 -d > /var/lib/kubenyx/pki/{f}")

    # Operator flow: rerun the PKI (custody accepted, leaves cascade from
    # the shipped CA), then clear the start-limit counters the pre-bundle
    # crash loops earned and restart the chain as one ordered transaction.
    durable.succeed("systemctl restart kubenyx-pki.service")
    # Shipping transports rarely preserve modes; the tool enforces 0600.
    durable.succeed("stat -c %a /var/lib/kubenyx/pki/ca.key | grep -q 600")
    durable.succeed("systemctl reset-failed")
    durable.succeed(
        "systemctl restart --no-block etcd.service kube-apiserver.service"
        " kube-controller-manager.service kube-scheduler.service"
        " kube-proxy.service kubelet.service kubenyx-addons.service"
    )

    # The running CA IS the shipped one — bit-identical to the operator's
    # copy, not a fresh mint that merely arrived at the same path.
    with open(os.path.join(bundle, "ca.crt"), "rb") as fh:
        shipped = hashlib.sha256(fh.read()).hexdigest()
    durable.succeed(
        f"sha256sum /var/lib/kubenyx/pki/ca.crt | grep -q {shipped}"
    )

    # Full boot on the shipped roots: node Ready end-to-end.
    durable.wait_until_succeeds(
        "kubectl get node durable -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )
  '';
}
