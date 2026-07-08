# Local storage (air/v0.4/byod.org §2): kubenyx.storage.localVolumes
# declares static local PVs + a default no-provisioner StorageClass through
# the addons applier — zero daemons, zero images. The leg proves the
# WaitForFirstConsumer contract end to end: the PVC pends until a pod
# schedules, binds on schedule, and the data a pod writes survives a pod
# delete/recreate (the PVC — and so the PV directory — outlives the pod).
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };

  pvc = builtins.toJSON {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata.name = "data";
    spec = {
      # No storageClassName: binding must come from the default-class
      # annotation on kubenyx's StorageClass.
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = "1Gi";
    };
  };

  mkPod =
    name: command:
    builtins.toJSON {
      apiVersion = "v1";
      kind = "Pod";
      metadata.name = name;
      spec = {
        restartPolicy = "Never";
        containers = [
          {
            inherit name;
            image = "kubenyx.local/test:1";
            command = [
              "/bin/busybox"
              "sh"
              "-c"
              command
            ];
            volumeMounts = [
              {
                name = "data";
                mountPath = "/data";
              }
            ];
          }
        ];
        volumes = [
          {
            name = "data";
            persistentVolumeClaim.claimName = "data";
          }
        ];
      };
    };

  writerPod = mkPod "writer" "echo kubenyx-persisted > /data/probe && /bin/busybox sleep 3600";
  readerPod = mkPod "reader" "/bin/busybox sleep 3600";
in
{
  name = "kubenyx-local-storage";

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
        dns.upstream = [ ]; # airgapped: no external forwarding
        node.seedImages = [ testImage ];
        storage.localVolumes = {
          count = 2;
          size = "2Gi";
        };
      };
    };

  testScript = ''
    import base64

    def apply(manifest):
        blob = base64.b64encode(manifest.encode()).decode()
        machine.succeed(f"echo '{blob}' | base64 -d | kubectl apply -f -")

    machine.start()

    machine.wait_for_unit("kube-apiserver.service", timeout=1800)
    machine.wait_for_unit("kubenyx.target", timeout=1800)
    machine.wait_for_unit("kubenyx-addons.service", timeout=1800)

    # --- declared objects exist, nothing runs for them ------------------------
    # The default StorageClass: no-provisioner, WaitForFirstConsumer.
    machine.succeed(
        "kubectl get storageclass kubenyx-local -o jsonpath='{.provisioner}'"
        " | grep -q 'kubernetes.io/no-provisioner'"
    )
    machine.succeed(
        "kubectl get storageclass kubenyx-local -o jsonpath='{.volumeBindingMode}'"
        " | grep -q WaitForFirstConsumer"
    )
    machine.succeed(
        "kubectl get storageclass kubenyx-local -o jsonpath="
        "'{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}'"
        " | grep -q true"
    )

    # count=2 PVs, Available, pinned to this node, backed by tmpfiles dirs.
    machine.succeed("kubectl get pv local-pv-0 local-pv-1")
    machine.succeed(
        "kubectl get pv local-pv-0 -o jsonpath='{.status.phase}' | grep -q Available"
    )
    machine.succeed(
        "kubectl get pv local-pv-0 -o jsonpath="
        "'{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'"
        " | grep -qx machine"
    )
    machine.succeed("test -d /var/lib/kubenyx/volumes/local-pv-0")
    machine.succeed("test -d /var/lib/kubenyx/volumes/local-pv-1")

    # Zero daemons: the storage feature added no pods (the cluster runs
    # none at all before the test's own) and no provisioner process.
    machine.succeed("[ -z \"$(kubectl get pods -A -o name)\" ]")
    machine.fail("pgrep -f provisioner")

    # --- WaitForFirstConsumer: the PVC pends until a pod schedules ------------
    machine.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    pvc = ${builtins.toJSON pvc}
    apply(pvc)
    # Deliberate settle window: binding now would be an eager-binding bug.
    machine.sleep(10)
    machine.succeed("kubectl get pvc data -o jsonpath='{.status.phase}' | grep -q Pending")

    # --- pod schedules; PVC binds; pod writes ---------------------------------
    writer = ${builtins.toJSON writerPod}
    apply(writer)
    machine.wait_until_succeeds(
        "kubectl get pod writer -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )
    machine.wait_until_succeeds(
        "kubectl get pvc data -o jsonpath='{.status.phase}' | grep -q Bound", timeout=300
    )
    # Bound to one of the declared PVs, and the write landed in its directory.
    bound_pv = machine.succeed("kubectl get pvc data -o jsonpath='{.spec.volumeName}'").strip()
    assert bound_pv in ("local-pv-0", "local-pv-1"), f"PVC bound to unexpected PV: {bound_pv}"
    machine.wait_until_succeeds(
        "kubectl exec writer -- /bin/busybox cat /data/probe | grep -q kubenyx-persisted",
        timeout=300,
    )
    machine.succeed(f"grep -q kubenyx-persisted /var/lib/kubenyx/volumes/{bound_pv}/probe")

    # --- data survives pod delete/recreate -------------------------------------
    machine.succeed("kubectl delete pod writer --wait=true --timeout=120s")
    reader = ${builtins.toJSON readerPod}
    apply(reader)
    machine.wait_until_succeeds(
        "kubectl get pod reader -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )
    # Same claim, same PV, same bytes.
    still_bound = machine.succeed("kubectl get pvc data -o jsonpath='{.spec.volumeName}'").strip()
    assert still_bound == bound_pv, f"PVC re-bound across pod recreate: {bound_pv} -> {still_bound}"
    machine.succeed("kubectl exec reader -- /bin/busybox cat /data/probe | grep -q kubenyx-persisted")
  '';
}
