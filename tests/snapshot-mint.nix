# v0.10 mint leg (air/v0.1/snapshot/ci-artifacts.org): the snapshot
# artifact as a DERIVATION. The same 2-node shape as harness-snapshot is
# booted through lib.harness with mintable = true (derivation-built
# store image, pinned CPU model), cut at the fixed snapshot point
# (after waitReady), seeded with the provenance/leak marker pair, and
# packaged: $out = { manifest, sizes, <node>.qcow2.zst... }. The
# snapshot-restore leg consumes this output as a derivation input —
# that dependency edge is the entire point of the leg.
#
# Skylake-Server-v4 with enforce (ci-artifacts.org §1): the newest
# model every Xeon Scalable gen 1+ host satisfies, noTSX (TAA-microcode
# safe), no XSAVES (no supervisor xstate in the frozen vmstate — the
# phase 2 XRSTORS lesson), no ARCH_CAPABILITIES (an enforce-portability
# trap across mixed microcode), and structurally AMX-free (the qemu
# twin of the firecracker amx mask).
{ kubenyx, pkgs }:
kubenyx.lib.harness.mkSnapshotMint {
  inherit pkgs;
  name = "kubenyx-snapshot-mint";
  cpuModel = "Skylake-Server-v4";
  clusterArgs = {
    members = {
      server = {
        index = 0;
        role = "server";
      };
      agent = {
        index = 1;
      }; # role defaults to "agent"
    };
    defaults = {
      # kine is single-node by assertion; etcd is the smallest
      # multi-node datastore choice.
      datastore.backend = "etcd";
    };
  };
}
