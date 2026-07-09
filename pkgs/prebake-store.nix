# Build-time pre-baked containerd store (air/v0.4/prebake.org): run
# containerd inside the nix sandbox with --root $out, `ctr import` the
# seed set, and ship the resulting /var/lib/containerd tree (content
# blobs + boltdb metadata) in the closure. Boot-time import cost drops
# to mounting a filesystem.
#
# Sandbox constraints, discovered empirically (recorded in the doc's
# History):
# - No KVM, no root, no mount(2): every runtime/CRI/task plugin is
#   disabled; only content, images, metadata (bolt), diff, leases and
#   the native snapshotter stay up. The overlayfs snapshotter cannot
#   even be baked against — its mounts need CAP_SYS_ADMIN.
# - The import runs --no-unpack: baked SNAPSHOTS would be corrupted by
#   nix store normalization (every file forced to 0444/0555, uid 0,
#   mtime 1 — a native snapshot is plain dirs, so tmp-style 1777 dirs
#   and non-root ownership inside images would be silently destroyed).
#   Content blobs are opaque tars, immune to normalization; the guest
#   unpacks lazily at first use into the tmpfs upper with real modes.
{
  lib,
  runCommand,
  containerd,
  # [pauseImage] ++ seedImages: executable entries are streamLayeredImage
  # scripts (stdout piped to ctr), non-executable entries are plain
  # OCI/docker archives — the same branch the boot-time seed unit takes.
  images,
}:
runCommand "kubenyx-prebaked-containerd"
  {
    nativeBuildInputs = [ containerd ];
  }
  ''
    mkdir -p "$out"
    state="$NIX_BUILD_TOP/containerd-state"
    mkdir -p "$state"
    sock="$state/c.sock"

    cat > containerd.toml <<EOF
    version = 3
    root = "$out"
    state = "$state"
    disabled_plugins = [
      "io.containerd.grpc.v1.cri",
      "io.containerd.cri.v1.runtime",
      "io.containerd.cri.v1.images",
      "io.containerd.runtime.v2.task",
      "io.containerd.shim.v1.manager",
      "io.containerd.service.v1.tasks-service",
      "io.containerd.grpc.v1.tasks",
      "io.containerd.nri.v1.nri",
      "io.containerd.internal.v1.opt",
      "io.containerd.internal.v1.tracing",
      "io.containerd.monitor.container.v1.restart",
      "io.containerd.monitor.task.v1.cgroups",
      "io.containerd.snapshotter.v1.blockfile",
      "io.containerd.snapshotter.v1.btrfs",
      "io.containerd.snapshotter.v1.devmapper",
      "io.containerd.snapshotter.v1.erofs",
      "io.containerd.snapshotter.v1.overlayfs",
      "io.containerd.snapshotter.v1.zfs",
      "io.containerd.differ.v1.erofs",
      "io.containerd.mount-handler.v1.erofs",
      "io.containerd.image-verifier.v1.bindir",
      "io.containerd.tracing.processor.v1.otlp",
    ]

    # uid/gid: containerd chowns its sockets to the configured owner
    # (default 0); the sandbox user cannot chown to root (EINVAL — uid 0
    # is unmapped in the build userns), so own them explicitly.
    [grpc]
      address = "$sock"
      uid = $(id -u)
      gid = $(id -g)

    [ttrpc]
      address = "$sock.ttrpc"
      uid = $(id -u)
      gid = $(id -g)
    EOF

    containerd --config containerd.toml --log-level warn &
    pid=$!

    for _ in $(seq 1 300); do
      if [ -S "$sock" ] && ctr --address "$sock" version >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    ctr --address "$sock" version >/dev/null

    for img in ${lib.escapeShellArgs (map toString images)}; do
      if [ -x "$img" ]; then
        "$img" | ctr --address "$sock" --namespace k8s.io images import \
          --local --no-unpack --all-platforms -
      else
        ctr --address "$sock" --namespace k8s.io images import \
          --local --no-unpack --all-platforms "$img"
      fi
    done

    ctr --address "$sock" --namespace k8s.io images ls

    # Graceful stop: bolt must close cleanly or the baked meta.db could
    # carry a stale lock/dirty pages.
    kill "$pid"
    wait "$pid" || true
  ''
