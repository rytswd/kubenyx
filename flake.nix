{
  description = "Kubenyx — drop-in stock Kubernetes for NixOS, tuned for uncompromising startup speed";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # MicroVM runners for disposable test clusters: firecracker /
    # cloud-hypervisor boot the guest profile to cluster-ready in
    # single-digit seconds on any KVM host.
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkMicrovm =
        hypervisor: extra:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            self.nixosModules.default
            ./guests/microvm.nix
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

      # ---- multi-node microVM mesh (air/v0.2/multinode-microvm.org §2) ------
      # One nodes attrset drives everything: per-node runners, taps, MACs,
      # addresses, membership, pod-CIDR carving, and the per-agent credential
      # handoff ports (10125 + sorted-agent position, derived independently
      # by server and agents from this same attrset).
      #   server: kubenyx-tap0, 02:...:01, 10.100.0.2
      #   agentN: kubenyx-tapN, 02:...:N+1, 10.100.0.(2+N)
      mkMicrovmClusterMembers =
        agents:
        {
          server = {
            index = 0;
            address = "10.100.0.2";
            role = "server";
          };
        }
        // nixpkgs.lib.listToAttrs (
          map (
            i:
            nixpkgs.lib.nameValuePair "agent${toString i}" {
              index = i;
              address = "10.100.0.${toString (2 + i)}";
              role = "agent";
            }
          ) (nixpkgs.lib.range 1 agents)
        );
      # Boot order: server first (agents' credential fetch retries anyway,
      # but the server owns the whole readiness chain), then agents in
      # parallel. Teardown reverses this.
      clusterBootOrderFor =
        members:
        [ "server" ] ++ nixpkgs.lib.attrNames (nixpkgs.lib.filterAttrs (_: n: n.role == "agent") members);
      # Two mesh sizes: the 3-node default and a 7-node variant (1 server +
      # 6 agents) for scale measurements. Same generator, same conventions
      # (taps kubenyx-tap<index>, addresses 10.100.0.(2+index)).
      clusterMembers = mkMicrovmClusterMembers 2;
      clusterBootOrder = clusterBootOrderFor clusterMembers;
      cluster7Members = mkMicrovmClusterMembers 6;
      cluster7BootOrder = clusterBootOrderFor cluster7Members;

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
      # The implicit one-node membership every single-node variant declares.
      mkSingleNodeMembership = address: {
        kubenyx.nodes.kubenyx = {
          index = 0;
          inherit address;
          role = "server";
        };
      };

      mkMicrovmClusterNode =
        members: name:
        let
          n = members.${name};
          mac = "02:00:00:00:00:${
            nixpkgs.lib.fixedWidthString 2 "0" (nixpkgs.lib.toLower (nixpkgs.lib.toHexString (n.index + 1)))
          }";
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
          // nixpkgs.lib.optionalAttrs (n.role == "agent") {
            role = "agent";
            controlPlaneEndpoint = members.server.address;
          };
        };
    in
    {
      nixosModules.kubenyx = import ./modules;
      nixosModules.default = self.nixosModules.kubenyx;

      nixosConfigurations =
        let
          # Single-node tap identity shared by the KVM variants: the mesh
          # launcher owns the host side these days (kubenyx-br0 holds
          # 10.100.0.1/24 with kubenyx-tap0 enslaved — see mkClusterLauncher);
          # for a tapless host, create the tap and either bridge it the same
          # way or put 10.100.0.1/24 directly on it. The firecracker and
          # cloud-hypervisor variants are alternatives: they share the tap
          # id, MAC and guest IP — run one at a time.
          singleNodeTapNet = mkGuestNet {
            interface = {
              type = "tap";
              id = "kubenyx-tap0";
            };
            mac = "02:00:00:00:00:01";
            address = "10.100.0.2";
            gateway = "10.100.0.1";
          };
        in
        {
          # KVM hosts: `nix run .#microvm-firecracker`.
          microvm-firecracker = mkMicrovm "firecracker" {
            imports = [
              singleNodeTapNet
              (mkSingleNodeMembership "10.100.0.2")
            ];
            # Snapshot-safe xstate config (measured: no boot cost, 8.74s vs
            # 8.31s baseline is within run variance). Restoring a snapshot
            # into a FRESH firecracker process on AMX hosts (Granite Rapids)
            # kernel-panics in restore_fpregs_from_fpstate: XRSTORS #GP on
            # the AMX tile state (the new VMM never re-acquires the AMX
            # xstate permission) and again on IA32_XSS-managed CET state.
            # Masking AMX CPUID alone is not enough — noxsaves removes all
            # supervisor xstates from XSAVES so the snapshot carries none.
            boot.kernelParams = [
              "clearcpuid=amx_tile,amx_int8,amx_bf16"
              "noxsaves"
            ];
          };
          microvm-cloud-hypervisor = mkMicrovm "cloud-hypervisor" {
            imports = [
              singleNodeTapNet
              (mkSingleNodeMembership "10.100.0.2")
            ];
          };
          # SLiRP user networking; runs anywhere (KVM with TCG fallback) —
          # this is the variant CI/KVM-less machines can execute. q35: the
          # `microvm` machine type needs KVM's in-kernel irqchip (pic=off)
          # and cannot fall back to TCG.
          microvm-qemu = mkMicrovm "qemu" {
            imports = [
              (mkGuestNet {
                interface = {
                  type = "user";
                  id = "u0";
                };
                mac = "02:00:00:00:00:01";
                address = "10.0.2.15";
                gateway = "10.0.2.2"; # SLiRP gateway
              })
              (mkSingleNodeMembership "10.0.2.15")
            ];
            microvm.qemu.machine = "q35";
            # Explicit CPU model drops -enable-kvm/-cpu host from the runner
            # (microvm.nix's emulation escape hatch). KVM hosts should use
            # the firecracker/cloud-hypervisor variants instead.
            microvm.cpu = "max";
          };
        }
        # Mesh nodes: microvm-cluster-server, microvm-cluster-agent1, … —
        # per-node firecracker variants generated from the members sets.
        // nixpkgs.lib.listToAttrs (
          map (
            name: nixpkgs.lib.nameValuePair "microvm-cluster-${name}" (mkMicrovmClusterNode clusterMembers name)
          ) clusterBootOrder
        )
        // nixpkgs.lib.listToAttrs (
          map (
            name:
            nixpkgs.lib.nameValuePair "microvm-cluster7-${name}" (mkMicrovmClusterNode cluster7Members name)
          ) cluster7BootOrder
        );

      lib = import ./lib { inherit (nixpkgs) lib; };

      packages = forAllSystems (
        pkgs:
        {
          kubenyx-tools = pkgs.callPackage ./pkgs/kubenyx-tools.nix { };
          # Agent-side apiserver LB for multi-server clusters (durable-ha
          # §4). Separate from kubenyx-tools on purpose: single-server guest
          # closures must not grow (the module only references this package
          # when lb.enable gates it on).
          kubenyx-lb = pkgs.callPackage ./pkgs/kubenyx-lb.nix { };
          # Host-side snapshot/restore CLI with the matching firecracker on
          # PATH (snapshots are only portable across identical VMM versions).
          # take: boot the runner to cluster-ready and write snap.vmstate +
          # snap.mem; resume: fresh VMM + /snapshot/load + time pokes, ~75ms
          # to a serving apiserver; cycle: the recreation benchmark.
          kubenyx-snap = pkgs.writeShellScriptBin "kubenyx-snap" ''
            export PATH=${pkgs.firecracker}/bin:$PATH
            exec ${self.packages.${pkgs.stdenv.hostPlatform.system}.kubenyx-tools}/bin/kubenyx-snap "$@"
          '';
          pause-image = pkgs.callPackage ./pkgs/pause-image.nix { };
          test-image = pkgs.callPackage ./pkgs/test-image.nix { };
          native-bench = pkgs.callPackage ./pkgs/native-bench.nix { kine = pkgs.kine; };
        }
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
          let
            lib = nixpkgs.lib;
            clusterRunnerFor =
              prefix: name: self.nixosConfigurations."${prefix}-${name}".config.microvm.declaredRunner;
            clusterTapFor = members: name: "kubenyx-tap${toString members.${name}.index}";
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
            mkClusterLauncher =
              {
                binName,
                prefix,
                members,
                bootOrder,
                runDir,
              }:
              pkgs.writeShellScriptBin binName ''
                set -euo pipefail
                export PATH=${hostTools}''${PATH:+:$PATH}

                BR=kubenyx-br0
                RUN="''${KUBENYX_CLUSTER_DIR:-${runDir}}"

                if pgrep -x firecracker >/dev/null 2>&1; then
                  echo "${binName}: a firecracker VM is already running — the kubenyx tap family is exclusive; run ${binName}-shutdown (or kill it) first" >&2
                  exit 1
                fi

                echo "${binName}: configuring host bridge $BR + taps (sudo)"
                sudo ip link add "$BR" type bridge 2>/dev/null || true
                sudo ip addr replace 10.100.0.1/24 dev "$BR"
                sudo ip link set "$BR" up
                for tap in ${lib.concatMapStringsSep " " (clusterTapFor members) bootOrder}; do
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

                ${lib.concatMapStringsSep "\n" (
                  name: "launch ${name} ${clusterRunnerFor prefix name}/bin/microvm-run"
                ) bootOrder}

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

            mkClusterShutdown =
              {
                binName,
                bootOrder,
                runDir,
              }:
              pkgs.writeShellScriptBin "${binName}-shutdown" ''
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
                  echo "${binName}-shutdown: $node"
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
                ${lib.concatMapStringsSep "\n" (name: "stop_node ${name}") (lib.reverseList bootOrder)}
                # Settle before judging: the last VMM may still be mid-exit.
                for _ in $(seq 1 25); do
                  pgrep -x firecracker >/dev/null 2>&1 || break
                  sleep 0.2
                done
                if pgrep -x firecracker >/dev/null 2>&1; then
                  echo "${binName}-shutdown: firecracker still running — pkill -x firecracker if it is wedged" >&2
                  exit 1
                fi
                echo "${binName}-shutdown: all nodes down"
              '';
            cluster3 = {
              binName = "microvm-cluster";
              prefix = "microvm-cluster";
              members = clusterMembers;
              bootOrder = clusterBootOrder;
              runDir = "/tmp/kubenyx-cluster";
            };
            cluster7 = {
              binName = "microvm-cluster7";
              prefix = "microvm-cluster7";
              members = cluster7Members;
              bootOrder = cluster7BootOrder;
              runDir = "/tmp/kubenyx-cluster7";
            };
          in
          lib.listToAttrs (
            map (
              name: lib.nameValuePair "microvm-cluster-${name}" (clusterRunnerFor "microvm-cluster" name)
            ) clusterBootOrder
          )
          // lib.listToAttrs (
            map (
              name: lib.nameValuePair "microvm-cluster7-${name}" (clusterRunnerFor "microvm-cluster7" name)
            ) cluster7BootOrder
          )
          // {
            microvm-cluster = mkClusterLauncher cluster3;
            microvm-cluster-shutdown = mkClusterShutdown { inherit (cluster3) binName bootOrder runDir; };
            microvm-cluster7 = mkClusterLauncher cluster7;
            microvm-cluster7-shutdown = mkClusterShutdown { inherit (cluster7) binName bootOrder runDir; };
            microvm-firecracker = self.nixosConfigurations.microvm-firecracker.config.microvm.declaredRunner;
            # cloud-hypervisor's microvm.nix runner hardcodes --net
            # num_queues=2*vcpu (tapMultiQueue is a hypervisor property, not
            # an option), which fatally errors (MultiQueueNoTapSupport) on the
            # plain single-queue tap the firecracker variant shares. Pin one
            # queue pair (num_queues=2 = 1 RX + 1 TX — exactly what a plain
            # tap provides). Boot-path cost: none measured; only bulk net
            # throughput would notice fewer queues.
            microvm-cloud-hypervisor =
              let
                runner = self.nixosConfigurations.microvm-cloud-hypervisor.config.microvm.declaredRunner;
              in
              pkgs.runCommand "microvm-cloud-hypervisor-single-queue"
                {
                  nativeBuildInputs = [ pkgs.gnused ];
                }
                ''
                  cp -r ${runner} $out
                  chmod -R u+w $out
                  sed -i 's/num_queues=[0-9]*/num_queues=2/g' $out/bin/microvm-run
                  # tap-flags advertises multi_queue for tap setup helpers;
                  # a single-queue runner must not request it.
                  if [ -f $out/share/microvm/tap-flags ]; then
                    sed -i '/multi_queue/d' $out/share/microvm/tap-flags
                  fi
                '';
            microvm-qemu = self.nixosConfigurations.microvm-qemu.config.microvm.declaredRunner;
          }
        )
      );

      apps = forAllSystems (
        pkgs:
        {
          native-bench = {
            type = "app";
            program = nixpkgs.lib.getExe (pkgs.callPackage ./pkgs/native-bench.nix { kine = pkgs.kine; });
          };
        }
        # Graceful guest shutdown (Ctrl-Alt-Del over the VMM API socket,
        # then wait for exit). The socket path is relative — run these
        # from the same directory the VM was started in.
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
          nixpkgs.lib.genAttrs
            [
              "microvm-firecracker"
              "microvm-cloud-hypervisor"
              "microvm-qemu"
            ]
            (variant: {
              type = "app";
              program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.${variant}}/bin/microvm-run";
            })
          //
            nixpkgs.lib.genAttrs
              [
                "microvm-firecracker-shutdown"
                "microvm-cloud-hypervisor-shutdown"
                "microvm-qemu-shutdown"
              ]
              (name: {
                type = "app";
                program = "${
                  self.packages.${pkgs.stdenv.hostPlatform.system}.${nixpkgs.lib.removeSuffix "-shutdown" name}
                }/bin/microvm-shutdown";
              })
          # Mesh launcher / teardown (air/v0.2/multinode-microvm.org §2):
          # `nix run .#microvm-cluster` boots server + agents, merges the
          # per-node consoles with name prefixes, and prints the kubeconfig
          # curl once every node reports KUBENYX-CLUSTER-READY.
          // {
            microvm-cluster = {
              type = "app";
              program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster}/bin/microvm-cluster";
            };
            microvm-cluster-shutdown = {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster-shutdown
              }/bin/microvm-cluster-shutdown";
            };
            # The 7-node twin (1 server + 6 agents) — same conventions,
            # its own run dir (/tmp/kubenyx-cluster7) so mesh snapshots of
            # both sizes can coexist.
            microvm-cluster7 = {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster7
              }/bin/microvm-cluster7";
            };
            microvm-cluster7-shutdown = {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster7-shutdown
              }/bin/microvm-cluster7-shutdown";
            };
          }
        )
      );

      checks = forAllSystems (
        pkgs:
        let
          runTest =
            path:
            pkgs.testers.runNixOSTest (
              import path {
                kubenyx = self;
              }
            );
        in
        {
          # Eval-level unit tests for lib/ CIDR math (ipv6.org §1): pure
          # lib.runTests at flake-check level, no VM. runTests returns the
          # list of failures — an empty list is green.
          lib-tests =
            let
              failures = import ./tests/lib-tests.nix { inherit (nixpkgs) lib; };
            in
            pkgs.runCommand "kubenyx-lib-tests"
              {
                failures = builtins.toJSON failures;
                passAsFile = [ "failures" ];
              }
              ''
                if [ "$(cat "$failuresPath")" != "[]" ]; then
                  echo "kubenyx lib tests failed:" >&2
                  cat "$failuresPath" >&2
                  exit 1
                fi
                touch $out
              '';
          single-node = runTest ./tests/single-node.nix;
          # lib.harness dogfood (air/v0.6/harness.org): server + agent
          # stood up exclusively through the exported helper.
          harness = runTest ./tests/harness.nix;
          # IPv6 single-stack acceptance legs (ipv6.org §3-4).
          ipv6 = runTest ./tests/ipv6.nix;
          ipv6-multi = runTest ./tests/ipv6-multi.nix;
          single-node-etcd = runTest ./tests/single-node-etcd.nix;
          multi-node = runTest ./tests/multi-node.nix;
          multi-node-mem = runTest ./tests/multi-node-mem.nix;
          multi-server = runTest ./tests/multi-server.nix;
          failover = runTest ./tests/failover.nix;
          server-reboot = runTest ./tests/server-reboot.nix;
          agent-add = runTest ./tests/agent-add.nix;
          # Declarative control-plane scale-out via etcd learners
          # (air/v0.5/cp-growth.org): growth machinery + shrink refusal.
          server-add = runTest ./tests/server-add.nix;
          external-cni = runTest ./tests/external-cni.nix;
          local-storage = runTest ./tests/local-storage.nix;
          # Pre-baked image stores (prebake.org): correctness with
          # prebake ON, and the >=90% import-elimination bench contract.
          prebake = runTest ./tests/prebake.nix;
          prebake-bench = runTest ./tests/prebake-bench.nix;
          ca-custody = runTest ./tests/ca-custody.nix;
          bench-vs-k3s = runTest ./tests/bench-vs-k3s.nix;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            kubectl
            jq
            nixfmt-rfc-style
            # etcd-mem's tonic-build needs protoc; without it `cargo
            # clippy/test --workspace` cannot even check the tree.
            protobuf
          ];
        };
      });

      templates.default = {
        path = ./templates/default;
        description = "Single-node Kubenyx cluster configuration";
      };
    };
}
