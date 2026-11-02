{ lib, ... }:
#
# Compatibility policy for nvmd/nixos-raspberrypi's Pi vendor kernels.
#
# The vendor kernel and its out-of-tree modules come from nvmd's own pinned
# nixpkgs, so they substitute from nvmd's cache, while the rest of the system
# evaluates against our nixpkgs. Each rule below reconciles one place where
# that split shows.
#
# This is deliberately composed directly beside the upstream Pi 4/Pi 5 base
# modules in flake.nix. It is not in the universal module bundle: non-Pi
# systems do not use nvmd's vendor kernel or its firmware-generation staging.
{
  # Recent nixpkgs versions make `hardware.deviceTree.enable` default to the
  # kernel's `buildDTBs` passthru. nvmd's vendor kernels carry usable DTBs under
  # `$kernel/dtbs`, but do not expose that passthru. An explicit value therefore
  # avoids the broken default *and* creates the built system's `dtbs` link, which
  # nvmd's direct-EEPROM boot staging copies into each firmware generation.
  hardware.deviceTree.enable = lib.mkDefault true;

  # The SD-image installer profile (nixpkgs' profiles/base.nix) turns ZFS on by
  # default. Its kernel module would come from the vendor kernel's package set
  # and its tools from ours, and NixOS refuses to evaluate once their versions
  # differ. No Pi machine here uses ZFS, so it is off rather than matched.
  boot.supportedFilesystems.zfs = false;
}
