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
let
  cfg = config.kubenyx;
  # Warmup script: pre-read the critical Go binaries from the erofs store
  # into the guest page cache during the initrd phase. The script must be
  # a named let binding so it can be added to boot.initrd.systemd.storePaths
  # — the initrd builder does NOT auto-follow ExecStart paths into the initrd.
  storeWarmupScript = pkgs.writeShellScript "kubenyx-warmup" ''
    # erofs is mounted at /sysroot/nix/store in the initrd (sysroot-nix-store.mount).
    # Page cache is keyed by block device, so warming here benefits the real system
    # reads of /nix/store/... after switch-root — same device, same cache entries.
    echo "KUBENYX-WARMUP start=$(${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime)" > /dev/console
    _dd() { ${pkgs.coreutils}/bin/dd if="$1" of=/dev/null bs=4M status=none 2>/dev/null || true; }
    _dd "/sysroot${lib.getExe' cfg.packages.kubernetes "kube-apiserver"}"
    _dd "/sysroot${lib.getExe' cfg.packages.kubernetes "kubelet"}"
    _dd "/sysroot${lib.getExe' cfg.packages.containerd "containerd"}"
    echo "KUBENYX-WARMUP done=$(${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime)" > /dev/console
  '';
in
lib.mkMerge [
  # ---- base profile ----------------------------------------------------------
  {
    networking.hostName = lib.mkDefault "kubenyx";

    # erofs over squashfs: better random-read latency under KVM (no per-read
    # block decompression overhead; the host page cache serves reads at memory
    # speed). squashfs is only needed for container builds where mkfs.erofs
    # lacks shared-xattr support — not an issue on a real host.
    # microvm.storeDiskType defaults to erofs when this line is absent.

    # ---- initrd store warmup -------------------------------------------------
    # The critical Go binaries (apiserver 85MB, kubelet 58MB, containerd 42MB)
    # are demand-paged from the erofs virtio-blk disk on first exec. Reading
    # them sequentially in the initrd warms the guest page cache — pages
    # survive pivot_root/switch-root because the page cache is keyed by
    # (device, offset), which doesn't change. etcd-mem is Rust (1.9MB) and
    # needs no warming. At 1GB/s virtio-blk this is ~180ms one-time cost.
    #
    # storePaths is required: the initrd builder does NOT auto-follow ExecStart
    # paths; without it the script is absent from the initrd's /nix/store and
    # the service silently fails to exec.
    boot.initrd.systemd.storePaths = [ storeWarmupScript ];
    boot.initrd.systemd.services.kubenyx-store-warmup = {
      description = "Pre-read kubenyx binaries into guest page cache";
      after = [ "sysroot-nix-store.mount" ];
      # Anchor to initrd-nixos-activation.service — it is definitely in the switch-root
      # transaction and runs after sysroot-nix-store.mount, so warmup runs at the right
      # time and blocks switch-root. Using initrd-default.target was insufficient because
      # Wants= does not hold the target, and Before=initrd-switch-root.service was not
      # in the same transaction.
      before = [ "initrd-nixos-activation.service" ];
      wantedBy = [ "initrd-nixos-activation.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 30;
        ExecStart = storeWarmupScript;
      };
    };

    kubenyx = {
      enable = true;
      datastore.backend = "etcd-mem";
      datastore.volatile = true;
    };

    # ---- snapshot/restore hygiene ---------------------------------------------
    # Firecracker exposes an ACPI VMGenID device (FCVMGID), but nothing loads
    # the driver by default — without it a restored clone KEEPS the snapshot's
    # CRNG state, so every clone draws identical randomness. With the module
    # the kernel reseeds on restore ("crng reseeded due to virtual machine
    # fork"). No cost on ordinary boots.
    boot.kernelModules = [ "vmgenid" ];

    # ---- interactive console ---------------------------------------------------
    # Disposable host-only test VM: autolog the serial console in as root.
    # Without this there is no way in at all — root is locked by default and
    # the per-boot PKI (and thus any credential) exists only inside the
    # guest tmpfs. kubectl works immediately in the shell via the global
    # KUBECONFIG. Exit the VM with `poweroff` (or `reboot` — firecracker
    # treats a guest reboot as VMM exit).
    services.getty.autologinUser = "root";

    # ---- boot leanness -------------------------------------------------------
    documentation.enable = false;
    nix.enable = false; # guests are built, never build
    # No DHCP wait: addresses are static per variant; boot must not block on
    # network-online for anything but the (instant) declared-address PKI.
    networking.useDHCP = false;
    systemd.network.wait-online.enable = false;
    boot.initrd.systemd.enable = true;

    # Ephemeral-VM service pruning: none of these serve disposable test clusters.
    networking.firewall.enable = false; # nftables startup + module load
    services.timesyncd.enable = false; # no persistent clock needed
    services.logrotate.enable = false; # nothing to rotate in a tmpfs guest
    # Volatile journal: skip the flush-to-disk service entirely.
    services.journald.storage = "volatile";

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
          "etcd-mem"
          "kube-apiserver"
          "kubelet"
          "coredns"
          "kubenyx-addons"
        ]
        (name: {
          serviceConfig.ExecStartPost = "${pkgs.runtimeShell} -c 'echo KUBENYX-PHASE ${name} up=$(cut -d\" \" -f1 /proc/uptime) > /dev/console'";
        })
      // {
        # Disable ephemeral-irrelevant services. These must live inside the
        # services attrset to avoid a Nix attribute-conflict with the genAttrs
        # block above; the second lib.mkMerge block below can use separate
        # top-level keys freely.
        systemd-random-seed.enable = false; # nothing to save/restore per boot
        systemd-networkd-persistent-state.enable = false; # volatile guest

        # Post-restore wall-clock correction: a restored snapshot keeps
        # monotonic time (kvmclock state travels with the snapshot) but
        # CLOCK_REALTIME is stale by the snapshot→restore gap and nothing
        # in the guest fixes it (firecracker attaches no VMCLOCK device —
        # verified; no RTC). kubenyx-snap sends UDP time pokes from the
        # host right after /snapshot/load; this daemon steps the clock.
        # Steps only on >500ms offset, so it is a no-op on ordinary boots.
        kubenyx-clockstep = {
          description = "Step the wall clock from host time pokes after a snapshot restore";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${lib.getExe' cfg.internal.tools "kubenyx-clockstep"} --allow-from 10.100.0.1";
            Restart = "always";
            RestartSec = 1;
          };
        };

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
              sleep 0.25
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

  # ---- early-boot override ---------------------------------------------------
  # Pull kubenyx.target out of the basic.target dependency chain so the
  # cluster services can start as soon as tmpfiles are set up (~2s) rather
  # than waiting for the full "Basic System" target (~5s). Each service also
  # needs DefaultDependencies=false to shed the implicit After=basic.target.
  #
  # Safety: kine uses only Unix sockets + SQLite (no dbus/nss needed); the
  # apiserver, kcm, and scheduler have explicit After= for their direct deps
  # already; kubelet needs containerd which is co-opted here. The tap/routes
  # still configure via networkd (parallel, not serialised through kubenyx),
  # so pod networking converges in the background as it did before.
  {
    systemd.targets.kubenyx = {
      wantedBy = lib.mkForce [ "sysinit.target" ];
      after = lib.mkForce [
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-setup-dev.service"
      ];
      requires = lib.mkForce [ "systemd-tmpfiles-setup.service" ];
      unitConfig.DefaultDependencies = lib.mkForce false;
    };

    # Drop the implicit basic.target gate from each critical-path service.
    systemd.services.etcd-mem.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kubenyx-pki.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kube-apiserver.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kube-controller-manager.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kube-scheduler.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kubelet.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.coredns.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kubenyx-addons.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.kubenyx-dns-iface.unitConfig.DefaultDependencies = lib.mkForce false;
    systemd.services.containerd.unitConfig.DefaultDependencies = lib.mkForce false;
  }
]
