{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  klib = import ../lib { inherit lib; };

  nodeSubmodule = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Routable IP of this node, either family (single-stack: must match
          the cluster/service CIDR family). May stay null on a single-node
          cluster (the PKI generator and components autodetect the
          default-route address at runtime); multi-node clusters must set
          it — static routes and worker kubeconfigs need concrete peers.
        '';
      };
      index = lib.mkOption {
        type = lib.types.ints.between 0 255;
        description = "Stable node index; node N owns the Nth pod subnet (D6).";
      };
      role = lib.mkOption {
        type = lib.types.enum [
          "server"
          "agent"
        ];
        default = "agent";
        description = ''
          This member's cluster role, as seen by every node. Shared schema
          for the v0.2 microVM mesh and v0.3 durable/HA tracks: datastore
          constraints count servers, and v0.3 later derives the etcd quorum
          and LB backend set from the same field. Default "agent" — explicit
          multi-node declarations must mark their server(s); the implicit
          single-node default entry inherits the machine-level kubenyx.role.
        '';
      };
    };
  };

  serverCount = lib.length (lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cfg.nodes));

  # systemd unit providing the datastore for the configured backend —
  # mirrors control-plane.nix (unit basenames, no .service suffix here).
  datastoreUnit =
    {
      "kine-sqlite" = "kine";
      "etcd-mem" = "etcd-mem";
      "etcd" = "etcd";
    }
    .${cfg.datastore.backend};

  # Units that announce a boot phase, per role. The list must only name
  # units this evaluation actually defines: genAttrs on an undefined unit
  # would conjure an ExecStart-less service. Servers own the datastore,
  # apiserver and addons applier; every role runs kubelet; coredns exists
  # only in host DNS mode.
  phaseMarkerUnits =
    lib.optionals (cfg.role == "server") [
      datastoreUnit
      "kube-apiserver"
      "kubenyx-addons"
    ]
    ++ [ "kubelet" ]
    ++ lib.optional cfg.dns.enable "coredns";

  mkPkgOption =
    name: pkg:
    lib.mkOption {
      type = lib.types.package;
      default = pkg;
      defaultText = lib.literalExpression "pkgs.${name}";
      description = "Package used for ${name}; swap for a locally-built binary during development.";
    };
in
{
  imports = [
    ./pki.nix
    ./datastore.nix
    ./control-plane.nix
    ./node.nix
    ./lb.nix
    ./network.nix
    ./dns.nix
    ./addons.nix
    ./storage.nix
  ];

  options.kubenyx = {
    enable = lib.mkEnableOption "Kubenyx, stock Kubernetes as systemd services";

    profile = lib.mkOption {
      type = lib.types.enum [
        "testing"
        "balanced"
      ];
      default = "testing";
      description = ''
        Moves defaults only (architecture.org D12): `testing` optimizes for
        disposable, fast test clusters; `balanced` keeps durable defaults.
        Every affected option remains individually settable.
      '';
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "agent"
      ];
      default = "server";
      description = "server = control plane + worker; agent = worker only.";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "This node's name; must match an entry in kubenyx.nodes and the kubelet cert CN.";
    };

    controlPlaneEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Address agents use to reach the apiserver. Required for agents of a
        single-server cluster; on a multi-server cluster agents default to
        the local kubenyx-lb endpoint instead, and setting this (e.g. to a
        real external load balancer or DNS name) disables kubenyx-lb.
      '';
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf nodeSubmodule;
      default = {
        # Implicit single-node membership inherits the machine role, so the
        # zero-config single-node server keeps counting as its own server.
        ${cfg.nodeName} = {
          index = 0;
          role = cfg.role;
        };
      };
      defaultText = lib.literalExpression "{ \${nodeName} = { index = 0; role = role; }; }";
      description = "Declared cluster membership. Nix is the source of truth, not runtime allocation.";
    };

    packages = {
      kubernetes = mkPkgOption "kubernetes" pkgs.kubernetes;
      kubectl = mkPkgOption "kubectl" pkgs.kubectl;
      containerd = mkPkgOption "containerd" pkgs.containerd;
      crun = mkPkgOption "crun" pkgs.crun;
      cniPlugins = mkPkgOption "cni-plugins" pkgs.cni-plugins;
      coredns = mkPkgOption "coredns" pkgs.coredns;
      kine = mkPkgOption "kine" pkgs.kine;
      etcd = mkPkgOption "etcd" pkgs.etcd_3_6;
    };

    phaseMarkers = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Emit a `KUBENYX-PHASE <unit> up=<seconds>` line to `device` as
          each key kubenyx unit comes up (the datastore, kube-apiserver,
          kubelet, coredns, kubenyx-addons — scoped to the units this
          role actually runs). Boot-phase attribution for harnesses that
          only observe the console: systemd stops mirroring unit status
          once startup "finishes", so without the markers a profiler has
          to reconstruct phases from journal timestamps after the fact
          (air/v0.7). Semantics: notify units (the datastore,
          kube-apiserver, coredns) mark genuine readiness — ExecStartPost
          runs after READY=1 — while kubelet (Type=simple) and oneshots
          mark process start/completion. The flake's own microVM guest
          profile already emits these markers itself; enabling this there
          duplicates the lines. Default off: the added ExecStartPost is
          unit text, so the default must contribute nothing (drv gate).
        '';
      };
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/console";
        description = ''
          Where marker lines are written. The default suits serial-console
          scraping (the common harness transport); point it at
          `/dev/kmsg` to land markers in dmesg/journal instead.
        '';
      };
    };

    internal = {
      pkiDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/kubenyx/pki";
        readOnly = true;
        internal = true;
      };
      kubeconfigDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/kubenyx/kubeconfigs";
        readOnly = true;
        internal = true;
      };
      apiserverUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        # Servers dial their own apiserver; agents behind kubenyx-lb dial
        # the local forwarder (the apiserver certs carry IP:127.0.0.1, so
        # TLS verification holds through the LB); other agents dial the
        # declared endpoint. This one default is the whole "extend, don't
        # fork" wiring: kubenyx-pki renders every agent kubeconfig from it.
        # hostPort brackets a v6 endpoint (ipv6.org §4); v4 and DNS-name
        # endpoints render exactly as before.
        default =
          if cfg.role == "server" then
            "https://127.0.0.1:6443"
          else if cfg.lb.enable then
            "https://127.0.0.1:${toString cfg.lb.port}"
          else
            "https://${klib.hostPort cfg.controlPlaneEndpoint 6443}";
        description = "URL local components use to reach the apiserver.";
      };
      apiserverServiceIp = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        default = klib.cidrHost config.kubenyx.network.serviceCidr 1;
      };
      nodePodCidr = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        # `or` fallback keeps evaluation alive long enough for the friendly
        # assertion below to fire when nodeName is missing from nodes.
        # Family-aware carve (ipv6.org §1-2): the Nth /24 of a v4 cluster
        # CIDR (unchanged), the Nth /64 of a v6 cluster prefix.
        default = klib.nodePodCidr config.kubenyx.network.clusterCidr (
          if klib.isV6 config.kubenyx.network.clusterCidr then 64 else 24
        ) (cfg.nodes.${cfg.nodeName} or { index = 0; }).index;
        description = "Pod subnet owned by this node.";
      };
      tools = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        internal = true;
        default = pkgs.callPackage ../pkgs/kubenyx-tools.nix { };
        description = "Rust boot-path tools: kubenyx-pki, kubenyx-ready.";
      };
      hostResolvConf = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        default =
          if config.services.resolved.enable then "/run/systemd/resolve/resolv.conf" else "/etc/resolv.conf";
        description = "The host's real upstream resolv.conf (never the 127.0.0.53 stub).";
      };
      testingProfile = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        internal = true;
        default = cfg.profile == "testing";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # warnIf (not an assertion): a 2-server membership is legal but an even
    # quorum — it survives zero failures while doubling the blast surface.
    # v0.3's durable track wants 1 or 3+.
    assertions =
      lib.warnIf (serverCount == 2)
        "kubenyx: 2 nodes declare role = \"server\" — an even quorum tolerates zero failures; use 1 or 3+ servers"
        [
          {
            assertion = cfg.nodes ? ${cfg.nodeName};
            message = "kubenyx: nodeName ${cfg.nodeName} is not declared in kubenyx.nodes";
          }
          {
            # `or` fallback keeps evaluation alive so the missing-nodeName
            # assertion above fires first with its friendlier message.
            assertion = (cfg.nodes.${cfg.nodeName} or { role = cfg.role; }).role == cfg.role;
            message = "kubenyx: this machine's kubenyx.role (${cfg.role}) does not match its own kubenyx.nodes.${cfg.nodeName}.role entry";
          }
          {
            assertion = serverCount >= 1;
            message = "kubenyx: at least one node in kubenyx.nodes must declare role = \"server\"";
          }
          {
            assertion = cfg.role != "agent" || cfg.controlPlaneEndpoint != null || cfg.lb.enable;
            message = "kubenyx: role = \"agent\" requires controlPlaneEndpoint (the server address agents dial) unless kubenyx-lb covers it (multi-server cluster, lb.enable)";
          }
          {
            assertion =
              lib.length (lib.attrValues cfg.nodes)
              == lib.length (lib.unique (map (n: n.index) (lib.attrValues cfg.nodes)));
            message = "kubenyx: node indices must be unique";
          }
          {
            assertion =
              lib.length (lib.attrNames cfg.nodes) == 1
              || lib.all (n: n.address != null) (lib.attrValues cfg.nodes);
            message = "kubenyx: multi-node clusters must set an address for every node";
          }
          {
            # Single-stack by construction (ipv6.org §2): clusterCidr,
            # serviceCidr and every declared node address must be one
            # family. Dual-stack is out of scope; mixing is an error here,
            # not a runtime surprise.
            assertion =
              let
                v6 = klib.isV6 cfg.network.clusterCidr;
                addresses = lib.filter (a: a != null) (map (n: n.address) (lib.attrValues cfg.nodes));
              in
              klib.isV6 cfg.network.serviceCidr == v6 && lib.all (a: klib.isV6 a == v6) addresses;
            message = "kubenyx: single-stack only — network.clusterCidr, network.serviceCidr and every kubenyx.nodes.<name>.address must share one address family (all IPv4 or all IPv6); dual-stack is not supported";
          }
          {
            # Node pod subnets must stay inside clusterCidr. The carve is
            # /24 from a v4 prefix, /64 from a v6 prefix; index < 2^(carve
            # - prefix). The `min 8` is exact, not a cap: node indices are
            # typed 0-255, so any headroom of 8+ bits already admits every
            # legal index (and pow2 of large v6 headroom would overflow).
            assertion =
              let
                prefix = klib.cidrPrefix cfg.network.clusterCidr;
                carve = if klib.isV6 cfg.network.clusterCidr then 64 else 24;
              in
              prefix <= carve
              && lib.all (n: n.index < klib.pow2 (lib.min 8 (carve - prefix))) (lib.attrValues cfg.nodes);
            message = "kubenyx: a node index places its pod subnet outside network.clusterCidr (v4: prefix <= 24, index < 2^(24 - prefix); v6: prefix <= 64, index < 2^(64 - prefix))";
          }
        ];

    systemd.targets.kubenyx = {
      description = "Kubenyx Kubernetes cluster";
      wantedBy = [ "multi-user.target" ];
    };

    # Phase markers (option above). Marker text matches the microVM guest
    # profile byte-for-byte so one parser serves both sources. mkIf false
    # contributes nothing — every default-path unit stays byte-identical.
    systemd.services = lib.mkIf cfg.phaseMarkers.enable (
      lib.genAttrs phaseMarkerUnits (name: {
        serviceConfig.ExecStartPost = "${pkgs.runtimeShell} -c 'echo KUBENYX-PHASE ${name} up=$(cut -d\" \" -f1 /proc/uptime) > ${cfg.phaseMarkers.device}'";
      })
    );

    systemd.tmpfiles.rules = [
      "d /run/kubenyx 0755 root root -"
      "d /var/lib/kubenyx 0755 root root -"
    ];

    environment.systemPackages = [ cfg.packages.kubectl ];
    # Test-cluster ergonomics: root gets a working kubectl with no ceremony.
    environment.variables.KUBECONFIG = "${cfg.internal.kubeconfigDir}/admin.kubeconfig";
  };
}
