{ config, lib, pkgs, ... }:
{
  imports = [
    ../../../Modules/PrintersScanners/LaserJetPrinter
    ../../../Modules/PrintersScanners/EpkowaScanner
    ../../../Modules/PrintersScanners/Daemon
    ../../../Modules/PrintersScanners/TelegramBot
    ../../../Modules/Monitoring/TelegramAlerts
    ../../../Modules/System/AutoRebuildOnPush
    ../../../Modules/System/BootStabilityProbe
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
  # Root cause not identified; see PLAN.md "Driver Saga" + troubleshooting
  # notes. The PMIC warning threshold is ABOVE the brownout-reset
  # threshold, so "silent reset with no warning log" is consistent with a
  # transient 5 V droop that trips the reset path but never the warning
  # path (see https://forums.raspberrypi.com/viewtopic.php?t=290853).
  #
  # The settings below don't fix a specific cause — they reduce the
  # transient-current area-under-curve during the first 10 s of boot by
  # removing unused subsystems that init in parallel there. If the
  # root cause WAS an overlapped transient spike during peripheral
  # bring-up, these help; if it was something else, they don't hurt.

  # Blacklist unused radios + camera stack. WiFi stays, we use it.
  # NOTE on Bluetooth: the Wi-Fi and Bluetooth share one silicon die
  # (BCM4345). Blacklisting BT does NOT skip the big Wi-Fi firmware load
  # (the ~1.5 MB transfer over SDIO is the heavy transient). It skips the
  # separate BT "patchram" upload over HCI-UART (~30-80 KB) and the BT
  # RF calibration pass. Modest transient-load reduction, not dramatic.
  # Worth it because we don't use BT at all on this headless server.
  #
  # Camera (bcm2835_v4l2 + bcm2835_mmal_vchiq) loads at boot via VCHIQ,
  # probes the CSI ribbon connector. No camera attached — pure waste.
  boot.blacklistedKernelModules = [
    # Bluetooth — unused, and removes one transient overlap during init
    "btbcm"        # Broadcom BT firmware loader
    "hci_uart"     # HCI-over-UART transport (how BT attaches on Pi)
    "bluetooth"    # core BT stack
    # Camera — no CSI camera, no need to probe/load
    "bcm2835_v4l2"
    "bcm2835_mmal_vchiq"
  ];
  # Belt-and-braces — disable the top-level bluetooth service stack too
  # so no userspace tries to talk to a blacklisted module.
  hardware.bluetooth.enable = false;

  # Kernel-level HDMI disable for headless boot. Tells the DRM driver to
  # not activate either HDMI output, which skips display-pipeline bring-up
  # (HPD probing, EDID read, pixel-clock programming). Minor power saver
  # on boot for a server that never has a monitor attached.
  #
  # Note: the Pi's GPU firmware may still probe HDMI BEFORE handing off
  # to Linux — a fuller disable would need hdmi_blanking=2 in
  # /boot/firmware/config.txt. We're leaving that alone for now to avoid
  # touching the boot partition from NixOS, which is fiddly on the Pi.
  boot.kernelParams = [
    "video=HDMI-A-1:d"
    "video=HDMI-A-2:d"

    # pstore/ramoops forensics. If a future reset is kernel-triggered
    # (oops, panic, BUG:), ramoops writes the last bytes of the kernel
    # log into a RAM region that survives a warm reboot; next boot,
    # systemd-pstore.service copies /sys/fs/pstore/* into
    # /var/lib/systemd/pstore/ for post-mortem inspection.
    #
    # Two caveats:
    #  1. Full power-loss / brownout clears RAM, so ramoops will NOT
    #     catch the silent-reset pattern suspected on 2026-04-21. It
    #     only catches kernel-triggered resets where power stays on.
    #  2. Memory reservation on ARM64 wants a device-tree reserved-
    #     memory node — the `memmap=` kernel param works only on x86.
    #     Doing DT reservation from NixOS means rebuilding the Pi's
    #     device tree, which is fiddly. We're doing best-effort here:
    #     ramoops tries to ioremap the given region at module load; if
    #     the kernel already allocated there, ramoops logs a failure
    #     and pstore is quietly unavailable (check `dmesg | grep
    #     ramoops` after boot, and `/sys/fs/pstore/` should be a
    #     non-empty directory on a working setup).
    #
    # Address 0x08000000 (128 MiB) is above the typical kernel+initrd
    # load area on Pi 4 (~16 MiB from 0x00080000) but well below where
    # modules and slab live at runtime; gives the best chance. ecc=1
    # makes marginal voltage corruption detectable, not silently wrong.
    "ramoops.mem_address=0x08000000"
    "ramoops.mem_size=0x100000"
    "ramoops.record_size=0x20000"
    "ramoops.console_size=0x20000"
    "ramoops.ecc=1"
  ];

  boot.kernelModules = [ "ramoops" ];

  # Staged-peripheral-bringup diagnostic. Defers USB-A (xhci_pci) and
  # Wi-Fi (brcmfmac) past the brownout-prone first ~10 s of boot, then
  # brings them up serially with aggressive journal syncs, so the journal
  # durably records which stage was in flight if a reset occurs.
  #
  # Activated 2026-04-22 after the 74-cycle silent-reset boot loop: the
  # fact that every failed boot died at the same journald-flush milestone
  # (~3 s in, "flushed 552 entries") strongly suggested an issue during
  # early peripheral init; this module will either make the reset go
  # away (if the cause was transient-current overlap, now serialised) or
  # make the journal pinpoint which stage triggers it.
  #
  # Side effect: USB + Wi-Fi unavailable for ~30-40 s after boot. SSH
  # over Wi-Fi is unreachable during that window — use Ethernet if you
  # need reliable early-boot access. Scanner and printer come up after
  # the USB stage completes.
  #
  # See Modules/System/BootStabilityProbe/default.nix for rescue notes
  # (U-Boot menu rollback, SD-card extlinux.conf edit).
  services.boot-stability-probe.enable = true;

  # ── Throttle history ────────────────────────────────────────────────────
  #
  # vcgencmd's get_throttled register reports whether the Pi has detected
  # undervoltage / thermal throttle / capped-clock events — but the value
  # reads "events since last boot", so a brownout-induced reset wipes it
  # clean before we can see anything. Sample every 5 min and append to a
  # persistent log so sub-brownout voltage sags (which set the bit without
  # triggering a full reset) accumulate a visible history. If the log
  # shows 0x50000 right before a silent reset, power supply is confirmed
  # as the trigger.
  #
  # Run as root (needs /dev/vcio). ~80 bytes/sample × 288/day ≈ 23 KB/day,
  # no rotation needed for years.
  systemd.services.throttle-history = {
    description = "Log RPi undervoltage/throttle state to /var/log/throttle.log";
    serviceConfig = {
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

  networking = {
    # systemd-networkd + systemd-resolved (modern stack), matching HyperJetHV.
    # Replaces the legacy dhcpcd + Avahi pair. Wi-Fi auth still goes through
    # wpa_supplicant; networkd takes over L3 after association.
    useNetworkd = true;
    useDHCP = false;         # per-interface via .network files below
    dhcpcd.enable = false;   # networkd has its own DHCP client

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 5353 ];  # mDNS (systemd-resolved)
    };

    # WiFi client — connect to IoT PPSK network
    wireless = {
      enable = true;
      secretsFile = config.sops.templates."wpa-secrets".path;
      # Disable Wi-Fi Direct (P2P) — RPi4's BCM43455 doesn't support the
      # required DFS/wide channels, causing constant brcmf_set_channel errors.
      extraConfig = "p2p_disabled=1";
      networks."HyperAir.IotPsk" = {
        pskRaw = "ext:psk_iot";  # pskRaw outputs unquoted — required for ext: refs
        hidden = true;  # SSID not broadcast — probe actively
      };
    };
  };

  # Ensure wpa_supplicant starts after sops decrypts secrets
  systemd.services.wpa_supplicant = {
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
  };

  # systemd-resolved — stub resolver ONLY; mDNS deliberately disabled.
  #
  # Why split resolved (DNS) and avahi (mDNS) on the same host:
  #
  # resolved's mDNS implementation has a structural issue on hosts with
  # multiple interfaces on the same L2 segment (our case: end0 + wlan0
  # both bridged by the AP into 192.168.1.0/24). Each link owns its own
  # mDNS scope independently, with no cross-link coordination — so the
  # end0 scope publishes "printscan.local → 192.168.1.129", and the
  # wlan0 scope publishes "printscan.local → 192.168.1.130". When the
  # AP bridges the multicast traffic between wlan0 and end0, resolved
  # sees its own sibling-link announcement and treats it as another
  # device claiming the name with a different IP. It then runs RFC 6762
  # conflict resolution, renaming the host to printscan7.local, then
  # printscan11.local, leaving printscan.local unreachable. Observed
  # on 2026-04-22. See upstream systemd issues #28491, #23910.
  #
  # Avahi handles multi-interface mDNS coherently (knows about its own
  # links, avoids self-conflict, publishes correctly across all of them)
  # because it was designed for exactly this case — eth+wifi laptops.
  # That's why every major Linux distro with dual-NIC expectations
  # (Fedora Workstation, Ubuntu, ChromeOS) ships Avahi regardless of
  # whether resolved is also present.
  #
  # So: resolved owns DNS (stub at 127.0.0.53, per-link DNS from DHCP)
  # but NOT mDNS. Avahi owns mDNS. They don't collide on :5353 because
  # resolved with MulticastDNS=no doesn't bind that socket.
  services.resolved = {
    enable = true;
    settings.Resolve.MulticastDNS = "no";  # Avahi does mDNS, not us
  };

  # Per-interface networkd config. DHCP + IPv6 RA on both interfaces.
  # MulticastDNS deliberately NOT set — Avahi handles mDNS on all
  # interfaces directly, independently of networkd's per-link flags.
  # wait-online is disabled entirely — nothing in this flake depends on
  # network-online.target anymore (notifications go through the alert
  # outbox, which tolerates offline indefinitely). Boot proceeds as fast
  # as sysinit finishes, regardless of Wi-Fi/Ethernet state.
  systemd.network = {
    wait-online.enable = false;

    networks."20-end0" = {
      matchConfig.Name = "end0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = "yes";
      };
    };

    networks."20-wlan0" = {
      matchConfig.Name = "wlan0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = "yes";
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  # Avahi — mDNS publisher and resolver. Announces printscan.local on
  # every interface it sees, in a self-conflict-aware way (see comment
  # above resolved for why we can't let resolved do this). nssmdns4=true
  # installs the nsswitch glue so local apps resolve *.local via avahi
  # directly (glibc → nss_mdns4), bypassing resolved for those names.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  users.users.administrator = {
    isNormalUser = true;
    extraGroups = [ "wheel" "scanner" "lp" ];  # scanner+lp for SANE/CUPS access
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLESV1KGuOruuV5JdUr8wS8iQyIfEeYdJz2MC5zNCOjoTqzJpA3j5e3kdXbyFczRK25o5bFlThHzK2kmwmCE4zE= printscan-administrator"
    ];
  };
  users.users.root.hashedPassword = "!";  # disable root login entirely
  # Headless device — no interactive console for password entry.
  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;  # hardlink identical store paths — saves SD card space

      # Keep build closures (toolchains, buildInputs) alive as long as the
      # system generation that built them is still within gc retention.
      # Without these, every on-push rebuild would re-fetch rustc / gcc /
      # autoreconfHook etc. as soon as a gc swept the previous one away —
      # which defeats the point of iterating on the Pi at all. The cost is
      # a larger store (build deps linger with their generation); monthly
      # gc with 30d retention keeps that bounded.
      keep-outputs = true;
      keep-derivations = true;
    };
    # Run gc once a month, the day after system.autoUpgrade. On-push rebuilds
    # don't trigger gc — between monthly upgrades the store barely changes, and
    # gc scans are writes the SD card doesn't need. The 1-day lag past
    # autoUpgrade leaves a rollback window; --delete-older-than 30d then keeps
    # at least the previous month's generation once we collect.
    gc = {
      automatic = true;
      dates = "*-*-02 04:00";
      randomizedDelaySec = "6h";
      options = "--delete-older-than 30d";
      persistent = true;
    };
  };
  nixpkgs.config.allowUnfree = true;

  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos#default";
    dates = "*-*-01 02:00";  # first day of each month at 2 AM
    randomizedDelaySec = "6h"; # spreads to 2-8 AM
    allowReboot = true;      # unattended machine, reboot if kernel changed
    flags = [ "--refresh" ]; # always pull latest from GitHub
  };

  # Generate /etc/nixos/flake.nix on first boot (or if missing).
  # This local flake owns the lock file and controls nixpkgs version.
  system.activationScripts.localFlake = ''
    if [ ! -f /etc/nixos/flake.nix ]; then
      mkdir -p /etc/nixos
      cat > /etc/nixos/flake.nix << 'FLAKE'
# GENERATED by NixOS activation script — do not edit.
# To customize, delete this file and create your own.
# Source: Machines/RPi4/PrintScanServer/configuration.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    upstream = {
      url = "github:hypersw/HyperNix";                   # ← remote flake
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixos-hardware.follows = "nixos-hardware";
    };
  };

  outputs = { upstream, ... }: {
    nixosConfigurations.default =
      upstream.nixosConfigurations.PrintScanServer;       # ← configuration name
  };
}
FLAKE
    fi
  '';

  # Update flake inputs (nixpkgs, upstream) before each auto-upgrade.
  # Without this, auto-upgrade would rebuild from the stale lock file
  # and never pick up new nixpkgs or upstream changes.
  systemd.services.nixos-upgrade.preStart = "nix flake update --flake /etc/nixos";

  # Expand root partition to fill the SD card on first boot
  boot.growPartition = true;

  # SD card longevity — minimize writes to extend flash lifetime.
  boot.tmp.useTmpfs = true;                          # /tmp in RAM, not on disk
  fileSystems."/".options = [ "noatime" ];            # skip access-time writes
  # Journal in RAM (volatile) saves writes but loses history across reboots.
  # On a settled Pi where everything just works, that's the right trade-off.
  # While the system is still being iterated on, we need logs from previous
  # boots to diagnose stalls/crashes — so keep the journal persistent for
  # now. Flip back to volatile once the config stabilises.
  #   services.journald.extraConfig = "Storage=volatile";

  # Memory management: zram first, disk swap as OOM safety net
  zramSwap = {
    enable = true;
    memoryPercent = 50;   # ~2 GB compressed swap in RAM
    algorithm = "zstd";
  };
  swapDevices = [{
    device = "/var/swapfile";
    size = 2048;  # 2 GB on disk — last resort before OOM killer
  }];
  boot.kernel.sysctl."vm.swappiness" = 1;  # almost never touch disk swap

  environment.systemPackages = with pkgs; [
    htop
    usbutils
    sane-backends
  ];

  # ── Secrets (sops-nix) ──
  # Decryption key derived from SSH host ed25519 key — no extra key management.
  # Secrets are encrypted in the repo, decrypted to /run/secrets/ at activation.
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Monitoring bot
    secrets.telegram-monitoring-bot-token = {};
    secrets.telegram-alerts-chat-id = {};
    secrets.telegram-log-chat-id = {};

    # Print/scan bot
    secrets.printscan-bot-token = {};

    # WiFi
    secrets.wifi-iot-psk = {};

    # wpa_supplicant secrets file — maps sops secret to ext: reference.
    # wpa_supplicant runs sandboxed as its own user, needs read access.
    templates."wpa-secrets" = {
      content = "psk_iot=${config.sops.placeholder."wifi-iot-psk"}";
      owner = "wpa_supplicant";
    };
  };

  # Enable x86_64 binary emulation via qemu-user binfmt.
  # The EpkowaScanner module's proxy/stub approach spawns a short-lived
  # x86_64 helper per scan (see EpkowaStubX64/PROTOCOL.md). qemu-user runs
  # the helper transparently. USB stays aarch64-native in our code — the
  # helper does pure CPU work (ESC/I byte munging), which qemu-user handles
  # fine. This also lets nix build x86_64 dependencies under emulation.
  boot.binfmt.emulatedSystems = [ "x86_64-linux" ];

  # ── Module enablement ──
  services.laserjet-printer.enable = true;
  services.epkowa-scanner.enable = true;
  services.printscan-daemon.enable = true;

  services.printscan-telegram-bot = {
    enable = true;
    tokenFile = config.sops.secrets.printscan-bot-token.path;
    allowedUsers = [
      { id = 1398173959; name = "hypersw"; }
      { id = 2074641026; name = "ol"; }
      { id = 6935307009; name = "alice"; }
    ];
  };

  services.telegram-alerts = {
    enable = true;
    tokenFile = config.sops.secrets.telegram-monitoring-bot-token.path;
    alertsChatIdFile = config.sops.secrets.telegram-alerts-chat-id.path;
    logChatIdFile = config.sops.secrets.telegram-log-chat-id.path;
    # Revision info is passed from the flake (see flake.nix specialArgs or module overlay)
    # These are set by the flake where self.rev and nixpkgs.rev are available.
  };

  # Poll upstream flake for config changes every 5 min, rebuild if changed.
  # Only updates the 'upstream' input (HyperNix), not nixpkgs —
  # nixpkgs is updated by the monthly auto-upgrade service.
  services.auto-rebuild-on-push.enable = true;
}
