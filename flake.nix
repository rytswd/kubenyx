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
    in
    {
      nixosModules.kubenyx = import ./modules;
      nixosModules.default = self.nixosModules.kubenyx;

      nixosConfigurations =
        let
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
        in
        {
          # KVM hosts: `nix run .#microvm-firecracker` (after creating the
          # tap: ip tuntap add kubenyx-tap0 mode tap && ip addr add
          # 10.100.0.1/24 dev kubenyx-tap0 && ip link set kubenyx-tap0 up).
          # The firecracker and cloud-hypervisor variants are alternatives:
          # they share the tap id, MAC and guest IP — run one at a time.
          microvm-firecracker = mkMicrovm "firecracker" {
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
            microvm.interfaces = [
              {
                type = "tap";
                id = "kubenyx-tap0";
                mac = "02:00:00:00:00:01";
              }
            ];
            systemd.network.networks."05-kubenyx" = {
              matchConfig.MACAddress = "02:00:00:00:00:01";
              address = [ "10.100.0.2/24" ];
              routes = [ { Gateway = "10.100.0.1"; } ];
            };
            kubenyx.nodes.kubenyx = {
              index = 0;
              address = "10.100.0.2";
            };
          };
          microvm-cloud-hypervisor = mkMicrovm "cloud-hypervisor" {
            microvm.interfaces = [
              {
                type = "tap";
                id = "kubenyx-tap0";
                mac = "02:00:00:00:00:01";
              }
            ];
            systemd.network.networks."05-kubenyx" = {
              matchConfig.MACAddress = "02:00:00:00:00:01";
              address = [ "10.100.0.2/24" ];
              routes = [ { Gateway = "10.100.0.1"; } ];
            };
            kubenyx.nodes.kubenyx = {
              index = 0;
              address = "10.100.0.2";
            };
          };
          # SLiRP user networking; runs anywhere (KVM with TCG fallback) —
          # this is the variant CI/KVM-less machines can execute. q35: the
          # `microvm` machine type needs KVM's in-kernel irqchip (pic=off)
          # and cannot fall back to TCG.
          microvm-qemu = mkMicrovm "qemu" {
            microvm.qemu.machine = "q35";
            # Explicit CPU model drops -enable-kvm/-cpu host from the runner
            # (microvm.nix's emulation escape hatch). KVM hosts should use
            # the firecracker/cloud-hypervisor variants instead.
            microvm.cpu = "max";
            microvm.interfaces = [
              {
                type = "user";
                id = "u0";
                mac = "02:00:00:00:00:01";
              }
            ];
            systemd.network.networks."05-kubenyx" = {
              matchConfig.MACAddress = "02:00:00:00:00:01";
              address = [ "10.0.2.15/24" ];
              routes = [ { Gateway = "10.0.2.2"; } ]; # SLiRP gateway
            };
            kubenyx.nodes.kubenyx = {
              index = 0;
              address = "10.0.2.15";
            };
          };
        };

      lib = import ./lib { inherit (nixpkgs) lib; };

      packages = forAllSystems (
        pkgs:
        {
          kubenyx-tools = pkgs.callPackage ./pkgs/kubenyx-tools.nix { };
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
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          microvm-firecracker =
            self.nixosConfigurations.microvm-firecracker.config.microvm.declaredRunner;
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
          // nixpkgs.lib.genAttrs
            [
              "microvm-firecracker-shutdown"
              "microvm-cloud-hypervisor-shutdown"
              "microvm-qemu-shutdown"
            ]
            (name: {
              type = "app";
              program = "${
                self.packages.${pkgs.stdenv.hostPlatform.system}.${
                  nixpkgs.lib.removeSuffix "-shutdown" name
                }
              }/bin/microvm-shutdown";
            })
        )
      );

      checks = forAllSystems (
        pkgs:
        let
          runTest =
            path:
            pkgs.testers.runNixOSTest (import path {
              kubenyx = self;
            });
        in
        {
          single-node = runTest ./tests/single-node.nix;
          single-node-etcd = runTest ./tests/single-node-etcd.nix;
          multi-node = runTest ./tests/multi-node.nix;
          bench-vs-k3s = runTest ./tests/bench-vs-k3s.nix;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            kubectl
            jq
            nixfmt-rfc-style
          ];
        };
      });

      templates.default = {
        path = ./templates/default;
        description = "Single-node Kubenyx cluster configuration";
      };
    };
}
