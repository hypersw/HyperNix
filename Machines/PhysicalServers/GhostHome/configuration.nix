{ config, lib, pkgs, ... }:
#
# GhostHome — Raspberry Pi 5 home-automation server.
#
# The print/scan stack is a temporary guest service on this host
# until a dedicated home-automation workload (Home Assistant /
# Zigbee2MQTT / etc.) takes its place as the headline role; the
# branding (hostname, mDNS publication, log header) is GhostHome
# regardless.
#
# Most of the configuration lives in three profile modules
# (PhysicalServerBase / PrintScanServer / MultiHomedNetworking).
# What stays here is genuinely Pi-5-specific or specific to this
# physical box:
#   - Pi-5 SD-card layout
#   - kernel choice (rationale below)
#   - WiFi network details
#   - the administrator's ssh key
#   - sops file + the per-machine age key
#
{
  imports = [
    # The whole HyperNix module-list: every sub-module + every
    # profile, loaded once. Activation is via option-setting
    # below (`hypersw.profiles.X.enable = true`, etc.). See
    # `Modules/default.nix` for the rationale on this shape.
    ../../../Modules
  ];

  networking.hostName = "GhostHome";
  system.stateVersion = "25.05";

  # Filesystems — RPi5 SD-card layout (same NIXOS_SD / FIRMWARE
  # labels the sd-image-aarch64 module emits as on Pi 4). Switch
  # to NVMe-by-uuid once we move off SD.
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

  # Bootloader: direct EEPROM kernel boot via nvmd's loader
  # (`boot.loader.raspberry-pi.bootloader = "kernel"`). The
  # firmware partition holds the kernel image + initrd + cmdline
  # directly; the Pi 5 EEPROM loads them and jumps into Linux
  # with no u-boot in the chain.
  #
  # Why no u-boot: upstream u-boot's Pi 5 USB-MSD support is
  # broken — RP1/PCIe driver isn't there, so u-boot hangs trying
  # to enumerate the USB SSD on Pi 5 (SUSE engineers' explicit
  # 2025-11 statement). The Pi 5 EEPROM itself reads USB fine, so
  # skipping u-boot dodges the only problem layer.
  #
  # Generation retention: 3 (last three system generations are
  # kept under /boot/firmware/nixos/<N>/ for manual rollback —
  # mount the FAT partition on another box, copy a previous gen's
  # files over the FAT root to recover from a bad upgrade).
  boot.loader.raspberry-pi.bootloader = "kernel";
  boot.loader.raspberry-pi.configurationLimit = 3;

  # Kernel comes from nvmd's Pi-5-vendor package
  # (linuxPackages_rpi5, Foundation patch series) — set by
  # raspberry-pi-5.base in flake.nix. Their binary cache at
  # nixos-raspberrypi.cachix.org has it prebuilt, so we don't
  # pay the rebuild cost we'd have paid going through
  # nixpkgs' uncached linuxPackages_rpi5.

  # Headless boot tweaks — same rationale as the Pi 4 config but
  # without the brownout-mitigation bundle. Pi 5's PMIC + 5 V power
  # path are well-behaved out of the box, so we don't ship the
  # boot-stability-probe staged peripheral bring-up nor the
  # vcgencmd throttle-history sampler. Re-add if we actually
  # observe brownout symptoms.
  boot.kernelParams = [
    # HDMI temporarily kept ON during initial bring-up. The
    # original intent was "headless server, no monitor at steady
    # state, save a hair of GPU + framebuffer memory by killing
    # the connectors entirely". But during this Pi 5's first
    # weeks on USB-SSD storage we want to be able to plug a
    # monitor in and see kernel boot text / oops messages when
    # diagnosing post-switch hangs — `video=…:d` blanks the
    # framebuffer console and removes that diagnostic channel.
    # Re-enable the two `video=HDMI-A-X:d` lines once the live
    # config is unambiguously stable.
    # "video=HDMI-A-1:d"
    # "video=HDMI-A-2:d"

    # ramoops region for kernel-triggered-reset forensics. Doesn't
    # catch full power loss (RAM is wiped); useful for kernel
    # oopses / panics that survive a warm reboot.
    "ramoops.mem_address=0x08000000"
    "ramoops.mem_size=0x100000"
    "ramoops.record_size=0x20000"
    "ramoops.console_size=0x20000"
    "ramoops.ecc=1"
  ];
  boot.kernelModules = [ "ramoops" ];

  # Disable the BT/camera kernel modules. Pi 5 uses a similar
  # BCM43xx WiFi/BT silicon and the same camera-ribbon CSI on
  # bcm2835_v4l2; blacklisting BT trims a small amount of init
  # work and protects against any camera-ribbon probing on a
  # board with no camera attached.
  boot.blacklistedKernelModules = [
    "btbcm" "hci_uart" "bluetooth"
    "bcm2835_v4l2" "bcm2835_mmal_vchiq"
  ];
  hardware.bluetooth.enable = false;

  # Wireless: the AP we attach to. Pi 5's BCM4345 onboard radio
  # supports the same WPA2-PPSK / 5 GHz the Pi 4 uses — same
  # network entry, same hidden-SSID quirk.
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

  # Expand root partition to fill the SD card on first boot.
  boot.growPartition = true;

  # ── Secrets (sops-nix) ──
  # Per-machine sops file. The template was seeded from the Pi 4
  # config but needs to be re-encrypted to GhostHome's age key
  # (derived from the host's ssh ed25519 key, available after
  # first boot). Until that's done, the bot / alerts / wpa_
  # supplicant services will fail to start with sops decrypt
  # errors — expected before initial provisioning.
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Naming convention: UpperCamelCase, <Owner><LocalName> — see
    # the matching block in PrintScanServerPi4's configuration.nix
    # for the full reasoning. Keep the same names across machines
    # so the profile wiring is uniform.
    secrets.MonitoringTelegramBotToken = {};
    # Always-channel: bot's C# normaliser accepts bare positive id
    # and prepends "-100" if missing.
    secrets.MonitoringTelegramAlertsChatId = {};
    secrets.MonitoringTelegramLogChatId = {};
    secrets.PrintScanTelegramBotToken = {};
    secrets.MachineWifiPsk = {};

    templates."wpa-secrets" = {
      # `psk_iot` is the wpa_supplicant-internal variable name
      # referenced by `pskRaw = "ext:psk_iot"`, not the sops key.
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
        # Same key as the Pi 4 administrator — same human, same
        # device — until you provision a fresh GhostHome key.
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLESV1KGuOruuV5JdUr8wS8iQyIfEeYdJz2MC5zNCOjoTqzJpA3j5e3kdXbyFczRK25o5bFlThHzK2kmwmCE4zE= printscan-administrator"
      ];
    };
    alerts = {
      tokenFile        = config.sops.secrets.MonitoringTelegramBotToken.path;
      alertsChatIdFile = config.sops.secrets.MonitoringTelegramAlertsChatId.path;
      logChatIdFile    = config.sops.secrets.MonitoringTelegramLogChatId.path;
    };
    localFlake.configurationName = "GhostHome";
  };

  # Pi-host-side networking — networkd, per-interface DHCP/
  # routing, ARP-strict sysctls + iptables CONNMARK source
  # routing for the end0+wlan0 dual-interface bridge case, Avahi
  # mDNS publication of `ghosthome.local`, resolved as stub
  # resolver. Re-enabled here because the first phase-1 attempt
  # disabled it along with printScanServer; that was overzealous
  # — multiHomedNetworking has no x86_64 build dependencies and
  # is genuinely required for the Pi to be reachable on the LAN
  # by hostname.
  hypersw.profiles.multiHomedNetworking.enable = true;

  # ── PrintScanServer (workload, not infrastructure) — off ───
  # PHASE 1 (now): GhostHome boots, is reachable, has telemetry,
  # auto-rebuilds-on-push. No print/scan workload.
  # PHASE 2 (later, interactively from the booted live config):
  # uncomment the block below and resolve whatever breaks. It
  # was the cause of the first-boot build failure — the
  # EpkowaScanner leg pulls in an x86_64-linux derivation (the
  # proprietary Epson interpreter stub) and the provisioning
  # image / Pi build host doesn't have qemu-x86_64 binfmt
  # registered, so the cross-arch derivation can't be built.
  # Tractable but not on the critical path.
  #
  # hypersw.profiles.printScanServer = {
  #   enable = true;
  #   bot = {
  #     tokenFile = config.sops.secrets.PrintScanTelegramBotToken.path;
  #     allowedUsers = [
  #       { id = 1398173959; name = "hypersw"; }
  #       { id = 2074641026; name = "ol"; }
  #       { id = 6935307009; name = "alice"; }
  #     ];
  #   };
  # };
}
