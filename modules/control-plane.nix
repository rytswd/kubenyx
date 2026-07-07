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

  usingKine = cfg.datastore.backend == "kine-sqlite";
  thisNode = cfg.nodes.${cfg.nodeName} or {
    address = null;
    index = 0;
  };

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
    ++ lib.optionals (!usingKine) [
      "--etcd-cafile=${pki}/ca.crt"
      "--etcd-certfile=${pki}/apiserver-etcd-client.crt"
      "--etcd-keyfile=${pki}/apiserver-etcd-client.key"
    ]
    ++ lib.optional (!cp.apiserver.priorityAndFairness) "--enable-priority-and-fairness=false"
    ++ cp.apiserver.extraFlags;

  kcmFlags =
    [
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
      "--allocate-node-cidrs=false"
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
      default = false;
      description = ''
        Leader election for kcm/scheduler. Off by default: a single
        control-plane node gains nothing and waiting out lease acquisition
        is one of the biggest single-node startup costs.
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
    systemd.services.kube-apiserver = {
      description = "Kubernetes API server";
      wantedBy = [ "kubenyx.target" ];
      after = [
        "kubenyx-pki.service"
        (if usingKine then "kine.service" else "etcd.service")
      ];
      # PKI is Wants, not Requires: a PKI rerun (nixos-rebuild switch) must
      # never bounce the control plane via restart propagation.
      wants = [ "kubenyx-pki.service" ];
      requires = [ (if usingKine then "kine.service" else "etcd.service") ];
      serviceConfig = hardening // {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 120;
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
