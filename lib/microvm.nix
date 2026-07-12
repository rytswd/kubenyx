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
# `servers > 1` builds a real etcd quorum (air/v0.7/quorum-mesh.org):
# the launcher mints one CA per run and serves it over the bridge before
# any VM boots (§D2), servers switch to backend = "etcd" (§D1), and
# agents ride kubenyx-lb instead of a declared endpoint (§D6).
# `servers == 1` keeps the single node name "server" so the cp1 presets'
# node names, taps, MACs, addresses — and therefore their drvs and
# launcher scripts — stay byte-identical (§D5, hard requirement).
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
  # by server and agents from this same attrset). The index drives tap,
  # MAC and address, so the mesh stays collision-free at any size:
  #   serverN: index N-1, agents pack after at index servers..s+a-1
  #   node:    kubenyx-tap<index>, 02:...:<index+1>, 10.100.0.(2+index)
  mkMembers =
    {
      servers ? 1,
      agents,
    }:
    assert lib.assertMsg (servers >= 1) "kubenyx.lib.microvm: a mesh needs at least one server";
    assert lib.assertMsg (2 + servers + agents <= 254) ''
      kubenyx.lib.microvm: ${toString servers} servers + ${toString agents} agents
      do not fit the 10.100.0.0/24 host bridge (guest addresses start at .2).'';
    let
      # servers == 1 keeps the single name "server": cp1w2/cp1w6 node
      # names, taps, MACs and addresses — and therefore their drvs — stay
      # byte-identical (quorum-mesh.org §D5, hard requirement).
      serverFor =
        i:
        lib.nameValuePair (if servers == 1 then "server" else "server${toString i}") {
          index = i - 1;
          address = "10.100.0.${toString (1 + i)}";
          role = "server";
        };
      agentFor =
        i:
        lib.nameValuePair "agent${toString i}" {
          index = servers + i - 1;
          address = "10.100.0.${toString (1 + servers + i)}";
          role = "agent";
        };
    in
    lib.listToAttrs (map serverFor (lib.range 1 servers) ++ map agentFor (lib.range 1 agents));

  # Boot order: servers first (agents' credential fetch retries anyway,
  # but the servers own the whole readiness chain), then agents. Launch
  # stays fully parallel — the order only names teardown's reverse.
  bootOrderFor =
    members:
    lib.attrNames (lib.filterAttrs (_: n: n.role == "server") members)
    ++ lib.attrNames (lib.filterAttrs (_: n: n.role == "agent") members);

  mkNode =
    {
      members,
      joinProbeSec ? 3,
    }:
    name:
    let
      n = members.${name};
      # Derived from the membership itself (not a caller flag) so mkNode
      # stays a pure function of its inputs — the same gate the modules
      # compute from kubenyx.nodes (modules/pki.nix, modules/datastore.nix).
      multiServer = lib.count (m: m.role == "server") (lib.attrValues members) > 1;
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
      // lib.optionalAttrs (n.role == "agent") (
        {
          role = "agent";
        }
        # Multi-server agents declare NO endpoint, so lb.enable's default
        # turns kubenyx-lb on and every agent kubeconfig dials
        # https://127.0.0.1:6444 — the tests/multi-server.nix posture
        # (quorum-mesh.org §D6). Single-server agents keep the declared
        # endpoint, byte-identical to before.
        // lib.optionalAttrs (!multiServer) {
          controlPlaneEndpoint = members.server.address;
        }
      )
      # A quorum needs real raft: the guest profile's etcd-mem default is
      # single-member by design, so multi-server servers flip to the etcd
      # backend (volatile stays on — tmpfs data dir, quorum-mesh.org §D1)
      # and carry the launcher-chosen join-probe window (§D3).
      // lib.optionalAttrs (multiServer && n.role == "server") {
        datastore.backend = "etcd";
        datastore.etcd.joinProbeSec = joinProbeSec;
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
      # 3s is the D3 measured candidate (a live quorum on the host bridge
      # answers `endpoint health` in <1s, dead peers refuse instantly);
      # the 15-vs-3 cold-wall A/B is still pending, and the value is only
      # rendered for servers > 1 — single-server drvs never see it.
      joinProbeSec ? 3,
      name ? "kubenyx-cluster",
      runDir ? "/tmp/${name}",
    }:
    let
      multiServer = servers > 1;
      members = mkMembers { inherit servers agents; };
      bootOrder = bootOrderFor members;
      nodes = lib.genAttrs bootOrder (mkNode {
        inherit members joinProbeSec;
      });
      runners = lib.mapAttrs (_: node: node.config.microvm.declaredRunner) nodes;
      tapFor = n: "kubenyx-tap${toString members.${n}.index}";
      # Every server serves its own address-pinned admin kubeconfig on
      # :10124 (quorum-mesh.org §D7): print one curl per server — on
      # server loss, re-curl a survivor. In boot order, so servers == 1
      # renders the exact single line it always did.
      serverAddresses = map (n: members.${n}.address) (
        lib.filter (n: members.${n}.role == "server") bootOrder
      );
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
      # Driver-side kubenyx-pki, the same derivation the guests run as
      # internal.tools (mirrors tests/multi-server.nix). Referenced only
      # from multi-server-gated launcher lines, so single-server launcher
      # closures never pull it in.
      kubenyxPki = lib.getExe' (pkgs.callPackage ../pkgs/kubenyx-tools.nix { }) "kubenyx-pki";
      # Absolute path like kubenyxPki (NOT hostTools: that would change the
      # single-server launchers' PATH line and break their byte-identity).
      iptablesBin = lib.getExe' pkgs.iptables "iptables";
      # Launcher CA channel (quorum-mesh.org §D2), rendered only for
      # servers > 1 so the cp1 launcher text stays byte-identical. Mint
      # one CA into the run dir and serve it as a tar on the bridge
      # BEFORE any VM launches — three self-minted CAs would make etcd
      # peer TLS reject every raft connection (no quorum, looks like a
      # hang). The serve step must follow the bridge setup above: it
      # binds the bridge's own 10.100.0.1. --count makes it exit after
      # every server has actually landed the bundle.
      caServe = lib.optionalString multiServer (
        lib.concatStringsSep "\n" [
          # The CA fetch is the mesh's only guest→host flow (kubeconfig and
          # clockstep go host→guest, the agent bundle rides guest→guest), so
          # a default-deny host firewall refuses it silently: 90 s of guest
          # retries, then a loud ca-fetch abort — while curl from the host
          # itself works, because loopback-delivered traffic never crosses
          # the refuse chain. Same sudo trust as the tap/bridge setup;
          # delete-then-insert keeps re-runs from stacking duplicates, and
          # the -down script removes the rule with the run.
          ''sudo ${iptablesBin} -D INPUT -i "$BR" -p tcp --dport 10123 -j ACCEPT 2>/dev/null || true''
          ''sudo ${iptablesBin} -I INPUT 1 -i "$BR" -p tcp --dport 10123 -j ACCEPT''
          ''echo "${name}: minting the per-run CA bundle"''
          ''${kubenyxPki} mint-ca --out "$RUN/ca-bundle"''
          ''${kubenyxPki} serve --dir "$RUN/ca-bundle" --listen 10.100.0.1:10123 --count ${toString servers} > "$RUN/ca-serve.log" 2>&1 &''
          "ca_pid=$!"
          ""
          ""
        ]
      );
      # The bundle and its serve process die with the run — per-run trust
      # material, never operator custody (§D2). Rendered into cleanup()'s
      # 2-space body indentation, trailing entry re-indents pkill.
      caTeardown = lib.optionalString multiServer (
        lib.concatStringsSep "\n  " [
          ''kill "$ca_pid" 2>/dev/null || true''
          ''rm -rf "$RUN/ca-bundle"''
          ''sudo ${iptablesBin} -D INPUT -i "$BR" -p tcp --dport 10123 -j ACCEPT 2>/dev/null || true''
          ""
        ]
      );
      # Posture manifest for kubenyx-snap mesh-take (quorum-mesh.org §D8):
      # the snapshot tool sees run dirs and firecracker APIs, never guest
      # config, so the launcher — which holds the eval — records members
      # and posture at launch. mesh-take refuses a multi-server snapshot
      # without a volatile manifest: firecracker snapshots exclude virtio
      # disk contents, so resuming a durable quorum against mutated disks
      # corrupts etcd. Durability mirrors modules/pki.nix durablePosture
      # (profile balanced + non-volatile datastore), checked on EVERY node
      # — any disk that keeps moving poisons the mesh cut. Rendered only
      # for servers > 1: writing it for all sizes would change the
      # cp1w2/cp1w6 launcher text and break their drv byte-identity (§D5);
      # single-server discovery stays on the address convention.
      meshManifest = builtins.toJSON {
        posture =
          if
            lib.any (
              n: nodes.${n}.config.kubenyx.profile == "balanced" && !nodes.${n}.config.kubenyx.datastore.volatile
            ) bootOrder
          then
            "durable"
          else
            "volatile";
        nodes = map (n: {
          name = n;
          ip = members.${n}.address;
          role = members.${n}.role;
        }) bootOrder;
      };
      meshManifestWrite = lib.optionalString multiServer (
        lib.concatStringsSep "\n" [
          ''printf '%s\n' ${lib.escapeShellArg meshManifest} > "$RUN/kubenyx-mesh.json"''
          ""
          ""
        ]
      );
      # The -down script is the normal exit path (the launcher's trap only
      # covers INT/TERM, and its `wait` returns exactly when -down kills the
      # VMs), so the per-run trust surface dies here: the CA-port accept,
      # the bundle with its private keys, and — after a degraded run where
      # fewer than N servers fetched — the still-listening serve process.
      caShutdown = lib.optionalString multiServer (
        lib.concatStringsSep "\n" [
          "sudo ${iptablesBin} -D INPUT -i kubenyx-br0 -p tcp --dport 10123 -j ACCEPT 2>/dev/null || true"
          ''pkill -f "kubenyx-pki serve --dir $RUN/ca-bundle" 2>/dev/null || true''
          ''rm -rf "$RUN/ca-bundle"''
          ""
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

        ${meshManifestWrite}cleanup() {
          ${caTeardown}pkill -x firecracker 2>/dev/null || true
        }
        trap cleanup INT TERM

        ${caServe}start_ns=$(date +%s%N)

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
          ${lib.concatMapStringsSep "\n  " (
            a: ''echo "KUBENYX-KUBECONFIG curl -s ${a}:10124 > kubenyx.kubeconfig"''
          ) serverAddresses}
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
        ${caShutdown}echo "${name}-down: all nodes down"
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
