# microVM guest + mesh construction (air/v0.2/multinode-microvm.org),
# exported as flake `lib.microvm` so consumer flakes can instantiate a
# mesh at ANY size — the flake's own cp1w2/cp1w6 presets are just two
# calls into this file:
#
#   kubenyx.lib.microvm.mkCluster {
#     pkgs = nixpkgs.legacyPackages.x86_64-linux;
#     agents = 9;                     # 1 control plane + 9 workers
#     name = "cp1w9";                 # launcher binary + console prefix
#     runDir = "/tmp/kubenyx-cp1w9";  # per-size run dir; snapshots coexist
#   }
#   => { members, bootOrder, nodes, runners, launcher, shutdown }
#
# `servers` is declared in the signature but pinned to 1 for now:
# etcd-mem is single-member by design (modules/datastore.nix asserts it)
# and the volatile mesh self-mints its CA on the server — a multi-server
# microVM mesh needs the real-etcd quorum posture plus a host-side CA
# custody ship. The module itself already runs multi-server on NixOS
# hosts (tests/multi-server.nix); the microVM quorum preset is tracked
# work, not a missing assert.
#
# Unlike lib/default.nix and lib/harness.nix this file is flake-coupled:
# the caller must supply `nixosSystem` and the base module list (the
# microvm.nix module, the kubenyx module, the shared guest profile) —
# the kubenyx flake bakes them, flake-free callers can too.
{
  lib,
  nixosSystem,
  baseModules,
}:
rec {
  mkMicrovm =
    hypervisor: extra:
    nixosSystem {
      system = "x86_64-linux";
      modules = baseModules ++ [
        {
          microvm = {
            inherit hypervisor;
            vcpu = 4;
            mem = 3584;
          };
        }
        extra
      ];
    };

  # One guest NIC with a static address — the stanza every microVM
  # variant repeats: the interface (tap/user + id) is per-variant, the
  # MAC keys the systemd.network match, and address/gateway complete
  # the static config (no DHCP anywhere in these guests).
  mkGuestNet =
    {
      interface,
      mac,
      address,
      gateway,
    }:
    {
      microvm.interfaces = [ (interface // { inherit mac; }) ];
      systemd.network.networks."05-kubenyx" = {
        matchConfig.MACAddress = mac;
        address = [ "${address}/24" ];
        routes = [ { Gateway = gateway; } ];
      };
    };

  # One nodes attrset drives everything: per-node runners, taps, MACs,
  # addresses, membership, pod-CIDR carving, and the per-agent credential
  # handoff ports (10125 + sorted-agent position, derived independently
  # by server and agents from this same attrset).
  #   server: kubenyx-tap0, 02:...:01, 10.100.0.2
  #   agentN: kubenyx-tapN, 02:...:N+1, 10.100.0.(2+N)
  mkMembers =
    {
      servers ? 1,
      agents,
    }:
    assert lib.assertMsg (servers == 1) ''
      kubenyx.lib.microvm: multi-server microVM meshes are not wired yet —
      etcd-mem is single-member and the volatile mesh self-mints its CA on
      the server, so a quorum needs the real-etcd posture + host-side CA
      ship. The module supports multi-server on NixOS hosts today
      (tests/multi-server.nix).'';
    {
      server = {
        index = 0;
        address = "10.100.0.2";
        role = "server";
      };
    }
    // lib.listToAttrs (
      map (
        i:
        lib.nameValuePair "agent${toString i}" {
          index = i;
          address = "10.100.0.${toString (2 + i)}";
          role = "agent";
        }
      ) (lib.range 1 agents)
    );

  # Boot order: server first (agents' credential fetch retries anyway,
  # but the server owns the whole readiness chain), then agents in
  # parallel. Teardown reverses this.
  bootOrderFor =
    members: [ "server" ] ++ lib.attrNames (lib.filterAttrs (_: n: n.role == "agent") members);

  mkNode =
    members: name:
    let
      n = members.${name};
      mac = "02:00:00:00:00:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString (n.index + 1)))}";
    in
    mkMicrovm "firecracker" {
      imports = [
        (mkGuestNet {
          interface = {
            type = "tap";
            id = "kubenyx-tap${toString n.index}";
          };
          inherit mac;
          address = n.address;
          gateway = "10.100.0.1";
        })
      ];
      networking.hostName = name;
      # Same snapshot-safe xstate config as the single-node firecracker
      # variant (see its comment) — mesh snapshotting is phase 2, but
      # keeping the kernels identical costs nothing.
      boot.kernelParams = [
        "clearcpuid=amx_tile,amx_int8,amx_bf16"
        "noxsaves"
      ];
      kubenyx = {
        nodes = members;
      }
      // lib.optionalAttrs (n.role == "agent") {
        role = "agent";
        controlPlaneEndpoint = members.server.address;
      };
    };

  # Host datapath decision, stated plainly (review finding on
  # multinode-microvm.org §2): the guest modules assume L2 adjacency
  # between node addresses — each guest holds its /24 on-link and
  # resolves peers by ARP, and kubenyx-routes points peer pod /24s
  # `via` peer node addresses. Separate unbridged taps cannot
  # provide that, so the launcher enslaves the per-node taps into
  # one host bridge (kubenyx-br0) holding the 10.100.0.1/24 gateway.
  # Consequence: on a shared L2 a compromised guest could spoof
  # another agent's source address, so the per-agent IPAddressAllow
  # on the credential handoff sockets is advisory here, not a
  # boundary — accepted within the disposable trust model (network
  # positions declared in Nix, host-local taps, volatile clusters;
  # an agent can already reach the apiserver with its own creds).
  # The single-node flow keeps working afterwards: the bridge
  # answers for 10.100.0.1 whether one tap is enslaved or three.
  mkCluster =
    {
      pkgs,
      agents,
      servers ? 1,
      name ? "kubenyx-cluster",
      runDir ? "/tmp/${name}",
    }:
    let
      members = mkMembers { inherit servers agents; };
      bootOrder = bootOrderFor members;
      nodes = lib.genAttrs bootOrder (mkNode members);
      runners = lib.mapAttrs (_: node: node.config.microvm.declaredRunner) nodes;
      tapFor = n: "kubenyx-tap${toString members.${n}.index}";
      hostTools = lib.makeBinPath (
        with pkgs;
        [
          iproute2
          coreutils
          gnused
          gnugrep
          procps
          curl
        ]
      );

      launcher = pkgs.writeShellScriptBin name ''
        set -euo pipefail
        export PATH=${hostTools}''${PATH:+:$PATH}

        BR=kubenyx-br0
        RUN="''${KUBENYX_CLUSTER_DIR:-${runDir}}"

        if pgrep -x firecracker >/dev/null 2>&1; then
          echo "${name}: a firecracker VM is already running — the kubenyx tap family is exclusive; run ${name}-down (or kill it) first" >&2
          exit 1
        fi

        echo "${name}: configuring host bridge $BR + taps (sudo)"
        sudo ip link add "$BR" type bridge 2>/dev/null || true
        sudo ip addr replace 10.100.0.1/24 dev "$BR"
        sudo ip link set "$BR" up
        for tap in ${lib.concatMapStringsSep " " tapFor bootOrder}; do
          # Recreate each tap: guarantees current-user ownership (so
          # firecracker opens it unprivileged) and clears any stale
          # standalone address — the single-node instructions put
          # 10.100.0.1/24 on kubenyx-tap0 itself; the bridge owns it now.
          sudo ip link del "$tap" 2>/dev/null || true
          sudo ip tuntap add "$tap" mode tap user "$(id -un)"
          sudo ip link set "$tap" master "$BR" up
        done

        rm -rf "$RUN"
        mkdir -p "$RUN"

        cleanup() {
          pkill -x firecracker 2>/dev/null || true
        }
        trap cleanup INT TERM

        start_ns=$(date +%s%N)

        launch() {
          node=$1
          runner=$2
          mkdir -p "$RUN/$node"
          : > "$RUN/$node/console.log"
          # Short CWD per node: firecracker's API socket is a relative
          # path and must stay under SUN_LEN. Consoles merge onto our
          # stdout with a node-name prefix; the unprefixed copy lands
          # in console.log for the readiness grep.
          (
            cd "$RUN/$node" && exec "$runner"
          ) </dev/null 2>&1 \
            | tee -a "$RUN/$node/console.log" \
            | sed -u "s/^/[$node] /" &
        }

        ${lib.concatMapStringsSep "\n" (n: "launch ${n} ${runners.${n}}/bin/microvm-run") bootOrder}

        deadline=$(( $(date +%s) + 180 ))
        ready=0
        while [ "$(date +%s)" -lt "$deadline" ]; do
          ready=0
          for node in ${toString bootOrder}; do
            if grep -q KUBENYX-CLUSTER-READY "$RUN/$node/console.log" 2>/dev/null; then
              ready=$((ready + 1))
            fi
          done
          if [ "$ready" -eq ${toString (lib.length bootOrder)} ]; then break; fi
          sleep 0.2
        done
        wall_ms=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
        if [ "$ready" -eq ${toString (lib.length bootOrder)} ]; then
          echo "KUBENYX-MESH-READY nodes=$ready wall=''${wall_ms}ms"
          echo "KUBENYX-KUBECONFIG curl -s ${members.server.address}:10124 > kubenyx.kubeconfig"
        else
          echo "KUBENYX-MESH-DEGRADED: $ready/${toString (lib.length bootOrder)} nodes ready after 180s — consoles in $RUN/<node>/console.log" >&2
        fi
        wait
      '';

      shutdown = pkgs.writeShellScriptBin "${name}-down" ''
        set -uo pipefail
        export PATH=${hostTools}''${PATH:+:$PATH}
        RUN="''${KUBENYX_CLUSTER_DIR:-${runDir}}"

        # Graceful first (CtrlAltDel over the API socket), but with an
        # escalation ladder: firecracker's i8042 never probes in these
        # guests ("i8042 probe failed with error -22" at boot), so
        # CtrlAltDel is best-effort and SIGTERM/SIGKILL finish the job —
        # every mesh VM is disposable by design. The runner names each
        # VMM process microvm@<node> (exec -a), which is what pgrep/
        # pkill -f match on.
        stop_node() {
          node=$1
          pgrep -f "^microvm@$node" >/dev/null 2>&1 || return 0
          echo "${name}-down: $node"
          if [ -S "$RUN/$node/$node.sock" ]; then
            curl -s --max-time 3 --unix-socket "$RUN/$node/$node.sock" \
              -X PUT http://localhost/actions \
              -d '{ "action_type": "SendCtrlAltDel" }' >/dev/null 2>&1 || true
          fi
          for _ in $(seq 1 25); do
            pgrep -f "^microvm@$node" >/dev/null 2>&1 || return 0
            sleep 0.2
          done
          pkill -TERM -f "^microvm@$node" 2>/dev/null || true
          for _ in $(seq 1 25); do
            pgrep -f "^microvm@$node" >/dev/null 2>&1 || return 0
            sleep 0.2
          done
          pkill -KILL -f "^microvm@$node" 2>/dev/null || true
        }

        # Reverse boot order: agents drain first, the server last.
        ${lib.concatMapStringsSep "\n" (n: "stop_node ${n}") (lib.reverseList bootOrder)}
        # Settle before judging: the last VMM may still be mid-exit.
        for _ in $(seq 1 25); do
          pgrep -x firecracker >/dev/null 2>&1 || break
          sleep 0.2
        done
        if pgrep -x firecracker >/dev/null 2>&1; then
          echo "${name}-down: firecracker still running — pkill -x firecracker if it is wedged" >&2
          exit 1
        fi
        echo "${name}-down: all nodes down"
      '';
    in
    {
      inherit
        members
        bootOrder
        nodes
        runners
        launcher
        shutdown
        ;
    };
}
