# v0.10 consumer leg (air/v0.1/snapshot/ci-artifacts.org): restore the
# snapshot-mint artifact in a DIFFERENT derivation and hold it to the
# honesty bar. mkRestoreTest already gates identity (manifest
# exact-string, before any qemu spawn), starts the nodes paused (-S),
# loadvm-s the pristine tag, adopts the backdoor shells and
# health-gates to Ready — what remains here is proof the state is
# byte-honest in both directions:
#   - mint-leak (created in the mint AFTER the cut, in the active qcow2
#     layer) must be GONE — a consumer that booted the shipped disk
#     instead of loading the snapshot would see it;
#   - mint-provenance (created BEFORE the cut) must be PRESENT — a
#     consumer that quietly cold-booted would not have it;
#   - and a fresh post-restore WRITE must land (a write, not a TLS
#     answer).
{ kubenyx, pkgs }:
kubenyx.lib.harness.mkRestoreTest {
  mint = import ./snapshot-mint.nix { inherit kubenyx pkgs; };
  name = "kubenyx-snapshot-restore";
  testScript = ''
    with subtest("post-cut mint mutation is absent (loadvm really rewound)"):
        status, out = server.execute("kubectl -n default get configmap mint-leak 2>&1")
        assert status != 0 and "not found" in out, (
            f"configmap 'mint-leak' must be GONE after restore, got: {status} {out}"
        )

    with subtest("pre-cut provenance marker is present (state is the mint's)"):
        kubenyx_kubectl(server, "get configmap mint-provenance")

    with subtest("post-restore write lands (the honesty bar)"):
        kubenyx_kubectl(server, "create configmap fresh-write --from-literal=who=snapshot-restore")
        server.wait_until_succeeds(
            "kubectl -n default get configmap fresh-write"
            " -o jsonpath='{.data.who}' | grep -qx snapshot-restore",
            timeout=300,
        )
  '';
}
