# Kubenyx microVM guest profile: a disposable single-node test cluster
# tuned for boot speed. On a KVM host, the firecracker/cloud-hypervisor
# variants boot this to cluster-ready in single-digit seconds; the qemu
# variant exists so the profile stays verifiable on KVM-less machines.
#
# Everything is volatile by design: the root is tmpfs over a read-only
# store image, the datastore lives on tmpfs, and the PKI regenerates in
# ~6ms on every boot — a fresh, honest cluster per launch.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = lib.mkDefault "kubenyx";

  # squashfs over the default erofs: mkfs.erofs needs shared-xattr support
  # that overlayfs-backed build environments (containers) lack.
  microvm.storeDiskType = "squashfs";

  kubenyx = {
    enable = true;
    datastore.volatile = true;
  };

  # ---- boot leanness -------------------------------------------------------
  documentation.enable = false;
  nix.enable = false; # guests are built, never build
  # No DHCP wait: addresses are static per variant; boot must not block on
  # network-online for anything but the (instant) declared-address PKI.
  networking.useDHCP = false;
  systemd.network.wait-online.enable = false;
  boot.initrd.systemd.enable = true;

  # ---- observability -------------------------------------------------------
  # Phase markers on the console: systemd stops mirroring unit status once
  # startup "finishes", so key units announce themselves explicitly.
  # Semantics: notify units (kine, kube-apiserver, coredns) mark genuine
  # readiness (ExecStartPost runs after READY=1); kubelet (Type=simple)
  # and oneshots mark process start/completion. The list matches this
  # guest's fixed shape (kine backend, server role) — adjust it if the
  # profile ever changes backend or role.
  systemd.services =
    lib.genAttrs
      [
        "kine"
        "kube-apiserver"
        "kubelet"
        "coredns"
        "kubenyx-addons"
      ]
      (name: {
        serviceConfig.ExecStartPost = "${pkgs.runtimeShell} -c 'echo KUBENYX-PHASE ${name} up=$(cut -d\" \" -f1 /proc/uptime) > /dev/console'";
      })
    // {
      # Grep-able readiness marker with the in-guest monotonic time — the
      # benchmark interface for every variant. Polls with curl (cheap even
      # under emulation); wall-clock-based self-diagnosis when late.
      kubenyx-report = {
        description = "Report cluster readiness to the console";
        wantedBy = [ "multi-user.target" ];
        after = [ "kubenyx.target" ];
        path = [ pkgs.curl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 660; # bounded: the script gives up at 600s
        };
        script = ''
          node=${lib.escapeShellArg config.kubenyx.nodeName}
          pki=/var/lib/kubenyx/pki
          dumped=""
          probe() {
            # Admin identity: the healthz cert is deliberately unprivileged
            # and only passes always-allowed /healthz-class paths — reading
            # a node object needs RBAC. tr strips pretty-print whitespace so
            # the condition pair is greppable on one line.
            curl -s --max-time 5 \
              --cacert "$pki/ca.crt" --cert "$pki/admin.crt" --key "$pki/admin.key" \
              "https://127.0.0.1:6443/api/v1/nodes/$node" 2>/dev/null \
              | tr -d ' \n' | grep -q '"type":"Ready","status":"True"'
          }
          while ! probe; do
            sleep 1
            up=$(cut -d. -f1 /proc/uptime)
            if [ -z "$dumped" ] && [ "$up" -gt 300 ]; then
              dumped=1
              {
                echo "KUBENYX-DEGRADED: not ready at uptime ''${up}s"
                systemctl list-units --failed --no-legend || true
                for u in kubenyx-pki kine kube-apiserver kubelet; do
                  echo "--- $u:"
                  journalctl -u "$u" --no-pager -n 4 -o cat || true
                done
              } > /dev/console 2>&1
            fi
            # Terminal give-up: a failed unit (no marker) beats wedging
            # multi-user.target in "starting" forever.
            if [ "$up" -gt 600 ]; then
              echo "KUBENYX-FAILED: gave up at uptime ''${up}s" > /dev/console
              exit 1
            fi
          done
          up=$(cut -d' ' -f1 /proc/uptime)
          echo "KUBENYX-CLUSTER-READY uptime=''${up}s" > /dev/console
        '';
      };
    };

  system.stateVersion = lib.mkDefault "25.11";
}
