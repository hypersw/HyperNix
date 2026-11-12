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

  # The firmware loader retains copied boot artefacts, whereas Nix GC only
  # understands profile/GC-root links on the root filesystem.  Keep both
  # domains on the same policy: N normal system profiles plus explicit roots
  # for a booted system and a staged Pi tryboot candidate.
  generationLimit = 3;

  pruneSystemGenerations = pkgs.writeShellApplication {
    name = "hypersw-rpi-prune-system-generations";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.nix ];
    text = ''
      set -euo pipefail

      profile=/nix/var/nix/profiles/system
      gc_root=/nix/var/nix/gcroots/hypersw-rpi-tryboot
      firmware=/boot/firmware

      # A candidate made by nixos-rebuild-boot-once is not a profile
      # generation: it is a build result copied to the FAT partition.  Mirror
      # its `init=/nix/store/.../init` target into an ordinary host GC root
      # while tryboot.txt still selects that directory.  Conversely, remove a
      # stale root as soon as nvmd's normal stage has removed the sidecar.
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

      # Preserve the N newest normal profiles, plus whichever configuration
      # is currently running and whichever one booted this kernel.  The latter
      # two are normally among the newest N, but retaining them explicitly
      # makes a manual rollback/recovery boot safe until its next reboot.
      current=$(readlink -f /run/current-system 2>/dev/null || true)
      booted=$(readlink -f /run/booted-system 2>/dev/null || true)
      mapfile -t links < <(
        find /nix/var/nix/profiles -maxdepth 1 -type l -name 'system-[0-9]*-link' -printf '%f\n' \
          | sed -n 's/^system-\([0-9][0-9]*\)-link$/\1/p' | sort -n
      )

      keep_from=${toString generationLimit}
      first_keep=$(( ''${#links[@]} - keep_from ))
      if [ "$first_keep" -lt 0 ]; then first_keep=0; fi

      for i in "''${!links[@]}"; do
        gen=''${links[$i]}
        link=/nix/var/nix/profiles/system-''${gen}-link
        target=$(readlink -f "$link" 2>/dev/null || true)
        if [ "$i" -ge "$first_keep" ] || [ "$target" = "$current" ] || [ "$target" = "$booted" ]; then
          continue
        fi
        echo "deleting obsolete Pi system generation $gen ($target)"
        nix-env -p "$profile" --delete-generations "$gen"
      done
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

  # One authoritative retention count for the actual firmware boot payloads.
  # This deliberately wins over BootOnceRaspberryPi's generic mkDefault of 5;
  # a host can still make an explicit (normal-priority) recovery override.
  boot.loader.raspberry-pi.configurationLimit = lib.mkOverride 900 generationLimit;

  # Any `--delete-older-than` option would be a second, time-based retention
  # policy and could delete profiles independently of the boot limit.  This
  # Pi-specific policy deletes exact profile generations first; the standard
  # nix-gc service then collects their newly-unreachable store paths.
  nix.gc.options = lib.mkForce "";

  systemd.services.hypersw-rpi-prune-system-generations = {
    description = "Synchronise Pi system-profile retention with firmware boot generations";
    before = [ "nix-gc.service" ];
    requiredBy = [ "nix-gc.service" ];
    unitConfig.RequiresMountsFor = [ "/boot/firmware" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pruneSystemGenerations}/bin/hypersw-rpi-prune-system-generations";
    };
  };
}
