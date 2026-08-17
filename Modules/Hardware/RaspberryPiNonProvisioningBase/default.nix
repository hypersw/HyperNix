{ config, pkgs, ... }:
#
# Runtime-only policy for Pi systems using nvmd's vendor kernels.
#
# Keep ZFS userspace and its kernel module on the exact release exported by
# the selected vendor kernel package set. Provisioning and SD-image builds do
# not need this runtime policy, so the flake composes this module only into
# the live Pi 4 and Pi 5 configurations.
let
  vendorZfs = config.boot.kernelPackages.${pkgs.zfs.kernelModuleAttribute};
in
{
  boot.zfs = {
    package = vendorZfs;
    modulePackage = vendorZfs;
  };
}
