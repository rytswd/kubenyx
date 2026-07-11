# Addon delivery (air/v0.1/dns-addons.org): server-side apply of a
# Nix-rendered manifest directory. The unit's store path changes whenever a
# manifest changes, so `nixos-rebuild switch` reconverges the cluster.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  kc = cfg.internal.kubeconfigDir;

  # Bootstrap RBAC: the revocable admin group, apiserver->kubelet access,
  # and CoreDNS's read permissions. Applied with the system:masters
  # bootstrap identity — the only place it is ever used.
  builtinManifests =
    lib.optionalAttrs (!cfg.controlPlane.kcm.useServiceAccountCredentials) {
      # With the shared kcm identity (testing profile), every controller acts
      # as system:kube-controller-manager, whose built-in role is scoped for
      # the per-controller-SA mode. cluster-admin here grants nothing kcm
      # doesn't already hold — it possesses the cluster CA signing key.
      "rbac-kcm-shared-identity" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "kubenyx:kcm-shared-identity";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "cluster-admin";
        };
        subjects = [
          {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "User";
            name = "system:kube-controller-manager";
          }
        ];
      };
    }
    // {
      "rbac-admin" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "kubenyx:cluster-admins";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "cluster-admin";
        };
        subjects = [
          {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Group";
            name = "kubenyx:cluster-admins";
          }
        ];
      };
      "rbac-apiserver-kubelet" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "kubenyx:apiserver-kubelet";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "system:kubelet-api-admin";
        };
        subjects = [
          {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "User";
            name = "kube-apiserver-kubelet-client";
          }
        ];
      };
      "rbac-coredns-role" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        metadata.name = "kubenyx:coredns";
        rules = [
          {
            apiGroups = [ "" ];
            resources = [
              "services"
              "namespaces"
            ];
            verbs = [
              "list"
              "watch"
            ];
          }
          {
            apiGroups = [ "discovery.k8s.io" ];
            resources = [ "endpointslices" ];
            verbs = [
              "list"
              "watch"
            ];
          }
        ];
      };
      "rbac-coredns-binding" = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata.name = "kubenyx:coredns";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "kubenyx:coredns";
        };
        subjects = [
          {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "User";
            name = "system:coredns";
          }
        ];
      };
    };

  # Strings must be store paths (rendered files inside derivations, e.g.
  # "${helmRendered}/workloads.yaml") and are linked as-is — build-time
  # template pipelines hand those back constantly, and forcing a
  # runCommand copy-wrapper per file was pure friction. Any other string
  # is an error: a bare JSON scalar was never a valid manifest, but it
  # used to type-check and render as quoted-string garbage.
  renderManifest =
    name: m:
    if lib.isPath m || lib.isDerivation m then
      m
    else if lib.isString m then
      assert lib.assertMsg (lib.hasPrefix builtins.storeDir m) ''
        kubenyx: addons.manifests.${name} is the string "${m}", which is
        not a store path — pass an attrset manifest, an eval-time path, a
        derivation, or a rendered file inside one ("''${drv}/file.yaml").'';
      m
    else
      pkgs.writeText "${name}.json" (builtins.toJSON m);

  manifestDir = pkgs.linkFarm "kubenyx-addons" (
    lib.mapAttrsToList (name: m: {
      name = "${name}.json";
      path = renderManifest name m;
    }) (builtinManifests // cfg.addons.manifests)
  );

  applyScript = pkgs.writeShellApplication {
    name = "kubenyx-apply-addons";
    runtimeInputs = [ cfg.packages.kubectl ];
    text = ''
      export KUBECONFIG=${kc}/bootstrap.kubeconfig
      # Retry generously: a oneshot's job is canceled forever if a hard
      # dependency fails once, so resilience lives here, not in Requires=.
      for attempt in $(seq 1 120); do
        if kubectl apply --server-side --force-conflicts --request-timeout=10s -f ${manifestDir}/; then
          exit 0
        fi
        echo "kubenyx-addons: apply failed (attempt $attempt), retrying" >&2
        sleep 3
      done
      exit 1
    '';
  };
in
{
  options.kubenyx.addons.manifests = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.oneOf [
        (pkgs.formats.json { }).type
        lib.types.path
      ]
    );
    default = { };
    example = lib.literalExpression ''
      {
        my-app = { apiVersion = "v1"; kind = "Namespace"; metadata.name = "my-app"; };
        my-rendered = "''${myHelmRender}/workloads.yaml";
      }
    '';
    description = ''
      Manifests server-side-applied after the API is ready, in attr-name
      lexical order (the applier links each as <name>.json and retries
      the whole directory). Values may be attrsets, eval-time paths,
      derivations, or store-path strings (rendered files inside
      derivations).
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.role == "server") {
    systemd.services.kubenyx-addons = {
      description = "Kubenyx addon manifests (server-side apply)";
      wantedBy = [ "kubenyx.target" ];
      after = [ "kube-apiserver.service" ];
      wants = [ "kube-apiserver.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        ExecStart = lib.getExe applyScript;
      };
    };
  };
}
