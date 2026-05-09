{ config, lib, pkgs, ... }:
#
# PhysicalServerBase profile — physical-server-specific bits on top
# of AnyMachineBase. Pulls AnyMachineBase in via imports + auto-
# enables it; everything in this profile assumes there's actual
# hardware involved (RAM-backed swap, USB-attached devices, WiFi/
# BT firmware blobs).
#
# What lives here (vs AnyMachineBase): hardware firmware blobs,
# zramSwap + on-disk swap, vm.swappiness, /tmp on tmpfs, noatime
# on root, usbutils. None of these are right for microVMs and
# may be wrong for ephemeral containers.
#
let
  cfg = config.profiles.physicalServerBase;
in
{
  imports = [
    ../AnyMachineBase
  ];

  options.profiles.physicalServerBase = {
    enable = lib.mkEnableOption "Physical-server bundle on top of AnyMachineBase";

    redistributableFirmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install non-free firmware blobs from
        <literal>linux-firmware</literal>. Default true because most
        physical servers we run want WiFi / BT firmware (Pi 4/5,
        x86 laptops with Intel/Atheros radios). Disable for
        FOSS-only hosts that explicitly don't want the blobs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # PhysicalServerBase implies AnyMachineBase. Caller can still
    # set anyMachineBase.enable = false explicitly if they want only
    # the disk/swap/firmware bits below; in practice nobody does.
    profiles.anyMachineBase.enable = lib.mkDefault true;

    # ── firmware ────────────────────────────────────────────────────
    hardware.enableRedistributableFirmware = cfg.redistributableFirmware;

    # ── memory ──────────────────────────────────────────────────────
    # zramSwap first (compressed RAM), disk-backed swap as the OOM
    # safety net. Suits the typical "homelab box with 1-4 GB RAM and
    # disk you don't want to wear out" shape.
    zramSwap = {
      enable = true;
      memoryPercent = 50;
      algorithm = "zstd";
    };
    swapDevices = [{
      device = "/var/swapfile";
      size = 2048;
    }];
    boot.kernel.sysctl."vm.swappiness" = 1;

    # ── disk-write minimisation ─────────────────────────────────────
    # /tmp on tmpfs — works on any non-pathological RAM budget; small
    # enough tmp jobs use real fs only when explicitly directed.
    boot.tmp.useTmpfs = true;
    fileSystems."/".options = lib.mkDefault [ "noatime" ];

    # ── physical-host tools ─────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      usbutils
    ];
  };
}
