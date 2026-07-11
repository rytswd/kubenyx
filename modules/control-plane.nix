# Control plane (air/v0.1/control-plane.org): stock apiserver / kcm /
# scheduler as systemd services with k0s-derived lean flags and real
# readiness via the notify wrapper (no sd_notify upstream, k8s#8311).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  cp = cfg.controlPlane;
  pki = cfg.internal.pkiDir;
  kc = cfg.internal.kubeconfigDir;
  k8s = cfg.packages.kubernetes;
  wrap = lib.getExe' cfg.internal.tools "kubenyx-ready";
  klib = import ../lib { inherit lib; };

  usingEtcd = cfg.datastore.backend == "etcd";
  # systemd unit providing the datastore for this backend; a Requires= on a
  # nonexistent unit (e.g. etcd.service when backend = etcd-mem) fails the
  # apiserver start job outright.
  datastoreUnit =
    {
      "kine-sqlite" = "kine.service";
      "etcd-mem" = "etcd-mem.service";
      "etcd" = "etcd.service";
    }
    .${cfg.datastore.backend};
  thisNode =
    cfg.nodes.${cfg.nodeName} or {
      address = null;
      index = 0;
    };
  serverCount = lib.length (lib.attrNames (lib.filterAttrs (_: n: n.role == "server") cfg.nodes));

  apiserverFlags =
    # Declared address ships as --advertise-address: without it the
    # apiserver autodetects via the default route and exits on hosts that
    # have none (microVMs with static addressing).
    lib.optional (thisNode.address != null) "--advertise-address=${thisNode.address}"
    ++ [
      "--secure-port=6443"
      "--allow-privileged=true"
      "--authorization-mode=Node,RBAC"
      "--enable-admission-plugins=NodeRestriction"
      "--anonymous-auth=false"
      "--profiling=false"
      "--tls-min-version=VersionTLS12"
      "--client-ca-file=${pki}/ca.crt"
      "--tls-cert-file=${pki}/apiserver.crt"
      "--tls-private-key-file=${pki}/apiserver.key"
      "--kubelet-client-certificate=${pki}/apiserver-kubelet-client.crt"
      "--kubelet-client-key=${pki}/apiserver-kubelet-client.key"
      "--kubelet-certificate-authority=${pki}/ca.crt"
      "--service-cluster-ip-range=${cfg.network.serviceCidr}"
      "--service-account-issuer=https://kubernetes.default.svc"
      "--service-account-key-file=${pki}/sa.pub"
      "--service-account-signing-key-file=${pki}/sa.key"
      "--etcd-servers=${cfg.internal.etcdServers}"
      "--event-ttl=${cp.apiserver.eventTTL}"
      # Never on a single apiserver: even 0.001 measurably cuts throughput.
      "--goaway-chance=0"
      # Aggregation layer wiring (distinct front-proxy CA — see pki.nix).
      "--requestheader-client-ca-file=${pki}/front-proxy-ca.crt"
      "--requestheader-allowed-names=front-proxy-client"
      "--requestheader-username-headers=X-Remote-User"
      "--requestheader-group-headers=X-Remote-Group"
      "--requestheader-extra-headers-prefix=X-Remote-Extra-"
      "--proxy-client-cert-file=${pki}/front-proxy-client.crt"
      "--proxy-client-key-file=${pki}/front-proxy-client.key"
    ]
    # TLS client flags only for real etcd: kine and etcd-mem listen on a
    # plaintext unix socket (0700 dir is the access control) — passing
    # --etcd-cafile there makes the client attempt TLS against a
    # non-TLS listener.
    ++ lib.optionals usingEtcd [
      "--etcd-cafile=${pki}/ca.crt"
      "--etcd-certfile=${pki}/apiserver-etcd-client.crt"
      "--etcd-keyfile=${pki}/apiserver-etcd-client.key"
    ]
    ++ lib.optional (!cp.apiserver.priorityAndFairness) "--enable-priority-and-fairness=false"
    ++ cp.apiserver.extraFlags;

  kcmFlags = [
    "--kubeconfig=${kc}/controller-manager.kubeconfig"
    "--authentication-kubeconfig=${kc}/controller-manager.kubeconfig"
    "--authorization-kubeconfig=${kc}/controller-manager.kubeconfig"
    "--client-ca-file=${pki}/ca.crt"
    "--root-ca-file=${pki}/ca.crt"
    "--service-account-private-key-file=${pki}/sa.key"
    "--cluster-signing-cert-file=${pki}/ca.crt"
    "--cluster-signing-key-file=${pki}/ca.key"
    # Per-controller SA credentials mint a token for every controller
    # serially at startup — measured +4.9s on control-plane bring-up.
    # Testing profile trades that RBAC audit granularity for speed.
    "--use-service-account-credentials=${lib.boolToString cp.kcm.useServiceAccountCredentials}"
    # Nix owns pod subnets (deterministic per-node /24s in the CNI
    # conflist and static routes). KCM's allocator is not order-stable,
    # so letting it run writes a *wrong* node.spec.podCIDR — worse than
    # none. Divergence from the original doc recorded in networking.org.
    # The opt-in exists for external CNIs running Kubernetes-mode IPAM
    # (they *consume* node.spec.podCIDR) — asserted to external mode
    # below; false renders the exact flag string as before.
    "--allocate-node-cidrs=${lib.boolToString cp.kcm.allocateNodeCidrs}"
  ]
  # Family-correct carve, same geometry as klib.nodePodCidr (the Nth /24
  # of a v4 cluster CIDR, the Nth /64 of a v6 prefix) — allocated and
  # Nix-declared subnets share shape even though the allocator picks its
  # own order. kcm.extraFlags still wins last on any conflict.
  ++ lib.optionals cp.kcm.allocateNodeCidrs [
    "--cluster-cidr=${cfg.network.clusterCidr}"
    "--node-cidr-mask-size=${toString (if klib.isV6 cfg.network.clusterCidr then 64 else 24)}"
  ]
  ++ [
    "--service-cluster-ip-range=${cfg.network.serviceCidr}"
    "--controllers=*${lib.concatMapStrings (c: ",-${c}") cp.kcm.disabledControllers}"
    "--bind-address=127.0.0.1"
    "--profiling=false"
    "--terminated-pod-gc-threshold=1000"
    "--leader-elect=${lib.boolToString cp.leaderElect}"
  ]
  ++ cp.kcm.extraFlags;

  schedulerConfig = pkgs.writeText "kube-scheduler.yaml" (
    builtins.toJSON {
      apiVersion = "kubescheduler.config.k8s.io/v1";
      kind = "KubeSchedulerConfiguration";
      clientConnection.kubeconfig = "${kc}/scheduler.kubeconfig";
      leaderElection.leaderElect = cp.leaderElect;
      enableProfiling = false;
    }
  );

  hardening = {
    Restart = "always";
    RestartSec = 2;
    # The notify wrapper exits 143 when systemd TERMs the cgroup on an
    # orderly stop; without this the unit lands in "failed".
    SuccessExitStatus = "143";
    NoNewPrivileges = true;
    ProtectHome = true;
    PrivateTmp = true;
  };
in
{
  options.kubenyx.controlPlane = {
    leaderElect = lib.mkOption {
      type = lib.types.bool;
      # Option-level default (the mkDefault of option declarations): any
      # user assignment overrides it either way.
      default = serverCount > 1;
      defaultText = lib.literalExpression "serverCount > 1";
      description = ''
        Leader election for kcm/scheduler. Off by default on one server: a
        single control-plane node gains nothing and waiting out lease
        acquisition is one of the biggest single-node startup costs. On by
        default with multiple servers (durable-ha.org §5): concurrent
        kcm/scheduler instances without a lease would duplicate work and
        fight over object status.
      '';
    };
    apiserver = {
      eventTTL = lib.mkOption {
        type = lib.types.str;
        default = if cfg.internal.testingProfile then "10m0s" else "1h0m0s";
        defaultText = "10m (testing profile) / 1h (balanced)";
        description = "Event retention; short TTLs shrink datastore churn on busy test clusters.";
      };
      priorityAndFairness = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "APF overload protection; disable only for benchmarking.";
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
    kcm = {
      allocateNodeCidrs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let kcm allocate node.spec.podCIDR (plus a --cluster-cidr and a
          family-correct --node-cidr-mask-size: /24 of a v4 cluster CIDR,
          /64 of a v6 prefix — the same carve kubenyx's own subnetting
          uses). Only valid with network.cni = "external", for CNIs whose
          Kubernetes-mode IPAM consumes podCIDR; with the bridge CNI the
          allocator's order-instability would contradict the Nix-declared
          subnets the dataplane is built on.
        '';
      };
      useServiceAccountCredentials = lib.mkOption {
        type = lib.types.bool;
        default = !cfg.internal.testingProfile;
        defaultText = "false (testing profile) / true (balanced)";
        description = ''
          Per-controller ServiceAccount identities. Costs ~5s of serial
          token minting at every kcm start; the testing profile prefers a
          single shared identity.
        '';
      };
      disabledControllers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "cloud-node-lifecycle-controller" ];
        description = "Controllers to disable (appended as -name to --controllers).";
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
    scheduler.extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config = lib.mkIf (cfg.enable && cfg.role == "server") {
    assertions = [
      {
        assertion = !cp.kcm.allocateNodeCidrs || cfg.network.cni == "external";
        message = "kubenyx: controlPlane.kcm.allocateNodeCidrs requires network.cni = \"external\" — with the bridge CNI, Nix owns the pod subnets and kcm's order-unstable allocator would write node.spec.podCIDR values that contradict the configured dataplane";
      }
    ];

    systemd.services.kube-apiserver = {
      description = "Kubernetes API server";
      wantedBy = [ "kubenyx.target" ];
      after = [
        "kubenyx-pki.service"
        datastoreUnit
      ];
      # PKI is Wants, not Requires: a PKI rerun (nixos-rebuild switch) must
      # never bounce the control plane via restart propagation.
      wants = [ "kubenyx-pki.service" ] ++ lib.optional (serverCount > 1) datastoreUnit;
      # Single server: Requires — the apiserver is useless without its only
      # datastore, and stopping with it keeps today's semantics exactly.
      # Multi server: Wants — the datastore member is quorum-replicated, so a
      # LOCAL etcd death must not stop-propagate into this API replica. The
      # failover leg proved the Requires posture wrong twice over: the
      # propagated stop hangs ~90s in apiserver graceful shutdown (the etcd
      # restart job queues behind it, stretching quorum recovery from ~2s to
      # ~94s), and a dependency stop is "deliberate" to systemd, so
      # Restart=always never fires — one etcd blip permanently killed the
      # collocated API replica. The apiserver's own etcd client already
      # rides through no-leader windows (server3 did exactly that).
      # (<= 1, not == 1: an undeclared-nodes single box has serverCount 0.)
      requires = lib.optional (serverCount <= 1) datastoreUnit;
      # Multi-server only (single-server unit stays byte-identical), both
      # halves load-bearing for cp-growth.org's write-loop contract:
      # stopIfChanged=false makes a changed unit restart AFTER activation
      # (NixOS default stops it under the OLD definition BEFORE activation
      # and starts it after — measured: the API outage then spans the
      # whole switch, 66.8s), and TimeoutStopSec bounds the stop under the
      # NEW definition. Without the bound a deliberate stop hangs the full
      # 60s ShutdownTimeout: idle WATCH connections (kcm/scheduler/
      # kubelets hold ~10 at all times) keep the secure server's graceful
      # Shutdown open until "Failed to shutdown server: context deadline
      # exceeded" (measured 60.06s; the only in-binary knob is
      # --request-timeout, the wrong one to bend). By kill time /readyz
      # has been red and the listener draining for the whole window, so
      # real requests are long done; only idle watches die, and watch
      # clients re-list by design.
      stopIfChanged = lib.mkIf (serverCount > 1) false;
      serviceConfig = hardening // {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 120;
        TimeoutStopSec = lib.mkIf (serverCount > 1) 10;
        ExecStart = lib.concatStringsSep " " (
          [
            wrap
            "--url"
            "https://127.0.0.1:6443/readyz"
            "--cacert"
            "${pki}/ca.crt"
            "--cert"
            "${pki}/healthz.crt"
            "--key"
            "${pki}/healthz.key"
            "--"
            "${k8s}/bin/kube-apiserver"
          ]
          ++ map lib.escapeShellArg apiserverFlags
        );
      };
    };

    systemd.services.kube-controller-manager = {
      description = "Kubernetes controller manager";
      wantedBy = [ "kubenyx.target" ];
      after = [ "kube-apiserver.service" ];
      serviceConfig = hardening // {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 120;
        # Without this gate kcm crashed on its FIRST start of every boot
        # (12/12 profiled boots) and rejoined RestartSec=2s later: its
        # fatal startup read of the extension-apiserver-authentication
        # configmap raced the apiserver's RBAC *authorizer cache*. After=
        # apiserver only orders on /readyz, and /readyz (which includes
        # the rbac/bootstrap-roles poststarthook) proves the roles are in
        # STORAGE — not that the authorizer's informers have seen them.
        # Measured on a live boot: /readyz green at 2.453s monotonic, kcm
        # denied at 2.810s ("clusterrole cluster-admin not found"),
        # restart at 5.07s. The informer lag is real boot-time watch
        # latency, the same pathology the report probe hit. The gate
        # polls THE EXACT REQUEST kcm dies on — same resource, same
        # client identity — every 10ms, fork-free, so kcm starts within
        # ~10ms of the authorizer being able to admit it, and the crash
        # (plus its 200ms of CPU inside the convergence window and the
        # [FAILED] console noise) leaves the boot.
        ExecStartPre = lib.concatStringsSep " " [
          wrap
          "--wait"
          "--url"
          "https://127.0.0.1:6443/api/v1/namespaces/kube-system/configmaps/extension-apiserver-authentication"
          "--cacert"
          "${pki}/ca.crt"
          "--cert"
          "${pki}/controller-manager.crt"
          "--key"
          "${pki}/controller-manager.key"
        ];
        ExecStart = lib.concatStringsSep " " (
          [
            wrap
            "--url"
            "https://127.0.0.1:10257/healthz"
            "--insecure"
            "--"
            "${k8s}/bin/kube-controller-manager"
          ]
          ++ map lib.escapeShellArg kcmFlags
        );
      };
    };

    systemd.services.kube-scheduler = {
      description = "Kubernetes scheduler";
      wantedBy = [ "kubenyx.target" ];
      after = [ "kube-apiserver.service" ];
      serviceConfig = hardening // {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 120;
        ExecStart = lib.concatStringsSep " " (
          [
            wrap
            "--url"
            "https://127.0.0.1:10259/healthz"
            "--insecure"
            "--"
            "${k8s}/bin/kube-scheduler"
            "--config=${schedulerConfig}"
            "--bind-address=127.0.0.1"
            "--authentication-kubeconfig=${kc}/scheduler.kubeconfig"
            "--authorization-kubeconfig=${kc}/scheduler.kubeconfig"
          ]
          ++ map lib.escapeShellArg cp.scheduler.extraFlags
        );
      };
    };
  };
}
