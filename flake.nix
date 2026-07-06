{
  description = "Kubenyx — drop-in stock Kubernetes for NixOS, tuned for uncompromising startup speed";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
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

      lib = import ./lib { inherit (nixpkgs) lib; };

      packages = forAllSystems (pkgs: {
        kubenyx-tools = pkgs.callPackage ./pkgs/kubenyx-tools.nix { };
        pause-image = pkgs.callPackage ./pkgs/pause-image.nix { };
        test-image = pkgs.callPackage ./pkgs/test-image.nix { };
        native-bench = pkgs.callPackage ./pkgs/native-bench.nix { kine = pkgs.kine; };
      });

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
