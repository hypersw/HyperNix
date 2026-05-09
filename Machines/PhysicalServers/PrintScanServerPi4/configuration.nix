{ config, lib, pkgs, ... }:
#
# Print/scan server on a Raspberry Pi 4. The bulk of "what this box
# does" lives in two profile modules:
#
#   * Modules/Profiles/PhysicalServerBase  — base server bundle
#     (auto-rebuild, telegram-alerts, openssh, swap/zram, nix gc,
#     auto-upgrade). Hardware-agnostic; same on Pi 5 / x86_64 / etc.
#
#   * Modules/Profiles/PrintScanServer     — full print/scan stack
#     (CUPS + foo2zjs + epkowa scanner via x86_64 stub + bot +
#     renderer + fonts).
#
# What stays here is genuinely Pi-4-specific or specific to this
# physical box:
#   - Pi-4 SD-card layout, kernel choice, firmware blob hint
#   - brownout-targeting kernel tweaks (HDMI off, ramoops, blacklists,
#     boot-stability-probe staged peripheral bring-up,
#     throttle-history sampler)
#   - the dual-NIC (end0 + wlan0) source-routing setup with CONNMARK
#     fwmarks and per-interface routing tables
#   - the administrator's ssh key and login name
#   - the sops secrets file + which sops key the machine uses
#   - the localFlake activation script that points /etc/nixos at the
#     upstream HyperNix flake's PrintScanServerPi4 configuration
#
{
  imports = [
    ../../../Modules/Profiles/PhysicalServerBase
    ../../../Modules/Profiles/PrintScanServer
    # Pi-specific diagnostic — staged peripheral bring-up after the
    # 2026-04-22 silent-reset boot loop. May or may not be needed on
    # Pi 5; left here as machine-specific for now.
    ../../../Modules/System/BootStabilityProbe
    # Per-interface mDNS publication (printscan-eth.local /
    # printscan-wifi.local). Needed because end0 + wlan0 are on the
    # same L2 segment via the AP bridge — Avahi's default single-
    # hostname publish self-conflicts. Stays here because the
    # multi-NIC topology is a per-machine fact, not a print/scan
    # concern.
    ../../../Modules/System/AvahiPerInterfaceNames
  ];

  networking.hostName = "printscan";
  system.stateVersion = "25.05";

  # Required for RPi4 WiFi (brcmfmac) and Bluetooth firmware blobs.
  hardware.enableRedistributableFirmware = true;

  # Filesystems — RPi4 SD card layout (set by sd-image module on first flash,
  # then referenced directly for subsequent nixos-rebuild).
  # The sd-image module is only used for CI image builds, not runtime config.
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
  # The generic kernel is always cached and downloads in seconds.
  # Trade-off: loses RPi-specific patches (GPU/display, camera, HAT overlays)
  # which are irrelevant for a headless print/scan server.
  #
  # To restore RPi-specific kernel (requires own cachix or patience):
  #   boot.kernelPackages = pkgs.linuxPackages_rpi4;
  boot.kernelPackages = pkgs.linuxPackages;

  # ── Boot-stability tweaks ─────────────────────────────────────────────────
  #
  # Context: on 2026-04-21 we observed this Pi enter a 19-cycle boot loop,
  # each cycle dying silently at ~monotonic 8-10 s into systemd startup
  # with no kernel log, no Under-voltage detected! message, no SD errors,
  # no watchdog trace — just a hard reset. Eventually self-stabilised.
  # Brand-new official Pi PSU + cable, sustained CPU-100% works fine.
  # Root cause not identified.
  #
  # The settings below don't fix a specific cause — they reduce the
  # transient-current area-under-curve during the first 10 s of boot by
  # removing unused subsystems that init in parallel there.

  boot.blacklistedKernelModules = [
    "btbcm"        # Broadcom BT firmware loader
    "hci_uart"     # HCI-over-UART transport (how BT attaches on Pi)
    "bluetooth"    # core BT stack
    "bcm2835_v4l2"
    "bcm2835_mmal_vchiq"
  ];
  hardware.bluetooth.enable = false;

  # Kernel-level HDMI disable for headless boot.
  boot.kernelParams = [
    "video=HDMI-A-1:d"
    "video=HDMI-A-2:d"

    # pstore/ramoops forensics. ramoops tries to ioremap a region that
    # survives warm reboot; next boot, systemd-pstore.service copies
    # /sys/fs/pstore/* into /var/lib/systemd/pstore/ for inspection.
    "ramoops.mem_address=0x08000000"
    "ramoops.mem_size=0x100000"
    "ramoops.record_size=0x20000"
    "ramoops.console_size=0x20000"
    "ramoops.ecc=1"
  ];
  boot.kernelModules = [ "ramoops" ];

  # Staged-peripheral-bringup diagnostic. Defers USB-A and Wi-Fi past
  # the brownout-prone first ~10 s of boot; brings them up serially
  # with aggressive journal syncs. See module for the full story.
  services.boot-stability-probe.enable = true;

  # ── Throttle history ────────────────────────────────────────────────────
  #
  # vcgencmd's get_throttled register reports undervoltage / thermal
  # throttle / capped-clock events, but the value is "events since last
  # boot" — a brownout reset wipes it. Sample every 5 min and append to
  # a persistent log so sub-brownout sags accumulate visible history.
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

  # Multi-homed ARP behaviour on same-subnet interfaces. With default
  # arp_ignore=0 both interfaces answer ARPs for each other's IPs,
  # breaking the CONNMARK source-routing scheme below.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
    "net.ipv4.conf.default.arp_ignore" = 1;
    "net.ipv4.conf.default.arp_announce" = 2;
  };

  networking = {
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 5353 ];

      # Per-interface source routing via packet-mark + conntrack
      # persistence — see PLAN.md for the full reasoning.
      extraCommands = ''
        iptables -t mangle -I PREROUTING 1 -i end0 -j MARK --set-mark 100
        iptables -t mangle -I PREROUTING 2 -i wlan0 -j MARK --set-mark 200
        iptables -t mangle -I PREROUTING 3 -j CONNMARK --save-mark
        iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
      '';
      extraStopCommands = ''
        iptables -t mangle -D PREROUTING -i end0 -j MARK --set-mark 100 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i wlan0 -j MARK --set-mark 200 2>/dev/null || true
        iptables -t mangle -D PREROUTING -j CONNMARK --save-mark 2>/dev/null || true
        iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true
      '';
    };

    wireless = {
      enable = true;
      secretsFile = config.sops.templates."wpa-secrets".path;
      extraConfig = "p2p_disabled=1";
      networks."HyperAir.IotPsk" = {
        pskRaw = "ext:psk_iot";
        hidden = true;
      };
    };
  };

  systemd.services.wpa_supplicant = {
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
  };

  services.resolved = {
    enable = true;
    settings.Resolve.MulticastDNS = "no";
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = true;
  };

  services.avahi-per-interface-names.enable = true;

  systemd.network = {
    wait-online.enable = false;

    networks."20-end0" = {
      matchConfig.Name = "end0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = "yes";
      };
      dhcpV4Config.RouteMetric = 1002;
      ipv6AcceptRAConfig.RouteMetric = 1002;
      routes = [
        { Destination = "0.0.0.0/0"; Gateway = "_dhcp4"; Table = 100; }
      ];
      routingPolicyRules = [
        { FirewallMark = 100; Table = 100; }
      ];
    };

    networks."20-wlan0" = {
      matchConfig.Name = "wlan0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = "yes";
      };
      dhcpV4Config.RouteMetric = 3003;
      ipv6AcceptRAConfig.RouteMetric = 3003;
      routes = [
        { Destination = "0.0.0.0/0"; Gateway = "_dhcp4"; Table = 200; }
      ];
      routingPolicyRules = [
        { FirewallMark = 200; Table = 200; }
      ];
      linkConfig.RequiredForOnline = "no";
    };
  };

  users.users.administrator = {
    isNormalUser = true;
    extraGroups = [ "wheel" "scanner" "lp" ];  # scanner+lp for SANE/CUPS access
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLESV1KGuOruuV5JdUr8wS8iQyIfEeYdJz2MC5zNCOjoTqzJpA3j5e3kdXbyFczRK25o5bFlThHzK2kmwmCE4zE= printscan-administrator"
    ];
  };

  # Generate /etc/nixos/flake.nix on first boot. The local flake owns
  # the lock file and controls nixpkgs version. Subsequent edits stay
  # in place because the if-not-file guard skips the rewrite.
  system.activationScripts.localFlake = ''
    if [ ! -f /etc/nixos/flake.nix ]; then
      mkdir -p /etc/nixos
      cat > /etc/nixos/flake.nix << 'FLAKE'
# GENERATED by NixOS activation script — do not edit.
# Source: Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    upstream = {
      url = "github:hypersw/HyperNix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixos-hardware.follows = "nixos-hardware";
    };
  };

  outputs = { upstream, ... }: {
    nixosConfigurations.default =
      upstream.nixosConfigurations.PrintScanServerPi4;
  };
}
FLAKE
    fi
  '';

  # Expand root partition to fill the SD card on first boot
  boot.growPartition = true;

  # ── Secrets (sops-nix) ──
  # Decryption key derived from SSH host ed25519 key — no extra key management.
  # Secrets are encrypted in the repo, decrypted to /run/secrets/ at activation.
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Monitoring bot (consumed by profiles.physicalServerBase.alerts)
    secrets.telegram-monitoring-bot-token = {};
    secrets.telegram-alerts-chat-id = {};
    secrets.telegram-log-chat-id = {};

    # Print/scan bot (consumed by profiles.printScanServer.bot)
    secrets.printscan-bot-token = {};

    # WiFi
    secrets.wifi-iot-psk = {};

    # wpa_supplicant secrets file — maps sops secret to ext: reference.
    templates."wpa-secrets" = {
      content = "psk_iot=${config.sops.placeholder."wifi-iot-psk"}";
      owner = "wpa_supplicant";
    };
  };

  # ── Profile wiring ──
  # The two meta-modules expose the inputs they need (token paths,
  # allowed users) as required options; we satisfy them here. Nix
  # eval errors on any unset required option, which is the
  # "what secrets does this profile need" surface.
  profiles.physicalServerBase = {
    enable = true;
    alerts = {
      enable = true;
      tokenFile        = config.sops.secrets.telegram-monitoring-bot-token.path;
      alertsChatIdFile = config.sops.secrets.telegram-alerts-chat-id.path;
      logChatIdFile    = config.sops.secrets.telegram-log-chat-id.path;
      # configRevision / nixpkgsRevision come from the flake (see the
      # inline-module set on the nixosConfiguration in flake.nix).
    };
  };

  profiles.printScanServer = {
    enable = true;
    bot = {
      enable = true;
      tokenFile = config.sops.secrets.printscan-bot-token.path;
      allowedUsers = [
        { id = 1398173959; name = "hypersw"; }
        { id = 2074641026; name = "ol"; }
        { id = 6935307009; name = "alice"; }
      ];
    };
  };
}
