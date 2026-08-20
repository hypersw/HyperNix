{
  description = "VmSshFront — parameterized SSH bastion MicroVM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm }:
    let
      mkVmSshFront = args:
        import ./nixos.nix ({ inherit nixpkgs microvm; } // args);
      defaultVm = mkVmSshFront { };
    in {
      nixosConfigurations.VmSshFront = defaultVm;

      packages.x86_64-linux.VmSshFront =
        defaultVm.config.microvm.declaredRunner;

      # Consumers can build a concurrent instance with a distinct name, MAC,
      # IPv4 address and hostname. The name scopes all host-local state.
      lib.mkVmSshFront = mkVmSshFront;
    };
}