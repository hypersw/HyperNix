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
    ../../../Modules/Profiles/PhysicalServerBase
    ../../../Modules/Profiles/PrintScanServer
    ../../../Modules/Profiles/MultiHomedNetworking
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

  # Bootloader: extlinux on /boot/firmware (the same pattern as the
  # Pi 4 deployment). The nixos-hardware raspberry-pi-5 module
  # doesn't toggle this on by default the way the Pi 4 module does,
  # so we have to set it explicitly here. GRUB is disabled to
  # silence its "configure boot.loader.grub.devices" assertion.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Generic aarch64 kernel rather than linuxPackages_rpi5. Two
  # reasons:
  #   1. Cache. linuxPackages_rpi5 is a custom kernel (linux-rpi
  #      with the Foundation's patch series), not present in
  #      cache.nixos.org. Every nixpkgs bump rebuilds it from
  #      source; on a Pi 5 that's still 30–60 minutes of CPU per
  #      kernel rev. The generic mainline kernel is always cached.
  #   2. The Foundation patches we'd give up — GPU / camera /
  #      hardware-video-decode / HAT overlays — are irrelevant on
  #      a headless server. The mainline ARM64 kernel has full
  #      Pi 5 support (BCM2712, V3D Pi-5 GPU via vc4 driver,
  #      onboard NIC, USB-C, etc) since the post-release uptake.
  #      Realesr-ncnn-vulkan reaches V3D via mesa userspace +
  #      mainline DRM — works either way.
  #
  # Switch to linuxPackages_rpi5 only if a Pi-specific feature we
  # want shows up (camera ribbon, wireless-via-host-firmware quirks,
  # GPIO HAT overlays) and the build cost is justified.
  boot.kernelPackages = pkgs.linuxPackages;

  # Headless boot tweaks — same rationale as the Pi 4 config but
  # without the brownout-mitigation bundle. Pi 5's PMIC + 5 V power
  # path are well-behaved out of the box, so we don't ship the
  # boot-stability-probe staged peripheral bring-up nor the
  # vcgencmd throttle-history sampler. Re-add if we actually
  # observe brownout symptoms.
  boot.kernelParams = [
    # HDMI off — never has a monitor attached.
    "video=HDMI-A-1:d"
    "video=HDMI-A-2:d"

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

    secrets.telegram-monitoring-bot-token = {};
    secrets.telegram-alerts-chat-id = {};
    secrets.telegram-log-chat-id = {};
    secrets.printscan-bot-token = {};
    secrets.wifi-iot-psk = {};

    templates."wpa-secrets" = {
      content = "psk_iot=${config.sops.placeholder."wifi-iot-psk"}";
      owner = "wpa_supplicant";
    };
  };

  # ── Profile wiring ──
  profiles.physicalServerBase = {
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
      tokenFile        = config.sops.secrets.telegram-monitoring-bot-token.path;
      alertsChatIdFile = config.sops.secrets.telegram-alerts-chat-id.path;
      logChatIdFile    = config.sops.secrets.telegram-log-chat-id.path;
    };
    localFlake.configurationName = "GhostHome";
  };

  profiles.multiHomedNetworking.enable = true;

  profiles.printScanServer = {
    enable = true;
    bot = {
      tokenFile = config.sops.secrets.printscan-bot-token.path;
      allowedUsers = [
        { id = 1398173959; name = "hypersw"; }
        { id = 2074641026; name = "ol"; }
        { id = 6935307009; name = "alice"; }
      ];
    };
  };

  # The print/scan profile needs the administrator account in
  # `scanner` and `lp` for SANE / CUPS access. Append via the
  # standard NixOS list-merge.
  users.users.${config.profiles.physicalServerBase.administrator.name}
    .extraGroups = [ "scanner" "lp" ];
}
