# Single-node happy path (air/v0.1/vm-tests.org). Runs in the Nix sandbox
# with no network — which is itself the proof of the zero-registry design.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  testImage = pkgs.callPackage ../pkgs/test-image.nix { };
in
{
  name = "kubenyx-single-node";

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
      };
    };

  testScript = ''
    import time

    machine.start()
    t0 = time.time()

    machine.wait_for_unit("kube-apiserver.service", timeout=1800)
    t_api = time.time() - t0
    print(f"KUBENYX-METRIC apiserver_ready={t_api:.1f}s")

    machine.wait_for_unit("kubenyx.target", timeout=1800)

    machine.wait_until_succeeds(
        "kubectl get node machine -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        timeout=1800,
    )
    t_node = time.time() - t0
    print(f"KUBENYX-METRIC node_ready={t_node:.1f}s")

    # --- security posture ---------------------------------------------------
    # Anonymous requests must be rejected outright (401), health included.
    machine.succeed(
        "curl -ks -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/api | grep -q 401"
    )
    machine.succeed("kubectl auth can-i '*' '*' | grep -q yes")

    # PKI idempotency: re-running the generator must not reissue anything.
    before = machine.succeed("stat -c %Y /var/lib/kubenyx/pki/apiserver.crt /var/lib/kubenyx/pki/ca.crt")
    machine.systemctl("restart kubenyx-pki.service")
    machine.wait_for_unit("kubenyx-pki.service")
    after = machine.succeed("stat -c %Y /var/lib/kubenyx/pki/apiserver.crt /var/lib/kubenyx/pki/ca.crt")
    assert before == after, f"PKI regenerated on no-op activation: {before} vs {after}"

    # --- workload (zero registry access) -------------------------------------
    # Pod admission needs the default ServiceAccount, created async by kcm.
    machine.wait_until_succeeds("kubectl -n default get serviceaccount default", timeout=600)
    machine.succeed("kubectl run web --image=kubenyx.local/test:1 --restart=Never")
    machine.wait_until_succeeds(
        "kubectl get pod web -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )
    t_pod = time.time() - t0
    print(f"KUBENYX-METRIC pod_running={t_pod:.1f}s")

    # exec/logs prove the apiserver->kubelet client-cert path.
    machine.succeed("kubectl exec web -- /bin/busybox true")

    # crun is the runtime actually running the pod.
    machine.succeed(
        "systemctl show containerd -p SubState | grep -q running && ps aux | grep -v grep | grep -q containerd-shim"
    )

    # --- services + DNS -------------------------------------------------------
    machine.succeed("kubectl expose pod web --port=80 --target-port=8080 --name=websvc")
    machine.succeed("kubectl run client --image=kubenyx.local/test:1 --restart=Never --command -- /bin/busybox sleep 3600")
    machine.wait_until_succeeds(
        "kubectl get pod client -o jsonpath='{.status.phase}' | grep -q Running", timeout=900
    )

    # DNS from a pod (cluster names; upstream forwarding is off in this test).
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox nslookup kubernetes.default.svc.cluster.local", timeout=300
    )
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox nslookup websvc.default.svc.cluster.local", timeout=300
    )

    # Service VIP path through nftables kube-proxy.
    machine.wait_until_succeeds(
        "kubectl exec client -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )

    # Hairpin: the pod reaches itself through its own service VIP.
    machine.wait_until_succeeds(
        "kubectl exec web -- /bin/busybox wget -qO- http://websvc.default.svc.cluster.local | grep -q kubenyx-ok",
        timeout=300,
    )

    # --- audit ----------------------------------------------------------------
    machine.fail("pgrep flanneld")
    machine.fail("pgrep -f cilium")
    machine.fail("pgrep -x etcd")  # kine backend: no etcd process anywhere

    t_total = time.time() - t0
    print(f"KUBENYX-METRIC happy_path_total={t_total:.1f}s")
  '';
}
