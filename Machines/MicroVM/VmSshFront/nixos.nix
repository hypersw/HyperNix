# Called from the root flake: import ./Machines/MicroVM/VmSshFront/nixos.nix { inherit nixpkgs microvm; }
{ nixpkgs, microvm }:
let
  system = "x86_64-linux";
  VmNameBare = "SshFront";
  VmNamePrefixed = "Vm" + VmNameBare;
in
nixpkgs.lib.nixosSystem {
  modules = [
    { nixpkgs.hostPlatform.system = system; }
    microvm.nixosModules.microvm
    "${nixpkgs}/nixos/modules/profiles/hardened.nix"
    (import ./configuration.nix { inherit VmNameBare VmNamePrefixed; })
  ];
}
