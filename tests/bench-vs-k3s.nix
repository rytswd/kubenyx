# Head-to-head boot benchmark: Kubenyx vs k3s in identical VMs, both fully
# airgapped (Kubenyx by design, k3s via its airgap images). VMs boot
# sequentially so they never contend for host CPU. Absolute numbers are
# meaningless under nested/TCG virtualization — the *ratio* is the metric.
{ kubenyx }:
{ pkgs, lib, ... }:
let
  vmResources = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;
  };
in
{
  name = "kubenyx-bench-vs-k3s";

  nodes = {
    kubenyxvm =
      { config, pkgs, ... }:
      {
        imports = [ kubenyx.nixosModules.default ];
        virtualisation = vmResources;
        kubenyx = {
          enable = true;
          dns.upstream = [ ];
        };
      };

    k3svm =
      { config, pkgs, ... }:
      {
        virtualisation = vmResources;
        services.k3s = {
          enable = true;
          role = "server";
          images = [ config.services.k3s.package.airgap-images ];
          extraFlags = [
            # Keep the comparison honest: strip k3s's bundled extras the
            # same way its own docs recommend for lean installs.
            "--disable=traefik,servicelb,metrics-server"
            "--disable-cloud-controller"
          ];
        };
        environment.systemPackages = [ pkgs.k3s ];
      };
  };

  testScript = ''
    import time

    def bench(vm, ready_cmd, label):
        t0 = time.time()
        vm.start()
        vm.wait_until_succeeds(ready_cmd, timeout=3600)
        elapsed = time.time() - t0
        print(f"KUBENYX-METRIC {label}_node_ready={elapsed:.1f}s")
        vm.shutdown()
        return elapsed

    t_k3s = bench(
        k3svm,
        "k3s kubectl get node k3svm -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        "k3s",
    )

    t_kubenyx = bench(
        kubenyxvm,
        "kubectl get node kubenyxvm -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True",
        "kubenyx",
    )

    ratio = t_kubenyx / t_k3s
    print(f"KUBENYX-METRIC kubenyx_vs_k3s_ratio={ratio:.2f}")
  '';
}
