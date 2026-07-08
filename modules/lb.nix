# Client-side apiserver load balancing (air/v0.3/durable-ha.org §4,
# Decision 1): agents in a multi-server cluster run kubenyx-lb, a local
# health-checking TCP forwarder, and every agent-side kubeconfig dials
# https://127.0.0.1:6444. Failover is pure health-check policy (probe
# interval × fail threshold) — no VRRP, no floating IP, works on any
# network including clouds that block gratuitous ARP.
#
# Presence gating is the point: lb.enable defaults on exactly where the LB
# is needed (agent + >1 server + no external endpoint), servers keep
# dialing their own apiserver directly, and single-server clusters get ZERO
# units and ZERO closure weight — the kubenyx-lb package (deliberately
# separate from internal.tools) is only referenced inside the gated config.
#
# The backend list is rendered from kubenyx.nodes at eval time and re-read
# on every service restart — never frozen at bootstrap — so a future grown
# server set needs a rebuild, not an LB redesign (Decision 3's open door).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  pki = cfg.internal.pkiDir;
  servers = lib.filterAttrs (_: n: n.role == "server") cfg.nodes;
  serverCount = lib.length (lib.attrNames servers);
  # Name-sorted (attrValues follows attrNames order): every agent carries
  # the same list; spreading comes from the LB's round-robin cursor.
  backends = map (n: "${n.address}:6443") (lib.attrValues servers);
in
{
  options.kubenyx.lb = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.role == "agent" && serverCount > 1 && cfg.controlPlaneEndpoint == null;
      defaultText = lib.literalExpression ''role == "agent" && serverCount > 1 && controlPlaneEndpoint == null'';
      description = ''
        Run kubenyx-lb and point this agent's kubeconfigs at it. Defaults on
        exactly where it is needed: agents of a multi-server cluster with no
        external endpoint. Operators with a real load balancer set
        controlPlaneEndpoint instead and this stays off; single-server
        clusters never see it.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 6444;
      description = "Local port kubenyx-lb listens on (loopback only).";
    };
    probeIntervalMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500;
      description = ''
        /readyz probe interval per backend. Failover time is approximately
        probeIntervalMs × failThreshold (durable-ha.org Decision 1: policy,
        not engine, decides failover speed).
      '';
    };
    failThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Consecutive probe failures before a backend is evicted; the first success readmits it.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/kubenyx-lb.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/kubenyx-lb.nix { }";
      description = "kubenyx-lb package; deliberately separate from internal.tools so non-LB guests carry zero LB closure.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.lb.enable) {
    assertions = [
      {
        assertion = cfg.role == "agent";
        message = "kubenyx: lb.enable is agent-only — servers reach their local apiserver directly";
      }
      {
        assertion = serverCount > 1;
        message = "kubenyx: lb.enable without multiple servers is pure overhead — a single-server cluster uses controlPlaneEndpoint";
      }
      {
        assertion = lib.all (n: n.address != null) (lib.attrValues servers);
        message = "kubenyx: kubenyx-lb needs a declared address on every server node";
      }
    ];

    systemd.services.kubenyx-lb = {
      description = "Kubenyx client-side apiserver load balancer";
      wantedBy = [ "kubenyx.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        # READY fires on the first healthy backend, so units ordered after
        # this one start against a live endpoint.
        Type = "notify";
        NotifyAccess = "main";
        TimeoutStartSec = 300;
        # Drain-on-SIGTERM inside the binary caps at 10s; give it headroom
        # before systemd escalates to SIGKILL.
        TimeoutStopSec = 15;
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe' cfg.lb.package "kubenyx-lb")
            "--listen"
            "127.0.0.1:${toString cfg.lb.port}"
            "--probe-interval-ms"
            (toString cfg.lb.probeIntervalMs)
            "--fail-threshold"
            (toString cfg.lb.failThreshold)
            # Authenticated /readyz probe: the apiserver runs
            # --anonymous-auth=false, so an anonymous probe is answered 401
            # by the auth filter regardless of readiness — only an
            # authenticated request sees the real 200/500. The agent's
            # shipped kubelet client cert is the identity (any authenticated
            # subject may GET /readyz via system:public-info-viewer); the LB
            # loads it lazily, since credentials arrive over the operator
            # channel after this unit starts.
            "--probe-cert"
            "${pki}/kubelet.crt"
            "--probe-key"
            "${pki}/kubelet.key"
          ]
          ++ lib.concatMap (b: [
            "--backend"
            b
          ]) backends
        );
        Restart = "always";
        RestartSec = 1;
      };
    };

    # kubelet's first apiserver dial should hit a live endpoint: order it
    # after the LB's READY (= first healthy backend). Wants, not Requires —
    # kubelet's own retry loop is the recovery path if the LB flaps, and a
    # dead LB must never wedge the node out of the boot transaction.
    systemd.services.kubelet = {
      after = [ "kubenyx-lb.service" ];
      wants = [ "kubenyx-lb.service" ];
    };
  };
}
