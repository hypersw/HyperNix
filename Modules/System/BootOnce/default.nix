{ config, lib, pkgs, ... }:
#
# BootOnce — `nixos-rebuild-boot-once` wrapper for tryboot-style
# one-shot kernel testing.
#
# Models a Pi 5 / EFI workflow where the operator wants to:
#
#   1. Stage a new system generation as a candidate.
#   2. Reboot into the candidate exactly once.
#   3a. If the candidate boots cleanly, SSH in, verify everything
#       (network, services, peripherals), then run a normal
#       `sudo nixos-rebuild boot` to promote the candidate to LKG.
#   3b. If the candidate doesn't come back (hang in initrd, kernel
#       panic, no network), pull power. The next boot reads the
#       UNCHANGED default → LKG kernel returns. Zero userspace
#       cooperation required — the rollback is enforced by
#       firmware before the kernel runs.
#
# This is structurally identical to systemd-boot's `bootctl
# set-oneshot` or UEFI's `BootNext` variable, just spelled in
# Pi 5 EEPROM terms (the `[tryboot]` filter in `config.txt`
# combined with the `reboot "0 tryboot"` magic argument).
#
# Why no auto-promote daemon: the candidate is "good" only when
# the operator's intuition says so — network-reachable, services
# green, the specific bits being tested are working. That's
# explicit judgment, not a unit-determinable predicate. So we
# expose a stage-and-reboot command (this module) and leave the
# promotion to a plain `nixos-rebuild boot` once the operator is
# satisfied. Power-cycle is the implicit revert; nothing else.
#
# Currently only the Pi 5 `kernel` bootloader path is wired. The
# module asserts hard on other bootloaders so a misconfiguration
# fails at build time rather than producing a wrapper that
# silently no-ops.
#
let
  cfg = config.hypersw.system.bootOnce;

  # Bootloader detection — only one branch will produce a wrapper.
  # Future: add systemd-boot (bootctl set-oneshot) + grub (grub-reboot)
  # branches here.
  isPiKernelBootloader =
    (config.boot.loader.raspberry-pi.bootloader or null) == "kernel";

  # The set of config.txt directives we copy from the candidate's
  # [all] block into the new [tryboot] block. Anything in here
  # gets overridden on the tryboot pass; anything not in here
  # stays at whatever the LKG default chose (HDMI tweaks, GPIO
  # pin setup, etc. — properties of the BOX, not the kernel).
  #
  # Conservative on purpose: a too-narrow filter leaves the
  # tryboot kernel without an initramfs and it dies in early
  # boot. A too-wide filter overrides hardware-specific config
  # and might prevent the box from coming up at all. Start with
  # the standard kernel-side directives; extend when an actual
  # failure case justifies it.
  tryBootFieldsRx = "^(kernel|initramfs|cmdline|os_check|device_tree|dtoverlay)=";

  # buildPackages.* runs the shellcheck pass on the build platform,
  # so x86 dev hosts can verify the wrapper without aarch64 emulation.
  # On the Pi (native build) this is a no-op alias.
  piWrapper = pkgs.buildPackages.writeShellApplication {
    name = "nixos-rebuild-boot-once";
    runtimeInputs = with pkgs.buildPackages; [ coreutils gnugrep systemd ];
    # nixos-rebuild itself is on /run/current-system/sw/bin, so it
    # resolves via PATH at invocation time; not pulled in here to
    # avoid pinning to a specific nixos-rebuild package version.
    text = ''
      # nixos-rebuild-boot-once — build a NixOS generation and queue
      # it as a one-shot Pi 5 tryboot. Power-cycle on failure
      # reverts to the LKG kernel; `nixos-rebuild boot` on success
      # promotes the candidate to LKG.
      #
      # Args pass through to `nixos-rebuild boot`:
      #   sudo nixos-rebuild-boot-once --flake /etc/nixos#default
      #   sudo nixos-rebuild-boot-once --flake github:hypersw/HyperNix#GhostHome

      if [ "$EUID" -ne 0 ]; then
        echo "error: must be run as root (try: sudo nixos-rebuild-boot-once …)" >&2
        exit 1
      fi

      FIRMWARE_DIR=/boot/firmware
      CONFIG="$FIRMWARE_DIR/config.txt"

      if [ ! -f "$CONFIG" ]; then
        echo "error: $CONFIG not found — this host doesn't look Pi-firmware-managed." >&2
        echo "       boot-once is currently wired only for the Pi 5 'kernel' bootloader." >&2
        exit 1
      fi

      # Snapshot LKG config before nixos-rebuild boot mutates it.
      # Stored in /tmp (tmpfs) rather than alongside config.txt so a
      # failed run never leaves stray .lkg.* files on the FAT
      # partition that subsequent rebuilds might mis-parse.
      LKG_BACKUP=$(mktemp /tmp/config.lkg.XXXXXX.txt)
      cp -a "$CONFIG" "$LKG_BACKUP"
      cleanup() { rm -f "$LKG_BACKUP" "$NEW_CONFIG" 2>/dev/null || true; }
      NEW_CONFIG=""
      trap cleanup EXIT

      echo "==> running 'nixos-rebuild boot' to stage the candidate…"
      # `boot` (not `switch`): stage the candidate as the next-boot
      # default + copy its kernel/initrd/dtb to /boot/firmware/nixos/
      # <gen>/, but DO NOT activate it on the running system. We
      # then rewrite config.txt below so the candidate is reached
      # only via tryboot, not via the normal boot path.
      nixos-rebuild boot "$@"

      # Extract the candidate's kernel-relevant directives (now in
      # the [all] block of config.txt, courtesy of the stage above).
      CANDIDATE_BLOCK=$(grep -E ${lib.escapeShellArg tryBootFieldsRx} "$CONFIG" || true)
      if [ -z "$CANDIDATE_BLOCK" ]; then
        echo "error: nixos-rebuild boot ran but $CONFIG has no kernel= line. Aborting." >&2
        cp -a "$LKG_BACKUP" "$CONFIG"
        exit 1
      fi

      # Atomically swap config.txt back to LKG + append a [tryboot]
      # section pointing at the candidate. mv on the same filesystem
      # is atomic; on FAT the rename is a single directory-entry
      # update, no torn-write window.
      NEW_CONFIG=$(mktemp "$FIRMWARE_DIR/.config.new.XXXXXX.txt")
      {
        cat "$LKG_BACKUP"
        printf '\n[tryboot]\n%s\n' "$CANDIDATE_BLOCK"
      } > "$NEW_CONFIG"
      sync
      mv "$NEW_CONFIG" "$CONFIG"
      NEW_CONFIG=""  # consumed; don't try to rm it in cleanup
      sync

      cat <<'BANNER'

      ================================================================
        Candidate staged for one-shot boot via Pi 5 tryboot.
        Rebooting in 10s — Ctrl+C aborts.

        AFTER REBOOT:
          On success: ssh in, verify everything you care about, then
                       `sudo nixos-rebuild boot` to promote the
                       candidate to LKG.
          On failure: power-cycle the Pi. The unconsumed [all] block
                       in config.txt boots the previous kernel.
      ================================================================

      BANNER
      sleep 10
      # systemctl reboot --reboot-argument= passes the string through
      # to reboot(2)'s extra argument, which the Pi firmware reads as
      # the tryboot one-shot trigger. Plain `reboot` from systemd
      # doesn't propagate the argument.
      systemctl reboot --reboot-argument="0 tryboot"
    '';
  };
in {
  options.hypersw.system.bootOnce = {
    enable = lib.mkEnableOption ''
      `nixos-rebuild-boot-once` — stage a new system generation as a
      Pi 5 tryboot candidate. Power-cycle reverts on failure;
      `nixos-rebuild boot` from inside the candidate promotes.
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Hard assertion — fail at build time on hosts whose
      # bootloader doesn't have a wired implementation yet.
      # Cheaper than shipping a wrapper that silently no-ops.
      assertions = [
        {
          assertion = isPiKernelBootloader;
          message = ''
            hypersw.system.bootOnce.enable = true currently requires
            boot.loader.raspberry-pi.bootloader = "kernel" (Pi 5
            EEPROM direct-kernel-boot). Add systemd-boot or grub
            branches in Modules/System/BootOnce/default.nix to
            support other bootloaders.
          '';
        }
      ];
    }

    (lib.mkIf isPiKernelBootloader {
      environment.systemPackages = [ piWrapper ];

      # configurationLimit=3 means the firmware partition holds up
      # to 3 generations. Boot-once stages a candidate as a 4th
      # potential slot via `nixos-rebuild boot`, which would evict
      # the oldest — and if that oldest happens to be the
      # currently-running LKG, we'd lose the rollback target. Warn
      # if there's no headroom over the typical case.
      #
      # mkDefault rather than mkForce so per-host overrides win;
      # the user might know their Pi has plenty of FAT space and
      # want more retention regardless.
      boot.loader.raspberry-pi.configurationLimit = lib.mkDefault 5;
    })
  ]);
}
