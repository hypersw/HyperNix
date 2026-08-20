# Called from the root flake: import ./Machines/MicroVM/VmSshFront/nixos.nix { inherit nixpkgs microvm; }
{ nixpkgs
, microvm
, VmNameBare ? "SshFront"
, VmNamePrefixed ? "Vm${VmNameBare}"
, VmMacAddress ? "02:34:54:83:93:01"
, VmIpv4Address ? "192.168.1.8/24"
, VmGatewayAddress ? "192.168.1.1"
, VmHostname ? "ssh-front"
}:
let
  system = "x86_64-linux";
in
nixpkgs.lib.nixosSystem {
  modules = [
    { nixpkgs.hostPlatform.system = system; }
    microvm.nixosModules.microvm
    "${nixpkgs}/nixos/modules/profiles/hardened.nix"
    (import ./configuration.nix { inherit VmNameBare VmNamePrefixed VmMacAddress VmIpv4Address VmGatewayAddress VmHostname; })
  ];
}
