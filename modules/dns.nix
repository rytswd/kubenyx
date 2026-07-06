# DNS (air/v0.1/dns-addons.org): CoreDNS on the host by default —
# kubeconfig-backed kubernetes plugin on a link-local dummy address, the
# NodeLocal-DNSCache pattern without the DaemonSet. Zero images, no DNS
# bootstrap loop, DNS off the service dataplane.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  dns = cfg.dns;
  kc = cfg.internal.kubeconfigDir;
  wrap = lib.getExe' cfg.internal.tools "kubenyx-ready";

  upstream =
    if dns.upstream == null then cfg.internal.hostResolvConf else lib.concatStringsSep " " dns.upstream;

  corefile = pkgs.writeText "Corefile" ''
    .:53 {
        bind ${dns.address}
        errors
        ready ${dns.address}:8181
        kubernetes ${cfg.network.clusterDomain} in-addr.arpa ip6.arpa {
            kubeconfig ${kc}/coredns.kubeconfig
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        ${lib.optionalString (dns.upstream != [ ]) ''
          forward . ${upstream} {
              max_concurrent 1000
          }
        ''}
        cache 30
        loop
        ${dns.extraCorefile}
    }
  '';
in
{
  options.kubenyx.dns = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Cluster DNS via host-mode CoreDNS.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "169.254.20.10";
      description = "Link-local address CoreDNS binds on every node; kubelet's clusterDNS.";
    };
    upstream = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Upstream resolvers for non-cluster names. null = the host's real
        resolv.conf (never the 127.0.0.53 stub); [] disables forwarding
        entirely (airgapped test clusters).
      '';
    };
    extraCorefile = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra directives appended to the server block.";
    };
  };

  config = lib.mkIf (cfg.enable && dns.enable) {
    systemd.services.kubenyx-dns-iface = {
      description = "Kubenyx DNS dummy interface";
      wantedBy = [ "kubenyx.target" ];
      before = [ "coredns.service" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ip link add kubenyx-dns0 type dummy 2>/dev/null || true
        ip addr replace ${dns.address}/32 dev kubenyx-dns0
        ip link set kubenyx-dns0 up
      '';
    };

    systemd.services.coredns = {
      description = "CoreDNS (kubenyx host mode)";
      wantedBy = [ "kubenyx.target" ];
      after = [
        "kubenyx-dns-iface.service"
        "kubenyx-pki.service"
      ];
      requires = [ "kubenyx-dns-iface.service" ];
      # Deliberately NOT ordered before kubelet: node registration doesn't
      # need DNS, and CoreDNS's own readiness waits on the addons RBAC —
      # ordering kubelet after it would serialize the whole boot behind
      # that chain. DNS converges long before the first pod runs.
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 60;
        ExecStart = "${wrap} --url http://${dns.address}:8181/ready -- ${lib.getExe' cfg.packages.coredns "coredns"} -conf ${corefile}";
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = "143"; # notify-wrapper exit on orderly stop
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      };
    };
  };
}
