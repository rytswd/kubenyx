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
          # Declared address: PKI (and with it the whole control-plane
          # chain) starts at local-fs time instead of network-online.
          nodes.kubenyxvm = {
            index = 0;
            address = "192.168.1.1";
          };
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
    import re
    import time

    def bench(vm, ready_cmd, label):
        t0 = time.time()
        vm.start()
        vm.wait_until_succeeds(ready_cmd, timeout=3600)
        elapsed = time.time() - t0
        # Primary metric: the identical kubelet line both distros log, on the
        # in-VM monotonic clock — kubectl polling under TCG adds ~1min of
        # driver-side noise that would otherwise drown the signal.
        journal = vm.succeed(
            "journalctl --no-pager -o short-monotonic | grep -a 'just became ready' | head -1"
        )
        m = re.search(r"\[\s*([0-9.]+)\]", journal)
        in_vm = float(m.group(1)) if m else elapsed
        print(f"KUBENYX-METRIC {label}_node_ready_invm={in_vm:.1f}s")
        print(f"KUBENYX-METRIC {label}_node_ready={elapsed:.1f}s")
        vm.shutdown()
        return in_vm

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
