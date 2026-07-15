# Prebake bench leg (air/v0.1/perf/prebake.org acceptance): a deliberately
# LARGE synthetic image set — 10 distinct 30 MB layers, ~300 MB total,
# deterministic AES-CTR keystream so the bytes are incompressible and
# the sha256-dominated import cost is honest — measured in-guest on two
# otherwise identical single-node clusters:
#   importer: prebake OFF — the kubenyx-seed-images unit pays the full
#             `ctr import` (content ingest + digest verify + unpack);
#   baked:    prebake ON — the same set ships as a build-time store and
#             boot pays only the kubenyx-prebaked-store overlay mount.
# Contract: the prebaked side eliminates >= 90% of the import cost.
# Both walls come from each guest's own systemd monotonic clock
# (InactiveExit -> ActiveEnter of the oneshot), not host wall time.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  layerMB = 30;
  layerCount = 10;

  # One store path per layer: streamLayeredImage gives each its own
  # layer. openssl AES-CTR keystream = deterministic AND incompressible
  # (a /dev/zero-style filler would let the store image compress the
  # bench away).
  mkBlob =
    i:
    pkgs.runCommand "prebake-bench-blob-${toString i}" { } ''
      mkdir -p $out/blob
      # Bounded on the INPUT side: head|openssl, not openssl|head — the
      # latter SIGPIPEs openssl under stdenv's pipefail. CTR keystream
      # over zeros: output size == input size, deterministic per pass.
      head -c ${toString (layerMB * 1024 * 1024)} /dev/zero \
        | ${lib.getExe pkgs.openssl} enc -aes-128-ctr -nosalt \
            -pass pass:kubenyx-prebake-${toString i} \
        > $out/blob/layer-${toString i}.bin
    '';

  bigImage = pkgs.dockerTools.streamLayeredImage {
    name = "kubenyx.local/prebake-bench";
    tag = "1";
    contents = map mkBlob (lib.range 0 (layerCount - 1));
    config.Cmd = [ "/bin/true" ];
  };

  common = {
    imports = [ kubenyx.nixosModules.default ];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 10240;
    };
    kubenyx = {
      enable = true;
      dns.upstream = [ ];
      node.seedImages = [ bigImage ];
    };
  };
in
{
  name = "kubenyx-prebake-bench";

  nodes = {
    importer = common;
    baked = lib.recursiveUpdate common { kubenyx.node.prebakeImages = true; };
  };

  testScript = ''
    def unit_wall_us(machine, unit):
        # In-guest monotonic microseconds: unit activation start -> active.
        start = int(machine.succeed(
            f"systemctl show -p InactiveExitTimestampMonotonic --value {unit}"
        ).strip())
        done = int(machine.succeed(
            f"systemctl show -p ActiveEnterTimestampMonotonic --value {unit}"
        ).strip())
        assert done >= start > 0, f"{unit}: bad timestamps start={start} done={done}"
        return done - start

    start_all()

    importer.wait_for_unit("kubenyx-seed-images.service", timeout=1800)
    baked.wait_for_unit("kubenyx-prebaked-store.service", timeout=1800)

    # Both sides really hold the full set.
    for m in (importer, baked):
        m.wait_for_unit("kubenyx.target", timeout=1800)
        # Plain grep (not -q): -q's early exit SIGPIPEs ctr under pipefail.
        m.succeed("ctr --namespace k8s.io images ls | grep -F kubenyx.local/prebake-bench:1")
        m.succeed("ctr --namespace k8s.io images ls | grep -F kubenyx.local/pause:1")

    import_us = unit_wall_us(importer, "kubenyx-seed-images.service")
    mount_us = unit_wall_us(baked, "kubenyx-prebaked-store.service")

    eliminated = 100.0 * (1.0 - mount_us / import_us)
    print(
        f"PREBAKE-BENCH set={${toString layerCount}}x${toString layerMB}MB"
        f" import_wall={import_us/1e6:.3f}s prebaked_mount_wall={mount_us/1e6:.3f}s"
        f" eliminated={eliminated:.1f}%"
    )

    # The contract: >= 90% of the boot-time import cost is gone.
    assert mount_us <= 0.10 * import_us, (
        f"prebaked mount ({mount_us/1e6:.3f}s) must eliminate >=90% of the "
        f"import cost ({import_us/1e6:.3f}s), eliminated only {eliminated:.1f}%"
    )
  '';
}
