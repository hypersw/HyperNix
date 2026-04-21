{ config, lib, pkgs, ... }:

# ──────────────────────────────────────────────────────────────────────────────
# Boot-stability probe.
#
# Diagnostic module for the silent-hard-reset boot loop we hit on 2026-04-21
# (see PrintScanServer/PLAN.md). Defers the most-likely-culprit kernel modules
# past the brownout-prone first ~10 s of boot, then brings them up in sequence
# with before/after journal syncs so the journal has a durable record of which
# stage was in flight when (if) a reset occurs.
#
# This module does NOT fix a known root cause. It's a diagnostic tool: if the
# root cause was transient-current overlap during peripheral bring-up, the
# serialisation + delays here will reduce it; if it was something else, the
# stage-by-stage log will narrow down which subsystem is involved.
#
# ── What gets deferred ───────────────────────────────────────────────────────
# USB-A host controller (VL805 → xhci_pci): blacklisted at boot, modprobed
# after a delay. Side effect: scanner + printer USB unavailable during the
# first ~40 s of boot.
# Wi-Fi (brcmfmac): blacklisted at boot, modprobed after the USB stage.
# Side effect: SSH over Wi-Fi unavailable until the Wi-Fi stage completes.
# Ethernet (bcmgenet) is built into the kernel, not a module, so it is
# unaffected — plug in an Ethernet cable if you need reachable SSH during
# the deferral window.
#
# ── Electrical reality check ─────────────────────────────────────────────────
# Blacklisting xhci_pci stops software enumeration; it does NOT kill VBUS on
# the USB-A ports (port power is gated by the GPU firmware, before Linux
# runs) and it does NOT block a peripheral from back-feeding its own VBUS
# into the Pi's 5 V rail. To fully electrically isolate, unplug the USB
# cable. The deferral splits "electrical presence" from "enumeration" for
# isolating which one triggers the reset.
#
# ── Rescue if this ever produces an unbootable generation ───────────────────
#  1. At boot, U-Boot presents a menu of NixOS generations. With a monitor
#     and keyboard attached, pick the last-known-good one. This is the
#     standard NixOS rollback; no file edits needed.
#  2. If (1) isn't practical (closed case, no keyboard): pull the SD card,
#     mount on another Linux machine, edit
#     /boot/extlinux/extlinux.conf — comment out the `append …
#     modprobe.blacklist=…` line in the latest entry, or delete that entry
#     altogether to fall back to the previous generation.
#  3. The firmware partition (/boot/firmware/config.txt) is untouched by
#     this module; nothing here can brick the bootloader.
#
# ── Usage ────────────────────────────────────────────────────────────────────
# In machine configuration.nix:
#
#    services.boot-stability-probe.enable = true;
#
# Then `nixos-rebuild switch` + reboot. Captures one full staged bring-up
# per boot. Disable by flipping the option back to false + rebuild + reboot.
# ──────────────────────────────────────────────────────────────────────────────

let
  cfg = config.services.boot-stability-probe;

  # Modules deferred at kernel boot via cmdline. Must match modules modprobed
  # in order in the bringup service below.
  deferredModules = {
    usb  = [ "xhci_hcd_pci" "xhci_pci" ];
    wifi = [ "brcmfmac" "brcmfmac_wcc" "brcmutil" ];
  };

  allDeferred = deferredModules.usb ++ deferredModules.wifi;
in
{
  options.services.boot-stability-probe = {
    enable = lib.mkEnableOption "staged peripheral bring-up for boot-stability diagnosis";

    initialSettleSeconds = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = ''
        Seconds to wait after multi-user.target before the first module
        load. Chosen to push the first heavy peripheral bring-up well past
        the observed-critical ~8-10 s window.
      '';
    };

    stageGapSeconds = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        Seconds to wait between stages. Short enough to keep total boot
        to scan-readiness under a minute, long enough that a reset triggered
        by a stage is unambiguously attributable to it in the journal.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # Disable the modules at kernel boot time. The kernel parses this
    # cmdline and refuses to autoload anything in the list; our service
    # modprobes them explicitly later.
    boot.kernelParams = [
      "modprobe.blacklist=${lib.concatStringsSep "," allDeferred}"
    ];

    # Make journal-sync aggressive — default is async and a reset may catch
    # us between writes. SyncIntervalSec=1s bounds the worst-case loss
    # window to ~1 s in addition to the explicit syncs in the script.
    services.journald.extraConfig = lib.mkBefore ''
      SyncIntervalSec=1s
    '';

    systemd.services.peripheral-bringup = {
      description = "Staged peripheral bring-up for boot-stability diagnosis";
      # Runs once after multi-user.target. We intentionally do NOT require
      # network-online.target — we're the thing that brings the network up.
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Outer-bound: if something in the script hangs, don't wedge boot.
        TimeoutStartSec = "2min";
      };

      # Plain shell script — deliberately simple. Each stage: mark it,
      # modprobe the module list for that stage, capture modprobe exit
      # status, sync journal, wait.
      script = ''
        set +e   # continue on individual modprobe failure
        JOURNALCTL=${pkgs.systemd}/bin/journalctl
        MODPROBE=${pkgs.kmod}/bin/modprobe

        mono() { ${pkgs.gawk}/bin/awk '{print $1}' /proc/uptime; }
        log() { echo "peripheral-bringup[mono=$(mono)]: $*"; "$JOURNALCTL" --sync; }

        log "service starting, deferred modules: ${toString allDeferred}"
        log "initial settle: sleeping ${toString cfg.initialSettleSeconds} s"
        sleep ${toString cfg.initialSettleSeconds}

        # ─── stage 1: USB-A host controller (VL805) ───
        log "stage 1/2 USB: pre-load sync"
        for m in ${toString deferredModules.usb}; do
          log "stage 1/2 USB: modprobe $m"
          "$JOURNALCTL" --sync
          if "$MODPROBE" "$m"; then
            log "stage 1/2 USB: $m loaded OK"
          else
            log "stage 1/2 USB: $m modprobe FAILED (rc=$?)"
          fi
          "$JOURNALCTL" --sync
        done
        log "stage 1/2 USB: letting udev settle"
        ${pkgs.systemd}/bin/udevadm settle --timeout=15 || true
        "$JOURNALCTL" --sync
        log "stage 1/2 USB: complete; gap ${toString cfg.stageGapSeconds} s"
        sleep ${toString cfg.stageGapSeconds}

        # ─── stage 2: Wi-Fi (brcmfmac + firmware load over SDIO) ───
        log "stage 2/2 WiFi: pre-load sync"
        for m in ${toString deferredModules.wifi}; do
          log "stage 2/2 WiFi: modprobe $m"
          "$JOURNALCTL" --sync
          if "$MODPROBE" "$m"; then
            log "stage 2/2 WiFi: $m loaded OK"
          else
            log "stage 2/2 WiFi: $m modprobe FAILED (rc=$?)"
          fi
          "$JOURNALCTL" --sync
        done
        log "stage 2/2 WiFi: letting udev settle"
        ${pkgs.systemd}/bin/udevadm settle --timeout=15 || true
        "$JOURNALCTL" --sync
        log "stage 2/2 WiFi: kick wpa_supplicant (it gave up when wlan0 didn't appear)"
        ${pkgs.systemd}/bin/systemctl restart wpa_supplicant.service || \
          log "stage 2/2 WiFi: wpa_supplicant restart FAILED"
        "$JOURNALCTL" --sync

        log "complete. enumerated USB:"
        ${pkgs.usbutils}/bin/lsusb 2>&1 | while read -r line; do log "lsusb: $line"; done
        log "enumerated network:"
        ${pkgs.iproute2}/bin/ip -br link 2>&1 | while read -r line; do log "ip link: $line"; done
        "$JOURNALCTL" --sync
      '';
    };
  };
}
