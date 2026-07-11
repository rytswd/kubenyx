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
  klib = import ../lib { inherit lib; };
  dnsV6 = klib.isV6 dns.address;
  # CoreDNS's ready endpoint is a Go host:port — v6 needs brackets
  # (ipv6.org §4); v4 renders the exact same string as before.
  readyEndpoint = klib.hostPort dns.address 8181;

  upstream =
    if dns.upstream == null then cfg.internal.hostResolvConf else lib.concatStringsSep " " dns.upstream;

  # extraServerBlocks concatenates AFTER the primary block (empty default
  # adds zero bytes — Corefile identical). Zone-scoped blocks cannot ride
  # inside `.:53` (several plugins are once-per-block, e.g. hosts), and
  # splicing them through extraCorefile needs a close-brace hack that
  # also leaves CoreDNS logging benign plugin/loop errors every boot.
  corefile = pkgs.writeText "Corefile" (
    ''
      .:53 {
          bind ${dns.address}
          errors
          ready ${readyEndpoint}
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
    ''
    + dns.extraServerBlocks
  );
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
      description = ''
        Link-local address CoreDNS binds on every node; kubelet's
        clusterDNS. Either family — v6 clusters set a v6 address here
        (e.g. a ULA), since v6-only pods cannot reach the v4 default.
      '';
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
    extraServerBlocks = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = lib.literalExpression ''
        '''
          test-vms {
              bind 169.254.20.10
              hosts {
                  192.168.1.2 server
              }
          }
        '''
      '';
      description = ''
        Complete extra CoreDNS server blocks appended after the primary
        `.:53` block — for zone-scoped configuration that cannot live
        inside it (e.g. a second `hosts` zone; several plugins are
        once-per-block). CoreDNS binds per block: repeat
        `bind ''${dns.address}` in each block unless wildcard binding
        that zone is really intended.
      '';
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
      # v6 (ipv6.org §3): host prefix is /128 and DAD is skipped — a dummy
      # interface has no neighbors to probe, and CoreDNS starting against a
      # tentative address fails its bind. The v4 command text is unchanged.
      script = ''
        ip link add kubenyx-dns0 type dummy 2>/dev/null || true
        ip addr replace ${dns.address}/${if dnsV6 then "128" else "32"}${lib.optionalString dnsV6 " nodad"} dev kubenyx-dns0
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
      # Agents have no coredns.kubeconfig until the operator ships the
      # credential dir — without the condition CoreDNS crash-loops from
      # boot to ship (Restart=always recovered, loudly: dozens of failed
      # starts in every agent boot log). The condition skips those starts
      # cleanly; the path unit below fires the real one the moment the
      # renderer writes the kubeconfig. Servers order after kubenyx-pki
      # already, so their condition is satisfied on first evaluation.
      unitConfig.ConditionPathExists = "${kc}/coredns.kubeconfig";
      # Deliberately NOT ordered before kubelet: node registration doesn't
      # need DNS, and CoreDNS's own readiness waits on the addons RBAC —
      # ordering kubelet after it would serialize the whole boot behind
      # that chain. DNS converges long before the first pod runs.
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 60;
        ExecStart = "${wrap} --url http://${readyEndpoint}/ready -- ${lib.getExe' cfg.packages.coredns "coredns"} -conf ${corefile}";
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = "143"; # notify-wrapper exit on orderly stop
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      };
    };

    # Starter for every role: a skipped (condition-failed) unit is never
    # retried by systemd on its own, so watch for the kubeconfig the PKI
    # renderer writes and start CoreDNS then. Agents need it for the
    # credential ship; servers need it for the operator-CA bootstrap flow
    # (pre-bundle boots skip CoreDNS, and the recovery restart lists must
    # not have to remember it). Level-triggered by design: CoreDNS runs
    # whenever its credential exists. Mirrors the kubenyx-pki path unit
    # one directory up the chain.
    systemd.paths.coredns = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = "${kc}/coredns.kubeconfig";
        Unit = "coredns.service";
      };
    };
  };
}
