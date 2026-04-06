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
      # Packages — assembled from subfolder flakes
      packages = forAllSystems (system:
        let
          cf3 = closefrom3.packages.${system} or {};
          askpass = ssh-askpass.packages.${system} or {};
          vm = vm-ssh-front.packages.${system} or {};
        in
        {
          closefrom3 = cf3.default or null;
          ssh-askpass-credential-helper = askpass.default or null;
          VmSshFront = vm.VmSshFront or null;
        });

      # NixOS modules
      nixosModules = {
        ssh-askpass-credential-helper = ssh-askpass.nixosModules.default;
      };

      # NixOS configurations (for machines)
      nixosConfigurations = vm-ssh-front.nixosConfigurations or {};
    };
}
