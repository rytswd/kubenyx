# D1 snapshot verbs dogfood (air/v0.8/test-amplification.org): a 2-node
# cluster stood up through lib.harness with snapshotable = true, cut at
# the fixed snapshot point (after waitReady, before any mutation), then
# rewound. The honesty bar is deliberately higher than "the apiserver
# answers TLS": the pre-restore mutation must be GONE, the nodes must
# come back Ready, and a fresh post-restore WRITE must land. A second
# rewind through the per-subtest helper proves the snapshot survives
# being restored twice. Save/load wall seconds per node are logged by
# the verbs themselves (grep the test log for "savevm"/"loadvm").
#
# Reset-in-place costs SECONDS by design — loadvm loads guest RAM
# eagerly. This leg is about byte-honest reuse, not speed.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  cluster = kubenyx.lib.harness.mkCluster {
    members = {
      server = {
        index = 0;
        role = "server";
      };
      agent = {
        index = 1;
      }; # role defaults to "agent"
    };
    snapshotable = true;
    defaults = {
      # kine is single-node by assertion; etcd is the smallest
      # multi-node datastore choice.
      datastore.backend = "etcd";
    };
  };
in
{
  name = "kubenyx-harness-snapshot";

  nodes = cluster.nodes;

  testScript = ''
    start_all()

    ${cluster.waitReady}

    # ── the fixed snapshot point: after bring-up, before mutation ─────
    kubenyx_snapshot_all("pristine")

    with subtest("mutation after the cut is visible"):
        kubenyx_kubectl(server, "create configmap marker --from-literal=made=after-snapshot")
        kubenyx_kubectl(server, "get configmap marker")

    with subtest("restore rewinds the mutation away"):
        kubenyx_restore_all("pristine")
        # Serve first, so the absence below is a real NotFound from a
        # live apiserver, not a refused connection dressed up as one.
        server.wait_until_succeeds(
            "kubectl -n default get configmaps -o name", timeout=300
        )
        status, out = server.execute("kubectl -n default get configmap marker 2>&1")
        assert status != 0 and "not found" in out, (
            f"configmap 'marker' must be GONE after restore, got: {status} {out}"
        )

    with subtest("restored cluster serves: nodes Ready again"):
        kubenyx_wait_node(server, "server")
        kubenyx_wait_node(server, "agent")

    with subtest("post-restore write lands (the honesty bar)"):
        kubenyx_kubectl(server, "create configmap fresh-write --from-literal=who=harness-snapshot")
        server.wait_until_succeeds(
            "kubectl -n default get configmap fresh-write"
            " -o jsonpath='{.data.who}' | grep -qx harness-snapshot",
            timeout=300,
        )

    with kubenyx_fresh_subtest("second rewind is pristine too"):
        server.wait_until_succeeds(
            "kubectl -n default get configmaps -o name", timeout=300
        )
        for gone in ["marker", "fresh-write"]:
            status, out = server.execute(f"kubectl -n default get configmap {gone} 2>&1")
            assert status != 0 and "not found" in out, (
                f"configmap '{gone}' must be GONE after the second restore,"
                f" got: {status} {out}"
            )
        kubenyx_kubectl(server, "create configmap subtest-write --from-literal=ok=1")
        kubenyx_kubectl(server, "get configmap subtest-write")
  '';
}
