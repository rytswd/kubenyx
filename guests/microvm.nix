# Kubenyx microVM guest profile: a disposable test cluster node tuned
# for boot speed — the single-node variants and every mesh member
# (server or agent) share this file; all role/mesh deltas are gated so
# the single-node guest's unit list and closure never grow. On a KVM
# host, the firecracker/cloud-hypervisor variants boot this to
# cluster-ready in single-digit seconds; the qemu variant exists so the
# profile stays verifiable on KVM-less machines.
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
  isServer = cfg.role == "server";
  # v6 clusters need [brackets] wherever an address lands in a URL or
  # hostport (ipv6.org §4); klib.hostPort leaves v4/DNS names bare, so
  # these guests render byte-identically today (microVM host plumbing is
  # still v4 — ipv6.org §5).
  klib = import ../lib { inherit lib; };

  # ---- mesh membership (air/v0.2/multinode-microvm.org) ---------------------
  # Everything below derives from kubenyx.nodes; on a single-node cluster
  # agentNames is empty and every handoff unit vanishes — the single-node
  # guest gains zero units and zero closure weight.
  agentNames = lib.attrNames (lib.filterAttrs (_: n: n.role == "agent") cfg.nodes);
  agentCount = lib.length agentNames;
  # One credential-handoff port per agent, allocated by sorted-name position
  # starting at 10125. systemd cannot vary IPAddressAllow per Accept=yes
  # *instance*, so per-agent isolation needs one socket unit (one port) per
  # agent. Server and agents derive the identical mapping from the same
  # nodes attrset — no runtime negotiation.
  agentPort = name: 10125 + lib.lists.findFirstIndex (n: n == name) 0 agentNames;
  # The complete per-node bundle kubenyx-pki packages under nodes/<name>/
  # (mirrors the `needed` list in kubenyx-pki agent mode).
  bundleFiles = [
    "ca.crt"
    "kubelet.crt"
    "kubelet.key"
    "kubelet-server.crt"
    "kubelet-server.key"
    "kube-proxy.crt"
    "kube-proxy.key"
    "coredns.crt"
    "coredns.key"
  ];

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
      # Prebaked image store (prebake.org): the seed set (pause image) is
      # imported into a containerd content store at BUILD time and overlay-
      # mounted (~60ms) instead of `ctr import`ed during boot — the import
      # unit previously burned CPU inside the node-Ready convergence window
      # (profiler rank 4: seed-images blame 1.76s concurrent with kubelet
      # on 4 vcpus). Costs the `native` snapshotter (tmpfs-backed COW; the
      # kernel rejects overlay-upperdir-on-overlayfs), which the prebake
      # test legs validate end-to-end. Module default stays OFF.
      node.prebakeImages = true;
    };

    # ---- snapshot/restore hygiene ---------------------------------------------
    # Firecracker exposes an ACPI VMGenID device (FCVMGID), but nothing loads
    # the driver by default — without it a restored clone KEEPS the snapshot's
    # CRNG state, so every clone draws identical randomness. With the module
    # the kernel reseeds on restore ("crng reseeded due to virtual machine
    # fork"). No cost on ordinary boots.
    boot.kernelModules = [ "vmgenid" ];

    # virtio_net loads in the INITRD, deterministically. Stage 2 must not
    # depend on a udev coldplug replay to discover the NIC: virtio_net is
    # not in the stock microVM initrd, the pci MODALIAS uevent fires before
    # stage-2 udevd exists, and replaying the pci subsystem in stage 2 to
    # compensate sets off a legacy-probe storm (thousands of trapped CMOS
    # 0x70/0x71 I/O exits on an RTC-less firecracker — 3.5s boots became
    # 32s). Forcing the module in stage 1 gives eth0 to the initrd udev,
    # which records it initialized in /run/udev; the db survives
    # switch-root, so networkd manages the link without any pci replay.
    boot.initrd.kernelModules = [ "virtio_net" ];

    # ---- interactive console ---------------------------------------------------
    # Disposable host-only test VM: autolog the serial console in as root.
    # Without this there is no way in at all — root is locked by default and
    # the per-boot PKI (and thus any credential) exists only inside the
    # guest tmpfs. kubectl works immediately in the shell via the global
    # KUBECONFIG. Exit the VM with `poweroff` (or `reboot` — firecracker
    # treats a guest reboot as VMM exit).
    services.getty.autologinUser = "root";

    # ---- host-facing kubeconfig handoff ----------------------------------------
    # The per-boot PKI lives in tmpfs, so the host has no credential path of
    # its own. Serve the admin kubeconfig (server URL rewritten from
    # loopback to this node's declared address, which is in the apiserver
    # cert SANs) over trivial HTTP on the tap:
    #
    #   curl -s 10.100.0.2:10124 > kubenyx.kubeconfig
    #   kubectl --kubeconfig kubenyx.kubeconfig get nodes
    #
    # Trust model, stated plainly: IPAddressAllow restricts sources to the
    # tap/SLiRP gateway, which denies the pod network and hostNetwork pods
    # (their sources are pod CIDR / the node address) — in-cluster
    # workloads cannot escalate through this. Any local process on the
    # HOST can source from the gateway address, so "local host user" =
    # cluster-admin on this disposable, volatile test cluster. That is the
    # same exposure class as the tap itself; do not reuse this profile for
    # durable clusters.
    systemd.sockets =
      lib.optionalAttrs isServer {
        kubenyx-kubeconfig = {
          description = "Host-facing admin kubeconfig handoff";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "0.0.0.0:10124" ];
          socketConfig = {
            Accept = true;
            IPAddressAllow = [
              "10.100.0.1/32" # tap gateway (firecracker / cloud-hypervisor)
              "10.0.2.2/32" # SLiRP gateway (qemu variant)
            ];
            IPAddressDeny = "any";
          };
        };
      }
      # ---- agent credential handoff (server side) ------------------------------
      # The kubeconfig-handoff pattern generalized: one socket per agent,
      # IPAddressAllow = that agent's declared address only, serving a tar of
      # the agent's packaged credential directory (pki/nodes/<agent>/).
      # Trust model: same class as the kubeconfig handoff — positions are
      # declared in Nix and the taps are host-local. NOTE the mesh launcher
      # bridges the taps (the guest modules assume L2 adjacency), so a
      # compromised agent could spoof another agent's source address:
      # IPAddressAllow is advisory on this disposable test mesh, not a
      # boundary. An agent can already reach the apiserver with its own
      # creds; these clusters are volatile by design.
      // lib.optionalAttrs (isServer && agentCount > 0) (
        lib.listToAttrs (
          map (
            name:
            lib.nameValuePair "kubenyx-agent-pki-${name}" {
              description = "Credential bundle handoff for agent ${name}";
              wantedBy = [ "sockets.target" ];
              listenStreams = [ "0.0.0.0:${toString (agentPort name)}" ];
              socketConfig = {
                Accept = true;
                IPAddressAllow = [ "${cfg.nodes.${name}.address}/32" ];
                IPAddressDeny = "any";
              };
            }
          ) agentNames
        )
      );

    # The "kubenyx-kubeconfig@" instance service lives in the merged
    # systemd.services attrset below (a separate systemd.services.X key
    # here would conflict with the genAttrs definition).

    # ---- boot leanness -------------------------------------------------------
    documentation.enable = false;
    nix.enable = false; # guests are built, never build
    # TERM=dumb: systemd 260 probes the console's capabilities with DCS/CSI
    # escape queries (termcap name, window size, cursor position) and blocks
    # on replies that a mute VMM serial console never sends — measured ~1.0s
    # stalled in the initrd manager init AND ~1.0s again at the stage-2
    # switch-root exec (host-timestamped console, perf governor). A dumb
    # terminal is never queried. Costs status-line colors on the interactive
    # console — nothing else; these guests are benchmarked, not admired.
    #
    # MOUNT_RATE_LIMIT_BURST: PID1's mountinfo monitor is rate-limited to 5
    # events per 1s; the 7 API-fs mounts systemd itself performs at start
    # exhaust that budget, so every boot-path mount unit dispatched after
    # them (initrd: sysroot-nix-store.mount; stage 2: run-wrappers.mount)
    # freezes until the window expires — two separate ~0.95s stalls observed
    # via rd.systemd.log_level=debug ("mount-monitor-dispatch entered rate
    # limit state"). Upstream ships this env knob for exactly this ("it
    # stalls the boot sequence", core/mount.c mount_enumerate); a bare
    # KEY=VALUE cmdline word becomes PID1's environment in both stages
    # (switch-root preserves environ). 100 is arbitrary headroom: a boot
    # produces ~20 mount events, and a throttled monitor only defers
    # visibility of external mounts, so headroom is safe.
    boot.kernelParams = [
      "TERM=dumb"
      "SYSTEMD_DEFAULT_MOUNT_RATE_LIMIT_BURST=100"
    ];
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
    # and oneshots mark process start/completion. The list matches each
    # role's fixed unit shape (etcd-mem backend) — adjust it if the
    # profile ever changes backend.
    systemd.services =
      lib.genAttrs
        (
          if isServer then
            [
              "etcd-mem"
              "kube-apiserver"
              "kubelet"
              "coredns"
              "kubenyx-addons"
            ]
          else
            [
              "kubelet"
              "coredns"
            ]
        )
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
        # Stage-2 udev COLDPLUG replay, SCOPED to net+tty. The full replay
        # re-plugged blkid/by-* device units ~1.4s into stage 2 and burned
        # CPU inside the control-plane bring-up window; the block work is
        # dead weight (the store mount happens in stage 1). But a bare
        # `enable = false` is a trap found the hard way: without ANY replay
        # the NIC vanishes for stage 2 (see the virtio_net initrd note at
        # boot.initrd.kernelModules) and host->guest networking goes dark
        # while the in-guest markers still fire. With virtio_net now bound
        # in stage 1, replay net (belt-and-braces udev-db initialization —
        # networkd refuses links "pending udev initialization") and tty
        # (activates dev-ttyS0.device so serial-getty doesn't sit in a 90s
        # pending start job). Both sets are a handful of devices; the blkid
        # storm stays gone and no pci replay means no legacy-probe storm.
        systemd-udev-trigger.serviceConfig.ExecStart = [
          ""
          "${config.systemd.package}/bin/udevadm trigger --type=devices --subsystem-match=net --subsystem-match=tty --action=add"
        ];

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
        # benchmark interface for every variant. ONE curl process polling
        # over ONE persistent TLS session instead of a fork + full handshake
        # every 50ms: the fork-poll billed 0.5-0.6s of pure observation gap
        # to every fast boot (kubelet "node just became ready" at 2.93s
        # monotonic, marker at 3.49s) and 2.3-2.4s when the 4 vcpus were
        # saturated — each fork+handshake cost 0.5-1s wall inside the
        # convergence window it was supposed to observe. Mechanism: curl
        # walks a 600-entry repeat of the node URL at --rate 20/s, reusing
        # the connection across entries (5 GETs in 211ms measured in-guest,
        # spacing-dominated); refused connects before the apiserver listens
        # burn entries silently and cost no TLS; the shell reads the bodies
        # fork-free and kills curl the instant one carries Ready=True.
        # Tried and rejected: nodes?watch=1 (a real push channel) — during
        # early bring-up the first frame arrives seconds late (node Ready at
        # 3.03s, watch match at 5.61s — worse than the fork-poll it was
        # meant to fix; warm-cluster watches match instantly, boot-time ones
        # do not). ?pretty=false matters: the default for curl's user-agent
        # is pretty-printed JSON, which splits the condition pair across
        # lines (the old tr -d dance); compact bodies are one greppable line
        # with a trailing newline.
        # Wall-clock self-diagnosis when late, as before: 15s of silence or
        # an exhausted URL list ends the attempt, so the outer loop's dump /
        # give-up checks run at least every ~30s.
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
          script =
            if isServer then
              ''
                node=${lib.escapeShellArg config.kubenyx.nodeName}
                pki=/var/lib/kubenyx/pki
                dumped=""
                probe() {
                  # Admin identity: the healthz cert is deliberately unprivileged
                  # and only passes always-allowed /healthz-class paths — reading
                  # a node object needs RBAC (system:masters bypasses the RBAC
                  # bootstrap race by construction). Returns 0 the instant a
                  # body carries Ready=True; 1 on list exhaustion (~30s) or
                  # 15s of silence (server stall — recycle the session).
                  local pid line rc i
                  local -a urls=()
                  for ((i = 0; i < 600; i++)); do
                    urls+=("https://127.0.0.1:6443/api/v1/nodes/$node?pretty=false")
                  done
                  exec 9< <(curl -s --rate 20/s --max-time 15 \
                    --cacert "$pki/ca.crt" --cert "$pki/admin.crt" --key "$pki/admin.key" \
                    "''${urls[@]}" 2>/dev/null)
                  pid=$!
                  while :; do
                    IFS= read -r -t 15 -u9 line
                    rc=$?
                    if [ "$rc" -eq 0 ]; then
                      case $line in
                        *'"type":"Ready","status":"True"'*)
                          kill "$pid" 2>/dev/null || true
                          exec 9<&-
                          return 0
                          ;;
                      esac
                    elif [ "$rc" -gt 128 ]; then
                      kill "$pid" 2>/dev/null || true
                      exec 9<&-
                      return 1
                    else
                      exec 9<&-
                      return 1
                    fi
                  done
                }
                while ! probe; do
                  sleep 0.05
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
                # Tell the human on the console how to reach the cluster from
                # the host — the address is variant-specific, so print it
                # rather than making people memorize it.
                echo "KUBENYX-KUBECONFIG curl -s ${
                  klib.hostPort config.kubenyx.nodes.${config.kubenyx.nodeName}.address 10124
                } > kubenyx.kubeconfig" > /dev/console
              ''
            else
              # Agent flavor: no local apiserver and no admin identity — poll
              # this node's own Node object at the control-plane endpoint with
              # the kubelet client cert (the Node authorizer permits a node to
              # get itself). Same persistent-session mechanism as the server
              # flavor above. Marker format is identical so the mesh launcher
              # greps one string.
              ''
                node=${lib.escapeShellArg config.kubenyx.nodeName}
                pki=/var/lib/kubenyx/pki
                dumped=""
                probe() {
                  local pid line rc i
                  local -a urls=()
                  for ((i = 0; i < 600; i++)); do
                    urls+=("https://${klib.hostPort cfg.controlPlaneEndpoint 6443}/api/v1/nodes/$node?pretty=false")
                  done
                  exec 9< <(curl -s --rate 20/s --max-time 15 \
                    --cacert "$pki/ca.crt" --cert "$pki/kubelet.crt" --key "$pki/kubelet.key" \
                    "''${urls[@]}" 2>/dev/null)
                  pid=$!
                  while :; do
                    IFS= read -r -t 15 -u9 line
                    rc=$?
                    if [ "$rc" -eq 0 ]; then
                      case $line in
                        *'"type":"Ready","status":"True"'*)
                          kill "$pid" 2>/dev/null || true
                          exec 9<&-
                          return 0
                          ;;
                      esac
                    elif [ "$rc" -gt 128 ]; then
                      kill "$pid" 2>/dev/null || true
                      exec 9<&-
                      return 1
                    else
                      exec 9<&-
                      return 1
                    fi
                  done
                }
                while ! probe; do
                  sleep 0.05
                  up=$(cut -d. -f1 /proc/uptime)
                  if [ -z "$dumped" ] && [ "$up" -gt 300 ]; then
                    dumped=1
                    {
                      echo "KUBENYX-DEGRADED: not ready at uptime ''${up}s"
                      systemctl list-units --failed --no-legend || true
                      for u in kubenyx-pki-fetch kubenyx-pki kubelet; do
                        echo "--- $u:"
                        journalctl -u "$u" --no-pager -n 4 -o cat || true
                      done
                    } > /dev/console 2>&1
                  fi
                  if [ "$up" -gt 600 ]; then
                    echo "KUBENYX-FAILED: gave up at uptime ''${up}s" > /dev/console
                    exit 1
                  fi
                done
                up=$(cut -d' ' -f1 /proc/uptime)
                echo "KUBENYX-CLUSTER-READY uptime=''${up}s" > /dev/console
              '';
        };
      }
      # Serves the admin kubeconfig to the host — see the handoff
      # comment above the kubenyx-kubeconfig socket unit.
      // lib.optionalAttrs isServer {
        "kubenyx-kubeconfig@" = {
          description = "Serve the admin kubeconfig to the host";
          serviceConfig = {
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
            ExecStart = pkgs.writeShellScript "serve-kubeconfig" ''
              # Drain the ENTIRE request through the blank line: any bytes
              # left unread in the receive buffer turn our close() into an
              # RST, which can destroy the in-flight response tail (curl:
              # "Recv failure: Connection reset by peer" — observed on the
              # mesh bridge; one read of the request line was not enough).
              while IFS= read -t 5 -r line; do
                line=''${line%$'\r'}
                [ -z "$line" ] && break
              done
              printf 'HTTP/1.0 200 OK\r\nContent-Type: application/yaml\r\nConnection: close\r\n\r\n'
              exec ${pkgs.gnused}/bin/sed \
                's|https://127.0.0.1:6443|https://${
                  klib.hostPort config.kubenyx.nodes.${config.kubenyx.nodeName}.address 6443
                }|' \
                /var/lib/kubenyx/kubeconfigs/admin.kubeconfig
            '';
          };
        };
      }
      # ---- agent credential handoff (server side, instance services) ------------
      // lib.optionalAttrs (isServer && agentCount > 0) (
        lib.listToAttrs (
          map (
            name:
            lib.nameValuePair "kubenyx-agent-pki-${name}@" {
              description = "Serve agent ${name}'s credential bundle";
              serviceConfig = {
                StandardInput = "socket";
                StandardOutput = "socket";
                StandardError = "journal";
                ExecStart = pkgs.writeShellScript "serve-agent-pki-${name}" ''
                  # Drain the request through the blank line — see the
                  # serve-kubeconfig comment (unread bytes turn close()
                  # into RST and kill the response tail).
                  while IFS= read -t 5 -r line; do
                    line=''${line%$'\r'}
                    [ -z "$line" ] && break
                  done
                  dir=/var/lib/kubenyx/pki/nodes/${name}
                  # 503 until kubenyx-pki has minted and packaged the FULL
                  # bundle (the agent's fetch loop retries): partial tars
                  # would make the agent renderer run with missing leaves.
                  for f in ${lib.escapeShellArgs bundleFiles}; do
                    if [ ! -s "$dir/$f" ]; then
                      printf 'HTTP/1.0 503 Service Unavailable\r\nConnection: close\r\n\r\n'
                      exit 0
                    fi
                  done
                  printf 'HTTP/1.0 200 OK\r\nContent-Type: application/x-tar\r\nConnection: close\r\n\r\n'
                  exec ${pkgs.gnutar}/bin/tar c -C "$dir" .
                '';
              };
            }
          ) agentNames
        )
      )
      # ---- agent credential handoff (agent side) ---------------------------------
      # Bounded fetch-with-retry before kubenyx-pki.service: agents boot in
      # parallel with the server, so the bundle may not exist yet (the server
      # answers 503 until minted). On success the existing path unit /
      # renderer flow takes over; on timeout, a loud DEGRADED marker and
      # exit 0 — the path unit still recovers if material arrives later.
      // lib.optionalAttrs (!isServer) {
        kubenyx-pki-fetch = {
          description = "Fetch this node's credential bundle from the server";
          wantedBy = [ "kubenyx.target" ];
          before = [ "kubenyx-pki.service" ];
          after = [ "local-fs.target" ];
          path = with pkgs; [
            curl
            gnutar
            coreutils
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = 180;
          };
          script = ''
            pki=/var/lib/kubenyx/pki
            mkdir -p "$pki"
            # Idempotent: tmpfs makes every boot fresh, but restarts happen.
            # (if-form, not `&& exit 0`: the script runs under set -e.)
            if [ -s "$pki/kubelet.key" ]; then exit 0; fi
            url=http://${klib.hostPort cfg.controlPlaneEndpoint (agentPort cfg.nodeName)}
            deadline=$(( $(cut -d. -f1 /proc/uptime) + 90 ))
            while [ "$(cut -d. -f1 /proc/uptime)" -lt "$deadline" ]; do
              if curl -sf --connect-timeout 2 --max-time 5 "$url" -o /tmp/pki-bundle.tar; then
                tar x -f /tmp/pki-bundle.tar -C "$pki"
                rm -f /tmp/pki-bundle.tar
                echo "KUBENYX-PHASE pki-fetch up=$(cut -d' ' -f1 /proc/uptime)" > /dev/console
                exit 0
              fi
              sleep 0.25
            done
            echo "KUBENYX-DEGRADED: credential bundle fetch from $url timed out (90s)" > /dev/console
            exit 0
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
    # Role-gated: referencing a unit that a role never defines would create
    # a stub unit file on that role (an agent must not grow apiserver junk).
    systemd.services =
      lib.genAttrs
        (
          [
            "kubenyx-pki"
            "kubelet"
            "coredns"
            "kubenyx-dns-iface"
            "containerd"
          ]
          ++ lib.optionals isServer [
            "etcd-mem"
            "kube-apiserver"
            "kube-controller-manager"
            "kube-scheduler"
            "kubenyx-addons"
          ]
          ++ lib.optional (!isServer) "kubenyx-pki-fetch"
          # Prebake variants only (prebake.org): the store mount gates
          # containerd, so it must shed basic.target too. Conditional to
          # avoid a stub unit on the default path (byte-identity).
          ++ lib.optional cfg.node.prebakeImages "kubenyx-prebaked-store"
        )
        (_: {
          unitConfig.DefaultDependencies = lib.mkForce false;
        });
  }
]
