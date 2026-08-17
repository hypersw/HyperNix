{ config, lib, pkgs, ... }:
#
# Print/scan server on a Raspberry Pi 4. The original board took
# 5 V damage on 2026-04-21 and is currently offline; the role is
# served by GhostHome (Pi 5) for now. The configuration here is
# actively maintained alongside GhostHome — flashing
# `PrintScanServerPi4-provisioning-sdImage` to a fresh Pi 4 brings
# the role back up via the same first-boot self-flip pattern
# GhostHome uses.
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
    # The whole HyperNix module-list: every sub-module + every
    # profile, loaded once. Activation is via option-setting
    # below (`hypersw.profiles.X.enable = true`,
    # `hypersw.services.boot-stability-probe.enable = true`, …).
    # See `Modules/default.nix` for the rationale on this shape.
    ../../../Modules
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

  # Bootloader: direct EEPROM kernel boot via nvmd's loader,
  # forced — overrides nvmd's `mkDefault "uboot"` for Pi 4. Same
  # mode as GhostHome (Pi 5) for fleet uniformity. The mechanism
  # is implemented generically in nvmd; no upstream user has
  # confirmed it on Pi 4, so we're first — if it fails we fall
  # back to `lib.mkForce "uboot"` (or remove the override
  # entirely to inherit nvmd's default).
  boot.loader.raspberry-pi.bootloader = lib.mkForce "kernel";
  boot.loader.raspberry-pi.configurationLimit = 3;

  # (Second workaround for nvmd's linux-kernel.target read reverted
  # in lockstep with the GhostHome sibling — see that config for the
  # rationale.)

  # Kernel: nvmd's linuxPackages_rpi4 (Pi-Foundation patch
  # series) — set by raspberry-pi-4.base in flake.nix. Prebuilt
  # in their binary cache at nixos-raspberrypi.cachix.org so we
  # don't pay the rebuild cost we used to with nixpkgs'
  # un-cached linuxPackages_rpi4.

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
  hypersw.services.boot-stability-probe.enable = true;

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
  # AnyMachineBase carries everything every NixOS host we run
  # wants — auto-rebuild, telegram-alerts, sshd, the admin user,
  # and on non-container hosts also redistributable firmware,
  # zram, swap, /tmp on tmpfs, noatime on /. The container-only
  # gate means it imports cleanly into nspawn configs too;
  # everything below the gate auto-skips for them.
  hypersw.profiles.anyMachineBase = {
    enable = true;
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

  hypersw.profiles.multiHomedNetworking.enable = true;

  # Weekly upgrade uses the sandbox-first transactional flow — mirror
  # of the enable line in ../GhostHome/configuration.nix. See the
  # module docstring for the failure-mode analysis.
  hypersw.system.autoUpgradeTransactional.enable = true;

  hypersw.profiles.printScanServer = {
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
