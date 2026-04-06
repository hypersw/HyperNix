{
  description = "HyperNix — personal nix tools, modules, and machine configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    closefrom3 = {
      url = "path:./Util/CloseFrom3";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ssh-askpass = {
      url = "path:./Git/SshAskpassCredentialHelper";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.closefrom3.follows = "closefrom3";
    };

    vm-ssh-front = {
      url = "path:./Machines/MicroVM/VmSshFront";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, closefrom3, ssh-askpass, vm-ssh-front }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # Packages — path-based naming: folder path with hyphens
      packages = forAllSystems (system:
        let
          cf3 = closefrom3.packages.${system} or {};
          askpass = ssh-askpass.packages.${system} or {};
          vm = vm-ssh-front.packages.${system} or {};
        in
        {
          Util-CloseFrom3 = cf3.default or null;
          Git-SshAskpassCredentialHelper = askpass.default or null;
          Machines-MicroVM-VmSshFront = vm.VmSshFront or null;
        });

      # NixOS modules — same naming convention
      nixosModules = {
        Git-SshAskpassCredentialHelper = ssh-askpass.nixosModules.default;
      };

      # NixOS configurations
      nixosConfigurations = vm-ssh-front.nixosConfigurations or {};
    };
}
