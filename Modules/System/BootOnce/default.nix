{ config, lib, pkgs, ... }:
#
# BootOnce — `nixos-rebuild-boot-once` wrapper for tryboot-style
# one-shot kernel testing on Pi 5.
#
# ## Workflow
#
#   1. `sudo nixos-rebuild-boot-once --flake …` — builds the
#      candidate, stages its files into a sidecar directory, marks
#      config.txt's [tryboot] section. Exits without rebooting,
#      same posture as `nixos-rebuild boot`.
#   2. `sudo tryboot-reboot` — explicit second action. Reboots
#      into the EEPROM's tryboot mode. Until this command runs,
#      the Pi keeps running the current LKG; the [tryboot]
#      configuration is staged but dormant.
#   3. If the candidate boots cleanly, SSH in, verify by hand,
#      then promote with the ordinary `sudo nixos-rebuild boot`
#      (which runs nvmd's regular bootloader stage and makes the
#      candidate's gen the new default — also wipes the [tryboot]
#      section as a side effect of nvmd rewriting config.txt
#      from its template).
#   4. If the candidate doesn't come back (kernel panic, missing
#      driver, network broken in initrd), pull power. The EEPROM's
#      one-shot flag was consumed by the failed attempt; the next
#      boot reads `config.txt`'s [all] block and the LKG kernel
#      returns. Zero userspace cooperation, enforced by firmware
#      before the kernel runs.
#
#   Splitting stage and reboot has a useful safety property: if
#   the operator stages a candidate then runs `nixos-rebuild
#   boot` or `nixos-rebuild switch` (or auto-rebuild fires) BEFORE
#   triggering the tryboot, nvmd's regular bootloader stage runs
#   on the next switch and rewrites config.txt from the template
#   — wiping the [tryboot] section and the stale candidate is
#   cleaned up by removeObsoleteGenerations on the next stage.
#   No leaked tryboot state across day-to-day rebuilds.
#
# ## Critical design invariant: [all] is never touched
#
# This module's wrapper script writes to two things, both isolated
# from the live boot path:
#
#   1. `/boot/firmware/nixos/tryboot/` — a fresh per-gen directory
#      we own exclusively. nvmd's regular bootloader stage doesn't
#      use this name (it uses `default/` and `<N>-default/`), and
#      its retention logic leaves it untouched. Our wrapper rebuilds
#      this directory atomically (.tmp.$$ + mv) on each run.
#
#   2. The `[tryboot]` section of `/boot/firmware/config.txt`. We
#      strip any prior `[tryboot]` block (awk-based, range-scoped)
#      and append a fresh one pointing at `nixos/tryboot/`. The
#      `[all]` section and every other filter section are read but
#      never modified. We write atomically (to a tempfile, then mv).
#
# Net effect: if the wrapper crashes at *any* point, the worst case
# is a truncated `[tryboot]` block at the end of config.txt — which
# the Pi EEPROM ignores in non-tryboot mode. The LKG boot path
# (config.txt's [all] -> nixos/default/) is structurally invariant
# under our script's behaviour.
#
# ## Implementation note: staging primitives
#
# This module currently does its own minimal file-copy into
# `nixos/tryboot/` — kernel.img, initrd, cmdline.txt, DTBs, overlays.
# It pins to nvmd's current Pi-5-`kernel`-bootloader file-layout
# conventions (matches `kernelboot-gen-builder.sh` +
# `install-device-tree.sh` from nvmd/nixos-raspberrypi as of
# 2026-05).
#
# An upstream nvmd patch is queued (`stageGenCmd` option in
# `boot.loader.raspberry-pi`, see
# https://github.com/nvmd/nixos-raspberrypi) that exposes nvmd's
# per-gen builder as a primitive. Once it lands and we bump nvmd,
# the wrapper switches to using `config.boot.loader.raspberry-pi.stageGenCmd`
# instead of the inline shell — same external behaviour, drops the
# divergence-risk surface.
#
let
  cfg = config.hypersw.system.bootOnce;

  isPiKernelBootloader =
    (config.boot.loader.raspberry-pi.bootloader or null) == "kernel";

  # Future: when nvmd's stageGenCmd option lands upstream + we bump,
  # this branch will pick up the official primitive and the
  # `inlineStage` body below becomes a fallback for older nvmd.
  hasUpstreamStageCmd =
    (config.boot.loader.raspberry-pi.stageGenCmd or null) != null;

  # Companion to nixos-rebuild-boot-once — fires the actual tryboot
  # reboot once the operator is ready. Kept separate so the
  # stage step matches `nixos-rebuild boot` semantics (mark for
  # next boot, don't reboot now); the reboot is the operator's
  # explicit second action, same as `sudo reboot` after the
  # vanilla `nixos-rebuild boot` flow.
  trybootRebootWrapper = pkgs.buildPackages.writeShellApplication {
    name = "tryboot-reboot";
    runtimeInputs = with pkgs.buildPackages; [
      coreutils gnugrep systemd
    ];
    text = ''
      # tryboot-reboot — reboot into the Pi 5 EEPROM's tryboot mode.
      # Pre-flight check: refuse to fire if config.txt has no
      # [tryboot] section (= nothing was staged, the reboot would
      # be a wasted round-trip into the current LKG).

      if [ "$EUID" -ne 0 ]; then
        echo "error: must be run as root (try: sudo tryboot-reboot)" >&2
        exit 1
      fi

      CONFIG=/boot/firmware/config.txt

      if [ ! -f "$CONFIG" ]; then
        echo "error: $CONFIG not found — Pi-firmware-managed boot not detected." >&2
        exit 1
      fi

      if ! grep -q '^\[tryboot\]' "$CONFIG"; then
        echo "error: no [tryboot] section in $CONFIG — nothing to try." >&2
        echo "       run \`sudo nixos-rebuild-boot-once …\` first." >&2
        exit 1
      fi

      echo "==> rebooting into tryboot mode in 5s — Ctrl+C aborts."
      echo "    on failure to come back, power-cycle to revert."
      sleep 5
      systemctl reboot --reboot-argument="0 tryboot"
    '';
  };

  piWrapper = pkgs.buildPackages.writeShellApplication {
    name = "nixos-rebuild-boot-once";
    runtimeInputs = with pkgs.buildPackages; [
      coreutils gnugrep gawk gnused systemd
    ];
    text = ''
      # nixos-rebuild-boot-once — build a NixOS generation and queue
      # it as a one-shot Pi 5 tryboot. Power-cycle on failure reverts;
      # `nixos-rebuild boot` from inside the candidate promotes.
      #
      # Args pass through to `nixos-rebuild build`:
      #   sudo nixos-rebuild-boot-once --flake /etc/nixos#default
      #   sudo nixos-rebuild-boot-once --flake github:hypersw/HyperNix#GhostHome

      if [ "$EUID" -ne 0 ]; then
        echo "error: must be run as root (try: sudo nixos-rebuild-boot-once …)" >&2
        exit 1
      fi

      FIRMWARE_DIR=/boot/firmware
      CONFIG="$FIRMWARE_DIR/config.txt"
      CANDIDATE_NAME=tryboot
      CANDIDATE_DIR="$FIRMWARE_DIR/nixos/$CANDIDATE_NAME"

      if [ ! -f "$CONFIG" ]; then
        echo "error: $CONFIG not found — Pi-firmware-managed boot not detected." >&2
        echo "       boot-once is currently wired only for the Pi 5 'kernel' bootloader." >&2
        exit 1
      fi

      # 1) Build the candidate system. `nixos-rebuild build` doesn't
      #    touch /boot/firmware, doesn't run activation, just produces
      #    a system store path under ./result (or wherever cwd is).
      #    Run from /tmp to avoid leaving a ./result symlink in the
      #    operator's working dir.
      WORKDIR=$(mktemp -d)
      cleanup_workdir() { rm -rf "$WORKDIR" 2>/dev/null || true; }
      trap cleanup_workdir EXIT

      echo "==> building candidate via 'nixos-rebuild build $*'…"
      (cd "$WORKDIR" && nixos-rebuild build "$@")

      SYSTEM_PATH=$(readlink -f "$WORKDIR/result")
      if [ -z "$SYSTEM_PATH" ] || [ ! -d "$SYSTEM_PATH" ]; then
        echo "error: nixos-rebuild build ran but no result symlink at $WORKDIR/result" >&2
        exit 1
      fi
      if [ ! -f "$SYSTEM_PATH/kernel" ] || [ ! -f "$SYSTEM_PATH/initrd" ]; then
        echo "error: candidate $SYSTEM_PATH missing kernel/initrd" >&2
        exit 1
      fi
      echo "    candidate: $SYSTEM_PATH"

      # 2) Stage the candidate into $CANDIDATE_DIR atomically.
      #    Replicates the file layout nvmd's `kernelboot-gen-builder.sh`
      #    + `install-device-tree.sh` produce, minus the system-link
      #    and kernel-link bookkeeping files (which nvmd uses for
      #    its own state tracking — the Pi EEPROM doesn't read them).
      #
      #    Pinned to nvmd's behaviour as of 2026-05: kernel.img,
      #    initrd, cmdline.txt, *.dtb, overlays/*. Re-verify on nvmd
      #    bumps; switch to the upstream `stageGenCmd` primitive when
      #    available.
      STAGE_TMP="$CANDIDATE_DIR.tmp.$$"
      cleanup_stage() {
        cleanup_workdir
        rm -rf "$STAGE_TMP" 2>/dev/null || true
      }
      trap cleanup_stage EXIT

      mkdir -p "$STAGE_TMP"

      cp "$(readlink -f "$SYSTEM_PATH/kernel")" "$STAGE_TMP/kernel.img.tmp"
      mv "$STAGE_TMP/kernel.img.tmp" "$STAGE_TMP/kernel.img"

      cp "$(readlink -f "$SYSTEM_PATH/initrd")" "$STAGE_TMP/initrd.tmp"
      mv "$STAGE_TMP/initrd.tmp" "$STAGE_TMP/initrd"

      # cmdline.txt mirrors what nvmd writes: kernel-params + init=
      # pointing at the candidate system's init script.
      printf '%s init=%s/init\n' \
        "$(cat "$SYSTEM_PATH/kernel-params")" \
        "$SYSTEM_PATH" \
        > "$STAGE_TMP/cmdline.txt"

      # DTBs: $SYSTEM_PATH/dtbs/ is a symlink to the kernel package's
      # device-tree output. Pi-vendor kernels lay broadcom DTBs under
      # broadcom/, but EEPROM looks at $os_prefix/ root — so we
      # flatten broadcom/*.dtb into the gen dir alongside any
      # top-level .dtb files.
      DTB_SRC=$(readlink -f "$SYSTEM_PATH/dtbs" 2>/dev/null || true)
      if [ -n "$DTB_SRC" ] && [ -d "$DTB_SRC" ]; then
        shopt -s nullglob
        for dtb in "$DTB_SRC"/*.dtb "$DTB_SRC"/broadcom/*.dtb; do
          cp "$dtb" "$STAGE_TMP/$(basename "$dtb").tmp"
          mv "$STAGE_TMP/$(basename "$dtb").tmp" "$STAGE_TMP/$(basename "$dtb")"
        done
        if [ -d "$DTB_SRC/overlays" ]; then
          mkdir -p "$STAGE_TMP/overlays"
          for ovr in "$DTB_SRC/overlays"/*; do
            cp "$ovr" "$STAGE_TMP/overlays/$(basename "$ovr").tmp"
            mv "$STAGE_TMP/overlays/$(basename "$ovr").tmp" \
               "$STAGE_TMP/overlays/$(basename "$ovr")"
          done
        fi
        shopt -u nullglob
      fi

      # Swap into place atomically — single mv at the parent level.
      rm -rf "$CANDIDATE_DIR.bkp.$$" 2>/dev/null || true
      if [ -d "$CANDIDATE_DIR" ]; then
        mv "$CANDIDATE_DIR" "$CANDIDATE_DIR.bkp.$$"
      fi
      mv "$STAGE_TMP" "$CANDIDATE_DIR"
      rm -rf "$CANDIDATE_DIR.bkp.$$" 2>/dev/null || true

      # 3) Replace the [tryboot] block in config.txt atomically.
      #    awk-based: strip any prior [tryboot] section (from header
      #    until the next section header), then append a fresh one.
      #    The [all] block and every other section pass through
      #    unmodified.
      CONFIG_TMP=$(mktemp "$FIRMWARE_DIR/.config.txt.new.XXXXXX")
      awk '
        /^\[tryboot\]$/ { in_tryboot = 1; next }
        in_tryboot && /^\[/ { in_tryboot = 0 }
        !in_tryboot { print }
      ' "$CONFIG" > "$CONFIG_TMP"

      {
        echo ""
        echo "[tryboot]"
        echo "os_prefix=nixos/$CANDIDATE_NAME/"
      } >> "$CONFIG_TMP"

      sync
      mv "$CONFIG_TMP" "$CONFIG"
      sync

      cat <<BANNER

      ================================================================
        Candidate staged for one-shot boot via Pi 5 tryboot.
          candidate dir: $CANDIDATE_DIR/
          [tryboot] os_prefix=nixos/$CANDIDATE_NAME/

        Did NOT reboot. To trigger the tryboot, run:
          sudo tryboot-reboot
          # or equivalently:
          sudo systemctl reboot --reboot-argument="0 tryboot"

        Until the tryboot is triggered, the Pi continues running
        the current LKG normally. Any nixos-rebuild boot / switch
        in the meantime cleanly wipes the [tryboot] state.

        AFTER YOU TRIGGER THE TRYBOOT REBOOT:
          On success: ssh in, verify everything you care about, then
                       \`sudo nixos-rebuild boot\` to promote the
                       candidate to LKG (nvmd's normal stage takes
                       over from here).
          On failure: power-cycle the Pi. The unconsumed [all] block
                       in config.txt boots the previous kernel.
      ================================================================

      BANNER
    '';
  };
in {
  options.hypersw.system.bootOnce = {
    enable = lib.mkEnableOption ''
      `nixos-rebuild-boot-once` + `tryboot-reboot` — split-action
      one-shot kernel testing on Pi 5.

      `nixos-rebuild-boot-once` stages a candidate generation and
      marks config.txt's [tryboot] section. It does NOT reboot —
      that matches `nixos-rebuild boot` semantics. The Pi keeps
      running the current LKG until the operator explicitly
      triggers a tryboot reboot via the companion `tryboot-reboot`
      command (or directly via
      `systemctl reboot --reboot-argument="0 tryboot"`).

      Power-cycle from inside the tryboot reverts to LKG.
      `nixos-rebuild boot` from inside the candidate promotes it.
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
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

      # Future-proofing: warn if upstream nvmd grows the stageGenCmd
      # primitive — at that point we should refactor this wrapper to
      # delegate to it rather than vendoring the file-copy logic.
      warnings = lib.optional hasUpstreamStageCmd ''
        nvmd's `boot.loader.raspberry-pi.stageGenCmd` is now
        available upstream. The BootOnce module is still using its
        inline vendored stage; switch the wrapper at
        Modules/System/BootOnce to delegate to that option instead
        and drop the inline shell.
      '';
    }

    (lib.mkIf isPiKernelBootloader {
      environment.systemPackages = [ piWrapper trybootRebootWrapper ];

      # Bumped from nvmd's default of 4 so a staged tryboot candidate
      # has FAT-partition headroom alongside the active default and
      # rotated-out gens. Per-host configs can override.
      boot.loader.raspberry-pi.configurationLimit = lib.mkDefault 5;
    })
  ]);
}
