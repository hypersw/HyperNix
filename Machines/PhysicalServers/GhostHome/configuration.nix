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

  # Kernel: force the mainline nixpkgs kernel, overriding nvmd's
  # vendor package (linuxPackages_rpi5, Foundation patch series)
  # that raspberry-pi-5.base would otherwise wire up.
  #
  # Why not the vendor kernel: nvmd's binary cache at
  # nixos-raspberrypi.cachix.org is keyed on their pinned
  # nixpkgs (currently 25.11), and we track nixos-unstable for
  # fleet consistency. That cache mismatch means the vendor kernel
  # has to rebuild from source on every nixpkgs bump — ~3 hours
  # CPU-saturated on this Pi 5, every month, blocking the
  # auto-upgrade cycle for that whole window. Demonstrated cost,
  # not theoretical: we paid it once during initial bring-up.
  #
  # What we lose: nvmd's vendor-only multimedia bits (camera CSI
  # via bcm2835_v4l2, VPU offload, the full vc4-drm stack — but
  # we already blacklist vc4 anyway because of its IOMMU init
  # race). Nothing on the headless home-automation critical path.
  #
  # What mainline gives us (6.10+, we're on 6.12): full Pi 5
  # support — BCM2712 SoC, RP1 PCIe controller (USB + Ethernet +
  # GPIO), brcmfmac WiFi, EEPROM direct-kernel-boot. Cached on
  # cache.nixos.org, so substitution rather than source rebuild.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # Headless boot tweaks — same rationale as the Pi 4 config but
  # without the brownout-mitigation bundle. Pi 5's PMIC + 5 V power
  # path are well-behaved out of the box, so we don't ship the
  # boot-stability-probe staged peripheral bring-up nor the
  # vcgencmd throttle-history sampler. Re-add if we actually
  # observe brownout symptoms.
  boot.kernelParams = [
    # vc4-drm hang workaround (Pi 5). The Pi-vendor kernel's vc4
    # GPU driver has a non-deterministic init-order race on
    # BCM2712 that wedges in initrd at IOMMU attach time when
    # parallel service init creates enough pressure (matched
    # exactly by nvmd/nixos-raspberrypi#57 + several other open
    # upstream issues; no kernel-side fix as of mid-2026).
    # Provisioning image worked because its service set was
    # small enough to win the race by luck; the live config
    # consistently loses it. Disable the vc4 / V3D stack at
    # module-load time — headless server, we don't need the
    # GPU. Crucially we do NOT blacklist drm / drm_kms_helper:
    # those are the DRM core that simpledrm rides on, and we
    # want simpledrm to take over the firmware framebuffer so
    # HDMI text output keeps working without vc4.
    "modprobe.blacklist=vc4,vc4_kms_v3d,v3d"

    # ramoops kernel-cmdline reservation removed. The address
    # `0x08000000` (128 MB) was Pi-4-inherited; on Pi 5 it sits
    # adjacent to firmware-patched reserved-memory nodes
    # (`blconfig`, `blpubkey`) whose runtime placement we don't
    # control, and the kernel's own ramoops documentation pairs
    # this canonical address with `mem=128M` (which caps RAM
    # below the reservation) — a pairing we never had. Plausible
    # contributor to the vc4 race in addition to the GPU driver
    # bug itself. Re-add later via the device-tree
    # `reserved-memory` node form (which participates in early
    # memblock setup) or at a high address well clear of Pi 5
    # firmware reservations.
  ];

  # Disable the BT/camera kernel modules. Pi 5 uses a similar
  # BCM43xx WiFi/BT silicon and the same camera-ribbon CSI on
  # bcm2835_v4l2; blacklisting BT trims a small amount of init
  # work and protects against any camera-ribbon probing on a
  # board with no camera attached.
  #
  # vc4 / v3d additions are the workaround discussed in
  # boot.kernelParams above; redundant with `modprobe.blacklist=`
  # there but ensures the running system also refuses to load
  # them if something tries via modprobe later.
  boot.blacklistedKernelModules = [
    "btbcm" "hci_uart" "bluetooth"
    "bcm2835_v4l2" "bcm2835_mmal_vchiq"
    "vc4" "vc4_kms_v3d" "v3d"
  ];
  hardware.bluetooth.enable = false;

  # With vc4 blacklisted we lose the full KMS path, so HDMI text
  # output would go dark. simpledrm rides on the firmware-set
  # framebuffer (the one the EEPROM/start.elf programmed before
  # Linux took over) and exposes it as /dev/fb0 + DRM, which is
  # all the kernel console and getty need. Load it early so the
  # console is live from initrd; we don't get mode-set, resize,
  # or hot-plug, but for a headless server that's only ever
  # looked at via HDMI as a recovery probe, that's exactly the
  # tradeoff we want — no GPU driver, no race, but a readable
  # console if you plug a monitor in.
  boot.initrd.kernelModules = [ "simpledrm" ];

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

  # `sudo nixos-rebuild-boot-once --flake /etc/nixos#default` —
  # stages a candidate kernel via Pi 5 tryboot, power-cycle reverts.
  # First use will be the mainline-kernel migration; see the module
  # header for the full workflow rationale.
  hypersw.system.bootOnce.enable = true;

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
