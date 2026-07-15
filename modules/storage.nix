# Local storage (air/v0.1/hosts/byod.org §2): declared static local
# PersistentVolumes plus a no-provisioner default StorageClass, so
# PVC-shaped workloads run with zero daemons and zero images. Everything
# rides the existing addons applier (addons.nix); a dynamic provisioner
# stays a user-supplied addons.manifests concern. Default disabled — a
# config that never sets storage.localVolumes gets no manifests, no
# tmpfiles rules, nothing.
{
  config,
  lib,
  ...
}:
let
  cfg = config.kubenyx;
  lv = cfg.storage.localVolumes;
  enabled = lv != null;

  pvNames = lib.genList (i: "local-pv-${toString i}") (if enabled then lv.count else 0);

  storageClass = {
    apiVersion = "storage.k8s.io/v1";
    kind = "StorageClass";
    metadata = {
      name = lv.storageClass;
      annotations."storageclass.kubernetes.io/is-default-class" = "true";
    };
    provisioner = "kubernetes.io/no-provisioner";
    volumeBindingMode = "WaitForFirstConsumer";
  };

  # Static local PVs pinned to the declaring node. Retain, not Delete: with
  # no provisioner there is nothing to honor a Delete, and Retain keeps the
  # released-PV cleanup an explicit operator action.
  mkPv = name: {
    apiVersion = "v1";
    kind = "PersistentVolume";
    metadata.name = name;
    spec = {
      capacity.storage = lv.size;
      accessModes = [ "ReadWriteOnce" ];
      persistentVolumeReclaimPolicy = "Retain";
      storageClassName = lv.storageClass;
      volumeMode = "Filesystem";
      local.path = "${lv.basePath}/${name}";
      nodeAffinity.required.nodeSelectorTerms = [
        {
          matchExpressions = [
            {
              key = "kubernetes.io/hostname";
              operator = "In";
              values = [ cfg.nodeName ];
            }
          ];
        }
      ];
    };
  };
in
{
  options.kubenyx.storage.localVolumes = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          count = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Number of PVs to declare: local-pv-0 .. local-pv-(count-1).";
          };
          size = lib.mkOption {
            type = lib.types.str;
            default = "10Gi";
            description = "Declared capacity of each PV (PVCs bind by capacity/access-mode matching).";
          };
          basePath = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/kubenyx/volumes";
            description = "Backing directories live at basePath/<pv-name> (created by tmpfiles).";
          };
          storageClass = lib.mkOption {
            type = lib.types.str;
            default = "kubenyx-local";
            description = "Name of the created no-provisioner StorageClass (marked cluster default).";
          };
        };
      }
    );
    default = null;
    example = lib.literalExpression ''{ count = 4; size = "10Gi"; }'';
    description = ''
      Declared static local PersistentVolumes plus a default no-provisioner
      StorageClass (volumeBindingMode: WaitForFirstConsumer), delivered
      through the addons applier. Zero daemons, zero images: PVCs bind on
      pod schedule against these PVs, pinned via nodeAffinity to the node
      that declared them (the option is per-node config). null (the
      default) declares nothing at all.
    '';
  };

  config = lib.mkIf (cfg.enable && enabled) {
    # The addons applier is server-role-only: declared on an agent, these
    # manifests would feed a unit that never exists — silently nothing.
    # Cross-machine forwarding is not a thing per-machine modules can do,
    # so refuse with directions instead.
    assertions = [
      {
        assertion = cfg.role == "server";
        message = ''
          kubenyx: storage.localVolumes is declared on an agent-role node,
          but the addons applier runs on servers only — these PVs would
          never be applied. Declare localVolumes on a server (the PVs pin
          to the *declaring* node via nodeAffinity), or ship
          agent-node-affine PV manifests through a server's
          addons.manifests.'';
      }
    ];

    # "storage-0class" sorts before "storage-pv-*" in the applier's
    # lexical file order, so the StorageClass lands first.
    kubenyx.addons.manifests = {
      "storage-0class" = storageClass;
    }
    // lib.listToAttrs (
      map (name: {
        name = "storage-pv-${name}";
        value = mkPv name;
      }) pvNames
    );

    systemd.tmpfiles.rules = [
      "d ${lv.basePath} 0755 root root -"
    ]
    ++ map (name: "d ${lv.basePath}/${name} 0755 root root -") pvNames;
  };
}
