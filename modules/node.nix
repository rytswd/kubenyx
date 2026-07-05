# Node runtime (air/v0.1/node-runtime.org): containerd + crun, preloaded
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
    tlsCertFile = "${pki}/nodes/${cfg.nodeName}/kubelet-server.crt";
    tlsPrivateKeyFile = "${pki}/nodes/${cfg.nodeName}/kubelet-server.key";
    rotateCertificates = false; # activation-time renewal instead (pki.org)
    serializeImagePulls = false;
    maxParallelImagePulls = 10;
    failSwapOn = false;
    memorySwap.swapBehavior = "NoSwap";
    clusterDNS = [ cfg.dns.address ];
    clusterDomain = cfg.network.clusterDomain;
    resolvConf = cfg.internal.hostResolvConf;
    protectKernelDefaults = true; # the sysctl block below satisfies it
    nodeStatusReportFrequency = "5m0s";
  };

  # recursiveUpdate: a user overriding one nested key (e.g.
  # authentication.anonymous.enabled) must not wipe its siblings.
  kubeletConfigFile = pkgs.writeText "kubelet.yaml" (
    builtins.toJSON (lib.recursiveUpdate kubeletSettings node.kubelet.settings)
  );

  # Import nix-built images into containerd's k8s.io namespace so nothing
  # ever pulls from a registry. streamLayeredImage outputs an executable
  # that writes a docker archive to stdout.
  seedScript = pkgs.writeShellApplication {
    name = "kubenyx-seed-images";
    runtimeInputs = [ cfg.packages.containerd ];
    text = ''
      images=(${lib.escapeShellArgs ([ pauseImage ] ++ node.seedImages)})
      for img in "''${images[@]}"; do
        "$img" | ctr --namespace k8s.io images import --all-platforms -
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
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "streamLayeredImage derivations imported into containerd at boot (airgapped workloads).";
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
            snapshotter = "overlayfs";
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
    systemd.services.containerd.serviceConfig.LimitNOFILE = 1048576;

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

    systemd.services.kubenyx-seed-images = {
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

    systemd.services.kubelet = {
      description = "Kubernetes kubelet";
      wantedBy = [ "kubenyx.target" ];
      after = [
        "containerd.service"
        "network-online.target"
      ] ++ lib.optional (cfg.role == "server") "kubenyx-pki.service";
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
        ExecStart = lib.concatStringsSep " " (
          map lib.escapeShellArg (
            [
              "${cfg.packages.kubernetes}/bin/kubelet"
              "--config=${kubeletConfigFile}"
              "--kubeconfig=${kc}/kubelet.kubeconfig"
              "--hostname-override=${cfg.nodeName}"
            ]
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
