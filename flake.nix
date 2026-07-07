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
          pause-image = pkgs.callPackage ./pkgs/pause-image.nix { };
          test-image = pkgs.callPackage ./pkgs/test-image.nix { };
          native-bench = pkgs.callPackage ./pkgs/native-bench.nix { kine = pkgs.kine; };
        }
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          microvm-firecracker =
            self.nixosConfigurations.microvm-firecracker.config.microvm.declaredRunner;
          microvm-cloud-hypervisor =
            self.nixosConfigurations.microvm-cloud-hypervisor.config.microvm.declaredRunner;
          microvm-qemu = self.nixosConfigurations.microvm-qemu.config.microvm.declaredRunner;
        }
      );

      apps = forAllSystems (pkgs: {
        native-bench = {
          type = "app";
          program = nixpkgs.lib.getExe (pkgs.callPackage ./pkgs/native-bench.nix { kine = pkgs.kine; });
        };
      });

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
