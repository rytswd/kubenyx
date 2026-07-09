# Networking (air/v0.1/networking.org): zero-daemon CNI (bridge +
# host-local, deterministic per-node subnets), nftables kube-proxy, static
# routes for multi-node, and a firewall that stays ON.
# air/v0.4/byod.org §1: cni = "external" hands the pod dataplane to an
# operator-deployed CNI — no conflist (ABSENT, not empty: containerd loads
# the lexically first conflist, so even a stub would shadow the external
# CNI's), no static pod routes, no egress NAT, no cni0 firewall rules.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  net = cfg.network;
  kc = cfg.internal.kubeconfigDir;
  klib = import ../lib { inherit lib; };

  bridgeCni = net.cni == "bridge";

  conflist = builtins.toJSON {
    cniVersion = "1.0.0";
    name = "kubenyx";
    plugins = [
      {
        type = "bridge";
        bridge = "cni0";
        isGateway = true;
        isDefaultGateway = true;
        hairpinMode = true;
        # Masquerade is a single kubenyx nft rule instead (below): the
        # plugin's ipMasq would also NAT cross-node pod traffic.
        ipMasq = false;
        # No explicit ipam routes: isDefaultGateway already installs the
        # default route; listing 0.0.0.0/0 here too makes the bridge plugin
        # fail with EEXIST on sandbox creation.
        ipam = {
          type = "host-local";
          ranges = [ [ { subnet = cfg.internal.nodePodCidr; } ] ];
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  };

  kubeProxyConfig = pkgs.writeText "kube-proxy.yaml" (
    builtins.toJSON (
      {
        apiVersion = "kubeproxy.config.k8s.io/v1alpha1";
        kind = "KubeProxyConfiguration";
        mode = "nftables";
        clusterCIDR = net.clusterCidr;
        clientConnection.kubeconfig = "${kc}/kube-proxy.kubeconfig";
        metricsBindAddress = "127.0.0.1:10249";
      }
      // net.kubeProxy.extraConfig
    )
  );

  # NAT only traffic that actually leaves the cluster: pod-to-pod and
  # pod-to-service must keep their source addresses.
  natRules = pkgs.writeText "kubenyx-nat.nft" ''
    table ip kubenyx-nat
    flush table ip kubenyx-nat
    table ip kubenyx-nat {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${net.clusterCidr} ip daddr ${net.clusterCidr} return
        ip saddr ${net.clusterCidr} ip daddr ${net.serviceCidr} return
        ip saddr ${net.clusterCidr} masquerade
      }
    }
  '';

  peers = lib.filterAttrs (n: _: n != cfg.nodeName) cfg.nodes;
  serverCount = lib.length (lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cfg.nodes));
in
{
  options.kubenyx.network = {
    cni = lib.mkOption {
      type = lib.types.enum [
        "bridge"
        "external"
      ];
      default = "bridge";
      description = ''
        Who owns the pod dataplane. "bridge" is kubenyx's zero-daemon CNI
        (bridge + host-local, static cross-node routes, egress NAT).
        "external" makes kubenyx write nothing: no conflist in
        /etc/cni/net.d, no kubenyx-routes, no NAT unit — an
        operator-deployed CNI (typically a DaemonSet) is picked up the
        moment it writes its conflist. kubeProxy.enable stays orthogonal:
        disable it only when the external CNI brings a service dataplane.
      '';
    };
    clusterCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.244.0.0/16";
      description = ''
        Pod network, either family (single-stack: must match serviceCidr
        and the node addresses). Node N owns the Nth /24 of a v4 CIDR, the
        Nth /64 of a v6 prefix.
      '';
    };
    serviceCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.0/16";
      description = ''
        Service ClusterIP range, either family (single-stack: must match
        clusterCidr and the node addresses); host 1 is the apiserver,
        host 10 the conventional DNS IP.
      '';
    };
    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
    };
    kubeProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "nftables kube-proxy; disable only when another service dataplane exists.";
      };
      extraConfig = lib.mkOption {
        type = (pkgs.formats.json { }).type;
        default = { };
      };
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open 6443 (server) and 10250; Kubenyx must work with the firewall enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    # byod.org §1: ABSENT in external mode, never an empty stub —
    # containerd loads the lexically first conflist it finds.
    environment.etc."cni/net.d/10-kubenyx.conflist" = lib.mkIf bridgeCni { text = conflist; };

    networking.firewall = lib.mkIf net.openFirewall {
      allowedTCPPorts = [
        10250
      ]
      ++ lib.optional (cfg.role == "server") 6443
      # etcd quorum ports (durable-ha.org §2): with >1 server, peers dial
      # this member's client (2379) and peer/raft (2380) listeners on the
      # declared address. Both stay TLS + client-cert-auth (datastore.nix),
      # so the firewall opening is not the access control. Gated on the
      # multi-server etcd branch: single-server firewalls stay identical.
      ++ lib.optionals (cfg.role == "server" && cfg.datastore.backend == "etcd" && serverCount > 1) [
        2379
        2380
      ];
      # Deliberately NOT trustedInterfaces = [ "cni0" ]: that would let any
      # pod reach every host-bound port. Pods get exactly what the platform
      # needs — the apiserver via its service VIP (DNAT lands on host:6443)
      # and host CoreDNS on the dummy address.
      # byod.org §1: with an external CNI there is no cni0 — pod traffic
      # arrives on whatever interface that CNI creates, so the same
      # accepts key on the pod source addresses alone. The external CNI
      # manages any further openings itself.
      extraCommands =
        if bridgeCni then
          ''
            iptables -A nixos-fw -i cni0 -s ${net.clusterCidr} -p tcp --dport 6443 -j nixos-fw-accept
            iptables -A nixos-fw -i cni0 -s ${net.clusterCidr} -d ${cfg.dns.address}/32 -p udp --dport 53 -j nixos-fw-accept
            iptables -A nixos-fw -i cni0 -s ${net.clusterCidr} -d ${cfg.dns.address}/32 -p tcp --dport 53 -j nixos-fw-accept
          ''
        else
          ''
            iptables -A nixos-fw -s ${net.clusterCidr} -p tcp --dport 6443 -j nixos-fw-accept
            iptables -A nixos-fw -s ${net.clusterCidr} -d ${cfg.dns.address}/32 -p udp --dport 53 -j nixos-fw-accept
            iptables -A nixos-fw -s ${net.clusterCidr} -d ${cfg.dns.address}/32 -p tcp --dport 53 -j nixos-fw-accept
          '';
    };

    systemd.services.kubenyx-nat = lib.mkIf bridgeCni {
      description = "Kubenyx pod egress NAT";
      wantedBy = [ "kubenyx.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${natRules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table ip kubenyx-nat";
      };
    };

    # host-gw datapath with zero daemons: one static route per peer.
    # External CNIs own pod reachability — no routes in that mode.
    systemd.services.kubenyx-routes = lib.mkIf (bridgeCni && peers != { }) {
      description = "Kubenyx cross-node pod routes";
      wantedBy = [ "kubenyx.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 120;
      };
      # Bounded retry instead of trusting the ordering: guests that disable
      # systemd-networkd-wait-online (the microVM mesh) can reach
      # network-online.target before the node address is on the interface,
      # and `ip route ... via <peer>` needs the on-link source address to
      # exist. On hosts where wait-online is real, the first attempt wins.
      script = ''
        for attempt in $(seq 1 150); do
          if ${
            lib.concatStringsSep " \\\n             && " (
              lib.mapAttrsToList (
                name: peer: "ip route replace ${klib.nodePodCidr net.clusterCidr 24 peer.index} via ${peer.address}"
              ) peers
            )
          }; then
            exit 0
          fi
          sleep 0.2
        done
        echo "kubenyx-routes: could not install peer pod routes" >&2
        exit 1
      '';
    };

    systemd.services.kube-proxy = lib.mkIf net.kubeProxy.enable {
      description = "Kubernetes service proxy (nftables)";
      wantedBy = [ "kubenyx.target" ];
      after = [ "kubenyx-pki.service" ] ++ lib.optional (cfg.role == "server") "kube-apiserver.service";
      path = with pkgs; [
        nftables
        conntrack-tools
      ];
      serviceConfig = {
        ExecStart = "${cfg.packages.kubernetes}/bin/kube-proxy --config=${kubeProxyConfig} --hostname-override=${cfg.nodeName}";
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
