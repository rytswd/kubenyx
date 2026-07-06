# Datastore backends (air/v0.1/datastore.org): kine+sqlite (default) or
# etcd. The unmodified kube-apiserver talks etcd-v3 gRPC to either.
#
# Access control: a plaintext localhost datastore would let ANY local
# process (including hostNetwork pods) write straight past RBAC and
# admission. So the kine socket lives in a 0700 directory, and the etcd
# backend requires client certificates even on loopback.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kubenyx;
  ds = cfg.datastore;
  pki = cfg.internal.pkiDir;
  wrap = lib.getExe' cfg.internal.tools "kubenyx-ready";

  kineSock = "/run/kubenyx/kine/kine.sock";
  volatileDir = "/run/kubenyx/volatile-state"; # tmpfs; shared name for both backends
  kineDbDir = if ds.volatile then volatileDir else "/var/lib/kine";
  kineDsn = "sqlite://${kineDbDir}/state.db?_journal=WAL&cache=shared&_busy_timeout=30000";
in
{
  options.kubenyx.datastore = {
    backend = lib.mkOption {
      type = lib.types.enum [
        "kine-sqlite"
        "etcd"
      ];
      default = "kine-sqlite";
      description = ''
        kine+sqlite removes etcd's raft/fsync startup cost while the
        apiserver stays stock (k0s ships the same wiring). etcd remains
        first-class for multi-node and API-heavy loads.
      '';
    };
    volatile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        DANGER: keep cluster state on tmpfs. Fastest possible datastore;
        all objects are lost on reboot. Only sensible for disposable test
        clusters (the testing profile's opt-in extreme).
      '';
    };
    kine.extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra kine flags.";
    };
    etcd = {
      unsafeNoFsync = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "DANGER: --unsafe-no-fsync. Massive latency win; crash can corrupt the datastore.";
      };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra etcd flags.";
      };
    };
  };

  options.kubenyx.internal.etcdServers = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    internal = true;
    default = if ds.backend == "kine-sqlite" then "unix://${kineSock}" else "https://127.0.0.1:2379";
    description = "Value for kube-apiserver --etcd-servers.";
  };

  config = lib.mkIf (cfg.enable && cfg.role == "server") (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = ds.backend != "kine-sqlite" || lib.length (lib.attrNames cfg.nodes) == 1;
            message = "kubenyx: the kine-sqlite backend supports a single node; use backend = \"etcd\" for multi-node";
          }
        ];
        systemd.tmpfiles.rules = [
          # 0700: unix-socket reachability is the datastore's entire access
          # control — see header comment.
          "d /run/kubenyx/kine 0700 root root -"
        ] ++ lib.optional ds.volatile "d ${volatileDir} 0700 root root -";
      }

      (lib.mkIf (ds.backend == "kine-sqlite") {
        systemd.services.kine = {
          description = "kine etcd-shim (sqlite)";
          wantedBy = [ "kubenyx.target" ];
          serviceConfig = {
            # Type=notify via the socket probe: "started" must mean
            # "accepting connections", or the apiserver races a dead socket
            # and burns its storage-health timeout on first boot.
            Type = "notify";
            NotifyAccess = "all";
            ExecStart = lib.escapeShellArgs (
              [
                wrap
                "--url"
                "unix://${kineSock}"
                "--"
                (lib.getExe' cfg.packages.kine "kine")
                "--endpoint"
                kineDsn
                "--listen-address"
                "unix://${kineSock}"
                # The apiserver compacts every 5m already; doubling up from
                # kine's side only burns sqlite writes (k0s passes 0 too).
                "--compact-interval"
                "0"
                "--metrics-bind-address"
                "0"
                "--watch-progress-notify-interval"
                "5s"
              ]
              ++ ds.kine.extraFlags
            );
            Restart = "always";
            RestartSec = 2;
            SuccessExitStatus = "143"; # notify-wrapper exit on orderly stop
            StateDirectory = lib.mkIf (!ds.volatile) "kine";
          };
        };
      })

      (lib.mkIf (ds.backend == "etcd") {
        systemd.services.etcd = {
          description = "etcd (kubenyx datastore)";
          wantedBy = [ "kubenyx.target" ];
          after = [ "kubenyx-pki.service" ];
          wants = [ "kubenyx-pki.service" ];
          serviceConfig = {
            Type = "notify";
            NotifyAccess = "all";
            TimeoutStartSec = 120;
            ExecStart = lib.escapeShellArgs (
              [
                wrap
                "--url"
                "https://127.0.0.1:2379/readyz"
                "--cacert"
                "${pki}/ca.crt"
                "--cert"
                "${pki}/apiserver-etcd-client.crt"
                "--key"
                "${pki}/apiserver-etcd-client.key"
                "--"
                (lib.getExe' cfg.packages.etcd "etcd")
                "--name"
                "kubenyx"
                "--data-dir"
                (if ds.volatile then volatileDir else "/var/lib/etcd")
                # Client-cert auth even on loopback: without it any local
                # process could write past RBAC (security review finding).
                "--listen-client-urls"
                "https://127.0.0.1:2379"
                "--advertise-client-urls"
                "https://127.0.0.1:2379"
                "--client-cert-auth"
                "--trusted-ca-file"
                "${pki}/ca.crt"
                "--cert-file"
                "${pki}/etcd-server.crt"
                "--key-file"
                "${pki}/etcd-server.key"
                # Peer port carries raft; leaving it plaintext would be the
                # same local RBAC bypass the client port closes. Same cert
                # (SANs cover localhost/127.0.0.1), peer client-cert auth on.
                "--listen-peer-urls"
                "https://127.0.0.1:2380"
                "--initial-advertise-peer-urls"
                "https://127.0.0.1:2380"
                "--initial-cluster"
                "kubenyx=https://127.0.0.1:2380"
                "--peer-client-cert-auth"
                "--peer-trusted-ca-file"
                "${pki}/ca.crt"
                "--peer-cert-file"
                "${pki}/etcd-server.crt"
                "--peer-key-file"
                "${pki}/etcd-server.key"
                "--enable-pprof=false"
              ]
              ++ lib.optional ds.etcd.unsafeNoFsync "--unsafe-no-fsync"
              ++ ds.etcd.extraFlags
            );
            Restart = "always";
            RestartSec = 2;
            SuccessExitStatus = "143"; # notify-wrapper exit on orderly stop
            StateDirectory = lib.mkIf (!ds.volatile) "etcd";
          };
        };
      })
    ]
  );
}
