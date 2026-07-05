{
  description = "A single-node Kubenyx cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kubenyx.url = "github:rytswd/kubenyx";
    kubenyx.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      kubenyx,
      ...
    }:
    {
      nixosConfigurations.my-cluster = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          kubenyx.nixosModules.default
          {
            # Your existing hardware/system configuration goes alongside this.
            kubenyx.enable = true;

            # That's it — one option for a working single-node test cluster.
            # Useful extras:
            #
            #   kubenyx.datastore.volatile = true;   # tmpfs state: fastest, disposable
            #   kubenyx.addons.manifests.my-ns = {
            #     apiVersion = "v1"; kind = "Namespace";
            #     metadata.name = "my-app";
            #   };
            #
            # `kubectl` works as root out of the box (admin kubeconfig is
            # preconfigured via $KUBECONFIG).
          }
        ];
      };
    };
}
