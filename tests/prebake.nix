# Pre-baked image stores (air/v0.4/prebake.org): prebakeImages = true
# ships the whole seed set (pause + both seed formats) as a build-time
# containerd content store, overlay-mounted under /var/lib/containerd
# with a tmpfs upper. The leg proves:
# - the seed unit is GONE (not skipped — absent from the boot path);
# - the store is the overlay lower and every baked image is visible to
#   containerd before anything imported anything;
# - pods run from baked images (pause sandbox + both seed formats),
#   i.e. lazy unpack from baked content into the tmpfs upper works via
#   the native snapshotter;
# - the recorded snapshotter call is grounded: an overlay upperdir on
#   the store overlay is rejected by the kernel (the reason the guest
#   cannot keep the overlayfs snapshotter — probed, not assumed).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  # Same non-executable docker-archive shape as the local-storage leg
  # (byod.org §3): proves the bake handles both seed formats.
  archiveImage = pkgs.runCommand "test-archive-image.tar" { } ''
    ${
      pkgs.dockerTools.streamLayeredImage {
        name = "kubenyx.local/test-archive";
        tag = "1";
        contents = [ pkgs.busybox ];
        config.Cmd = [
          "/bin/busybox"
          "sleep"
          "3600"
        ];
      }
    } > $out
  '';
in
{
  name = "kubenyx-prebake";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ kubenyx.nixosModules.default ];

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 8192;
      };

      kubenyx = {
        enable = true;
        dns.upstream = [ ]; # airgapped
        node.prebakeImages = true;
        node.seedImages = [
          testImage
          archiveImage
        ];
      };
    };

  testScript = ''
    machine.start()

    machine.wait_for_unit("kubenyx-prebaked-store.service", timeout=1800)

    # --- the mount is the design: baked lower, tmpfs upper -------------------
    machine.succeed("mountpoint -q /var/lib/containerd")
    machine.succeed(
        "findmnt -n -o FSTYPE /var/lib/containerd | grep -qx overlay"
    )
    machine.succeed(
        "findmnt -n -o OPTIONS /var/lib/containerd | grep -q 'lowerdir=/nix/store/'"
    )

    # --- the seed unit is ABSENT, not just inactive ---------------------------
    machine.fail("systemctl cat kubenyx-seed-images.service")

    machine.wait_for_unit("kube-apiserver.service", timeout=1800)
    machine.wait_for_unit("kubenyx.target", timeout=1800)

    # Every baked image is listed straight from the store — nothing imported
    # them at boot (no seed unit exists to have done so).
    # Plain grep (not -q): -q exits at first match and the resulting
    # SIGPIPE fails ctr under pipefail (observed: exit 141).
    for ref in [
        "kubenyx.local/pause:1",
        "kubenyx.local/test:1",
        "kubenyx.local/test-archive:1",
    ]:
        machine.succeed(f"ctr --namespace k8s.io images ls | grep -F {ref}")

    # The runtime snapshotter really is native (the CRI config switch).
    # The config file is a store path on containerd's ExecStart, not /etc.
    machine.succeed(
        "grep -q 'snapshotter = \"native\"'"
        " \"$(systemctl cat containerd.service | grep -oE '/nix/store/[^ ]+\\.toml' | head -1)\""
    )

    # --- empirical ground for the snapshotter call ----------------------------
    # An overlay upperdir cannot live on an overlayfs: this is exactly what
    # the overlayfs snapshotter would attempt under the mounted store, and
    # the kernel refuses it. Recorded here so the `native` decision stays
    # tied to a probe, not folklore.
    machine.succeed(
        "mkdir -p /var/lib/containerd/.probe-upper /var/lib/containerd/.probe-work /tmp/.probe-merged"
    )
    machine.fail(
        "mount -t overlay overlay"
        " -o lowerdir=/nix/store,upperdir=/var/lib/containerd/.probe-upper,workdir=/var/lib/containerd/.probe-work"
        " /tmp/.probe-merged"
    )

    # --- pods run from baked images (lazy unpack into the tmpfs upper) --------
    machine.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    machine.succeed("kubectl run baked --image=kubenyx.local/test:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod baked -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )
    machine.succeed("kubectl run baked-archive --image=kubenyx.local/test-archive:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod baked-archive -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # The unpack landed in the tmpfs upper, not the immutable lower.
    machine.succeed(
        "ls /run/kubenyx/containerd-upper/io.containerd.snapshotter.v1.native/snapshots | grep -q ."
    )
  '';
}
