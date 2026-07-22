{
  description = "Kubenyx — drop-in stock Kubernetes for NixOS, tuned for uncompromising startup speed";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # MicroVM runners for disposable test clusters: firecracker /
    # cloud-hypervisor boot the guest profile to cluster-ready in
    # single-digit seconds on any KVM host.
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    # Older stable channels pin older stock Kubernetes releases,
    # binary-cached upstream. The k8s version matrix in checks swaps
    # only kubenyx.packages.{kubernetes,kubectl} from these — stock
    # Kubernetes means the version is just a package option.
    nixpkgs-2511.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-2505.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
      nixpkgs-2511,
      nixpkgs-2505,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # microVM guest + mesh construction lives in lib/microvm.nix (exported
      # as flake lib.microvm so consumer flakes instantiate meshes at any
      # size); the flake's own single-node variants and the cp1w2/cp1w6
      # presets are built from the same functions.
      microvmLib = import ./lib/microvm.nix {
        inherit (nixpkgs) lib;
        nixosSystem = nixpkgs.lib.nixosSystem;
        baseModules = [
          microvm.nixosModules.microvm
          self.nixosModules.default
          ./guests/microvm.nix
        ];
      };
      inherit (microvmLib) mkMicrovm mkGuestNet;
      # The two preset mesh sizes: the 3-node default and a 7-node twin for
      # scale measurements. pkgs pinned to x86_64-linux — the whole microVM
      # path is x86_64-only.
      cluster3 = microvmLib.mkCluster {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        name = "cp1w2";
        agents = 2;
        runDir = "/tmp/kubenyx-cluster";
      };
      cluster7 = microvmLib.mkCluster {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        name = "cp1w6";
        agents = 6;
        runDir = "/tmp/kubenyx-cluster7";
      };
      # cp3 quorum presets (air/v0.1/quorum/quorum-mesh.org): 3 control planes
      # forming a REAL etcd quorum in the volatile posture, alone and with
      # 2 workers. mkCluster's joinProbeSec default (3s, the §D3 measured
      # candidate) applies; own run dirs so snapshots of every mesh size
      # coexist.
      cp3Cluster = microvmLib.mkCluster {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        name = "cp3";
        servers = 3;
        agents = 0;
        runDir = "/tmp/kubenyx-cp3";
      };
      cp3w2Cluster = microvmLib.mkCluster {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        name = "cp3w2";
        servers = 3;
        agents = 2;
        runDir = "/tmp/kubenyx-cp3w2";
      };
      # The implicit one-node membership every single-node variant declares.
      mkSingleNodeMembership = address: {
        kubenyx.nodes.kubenyx = {
          index = 0;
          inherit address;
          role = "server";
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
          # 10.100.0.1/24 with kubenyx-tap0 enslaved — see lib/microvm.nix);
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
        # the same per-node systems the cp1w2/cp1w6 launchers boot,
        # registered under the historical names.
        // nixpkgs.lib.mapAttrs' (
          n: node: nixpkgs.lib.nameValuePair "microvm-cluster-${n}" node
        ) cluster3.nodes
        // nixpkgs.lib.mapAttrs' (
          n: node: nixpkgs.lib.nameValuePair "microvm-cluster7-${n}" node
        ) cluster7.nodes;

      lib = import ./lib { inherit (nixpkgs) lib; } // {
        microvm = microvmLib;
      };

      packages = forAllSystems (
        pkgs:
        {
          kubenyx-tools = pkgs.callPackage ./pkgs/kubenyx-tools.nix { };
          # Agent-side apiserver LB for multi-server clusters (durable-ha
          # §4). Since the multicall fold this is a thin symlink view over
          # kubenyx-tools (measured 52 KiB lb delta — see
          # pkgs/kubenyx-lb.nix); the module still only references it when
          # lb.enable gates it on.
          kubenyx-lb = pkgs.callPackage ./pkgs/kubenyx-lb.nix { };
          # The multicall CLI with the matching firecracker on PATH (the
          # snap verb drives the VMM, and snapshots are only portable
          # across identical VMM versions): `nix run .#kubenyx -- snap
          # take ...`, plus pki|ready|clockstep|lb|etcd-mem verbs.
          kubenyx = pkgs.writeShellScriptBin "kubenyx" ''
            export PATH=${pkgs.firecracker}/bin:$PATH
            exec ${self.packages.${pkgs.stdenv.hostPlatform.system}.kubenyx-tools}/bin/kubenyx "$@"
          '';
          # Alias for the snap verb under its historical name — same
          # wrapper semantics (pinned firecracker on PATH), dispatched via
          # the argv[0] compat symlink. take: boot the runner to
          # cluster-ready and write snap.vmstate + snap.mem; resume: fresh
          # VMM + /snapshot/load + time pokes, ~75ms to a serving
          # apiserver; cycle: the recreation benchmark.
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
          in
          # Per-node mesh runners under the historical names — same drvs the
          # cp1w2/cp1w6 launchers embed.
          lib.mapAttrs' (n: r: lib.nameValuePair "microvm-cluster-${n}" r) cluster3.runners
          // lib.mapAttrs' (n: r: lib.nameValuePair "microvm-cluster7-${n}" r) cluster7.runners
          // rec {
            cp1w2 = cluster3.launcher;
            cp1w2-down = cluster3.shutdown;
            cp1w6 = cluster7.launcher;
            cp1w6-down = cluster7.shutdown;
            # cp3 quorum meshes (quorum-mesh.org): launcher + teardown only —
            # no per-node nixosConfigurations registration; the launcher
            # embeds the runners it needs.
            cp3 = cp3Cluster.launcher;
            cp3-down = cp3Cluster.shutdown;
            cp3w2 = cp3w2Cluster.launcher;
            cp3w2-down = cp3w2Cluster.shutdown;
            # Deprecated aliases (pre-rename names); same derivations, the
            # binaries inside carry the new names.
            microvm-cluster = cp1w2;
            microvm-cluster-shutdown = cp1w2-down;
            microvm-cluster7 = cp1w6;
            microvm-cluster7-shutdown = cp1w6-down;
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
        # Guest shutdown with an escalation ladder. The stock microvm.nix
        # script sends Ctrl-Alt-Del over the API socket and waits for the
        # VMM to exit — forever, on firecracker guests: there is no i8042
        # ("i8042 probe failed with error -22" at every boot), so the
        # keystroke lands nowhere (the mesh teardown encoded this first).
        # Bounded graceful attempt, then SIGTERM, then SIGKILL — every
        # guest here is disposable by design. Run from the VM's directory
        # (the control socket is relative).
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
              (
                name:
                let
                  runner =
                    self.packages.${pkgs.stdenv.hostPlatform.system}.${nixpkgs.lib.removeSuffix "-shutdown" name};
                in
                {
                  type = "app";
                  program = nixpkgs.lib.getExe (
                    pkgs.writeShellScriptBin name ''
                      # The single-node guests are all named microvm@kubenyx
                      # (exec -a by the runner); anchor tightly so mesh nodes
                      # (microvm@server, microvm@agentN) are never touched.
                      alive() { ${pkgs.procps}/bin/pgrep -f '^microvm@kubenyx ' >/dev/null 2>&1; }
                      alive || { echo "${name}: nothing running"; exit 0; }
                      ${pkgs.coreutils}/bin/timeout 8 ${runner}/bin/microvm-shutdown 2>/dev/null || true
                      alive || { echo "${name}: down (graceful)"; exit 0; }
                      ${pkgs.procps}/bin/pkill -TERM -f '^microvm@kubenyx ' 2>/dev/null || true
                      for _ in $(${pkgs.coreutils}/bin/seq 1 25); do
                        alive || { echo "${name}: down (SIGTERM)"; exit 0; }
                        ${pkgs.coreutils}/bin/sleep 0.2
                      done
                      ${pkgs.procps}/bin/pkill -KILL -f '^microvm@kubenyx ' 2>/dev/null || true
                      echo "${name}: down (SIGKILL)"
                    ''
                  );
                }
              )
          # Mesh launcher / teardown (air/v0.1/microvm/multinode-microvm.org §2):
          # `nix run .#microvm-cluster` boots server + agents, merges the
          # per-node consoles with name prefixes, and prints the kubeconfig
          # curl once every node reports KUBENYX-CLUSTER-READY.
          // {
            microvm-cluster = {
              type = "app";
              program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster}/bin/cp1w2";
            };
            microvm-cluster-shutdown = {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster-shutdown
              }/bin/cp1w2-down";
            };
            # The 7-node twin (1 server + 6 agents) — same conventions,
            # its own run dir (/tmp/kubenyx-cluster7) so mesh snapshots of
            # both sizes can coexist.
            microvm-cluster7 = {
              type = "app";
              program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster7}/bin/cp1w6";
            };
            microvm-cluster7-shutdown = {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.microvm-cluster7-shutdown
              }/bin/cp1w6-down";
            };
          }
          # ---- k8s-composition names (the primary interface) ----------------
          # cpNwM = N control-plane nodes + M workers. The hypervisor is a
          # runtime concern, not a topology one: cp1 dispatches on KUBENYX_HV
          # (firecracker | cloud-hypervisor | qemu), defaulting to firecracker
          # when /dev/kvm is usable and falling back loudly to qemu (the only
          # variant with TCG) when it is not. The dispatch is a nested
          # `nix run` against the flake's own store path, so no hypervisor
          # closure is built until it is actually chosen. The microvm-* names
          # above remain as aliases for a deprecation window.
          // (
            let
              cp1Dispatch =
                action: # "" (run) or "-shutdown"
                pkgs.writeShellScriptBin "cp1${if action == "" then "" else "-down"}" ''
                  HV="''${KUBENYX_HV:-}"
                  if [ -z "$HV" ]; then
                    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
                      HV=firecracker
                    else
                      echo "kubenyx: /dev/kvm not usable — falling back to qemu (TCG, ~6.5x slower)" >&2
                      HV=qemu
                    fi
                  fi
                  case "$HV" in
                    firecracker | cloud-hypervisor | qemu) ;;
                    *)
                      echo "kubenyx: unknown KUBENYX_HV '$HV' (firecracker | cloud-hypervisor | qemu)" >&2
                      exit 1
                      ;;
                  esac
                  exec ${pkgs.nix}/bin/nix run "path:${self}#microvm-$HV${action}" -- "$@"
                '';
              mkApp = drv: {
                type = "app";
                program = nixpkgs.lib.getExe drv;
              };
            in
            {
              default = mkApp (cp1Dispatch "");
              cp1 = mkApp (cp1Dispatch "");
              cp1-down = mkApp (cp1Dispatch "-shutdown");
              cp1w2 = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp1w2}/bin/cp1w2";
              };
              cp1w2-down = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp1w2-down}/bin/cp1w2-down";
              };
              cp1w6 = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp1w6}/bin/cp1w6";
              };
              cp1w6-down = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp1w6-down}/bin/cp1w6-down";
              };
              cp3 = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp3}/bin/cp3";
              };
              cp3-down = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp3-down}/bin/cp3-down";
              };
              cp3w2 = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp3w2}/bin/cp3w2";
              };
              cp3w2-down = {
                type = "app";
                program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.cp3w2-down}/bin/cp3w2-down";
              };
            }
          )
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
          # lib.harness dogfood (air/v0.1/harness/harness.org): server + agent
          # stood up exclusively through the exported helper.
          harness = runTest ./tests/harness.nix;
          # D1 snapshot verbs (air/v0.1/snapshot/test-amplification.org): the
          # same 2-node shape with snapshotable = true — savevm cut
          # after Ready, mutate, loadvm rewind twice; asserts the
          # mutation is gone AND a fresh post-restore write lands (a
          # WRITE, not a TLS answer). Seconds-class by design.
          harness-snapshot = runTest ./tests/harness-snapshot.nix;
          # IPv6 single-stack acceptance legs (ipv6.org §3-4).
          ipv6 = runTest ./tests/ipv6.nix;
          ipv6-multi = runTest ./tests/ipv6-multi.nix;
          single-node-etcd = runTest ./tests/single-node-etcd.nix;
          multi-node = runTest ./tests/multi-node.nix;
          multi-node-mem = runTest ./tests/multi-node-mem.nix;
          multi-server = runTest ./tests/multi-server.nix;
          # The cp3 posture as a check (air/v0.1/quorum/quorum-mesh.org item 6):
          # volatile 3-member quorum, launcher-shape CA pre-seed, D3
          # fast-exit. The firecracker launcher itself stays host-tested
          # via the bench.
          quorum-volatile = runTest ./tests/quorum-volatile.nix;
          failover = runTest ./tests/failover.nix;
          server-reboot = runTest ./tests/server-reboot.nix;
          agent-add = runTest ./tests/agent-add.nix;
          # Declarative control-plane scale-out via etcd learners
          # (air/v0.1/quorum/cp-growth.org): growth machinery + shrink refusal.
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
        # v0.10 cross-derivation snapshot artifacts
        # (air/v0.1/snapshot/ci-artifacts.org): snapshot-mint BUILDS the
        # artifact (boot → savevm → package qcow2s + identity manifest
        # into $out); snapshot-restore consumes that output as a
        # derivation input, restores it without one cold-boot
        # instruction, and proves the honesty bar (post-cut mint
        # mutation absent, pre-cut provenance present, fresh write
        # lands). x86_64-only: the artifact pins Skylake-Server-v4.
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          snapshot-mint = import ./tests/snapshot-mint.nix {
            kubenyx = self;
            inherit pkgs;
          };
          snapshot-restore = pkgs.testers.runNixOSTest (
            import ./tests/snapshot-restore.nix {
              kubenyx = self;
              inherit pkgs;
            }
          );
        }
        # Stock Kubernetes means the version is just a package option:
        # these legs re-run representative scenarios with
        # kubenyx.packages.{kubernetes,kubectl} swapped in from older
        # stable nixpkgs channels (binary-cached upstream). Everything
        # else — containerd, etcd, CNI — stays on the primary pin, the
        # same mixed-component reality a real host lives with.
        // nixpkgs.lib.concatMapAttrs (
          _: channel:
          let
            kp = channel.legacyPackages.${pkgs.stdenv.hostPlatform.system};
            ver = nixpkgs.lib.versions.majorMinor kp.kubernetes.version;
            tag = nixpkgs.lib.replaceStrings [ "." ] [ "_" ] ver;
            runTestOn =
              leg: path:
              pkgs.testers.runNixOSTest {
                imports = [ (import path { kubenyx = self; }) ];
                name = nixpkgs.lib.mkForce "kubenyx-${leg}-k8s-${ver}";
                # `defaults` merges as a module, so this composes with
                # anything the base test already sets there.
                defaults = {
                  kubenyx.packages = {
                    kubernetes = kp.kubernetes;
                    kubectl = kp.kubectl;
                  };
                };
              };
          in
          {
            "single-node-k8s-${tag}" = runTestOn "single-node" ./tests/single-node.nix;
            "multi-node-mem-k8s-${tag}" = runTestOn "multi-node-mem" ./tests/multi-node-mem.nix;
          }
        ) { inherit nixpkgs-2511 nixpkgs-2505; }
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
