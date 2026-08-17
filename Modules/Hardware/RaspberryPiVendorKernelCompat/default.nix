{ lib, ... }:
#
# Compatibility policy for nvmd/nixos-raspberrypi's Pi vendor kernels.
#
# Recent nixpkgs versions make `hardware.deviceTree.enable` default to the
# kernel's `buildDTBs` passthru. nvmd's vendor kernels carry usable DTBs under
# `$kernel/dtbs`, but do not expose that passthru. An explicit value therefore
# avoids the broken default *and* creates the built system's `dtbs` link, which
# nvmd's direct-EEPROM boot staging copies into each firmware generation.
#
# This is deliberately composed directly beside the upstream Pi 4/Pi 5 base
# modules in flake.nix. It is not in the universal module bundle: non-Pi
# systems do not use nvmd's vendor kernel or its firmware-generation staging.
{
  hardware.deviceTree.enable = lib.mkDefault true;
}
