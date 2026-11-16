{ config, lib, pkgs, ... }:
#
# Generation retention in step with the boot loader.
#
# Every NixOS boot loader here (systemd-boot, GRUB, extlinux, the nvmd
# Raspberry Pi loader) installs the newest `configurationLimit` system
# generations by number. Nix GC, by contrast, keeps whatever profile
# generations still exist. A time-based `nix-collect-garbage
# --delete-older-than` is a second, unrelated policy: on a host that has
# not upgraded for a month it deletes generations the loader still offers,
# and their store paths go with the next GC.
#
# This module makes the count the only policy for system profiles:
#   - the system profile and every system-profiles/<name> keep their newest
#     N generations, plus the generations of the running system, the booted
#     system and the profile's current link;
#   - every other profile (per-user, channels, …) loses generations older
#     than `otherProfilesOlderThan`, since nothing boots from them;
#   - nix-gc then runs with no flags and collects what became unreachable.
let
  cfg = config.hypersw.system.generationRetention;
  loader = config.boot.loader;

  # The count the active loader installs; null when no loader applies
  # (a container) or the loader keeps everything.
  loaderLimit =
    if loader.systemd-boot.enable then loader.systemd-boot.configurationLimit
    else if loader.grub.enable then loader.grub.configurationLimit
    else if (loader ? raspberry-pi) && loader.raspberry-pi.enable then loader.raspberry-pi.configurationLimit
    else if loader.generic-extlinux-compatible.enable then loader.generic-extlinux-compatible.configurationLimit
    else null;

  pruneScript = pkgs.writeShellApplication {
    name = "hypersw-prune-generations";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.nix ];
    text = ''
      profiles=/nix/var/nix/profiles
      keep=${if cfg.systemGenerations == null then "" else toString cfg.systemGenerations}

      current=$(readlink -f /run/current-system 2>/dev/null || true)
      booted=$(readlink -f /run/booted-system 2>/dev/null || true)

      # Keep the newest $keep generations of one system profile, plus any
      # generation that the running system, the booted system or the
      # profile's own current link resolves to. nix-env refuses to delete
      # the current generation anyway; keeping it here avoids that error.
      prune_by_count() {
        local profile=$1 dir base own gen target
        local -a gens doomed=()
        dir=$(dirname "$profile")
        base=$(basename "$profile")
        own=$(readlink -f "$profile" 2>/dev/null || true)
        mapfile -t gens < <(
          find "$dir" -maxdepth 1 -type l -name "$base-[0-9]*-link" -printf '%f\n' \
            | sed -n "s/^$base-\([0-9][0-9]*\)-link$/\1/p" | sort -n
        )
        local first_keep=$(( ''${#gens[@]} - keep ))
        for i in "''${!gens[@]}"; do
          gen=''${gens[$i]}
          target=$(readlink -f "$dir/$base-$gen-link" 2>/dev/null || true)
          if [ "$i" -ge "$first_keep" ] || [ "$target" = "$current" ] \
            || [ "$target" = "$booted" ] || [ "$target" = "$own" ]; then
            continue
          fi
          doomed+=("$gen")
        done
        if [ "''${#doomed[@]}" -gt 0 ]; then
          echo "$profile: deleting generations ''${doomed[*]} (keeping the newest $keep)"
          nix-env -p "$profile" --delete-generations "''${doomed[@]}"
        fi
      }

      if [ -n "$keep" ]; then
        prune_by_count "$profiles/system"
        for p in "$profiles"/system-profiles/*; do
          case "$p" in *-link) continue ;; esac
          [ -L "$p" ] && prune_by_count "$p"
        done
      else
        echo "no loader generation count: system profiles are kept in full"
      fi

      # Every other profile: by age. A profile is any link that has
      # numbered generation links next to it.
      find "$profiles" -type l -name '*-[0-9]*-link' -printf '%h/%f\n' \
        | sed -n 's/-[0-9][0-9]*-link$//p' | sort -u \
        | while read -r p; do
            case "$p" in
              "$profiles/system" | "$profiles"/system-profiles/*) continue ;;
            esac
            [ -L "$p" ] || continue
            nix-env -p "$p" --delete-generations ${lib.escapeShellArg cfg.otherProfilesOlderThan}
          done
    '';
  };
in
{
  options.hypersw.system.generationRetention = {
    enable = lib.mkEnableOption ''
      count-based retention of system generations, matched to the boot
      loader, in place of nix-gc's time-based deletion
    '';

    systemGenerations = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = loaderLimit;
      defaultText = lib.literalMD "the active boot loader's `configurationLimit`";
      description = ''
        Newest generations kept in each system profile. Defaults to the
        count the active boot loader installs, so every boot entry keeps
        its store paths. Null keeps system profiles in full.
      '';
    };

    otherProfilesOlderThan = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = ''
        Generations of non-system profiles older than this are deleted
        (`nix-env --delete-generations` syntax). The current generation
        of each profile always stays.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A time-based option would be a second retention policy, independent
    # of the boot entries; GC itself runs without flags.
    nix.gc.options = lib.mkForce "";

    systemd.services.hypersw-prune-generations = {
      description = "Delete system generations beyond the boot loader's count, and old ones of other profiles";
      before = [ "nix-gc.service" ];
      # Wanted, not required: GC after a failed prune is still safe, since
      # it only collects paths no generation reaches.
      wantedBy = [ "nix-gc.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pruneScript}/bin/hypersw-prune-generations";
      };
    };
  };
}
