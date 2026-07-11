# Dogfood leg for lib.harness (air/v0.6/harness.org): a MINIMAL consumer
# stands up server + agent through mkCluster ONLY — no hand-written
# kubenyx config beyond the workload seed image — and runs a pod. The
# nodes, the credential ship, every readiness gate, and the kubectl
# wrapper all come from the exported helper; if the surface is
# insufficient for basic embedding, this check breaks before a consumer
# does. Addresses are deliberately omitted from the members set: the
# helper must resolve the driver-assigned ones (the alphabetical-order
# footgun the hand-written tests each carry a warning about).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

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
    defaults = {
      # kine is single-node by assertion; the smallest multi-node
      # datastore choice a consumer would make.
      datastore.backend = "etcd";
      node.seedImages = [ testImage ];
    };
  };
in
{
  name = "kubenyx-harness";

  nodes = cluster.nodes;

  testScript = ''
    start_all()

    ${cluster.waitReady}

    # ── the dogfood proof: a pod runs on the helper-built cluster ──────
    # Scheduler-placed (no nodeName pin): both nodes are Ready, so this
    # also exercises whichever node the scheduler picks.
    kubenyx_kubectl(server, "run web --image=kubenyx.local/test:1 --restart=Never")
    server.wait_until_succeeds(
        "kubectl get pod web -o jsonpath='{.status.phase}' | grep -q Running",
        timeout=900,
    )
    # The workload answers over the pod network from the server's netns
    # (via kubectl exec, so the kubelet client path is exercised too).
    server.wait_until_succeeds(
        "kubectl exec web -- /bin/busybox wget -qO- http://127.0.0.1:8080 | grep -q kubenyx-ok",
        timeout=300,
    )
  '';
}
