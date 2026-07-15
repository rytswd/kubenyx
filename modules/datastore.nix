# Datastore backends (air/v0.1/core/datastore.org): kine+sqlite, etcd-mem, or etcd.
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
  klib = import ../lib { inherit lib; };

  kineSock = "/run/kubenyx/kine/kine.sock";
  etcdMemSock = "/run/kubenyx/etcd-mem/etcd-mem.sock";
  volatileDir = "/run/kubenyx/volatile-state"; # tmpfs; shared name for both backends
  kineDbDir = if ds.volatile then volatileDir else "/var/lib/kine";
  kineDsn = "sqlite://${kineDbDir}/state.db?_journal=WAL&cache=shared&_busy_timeout=30000";

  # Both shims are single-writer, but only kube-apiserver ever talks to the
  # datastore — over a local unix socket, on the server. Agents never touch
  # it, so the correct constraint is "exactly one server", not "exactly one
  # node" (air/v0.1/microvm/multinode-microvm.org §1). Multi-SERVER (quorum) is
  # backend = "etcd" — the multiServer branch below (durable-ha.org §2).
  servers = lib.filterAttrs (_: n: n.role == "server") cfg.nodes;
  serverCount = lib.length (lib.attrNames servers);
  multiServer = serverCount > 1;
  thisNode = cfg.nodes.${cfg.nodeName} or { address = null; };

  etcdDataDir = if ds.volatile then volatileDir else "/var/lib/etcd";
  # Quorum wiring is derived from kubenyx.nodes at EVAL time, never frozen
  # at bootstrap (durable-ha.org Decision 3's door-open note) — which is
  # exactly what lets cp-growth.org treat a grown declaration as a diff to
  # reconcile rather than a re-bootstrap.
  #   Single server keeps today's loopback-only posture, flag-identical.
  etcdName = if multiServer then cfg.nodeName else "kubenyx";
  # hostPort brackets v6 addresses in the peer URLs (ipv6.org §4); v4
  # renders byte-identically.
  serverPeerUrl = n: "https://${klib.hostPort n.address 2380}";
  serverClientUrl = n: "https://${klib.hostPort n.address 2379}";
  etcdInitialCluster =
    if multiServer then
      lib.concatStringsSep "," (lib.mapAttrsToList (n: v: "${n}=${serverPeerUrl v}") servers)
    else
      "kubenyx=https://127.0.0.1:2380";

  # ---- CP growth (air/v0.1/quorum/cp-growth.org) ---------------------------------
  # Everything below the guard exists only at serverCount > 1; the
  # single-server unit stays byte-identical to v0.1.
  etcdCtl = lib.getExe' cfg.packages.etcd "etcdctl";
  # The apiserver-etcd-client identity: present on every server by
  # construction (kubenyx-pki mints it from the custody CA), and already
  # authorized on the client port — no new credentials for growth.
  ctlCreds = "--cacert=${pki}/ca.crt --cert=${pki}/apiserver-etcd-client.crt --key=${pki}/apiserver-etcd-client.key";
  selfPeerUrl = serverPeerUrl thisNode;
  declaredClientEps = lib.mapAttrsToList (_: v: serverClientUrl v) servers;
  otherClientEps = lib.mapAttrsToList (_: v: serverClientUrl v) (
    lib.filterAttrs (n: _: n != cfg.nodeName) servers
  );
  # Written by the join probe on every start, read by the launcher: etcd
  # ignores --initial-* flags entirely once the member dir exists, so the
  # declared values are placeholders on every boot after the first.
  clusterEnvFile = "/run/kubenyx/etcd-cluster.env";

  # Bootstrap fingerprint (durable-ha.org §2, revised by cp-growth.org §2):
  # record the member SET on first bootstrap. GROWTH is now allowed —
  # recorded ⊂ declared means kubenyx-etcd-reconcile is bringing the new
  # members in as learners, and the record is rewritten only after the
  # RUNTIME member list matches the declaration. Shrink or rename remain
  # the hard, distinct error: re-running bootstrap flags against a shrunk/
  # renamed set would silently split or wedge the quorum. The record lives
  # inside the data dir on purpose: wiping the data legitimately
  # re-bootstraps, so the fingerprint must die with it.
  etcdMemberGuard = pkgs.writeShellScript "kubenyx-etcd-member-guard" ''
    set -eu
    fp='${etcdDataDir}/.kubenyx-member-set'
    want='${etcdInitialCluster}'
    if [ -e "$fp" ]; then
      have=$(cat "$fp")
      if [ "$have" = "$want" ]; then
        exit 0
      fi
      # Superset rule (cp-growth.org §2), one-directional: every recorded
      # member still declared -> the set GREW -> allowed; the reconcile
      # rewrites the record once runtime matches the declaration.
      grew=1
      set -f
      IFS=','
      for m in $have; do
        case ",$want," in
          *",$m,"*) ;;
          *) grew=0 ;;
        esac
      done
      unset IFS
      set +f
      if [ "$grew" = 1 ]; then
        echo "kubenyx: declared etcd member set grew beyond the recorded bootstrap set (recorded: $have); kubenyx-etcd-reconcile adds the new members as learners and records the set once runtime matches" >&2
        exit 0
      fi
      echo "kubenyx: etcd member set changed since this datastore was bootstrapped:" >&2
      echo "  recorded: $have" >&2
      echo "  declared: $want" >&2
      echo "kubenyx: the control-plane set is fixed at cluster creation (air/v0.1/quorum/durable-ha.org). Changing it means a new initial-cluster plus an 'etcdctl snapshot save/restore' migration — a documented runbook, not machinery. Refusing to start with mismatched bootstrap flags." >&2
      exit 1
    fi
    if [ -e '${etcdDataDir}/member' ]; then
      # Initialized data dir without a record: bootstrapped by the
      # single-server unit (which runs no guard) and grown around (1 -> N).
      # The reconcile records the set once runtime matches the declaration.
      exit 0
    fi
    printf '%s\n' "$want" > "$fp"
  '';

  # Join probe (cp-growth.org §3): a fresh server with an empty data dir
  # must not guess between "bootstrap a new cluster" and "join an existing
  # one". Probe the OTHER declared servers' client endpoints; a healthy
  # answer proves a quorum-bearing cluster exists (learners answer
  # unhealthy — they reject the linearizable read behind `endpoint
  # health`), so we JOIN: wait until the peers' reconcile adds our peer
  # URL as a learner, then start with --initial-cluster-state existing and
  # the initial-cluster narrowed to the CURRENT member set + self (etcd
  # join semantics; unstarted members carry no name in `member list`,
  # which is why membership is matched by peer URL throughout). Nobody
  # answering within the probe window (etcd.joinProbeSec — the window IS
  # the cp3 cold-boot tax, quorum-mesh.org §D3) is the phase 3
  # first-bootstrap path, unchanged. Once a healthy peer has answered we
  # NEVER fall through to bootstrap: on join-wait expiry the unit fails
  # loudly (DEGRADED marker) and systemd retries — a wedged join is
  # recoverable, a second cluster is not.
  #
  # D3 fast-exit (quorum-mesh.org): burning the whole window is only
  # necessary when the probe cannot TELL fresh from mid-boot. It often
  # can: when every other declared server ACTIVELY refuses the TCP
  # connect (curl exit 7, an RST/unreachable answered instantly — vs 28,
  # silence until the timeout), nobody has a listener, and on the bridge
  # a booted-but-fresh peer refuses exactly like that while its own etcd
  # is still queued behind pki. All-refused sustained across three
  # consecutive sweeps (the streak rationale sits with the loop below)
  # concludes "all peers are also fresh" and bootstraps immediately.
  # Anything softer keeps the full
  # window: answers-but-unhealthy or a connect that hangs may be a
  # mid-boot member WITH state, and joining late beats splitting early.
  # Blast-radius honesty: a genuinely-running-but-unreachable quorum
  # whose partition REFUSES (members' hosts up, etcd ports closed by a
  # REJECT rule or crashed processes) now reaches declared/new sooner
  # than the timeout fall-through did. That is the same decision, only
  # earlier — this path runs solely on an EMPTY data dir, and the
  # member-set guard above already contains it: the fingerprint pins
  # this bootstrap to the same declared set the real cluster was born
  # from, so the deterministic cluster ID (the fresh-founder-race note
  # below) converges the two sides on heal instead of splitting, a
  # minority founder commits nothing alone in the meantime, and any
  # replay against a CHANGED set is refused loudly before this probe
  # ever runs.
  etcdJoinProbe = pkgs.writeShellScript "kubenyx-etcd-join-probe" ''
    set -eu
    env_file='${clusterEnvFile}'
    declared='${etcdInitialCluster}'
    self_peer='${selfPeerUrl}'
    write_env() {
      mkdir -p /run/kubenyx
      printf 'KUBENYX_ETCD_INITIAL_CLUSTER=%s\nKUBENYX_ETCD_INITIAL_CLUSTER_STATE=%s\n' "$1" "$2" > "$env_file"
    }
    # Initialized member: etcd ignores --initial-* flags entirely on
    # restart; write the declared placeholders and get out of the way.
    if [ -e '${etcdDataDir}/member' ]; then
      write_env "$declared" new
      exit 0
    fi
    # Custody flow: before the CA bundle lands and kubenyx-pki reruns
    # there are no client certs. Fail loudly instead of probing blind —
    # falling through to bootstrap here could seed a datastore with no
    # peers reachable to contradict it.
    for f in ${pki}/ca.crt ${pki}/apiserver-etcd-client.crt ${pki}/apiserver-etcd-client.key; do
      if [ ! -s "$f" ]; then
        echo "kubenyx-etcd-join-probe: $f missing; cannot probe the declared servers (ship the custody bundle and rerun kubenyx-pki)" >&2
        exit 1
      fi
    done
    others='${lib.concatStringsSep " " otherClientEps}'
    healthy_ep=""
    # Fast-exit needs 5 CONSECUTIVE all-refused sweeps, half a second
    # apart: a single refused observation can be a LIVE peer's listener
    # gap masquerading as fresh — the bind race on a normal etcd start,
    # or the RestartSec=2 refuse window while systemd revives a crashed
    # member. Five 0.5s-spaced sweeps still span that whole >2s window,
    # and any non-refused answer from any peer resets the streak; a
    # genuinely fresh mesh keeps refusing indefinitely, so the streak
    # costs ~2s against the up-to-joinProbeSec it saves. 5x0.5s rather
    # than 3x1s (same span, finer grain): on a synchronized cold mesh
    # the peers' etcd binds land ~2.1s after this probe starts, and the
    # coarse grid lost the race 1/9 server-boots — its LAST sweep
    # slipped past a peer's bound-but-not-yet-serving listener, reset
    # the streak, and blocked in the health RPC until the peers elected
    # (+1.4s on that member). The fine grid completes the streak ~0.1s
    # sooner and, more to the point, its final sweep lands well before
    # the earliest observed peer-bind.
    refused_streak=0
    probe_deadline=$(( $(date +%s) + ${toString ds.etcd.joinProbeSec} ))
    while [ "$(date +%s)" -lt "$probe_deadline" ]; do
      all_refused=1
      for ep in $others; do
        # TCP-classify before the health RPC: curl exit 7 is an ACTIVE
        # refusal (RST/unreachable, answered instantly — verified: 7 on
        # a closed port, 28 on silence/timeout), so there is no listener
        # to health-check and the etcdctl dial-timeout would only burn
        # probe budget.
        rc=0
        curl -so /dev/null --connect-timeout 1 --max-time 2 "$ep/health" || rc=$?
        if [ "$rc" = 7 ]; then
          continue
        fi
        all_refused=0
        # Silence (28) resets the streak — a partitioned member WITH
        # state can look exactly like this, so the window must hold —
        # but it must NOT dial etcdctl: TCP got no answer, so a 2s gRPC
        # dial into the same black hole is deterministic dead time.
        # Unbounded, a silent sweep cost 1s curl + 2s etcdctl per peer
        # (~6s for two), overshooting the whole probe window: measured
        # 2/5 cold boots where sweeps raced ahead of the peers' network
        # bring-up, etcd exec at 8.7s instead of 4.4s and +4.5s on the
        # mesh wall. With the skip a silent sweep is bounded at 1s/peer.
        # The one state that answers TCP but hangs HTTP — a bound
        # listener mid-bootstrap — also exits 28 (connect ok, --max-time
        # expiry) and also cannot pass a health RPC yet; the next sweep
        # re-probes it 0.5s later, well inside the window.
        if [ "$rc" = 28 ]; then
          echo "kubenyx-etcd-join-probe: $ep silent (no TCP answer within 1s); holding the probe window" >&2
          continue
        fi
        if ${etcdCtl} --endpoints="$ep" ${ctlCreds} --dial-timeout=2s --command-timeout=3s endpoint health >/dev/null 2>&1; then
          healthy_ep=$ep
          break 2
        fi
      done
      if [ "$all_refused" = 1 ]; then
        refused_streak=$(( refused_streak + 1 ))
        if [ "$refused_streak" -ge 5 ]; then
          echo "kubenyx-etcd-join-probe: every declared server actively refused across $refused_streak sweeps (all peers are also fresh); bootstrapping the declared initial-cluster without waiting out the probe window" >&2
          write_env "$declared" new
          exit 0
        fi
      else
        refused_streak=0
      fi
      sleep 0.5
    done
    if [ -z "$healthy_ep" ]; then
      echo "kubenyx-etcd-join-probe: no declared server answered; bootstrapping the declared initial-cluster" >&2
      write_env "$declared" new
      exit 0
    fi
    # Render name=peerURL for the CURRENT members + self. rc 1 while we
    # are not yet in the member list, or while another member is still
    # nameless (unstarted — cannot be rendered; one-learner-at-a-time
    # makes that transient on the growth path). rc 2 is the fresh-founder
    # race: we are already a VOTING (unstarted, nameless) member next to
    # other nameless founders — a concurrent first bootstrap where a
    # quorum formed before we probed. etcd's cluster ID is derived
    # deterministically from the initial-cluster set, so the phase 3
    # declared/new path converges into that same cluster.
    render_join() {
      list=$(${etcdCtl} --endpoints="$1" ${ctlCreds} --dial-timeout=2s --command-timeout=3s member list 2>/dev/null) || return 1
      printf '%s\n' "$list" | grep -qF "$self_peer" || return 1
      ic=""
      self_voting=0
      nameless_other=0
      while IFS= read -r row; do
        name=$(printf '%s\n' "$row" | awk -F', ' '{print $3}')
        peer=$(printf '%s\n' "$row" | awk -F', ' '{print $4}')
        learner=$(printf '%s\n' "$row" | awk -F', ' '{print $6}')
        [ -n "$peer" ] || continue
        if [ "$peer" = "$self_peer" ]; then
          name='${cfg.nodeName}'
          [ "$learner" = "true" ] || self_voting=1
        elif [ -z "$name" ]; then
          nameless_other=1
        fi
        if [ -z "$ic" ]; then ic="$name=$peer"; else ic="$ic,$name=$peer"; fi
      done <<KUBENYX_EOF
    $list
    KUBENYX_EOF
      if [ "$nameless_other" = 1 ]; then
        if [ "$self_voting" = 1 ]; then return 2; fi
        return 1
      fi
      if [ "$self_voting" = 1 ]; then
        printf 'voting %s\n' "$ic"
      else
        printf 'learner %s\n' "$ic"
      fi
    }
    join_deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$join_deadline" ]; do
      for ep in $others; do
        if out=$(render_join "$ep"); then
          kind=''${out%% *}
          ic=''${out#* }
          if [ "$kind" = "learner" ]; then
            # The grown-member path: the peers' reconcile added us.
            echo "kubenyx-etcd-join-probe: joining the existing cluster as a learner: $ic" >&2
          else
            # Already a declared voting member (fresh-founder race, or a
            # manual runbook add): same existing-state start.
            echo "kubenyx-etcd-join-probe: rejoining the existing cluster as a declared voting member: $ic" >&2
          fi
          write_env "$ic" existing
          exit 0
        elif [ "$?" = 2 ]; then
          echo "kubenyx-etcd-join-probe: concurrent first bootstrap detected (this node is already a declared voting member; other founders still unstarted); using the declared initial-cluster" >&2
          write_env "$declared" new
          exit 0
        fi
      done
      sleep 2
    done
    echo "KUBENYX-ETCD-JOIN-DEGRADED: a healthy cluster answered at $healthy_ep but this node's peer URL never appeared in the member list within 300s — kubenyx-etcd-reconcile on the running servers adds declared members one learner at a time; refusing to bootstrap a second cluster (the unit fails and retries)" >&2
    exit 1
  '';

  # etcd argument sets. The single-server list must render byte-identically
  # to v0.1 (cp-growth.org acceptance), so it stays a literal list; the
  # multi-server launcher reads the probe's initial-cluster decision at
  # start time (the one thing eval cannot know: joiners narrow it to the
  # runtime member set).
  etcdTlsArgs = [
    # Client-cert auth even on loopback: without it any local process
    # could write past RBAC (security review finding). Multi-server adds
    # the declared address as a second client listener (peers/etcdctl),
    # but the LOCAL apiserver keeps dialing loopback: internal.etcdServers
    # never changes.
    "--client-cert-auth"
    "--trusted-ca-file"
    "${pki}/ca.crt"
    "--cert-file"
    "${pki}/etcd-server.crt"
    "--key-file"
    "${pki}/etcd-server.key"
  ];
  etcdPeerTlsArgs = [
    # Peer port carries raft; leaving it plaintext would be the same local
    # RBAC bypass the client port closes. Same cert (SANs cover
    # localhost/127.0.0.1, plus every declared server address on
    # multi-server — see pki.nix), peer client-cert auth on.
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
  ++ ds.etcd.extraFlags;
  etcdStartScript = pkgs.writeShellScript "kubenyx-etcd-start" ''
    set -eu
    . '${clusterEnvFile}'
    exec ${
      lib.escapeShellArgs (
        [
          (lib.getExe' cfg.packages.etcd "etcd")
          "--name"
          etcdName
          "--data-dir"
          etcdDataDir
          "--listen-client-urls"
          "https://127.0.0.1:2379,${serverClientUrl thisNode}"
          "--advertise-client-urls"
          (serverClientUrl thisNode)
        ]
        ++ etcdTlsArgs
        ++ [
          "--listen-peer-urls"
          selfPeerUrl
          "--initial-advertise-peer-urls"
          selfPeerUrl
          # D1 timers (quorum-mesh.org): first raft-committed write 483ms
          # -> 143ms on the host bench, and the in-guest election wait
          # after storage bootstrap measured 0.26-1.19s on default
          # 100ms/1000ms — pure wall on every cold boot. el100 (not el50):
          # one >50ms vCPU scheduling stall under contention is a spurious
          # election, so 100ms is the safe floor the doc decided on. The
          # bridge RTT is ~0.1ms; a 10ms heartbeat is still 100x slack.
          # Multi-server only by construction: this script is exec'd only
          # on the multiServer branch (single-server flag list is a
          # byte-identity gate).
          "--heartbeat-interval"
          "10"
          "--election-timeout"
          "100"
        ]
        ++ etcdPeerTlsArgs
      )
    } \
      --initial-cluster "$KUBENYX_ETCD_INITIAL_CLUSTER" \
      --initial-cluster-state "$KUBENYX_ETCD_INITIAL_CLUSTER_STATE"
  '';

  # Declared-vs-runtime member reconcile (cp-growth.org §1). Learners are
  # the correctness core, not an optimization: a plain member-add of an
  # unstarted member COUNTS toward quorum — growing 1 -> 2 that way wedges
  # the cluster until the new member starts. A learner does not, so
  # unattended growth is safe at every intermediate step. One at a time is
  # etcd-enforced anyway (max-learners defaults to 1). Members are matched
  # by PEER URL, never name: unstarted members have no name in `member
  # list`, and the legacy single-server member republishes its name on the
  # first multi-server restart.
  etcdReconcile = pkgs.writeShellScript "kubenyx-etcd-reconcile" ''
    set -u
    declared='${etcdInitialCluster}'
    fp='${etcdDataDir}/.kubenyx-member-set'
    self='${cfg.nodeName}'
    self_peer='${selfPeerUrl}'
    eps='https://127.0.0.1:2379 ${lib.concatStringsSep " " declaredClientEps}'
    log() { echo "KUBENYX-ETCD-RECONCILE $*"; }

    # Try every endpoint: loopback first (free when this member votes),
    # then the declared set — learners reject member RPCs and the local
    # member may be down; any voting member serves the whole cluster.
    ctl() {
      for ep in $eps; do
        if out=$(${etcdCtl} --endpoints="$ep" ${ctlCreds} --dial-timeout=2s --command-timeout=5s "$@" 2>/dev/null); then
          printf '%s\n' "$out"
          return 0
        fi
      done
      return 1
    }
    declared_has_peer() {
      case ",$declared," in
        *"=$1,"*) return 0 ;;
      esac
      return 1
    }

    deadline=$(( $(date +%s) + 900 ))
    warned=" "
    while [ "$(date +%s)" -lt "$deadline" ]; do
      list=$(ctl member list) || {
        sleep 2
        continue
      }

      # Legacy 1 -> N transition: the single-server bootstrap advertised
      # the loopback peer URL. Only the member's own node moves it (the
      # name was republished as this nodeName on the multi-server
      # restart); everyone else waits — adding learners against a loopback
      # peer URL would hand joiners an initial-cluster that dials itself.
      loopback=$(printf '%s\n' "$list" | awk -F', ' '$4 == "https://127.0.0.1:2380" { print $1 "," $3 }')
      if [ -n "$loopback" ]; then
        lid=''${loopback%%,*}
        lname=''${loopback#*,}
        if [ "$lname" = "$self" ]; then
          if ctl member update "$lid" --peer-urls="$self_peer" >/dev/null; then
            log "moved legacy single-server peer URL to $self_peer (member $lid)"
          fi
        else
          log "waiting for $lname to move its legacy loopback peer URL"
        fi
        sleep 2
        continue
      fi

      # Never remove: members outside the declaration get a loud warning
      # citing the shrink runbook, once per member, and nothing else.
      extras=""
      while IFS= read -r row; do
        peer=$(printf '%s\n' "$row" | awk -F', ' '{print $4}')
        [ -n "$peer" ] || continue
        if ! declared_has_peer "$peer"; then
          extras="$extras $peer"
          mid=$(printf '%s\n' "$row" | awk -F', ' '{print $1}')
          case "$warned" in
            *" $mid "*) ;;
            *)
              warned="$warned$mid "
              log "WARNING: member $mid ($peer) is running but NOT in the declared server set. Refusing to remove it: shrinking the control plane is a destructive judgment call, not machinery (air/v0.1/quorum/cp-growth.org). Runbook: verify quorum health, then 'etcdctl member remove $mid' and drop the node from kubenyx.nodes."
              ;;
          esac
        fi
      done <<KUBENYX_EOF
    $list
    KUBENYX_EOF

      # One learner at a time (etcd enforces it; we sequence around it):
      # promote a started learner — the leader itself refuses until the
      # learner's raft log is in sync, so attempting IS the sync check —
      # and add nothing while any learner exists.
      learner=$(printf '%s\n' "$list" | awk -F', ' '$6 == "true" { print $1 "," $2 "," $4; exit }')
      if [ -n "$learner" ]; then
        lid=''${learner%%,*}
        rest=''${learner#*,}
        lstatus=''${rest%%,*}
        lpeer=''${rest#*,}
        if [ "$lstatus" = "started" ]; then
          if ctl member promote "$lid" >/dev/null; then
            log "promoted learner $lid ($lpeer) to voting member"
          else
            log "learner $lid ($lpeer) not in sync yet; retrying promotion"
          fi
        fi
        sleep 2
        continue
      fi

      # Missing members: add the first (name-sorted) as a LEARNER.
      missing=""
      set -f
      IFS=','
      for m in $declared; do
        peer=''${m#*=}
        if ! printf '%s\n' "$list" | grep -qF "$peer"; then
          missing=$m
          break
        fi
      done
      unset IFS
      set +f
      if [ -n "$missing" ]; then
        mname=''${missing%%=*}
        mpeer=''${missing#*=}
        if ctl member add "$mname" --learner --peer-urls="$mpeer" >/dev/null; then
          log "added $mname as learner ($mpeer)"
        else
          log "learner add for $mname pending (a concurrent reconcile may have won the race; retrying)"
        fi
        sleep 2
        continue
      fi

      # Converged when every declared member is a started voting member.
      all_in=1
      set -f
      IFS=','
      for m in $declared; do
        peer=''${m#*=}
        row=$(printf '%s\n' "$list" | awk -F', ' -v p="$peer" '$4 == p && $2 == "started" && $6 == "false"')
        [ -n "$row" ] || all_in=0
      done
      unset IFS
      set +f
      if [ "$all_in" = 1 ]; then
        if [ -z "$extras" ]; then
          if [ ! -e "$fp" ] || [ "$(cat "$fp")" != "$declared" ]; then
            printf '%s\n' "$declared" > "$fp".tmp && mv "$fp".tmp "$fp"
            log "runtime member set matches the declaration; recorded at $fp"
          fi
        else
          log "declared members all voting, but undeclared members remain ($extras); NOT recording the declared set"
        fi
        log "converged: $declared"
        exit 0
      fi
      sleep 2
    done
    log "did not converge within 900s (safe: the reconcile is idempotent — it reruns on the next boot/activation, or via 'systemctl restart kubenyx-etcd-reconcile')"
    exit 0
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
      joinProbeSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = ''
          Seconds a fresh multi-server member's join probe waits for an
          existing quorum before deciding first-bootstrap. The window is
          the safety margin against joining late vs splitting early
          (air/v0.1/quorum/quorum-mesh.org §D3); the 15s default preserves the
          original behavior. On an all-fresh cold boot the probe usually
          shortcuts it: when every declared peer actively REFUSES for
          three consecutive sweeps (nobody has state, all are fresh), it
          bootstraps immediately instead of burning the window — only
          peers that answer unhealthily or time out (possibly mid-boot
          WITH state) hold the probe to the full window.
        '';
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
          # Restart-after-activation on the quorum path (see the apiserver
          # unit for the measured rationale): the NixOS stop-early/
          # start-late default takes the datastore down for the whole
          # activation window; a post-reload restart is a ~2s blip that
          # the collocated apiserver's etcd client rides through.
          stopIfChanged = lib.mkIf multiServer false;
          # The guard/probe/launcher scripts need coreutils/awk/grep beyond
          # systemd's default path — plus curl, whose connect-error exit
          # codes are what lets the join probe tell an active refusal from
          # silence (etcdctl reports only pass/fail); gated so the
          # single-server unit text stays byte-identical to v0.1.
          path = lib.mkIf multiServer [
            pkgs.coreutils
            pkgs.curl
            pkgs.gawk
            pkgs.gnugrep
          ];
          serviceConfig = {
            Type = "notify";
            NotifyAccess = "all";
            # Multi-server covers the join wait (probe window + learner add
            # by a peer's reconcile + catch-up until /readyz greens — a
            # learner fails the linearizable readyz check until promoted).
            TimeoutStartSec = if multiServer then 900 else 120;
            # Multi-server only: the member-set guard gates bootstrap flags
            # against the recorded membership, then the join probe decides
            # bootstrap-vs-join (cp-growth.org §3) and writes the
            # initial-cluster the launcher execs with. The single-server
            # unit stays byte-identical to v0.1.
            ExecStartPre = lib.mkIf multiServer [
              "${etcdMemberGuard}"
              "${etcdJoinProbe}"
            ];
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
              ]
              ++ (
                if multiServer then
                  # The launcher carries every static flag; only
                  # --initial-cluster(-state) come from the probe's decision
                  # at start time.
                  [ "${etcdStartScript}" ]
                else
                  [
                    (lib.getExe' cfg.packages.etcd "etcd")
                    "--name"
                    etcdName
                    "--data-dir"
                    etcdDataDir
                    "--listen-client-urls"
                    "https://127.0.0.1:2379"
                    "--advertise-client-urls"
                    "https://127.0.0.1:2379"
                  ]
                  ++ etcdTlsArgs
                  ++ [
                    "--listen-peer-urls"
                    "https://127.0.0.1:2380"
                    "--initial-advertise-peer-urls"
                    "https://127.0.0.1:2380"
                    "--initial-cluster"
                    etcdInitialCluster
                  ]
                  ++ etcdPeerTlsArgs
              )
            );
            Restart = "always";
            RestartSec = 2;
            SuccessExitStatus = "143"; # notify-wrapper exit on orderly stop
            StateDirectory = lib.mkIf (!ds.volatile) "etcd";
          };
        };

        # Declared-vs-runtime member reconcile (cp-growth.org §1): one shot
        # of convergence per boot AND per activation — the declared set is
        # baked into the script text, so any membership change makes
        # switch-to-configuration restart the (RemainAfterExit) unit.
        # Type=exec: the start job completes at spawn, so neither boot nor
        # switch ever blocks on convergence — the script waits out learner
        # catch-up in the background and exits when runtime matches the
        # declaration (or after 900s, warned, converging further on the
        # next run). Safe on every server concurrently: adds are rejected
        # as duplicates, promotes of in-sync learners are idempotent, and
        # nothing is ever removed.
        systemd.services.kubenyx-etcd-reconcile = lib.mkIf multiServer {
          description = "Kubenyx etcd member reconcile (declared vs runtime)";
          wantedBy = [ "kubenyx.target" ];
          after = [ "etcd.service" ];
          path = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.gnugrep
          ];
          serviceConfig = {
            Type = "exec";
            RemainAfterExit = true;
            ExecStart = "${etcdReconcile}";
          };
        };
      })
    ]
  );
}
