# Node runtime (air/v0.1/core/node-runtime.org): containerd + crun, preloaded
# pause image, tuned kubelet, and every NixOS-specific kubelet gotcha
# (PATH, resolv.conf, sysctls, kernel modules) handled here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  node = cfg.node;
  pki = cfg.internal.pkiDir;
  kc = cfg.internal.kubeconfigDir;

  # Servers keep per-node material under nodes/<name>/; an agent's shipped
  # credential dir is flat at the PKI root.
  kubeletPkiDir = if cfg.role == "server" then "${pki}/nodes/${cfg.nodeName}" else pki;

  wrap = lib.getExe' cfg.internal.tools "kubenyx-ready";
  serverCount = lib.length (lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cfg.nodes));
  # Mesh servers only: single-server kubelet unit text is a drv gate
  # (cp1w2 byte-identity), and agents dial kubenyx-lb, which fails over —
  # a local-apiserver gate would be wrong there anyway.
  meshServer = cfg.role == "server" && serverCount > 1;

  thisNode =
    cfg.nodes.${cfg.nodeName} or {
      address = null;
      index = 0;
    };

  pauseImage = pkgs.callPackage ../pkgs/pause-image.nix { kubernetes = cfg.packages.kubernetes; };
  pauseRef = "kubenyx.local/pause:1";

  kubeletSettings = {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    cgroupDriver = "systemd";
    containerRuntimeEndpoint = "unix:///run/containerd/containerd.sock";
    staticPodPath = ""; # static-pod watcher fully disabled (D2)
    readOnlyPort = 0;
    healthzBindAddress = "127.0.0.1";
    healthzPort = 10248;
    authentication = {
      anonymous.enabled = false;
      webhook.enabled = true;
      x509.clientCAFile = "${pki}/ca.crt";
    };
    authorization.mode = "Webhook";
    tlsCertFile = "${kubeletPkiDir}/kubelet-server.crt";
    tlsPrivateKeyFile = "${kubeletPkiDir}/kubelet-server.key";
    rotateCertificates = false; # activation-time renewal instead (pki.org)
    serializeImagePulls = false;
    maxParallelImagePulls = 10;
    failSwapOn = false;
    memorySwap.swapBehavior = "NoSwap";
    clusterDNS = [ cfg.dns.address ];
    clusterDomain = cfg.network.clusterDomain;
    resolvConf = cfg.internal.hostResolvConf;
    protectKernelDefaults = true; # the sysctl block below satisfies it
    nodeStatusReportFrequency = "10s";
  };

  # recursiveUpdate: a user overriding one nested key (e.g.
  # authentication.anonymous.enabled) must not wipe its siblings.
  kubeletConfigFile = pkgs.writeText "kubelet.yaml" (
    builtins.toJSON (lib.recursiveUpdate kubeletSettings node.kubelet.settings)
  );

  # Build-time pre-baked containerd store (prebake.org): the whole seed
  # set — pause included — imported into a content store + bolt metadata
  # inside the nix sandbox. The guest overlays it under
  # /var/lib/containerd (tmpfs upper) and the seed unit disappears.
  prebakedStore = pkgs.callPackage ../pkgs/prebake-store.nix {
    containerd = cfg.packages.containerd;
    images = [ pauseImage ] ++ node.seedImages;
  };
  # tmpfs-backed upper/work for the store overlay; /run is always tmpfs.
  prebakeUpperDir = "/run/kubenyx/containerd-upper";
  prebakeWorkDir = "/run/kubenyx/containerd-work";

  # Import nix-built images into containerd's k8s.io namespace so nothing
  # ever pulls from a registry. streamLayeredImage outputs an executable
  # that writes a docker archive to stdout; plain OCI/docker archive files
  # (byod.org §3) are non-executable and ctr reads them directly.
  seedScript = pkgs.writeShellApplication {
    name = "kubenyx-seed-images";
    runtimeInputs = [ cfg.packages.containerd ];
    text = ''
      images=(${lib.escapeShellArgs ([ pauseImage ] ++ node.seedImages)})
      for img in "''${images[@]}"; do
        if [ -x "$img" ]; then
          "$img" | ctr --namespace k8s.io images import --all-platforms -
        else
          ctr --namespace k8s.io images import --all-platforms "$img"
        fi
      done
    '';
  };
in
{
  options.kubenyx.node = {
    kubelet.settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      description = "Merged over the rendered KubeletConfiguration (wins on conflict).";
    };
    kubelet.extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    seedImages = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Images imported into containerd at boot (airgapped workloads).
        Executable entries (streamLayeredImage derivations) are run with
        stdout piped to `ctr images import`; non-executable entries are
        plain OCI/docker archive files that ctr imports directly.
      '';
    };
    prebakeImages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Import the seed set (pause image + seedImages) into a containerd
        content store at BUILD time and ship it in the closure; the guest
        mounts it as the overlayfs lower layer under /var/lib/containerd
        with a tmpfs upper, and the boot-time seed unit disappears
        entirely. Layers unpack lazily into the tmpfs upper at first use,
        via the `native` snapshotter (the store overlay itself rules out
        overlayfs: an overlay upperdir cannot live on an overlayfs, and
        the sandbox bake cannot produce snapshots anyway — see
        pkgs/prebake-store.nix). Volatile/test-cluster oriented: every
        container rootfs copy is tmpfs-backed RAM.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [
      "br_netfilter"
      "overlay"
    ];

    # protectKernelDefaults requirements + practical scale headroom
    # (research/runtime-node.md §3).
    boot.kernel.sysctl = {
      "vm.overcommit_memory" = 1;
      "vm.panic_on_oom" = 0;
      "kernel.panic" = 10;
      "kernel.panic_on_oops" = 1;
      "kernel.keys.root_maxkeys" = 1000000;
      "kernel.keys.root_maxbytes" = 25000000;
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "fs.inotify.max_user_watches" = 1048576;
      "fs.inotify.max_user_instances" = 8192;
    };

    virtualisation.containerd = {
      enable = true;
      settings = {
        version = 2;
        plugins."io.containerd.grpc.v1.cri" = {
          sandbox_image = pauseRef;
          containerd = {
            default_runtime_name = "crun";
            # Prebaked stores force `native` (prebake.org): container
            # snapshots land under /var/lib/containerd, which is then
            # itself an overlay mount — and the kernel rejects an overlay
            # upperdir that lives on an overlayfs, so the overlayfs
            # snapshotter cannot operate there (probed in tests/prebake.nix).
            # native's COW copies are tmpfs-backed in that setup. The
            # default path stays overlayfs, byte-identical.
            snapshotter = if node.prebakeImages then "native" else "overlayfs";
            runtimes.crun = {
              runtime_type = "io.containerd.runc.v2";
              options = {
                BinaryName = lib.getExe' cfg.packages.crun "crun";
                SystemdCgroup = true;
              };
            };
          };
          cni = {
            bin_dir = "/opt/cni/bin";
            conf_dir = "/etc/cni/net.d";
          };
        };
        # No NRI plugins shipped; keep the surface closed.
        plugins."io.containerd.nri.v1.nri".disable = true;
      };
    };
    systemd.services.containerd = {
      serviceConfig.LimitNOFILE = 1048576;
      # The baked store must be mounted before containerd opens its root
      # (mkIf false contributes nothing — default path byte-identical).
      after = lib.mkIf node.prebakeImages [ "kubenyx-prebaked-store.service" ];
      requires = lib.mkIf node.prebakeImages [ "kubenyx-prebaked-store.service" ];
    };

    # /opt/cni/bin stays a real directory so DaemonSet-shipped CNIs keep
    # working later; Nix plugins are symlinked in at boot.
    systemd.tmpfiles.rules = [ "d /opt/cni/bin 0755 root root -" ];
    systemd.services.kubenyx-cni-install = {
      description = "Link CNI plugins into /opt/cni/bin";
      wantedBy = [ "kubenyx.target" ];
      before = [ "containerd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /opt/cni/bin
        ln -sf ${cfg.packages.cniPlugins}/bin/* /opt/cni/bin/
      '';
    };

    # With a prebaked store every seed entry is already in the mounted
    # content store — the unit disappears from the boot path entirely
    # (mkIf false inside attrsOf removes the attribute, not just empties it).
    systemd.services.kubenyx-seed-images = lib.mkIf (!node.prebakeImages) {
      description = "Import nix-built container images into containerd";
      wantedBy = [ "kubenyx.target" ];
      after = [ "containerd.service" ];
      requires = [ "containerd.service" ];
      # Runs in parallel with kubelet: node registration doesn't need the
      # pause image, only the first sandbox does — and kubelet retries
      # sandbox creation anyway. Serializing here cost boot time.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe seedScript;
      };
    };

    # Prebaked-store mount (prebake.org): the immutable baked tree is the
    # overlay lower, a tmpfs upper takes containerd's writes (bolt copies
    # up on first open; lazy unpacks and container snapshots land here).
    # A script unit rather than a fileSystems entry: the upper/work dirs
    # must exist first and /run tmpfiles ordering under the early-boot
    # microVM profile is not worth fighting.
    systemd.services.kubenyx-prebaked-store = lib.mkIf node.prebakeImages {
      description = "Mount the pre-baked containerd store (overlay, tmpfs upper)";
      wantedBy = [ "kubenyx.target" ];
      before = [ "containerd.service" ];
      path = with pkgs; [
        util-linux
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /var/lib/containerd ${prebakeUpperDir} ${prebakeWorkDir}
        if ! mountpoint -q /var/lib/containerd; then
          mount -t overlay kubenyx-prebake \
            -o lowerdir=${prebakedStore},upperdir=${prebakeUpperDir},workdir=${prebakeWorkDir} \
            /var/lib/containerd
        fi
      '';
    };

    systemd.services.kubelet = {
      description = "Kubernetes kubelet";
      wantedBy = [ "kubenyx.target" ];
      after = [
        "containerd.service"
        "network-online.target"
        "kubenyx-pki.service"
      ];
      wants = [ "network-online.target" ];
      # kubelet shells out constantly; a thin PATH is the #1 hand-rolled
      # kubelet failure on NixOS.
      path = with pkgs; [
        util-linux
        iproute2
        iptables
        nftables
        socat
        conntrack-tools
        kmod
        e2fsprogs
        coreutils
      ];
      serviceConfig = {
        # Mesh servers: hold kubelet until the LOCAL apiserver admits
        # kubelet's own node-informer request. Unordered, kubelet starts
        # ~4s before the quorum apiserver serves, and client-go's backoff
        # quantization then bills pure dead air twice: the registration
        # ladder (attempts at 2.4/2.6/3.0/3.8/5.4/8.6s — apiserver up at
        # 6.6s means up to ~2s idle before the next rung) and the node
        # informer's re-list backoff (the node invisible to kubelet's own
        # lister for ~2.5s AFTER successful registration). Measured 4.5s
        # p95 on the cp3 bench (quorum-mesh.org phase 3). The gate polls
        # THE EXACT REQUEST the informer issues — same resource, same
        # fieldSelector, same client identity — every 10ms, so kubelet's
        # first attempt lands after the authorizer can admit it and both
        # backoff ladders never start. Same pattern and rationale as the
        # kcm extension-apiserver-authentication gate (control-plane.nix).
        # Single-server unit text unchanged (mkIf drops the attribute).
        ExecStartPre = lib.mkIf meshServer (
          lib.concatStringsSep " " [
            wrap
            "--wait"
            "--url"
            # Raw '=' inside the query value: Go splits each pair at the
            # FIRST '=' so no encoding is needed — and %XX MUST be avoided
            # in unit text, systemd eats '%' as a specifier ("Invalid slot",
            # which silently drops ExecStartPre and deadlocks the boot).
            "https://127.0.0.1:6443/api/v1/nodes?fieldSelector=metadata.name=${cfg.nodeName}"
            "--cacert"
            "${pki}/ca.crt"
            "--cert"
            "${kubeletPkiDir}/kubelet.crt"
            "--key"
            "${kubeletPkiDir}/kubelet.key"
          ]
        );
        ExecStart = lib.concatStringsSep " " (
          map lib.escapeShellArg (
            [
              "${cfg.packages.kubernetes}/bin/kubelet"
              "--config=${kubeletConfigFile}"
              "--kubeconfig=${kc}/kubelet.kubeconfig"
              "--hostname-override=${cfg.nodeName}"
            ]
            # Declared address kills node-IP autodetection, which needs a
            # default route (absent in static-net microVMs).
            ++ lib.optional (thisNode.address != null) "--node-ip=${thisNode.address}"
            ++ node.kubelet.extraFlags
          )
        );
        Restart = "always";
        RestartSec = 2;
        # Native systemd watchdog support since kubelet 1.32.
        WatchdogSec = "30s";
        CPUAccounting = true;
        MemoryAccounting = true;
      };
    };
  };
}
