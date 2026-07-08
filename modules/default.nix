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
          Routable IP of this node. May stay null on a single-node cluster
          (the PKI generator and components autodetect the default-route
          address at runtime); multi-node clusters must set it — static
          routes and worker kubeconfigs need concrete peers.
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

  serverCount = lib.length (
    lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cfg.nodes)
  );

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
    ./network.nix
    ./dns.nix
    ./addons.nix
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
      description = "Address agents use to reach the apiserver; required for role = agent.";
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
      defaultText = lib.literalExpression ''{ ''${nodeName} = { index = 0; role = role; }; }'';
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
        default =
          if cfg.role == "server" then "https://127.0.0.1:6443" else "https://${cfg.controlPlaneEndpoint}:6443";
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
        default = klib.nodePodCidr config.kubenyx.network.clusterCidr 24
          ((cfg.nodes.${cfg.nodeName} or { index = 0; }).index);
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
    assertions = lib.warnIf (serverCount == 2)
      "kubenyx: 2 nodes declare role = \"server\" — an even quorum tolerates zero failures; use 1 or 3+ servers" [
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
        assertion = cfg.role != "agent" || cfg.controlPlaneEndpoint != null;
        message = "kubenyx: role = \"agent\" requires controlPlaneEndpoint (the server address agents dial)";
      }
      {
        assertion =
          lib.length (lib.attrValues cfg.nodes) == lib.length (
            lib.unique (map (n: n.index) (lib.attrValues cfg.nodes))
          );
        message = "kubenyx: node indices must be unique";
      }
      {
        assertion =
          lib.length (lib.attrNames cfg.nodes) == 1
          || lib.all (n: n.address != null) (lib.attrValues cfg.nodes);
        message = "kubenyx: multi-node clusters must set an address for every node";
      }
      {
        # Node pod /24s must stay inside clusterCidr: index < 2^(24 - prefix).
        assertion =
          let
            prefix = klib.cidrPrefix config.kubenyx.network.clusterCidr;
          in
          prefix <= 24
          && lib.all (n: n.index < klib.pow2 (24 - prefix)) (lib.attrValues cfg.nodes);
        message = "kubenyx: a node index places its pod /24 outside network.clusterCidr (prefix must be <= 24 and index < 2^(24 - prefix))";
      }
    ];

    systemd.targets.kubenyx = {
      description = "Kubenyx Kubernetes cluster";
      wantedBy = [ "multi-user.target" ];
    };

    systemd.tmpfiles.rules = [
      "d /run/kubenyx 0755 root root -"
      "d /var/lib/kubenyx 0755 root root -"
    ];

    environment.systemPackages = [ cfg.packages.kubectl ];
    # Test-cluster ergonomics: root gets a working kubectl with no ceremony.
    environment.variables.KUBECONFIG = "${cfg.internal.kubeconfigDir}/admin.kubeconfig";
  };
}
