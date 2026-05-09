{ config, lib, pkgs, ... }:
#
# Print/scan server on a Raspberry Pi 4 — the original deployment
# (now decommissioned; replaced by GhostHome on Pi 5). Kept here as
# a reference for what was specific to this hardware revision in
# case a Pi 4 ever gets re-flashed.
#
# Most of the configuration lives in three profile modules
# (PhysicalServerBase / PrintScanServer / MultiHomedNetworking).
# What stays here is genuinely Pi-4-specific or specific to this
# physical box:
#   - Pi-4 SD-card layout, kernel choice, firmware blob hint
#   - brownout-targeting kernel tweaks
#   - WiFi network details (HyperAir.IotPsk)
#   - the administrator's ssh key
#   - sops file + the per-machine age key
#
{
  imports = [
    ../../../Modules/Profiles/PhysicalServerBase
    ../../../Modules/Profiles/PrintScanServer
    ../../../Modules/Profiles/MultiHomedNetworking
    # Pi-specific diagnostic — staged peripheral bring-up after the
    # 2026-04-22 silent-reset boot loop. Pi-4-specific.
    ../../../Modules/System/BootStabilityProbe
  ];

  networking.hostName = "printscan";
  system.stateVersion = "25.05";

  # Filesystems — RPi4 SD card layout (set by sd-image module on
  # first flash, then referenced directly for subsequent
  # nixos-rebuild). The sd-image module is only used for CI image
  # builds, not runtime config.
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

  # Use the generic aarch64 kernel instead of the RPi-specific one.
  # The nixos-hardware raspberry-pi-4 module selects linuxPackages_rpi4
  # which uses a custom kernel (linux-rpi) that is NOT in cache.nixos.org.
  # Every nixpkgs update would trigger a kernel recompile — 4-8 hours on
  # the Pi, 1-2 hours under QEMU emulation on CI.
  boot.kernelPackages = pkgs.linuxPackages;

  # ── Pi 4 brownout-mitigation kernel tweaks ──────────────────────
  # Context: 2026-04-21 we observed this Pi enter a 19-cycle silent-
  # reset boot loop. Root cause not identified; suspected transient
  # 5 V droop tripping the brownout reset path without crossing the
  # PMIC warning threshold. Removing unused subsystems from the
  # boot-time init parallel reduces the transient-current AUC.

  boot.blacklistedKernelModules = [
    "btbcm" "hci_uart" "bluetooth"     # BT — unused on this server
    "bcm2835_v4l2" "bcm2835_mmal_vchiq"  # camera — none attached
  ];
  hardware.bluetooth.enable = false;

  boot.kernelParams = [
    # HDMI off — headless server, never has a monitor attached.
    "video=HDMI-A-1:d"
    "video=HDMI-A-2:d"

    # ramoops region for kernel-triggered-reset forensics. Survives
    # warm reboot; systemd-pstore.service copies it on next boot.
    # Doesn't catch full-power-loss / brownout (RAM is wiped).
    "ramoops.mem_address=0x08000000"
    "ramoops.mem_size=0x100000"
    "ramoops.record_size=0x20000"
    "ramoops.console_size=0x20000"
    "ramoops.ecc=1"
  ];
  boot.kernelModules = [ "ramoops" ];

  # Defers USB-A (xhci_pci) and Wi-Fi (brcmfmac) past the brownout-
  # prone first ~10 s of boot, then brings them up serially with
  # aggressive journal syncs. Pi 4-specific diagnostic.
  services.boot-stability-probe.enable = true;

  # Throttle history sampler — vcgencmd's get_throttled is "events
  # since last boot", so brownout resets wipe it. Persistent log
  # captures sub-brownout sags.
  systemd.services.throttle-history = {
    description = "Log RPi undervoltage/throttle state to /var/log/throttle.log";
    serviceConfig = {
      WorkingDirectory = "/var/empty";
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "throttle-history" ''
        VCGENCMD=${pkgs.libraspberrypi}/bin/vcgencmd
        TS=$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
        VAL=$("$VCGENCMD" get_throttled 2>&1 | ${pkgs.coreutils}/bin/tr -d '\n')
        VOLT=$("$VCGENCMD" measure_volts core 2>&1 | ${pkgs.coreutils}/bin/tr -d '\n')
        TEMP=$("$VCGENCMD" measure_temp 2>&1 | ${pkgs.coreutils}/bin/tr -d '\n')
        ${pkgs.coreutils}/bin/echo "$TS $VAL $VOLT $TEMP" >> /var/log/throttle.log
      '';
    };
  };

  systemd.timers.throttle-history = {
    description = "Sample RPi throttle state every 5 min";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };

  # Wireless: machine-specific because the WiFi network details
  # vary per box. The CONNMARK / per-interface routing for end0 +
  # wlan0 is set up by the MultiHomedNetworking profile.
  networking.wireless = {
    enable = true;
    secretsFile = config.sops.templates."wpa-secrets".path;
    extraConfig = "p2p_disabled=1";
    networks."HyperAir.IotPsk" = {
      pskRaw = "ext:psk_iot";
      hidden = true;
    };
  };
  systemd.services.wpa_supplicant = {
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
  };

  # Expand root partition to fill the SD card on first boot
  boot.growPartition = true;

  # ── Secrets (sops-nix) ──
  # Per-machine sops file, decrypted via this Pi's ssh host ed25519
  # key (derived to age via sops-nix). Each secret is consumed
  # downstream by a profile option set in this same file.
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Naming convention: UpperCamelCase, <Owner><LocalName>. The
    # owner is the top-level concern (Monitoring / PrintScan /
    # Machine). UpperCamelCase keeps the Nix-side accessor clean
    # — `config.sops.secrets.PrintScanTelegramBotToken.path` reads
    # without quoting and without the hyphen-vs-subtraction
    # ambiguity kebab-case carries.
    secrets.MonitoringTelegramBotToken = {};
    # Always-channel: the bot's C# normaliser accepts a bare
    # positive id and prepends "-100" if missing. Group ids (also
    # negative, but without the -100 prefix) are not expected here
    # — keep this for channels only.
    secrets.MonitoringTelegramAlertsChatId = {};
    secrets.MonitoringTelegramLogChatId = {};
    secrets.PrintScanTelegramBotToken = {};
    secrets.MachineWifiPsk = {};

    templates."wpa-secrets" = {
      # `psk_iot` here is wpa_supplicant's variable-name in its
      # secrets file — referenced by `pskRaw = "ext:psk_iot"`
      # below. Not the sops key name (that's MachineWifiPsk).
      content = "psk_iot=${config.sops.placeholder."MachineWifiPsk"}";
      owner = "wpa_supplicant";
    };
  };

  # ── Profile wiring ──
  # PhysicalServerBase auto-enables AnyMachineBase; per-host
  # data goes on the more general (anyMachineBase) namespace
  # because admin / alerts / localFlake apply to any NixOS host
  # we run, not just physical ones.
  profiles.physicalServerBase.enable = true;

  profiles.anyMachineBase = {
    administrator = {
      name = "administrator";
      authorizedKeys = [
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLESV1KGuOruuV5JdUr8wS8iQyIfEeYdJz2MC5zNCOjoTqzJpA3j5e3kdXbyFczRK25o5bFlThHzK2kmwmCE4zE= printscan-administrator"
      ];
    };
    alerts = {
      tokenFile        = config.sops.secrets.MonitoringTelegramBotToken.path;
      alertsChatIdFile = config.sops.secrets.MonitoringTelegramAlertsChatId.path;
      logChatIdFile    = config.sops.secrets.MonitoringTelegramLogChatId.path;
    };
    localFlake.configurationName = "PrintScanServerPi4";
  };

  profiles.multiHomedNetworking.enable = true;

  profiles.printScanServer = {
    enable = true;
    bot = {
      tokenFile = config.sops.secrets.PrintScanTelegramBotToken.path;
      allowedUsers = [
        { id = 1398173959; name = "hypersw"; }
        { id = 2074641026; name = "ol"; }
        { id = 6935307009; name = "alice"; }
      ];
    };
  };

  # (`scanner` + `lp` group membership for the administrator user
  # is now appended by the print-scan profile itself, gated on
  # which legs are enabled. No machine-side wiring needed.)
}
