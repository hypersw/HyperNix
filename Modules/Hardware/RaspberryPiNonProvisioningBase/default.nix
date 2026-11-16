{ config, lib, pkgs, ... }:
#
# Runtime-only policy for Pi systems using nvmd's vendor kernels.
#
# Keep ZFS userspace and its kernel module on the exact release exported by
# the selected vendor kernel package set. Provisioning and SD-image builds do
# not need this runtime policy, so the flake composes this module only into
# the live Pi 4 and Pi 5 configurations.
let
  vendorZfs = config.boot.kernelPackages.${pkgs.zfs.kernelModuleAttribute};

  # A candidate made by nixos-rebuild-boot-once is not a profile generation:
  # it is a build result copied to the FAT partition. BootOnceRaspberryPi
  # roots it when it stages it; this hook is the second line of defence
  # before every GC.
  syncTrybootGcRoot = pkgs.writeShellApplication {
    name = "hypersw-rpi-sync-tryboot-gc-root";
    runtimeInputs = [ pkgs.coreutils pkgs.gnused ];
    text = ''
      gc_root=/nix/var/nix/gcroots/hypersw-rpi-tryboot
      firmware=/boot/firmware

      # Mirror the candidate's `init=/nix/store/.../init` target into an
      # ordinary host GC root while tryboot.txt still selects that
      # directory. Conversely, remove a stale root as soon as nvmd's normal
      # stage has removed the sidecar.
      if [ -f "$firmware/tryboot.txt" ] && [ -f "$firmware/nixos/tryboot/cmdline.txt" ]; then
        candidate=$(sed -n 's#.*[[:space:]]init=\(/nix/store/[^[:space:]]*\)/init.*#\1#p' \
          "$firmware/nixos/tryboot/cmdline.txt" | head -n1)
        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
          mkdir -p "$(dirname "$gc_root")"
          ln -sfn "$candidate" "$gc_root"
        else
          echo "warning: staged tryboot payload has no live NixOS store target; leaving no candidate GC root" >&2
          rm -f "$gc_root"
        fi
      else
        rm -f "$gc_root"
      fi
    '';
  };
in
{
  # The generic monitoring module owns alerts and common metrics. This shared
  # live-Pi base selects only its Pi-specific collector policy, so Pi 4/Pi 5
  # machines do not duplicate it and provisioning images stay untouched.
  hypersw.services.telegram-alerts.netdata.profile = "raspberry-pi";

  boot.zfs = {
    package = vendorZfs;
    modulePackage = vendorZfs;
  };

  # One retention count for the firmware boot payloads and the system
  # profile: GenerationRetention reads the final loader limit, so a host
  # override of this value moves both together. This deliberately wins over
  # BootOnceRaspberryPi's generic mkDefault of 5.
  boot.loader.raspberry-pi.configurationLimit = lib.mkOverride 900 3;
  hypersw.system.generationRetention.enable = true;

  systemd.services.hypersw-rpi-sync-tryboot-gc-root = {
    description = "Keep a GC root on a staged Pi tryboot candidate";
    before = [ "nix-gc.service" ];
    # Required: GC without this root could collect a staged candidate.
    requiredBy = [ "nix-gc.service" ];
    unitConfig.RequiresMountsFor = [ "/boot/firmware" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncTrybootGcRoot}/bin/hypersw-rpi-sync-tryboot-gc-root";
    };
  };
}
