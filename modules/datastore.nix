# Datastore backends (air/v0.1/datastore.org): kine+sqlite, etcd-mem, or etcd.
# The unmodified kube-apiserver talks etcd-v3 gRPC to any of them.
#
# Access control: a plaintext localhost datastore would let ANY local
# process (including hostNetwork pods) write straight past RBAC and
# admission. So each socket lives in a 0700 directory, and the etcd
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
  etcdMemSock = "/run/kubenyx/etcd-mem/etcd-mem.sock";
  volatileDir = "/run/kubenyx/volatile-state"; # tmpfs; shared name for both backends
  kineDbDir = if ds.volatile then volatileDir else "/var/lib/kine";
  kineDsn = "sqlite://${kineDbDir}/state.db?_journal=WAL&cache=shared&_busy_timeout=30000";

  # Both shims are single-writer, but only kube-apiserver ever talks to the
  # datastore — over a local unix socket, on the server. Agents never touch
  # it, so the correct constraint is "exactly one server", not "exactly one
  # node" (air/v0.2/multinode-microvm.org §1). Multi-SERVER (quorum) is
  # backend = "etcd" — the multiServer branch below (durable-ha.org §2).
  servers = lib.filterAttrs (_: n: n.role == "server") cfg.nodes;
  serverCount = lib.length (lib.attrNames servers);
  multiServer = serverCount > 1;
  thisNode = cfg.nodes.${cfg.nodeName} or { address = null; };

  etcdDataDir = if ds.volatile then volatileDir else "/var/lib/etcd";
  # Quorum wiring is derived from kubenyx.nodes at EVAL time, never frozen
  # at bootstrap (durable-ha.org Decision 3's door-open note): a future
  # CP-growth path only has to change what the member-set guard below does
  # with a diff, not where the member list comes from.
  #   Single server keeps today's loopback-only posture, flag-identical.
  etcdName = if multiServer then cfg.nodeName else "kubenyx";
  etcdInitialCluster =
    if multiServer then
      lib.concatStringsSep "," (lib.mapAttrsToList (n: v: "${n}=https://${v.address}:2380") servers)
    else
      "kubenyx=https://127.0.0.1:2380";

  # Bootstrap fingerprint (durable-ha.org §2): record the member SET on
  # first bootstrap; a later mismatch is a hard, distinct error — the
  # control-plane set is fixed at cluster creation, and re-running the
  # bootstrap flags against a grown/shrunk set would silently split or
  # wedge the quorum. It lives inside the data dir on purpose: wiping the
  # data legitimately re-bootstraps, so the fingerprint must die with it.
  #
  # NOTE: this error site is the future CP-growth hook (durable-ha.org
  # Decision 3). A supported grow path would diff recorded vs declared
  # sets here and slot in `etcdctl member add` +
  # `--initial-cluster-state existing` for the new member instead of
  # erroring. Today: error, with the runbook pointer.
  etcdMemberGuard = pkgs.writeShellScript "kubenyx-etcd-member-guard" ''
    set -eu
    fp='${etcdDataDir}/.kubenyx-member-set'
    want='${etcdInitialCluster}'
    if [ -e "$fp" ]; then
      have=$(cat "$fp")
      if [ "$have" != "$want" ]; then
        echo "kubenyx: etcd member set changed since this datastore was bootstrapped:" >&2
        echo "  recorded: $have" >&2
        echo "  declared: $want" >&2
        echo "kubenyx: the control-plane set is fixed at cluster creation (air/v0.3/durable-ha.org). Changing it means a new initial-cluster plus an 'etcdctl snapshot save/restore' migration — a documented runbook, not machinery. Refusing to start with mismatched bootstrap flags." >&2
        exit 1
      fi
    else
      printf '%s\n' "$want" > "$fp"
    fi
  '';
in
{
  options.kubenyx.datastore = {
    backend = lib.mkOption {
      type = lib.types.enum [
        "kine-sqlite"
        "etcd-mem"
        "etcd"
      ];
      default = "kine-sqlite";
      description = ''
        etcd-mem: Rust in-memory etcd shim (<10ms startup, volatile only).
        kine-sqlite: Go etcd shim + SQLite (~2s startup, persistent capable).
        etcd: real etcd (multi-node, production).
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
    default =
      if ds.backend == "kine-sqlite" then
        "unix://${kineSock}"
      else if ds.backend == "etcd-mem" then
        "unix://${etcdMemSock}"
      else
        "https://127.0.0.1:2379";
    description = "Value for kube-apiserver --etcd-servers.";
  };

  config = lib.mkIf (cfg.enable && cfg.role == "server") (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = ds.backend != "kine-sqlite" || serverCount == 1;
            message = "kubenyx: the kine-sqlite backend supports exactly one server node; use backend = \"etcd\" for multi-server";
          }
        ];
        systemd.tmpfiles.rules = [
          # 0700: unix-socket reachability is the datastore's entire access
          # control — see header comment.
          "d /run/kubenyx/kine 0700 root root -"
        ]
        ++ lib.optional ds.volatile "d ${volatileDir} 0700 root root -";
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

      (lib.mkIf (ds.backend == "etcd-mem") {
        assertions = [
          {
            assertion = ds.volatile;
            message = "kubenyx: etcd-mem backend is in-memory only; set datastore.volatile = true";
          }
          {
            assertion = serverCount == 1;
            message = "kubenyx: etcd-mem backend supports exactly one server node; use backend = \"etcd\" for multi-server";
          }
        ];
        systemd.tmpfiles.rules = [ "d /run/kubenyx/etcd-mem 0700 root root -" ];
        systemd.services.etcd-mem = {
          description = "etcd-mem in-memory etcd v3 shim";
          wantedBy = [ "kubenyx.target" ];
          serviceConfig = {
            # etcd-mem sends READY=1 directly via sd_notify — no socket-probe
            # wrapper needed. Startup is <10ms vs kine's ~2s Go init.
            Type = "notify";
            NotifyAccess = "all";
            ExecStart = lib.escapeShellArgs [
              (lib.getExe' cfg.internal.tools "etcd-mem")
              "--listen-address"
              "unix://${etcdMemSock}"
            ];
            Restart = "always";
            RestartSec = 2;
            SuccessExitStatus = "143";
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
            # Multi-server only: the member-set guard (see the let binding)
            # gates bootstrap flags against the recorded membership. The
            # single-server unit stays byte-identical to v0.1.
            ExecStartPre = lib.mkIf multiServer "${etcdMemberGuard}";
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
                etcdName
                "--data-dir"
                etcdDataDir
                # Client-cert auth even on loopback: without it any local
                # process could write past RBAC (security review finding).
                # Multi-server adds the declared address as a second client
                # listener (peers/etcdctl), but the LOCAL apiserver keeps
                # dialing loopback: internal.etcdServers never changes.
                "--listen-client-urls"
                (
                  if multiServer then
                    "https://127.0.0.1:2379,https://${thisNode.address}:2379"
                  else
                    "https://127.0.0.1:2379"
                )
                "--advertise-client-urls"
                (if multiServer then "https://${thisNode.address}:2379" else "https://127.0.0.1:2379")
                "--client-cert-auth"
                "--trusted-ca-file"
                "${pki}/ca.crt"
                "--cert-file"
                "${pki}/etcd-server.crt"
                "--key-file"
                "${pki}/etcd-server.key"
                # Peer port carries raft; leaving it plaintext would be the
                # same local RBAC bypass the client port closes. Same cert
                # (SANs cover localhost/127.0.0.1, plus every declared server
                # address on multi-server — see pki.nix), peer client-cert
                # auth on.
                "--listen-peer-urls"
                (if multiServer then "https://${thisNode.address}:2380" else "https://127.0.0.1:2380")
                "--initial-advertise-peer-urls"
                (if multiServer then "https://${thisNode.address}:2380" else "https://127.0.0.1:2380")
                "--initial-cluster"
                etcdInitialCluster
              ]
              # --initial-cluster-state new is etcd's default; stating it on
              # the quorum path documents intent (and is the flag the future
              # CP-growth hook would flip to "existing" for a joining
              # member). Omitted single-server to stay flag-identical.
              ++ lib.optionals multiServer [
                "--initial-cluster-state"
                "new"
              ]
              ++ [
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
