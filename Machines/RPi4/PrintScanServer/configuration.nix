{ config, lib, pkgs, ... }:
{
  imports = [
    ../../../Modules/PrintersScanners/LaserJetPrinter
    ../../../Modules/PrintersScanners/EpkowaScanner
    ../../../Modules/PrintersScanners/Daemon
    ../../../Modules/PrintersScanners/TelegramBot
    ../../../Modules/Monitoring/TelegramAlerts
  ];

  networking.hostName = "printscan";
  system.stateVersion = "25.05";

  hardware.enableRedistributableFirmware = true;

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

  networking = {
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
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
    extraGroups = [ "wheel" "scanner" "lp" ];
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLESV1KGuOruuV5JdUr8wS8iQyIfEeYdJz2MC5zNCOjoTqzJpA3j5e3kdXbyFczRK25o5bFlThHzK2kmwmCE4zE= printscan-administrator"
    ];
  };
  users.users.root.hashedPassword = "!";  # no password, login disabled
  security.sudo.wheelNeedsPassword = false;

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };
  nixpkgs.config.allowUnfree = true;

  system.autoUpgrade = {
    enable = true;
    flake = "github:hypersw/HyperNix#nixosConfigurations.PrintScanServer";
    dates = "*-*-01 02:00";  # first day of each month at 2 AM
    randomizedDelaySec = "6h"; # spreads to 2-8 AM
    allowReboot = true;      # unattended machine, reboot if kernel changed
  };

  # Expand root partition to fill the SD card on first boot
  boot.growPartition = true;

  # SD card longevity
  boot.tmp.useTmpfs = true;
  services.journald.extraConfig = "Storage=volatile";
  fileSystems."/".options = [ "noatime" ];

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

  # ── Module enablement ──
  services.laserjet-printer.enable = true;
  services.epkowa-scanner.enable = true;
  services.printscan-daemon.enable = false;
  services.printscan-telegram-bot.enable = false;
  services.telegram-alerts.enable = false;
}
