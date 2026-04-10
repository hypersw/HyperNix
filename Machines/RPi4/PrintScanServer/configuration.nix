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

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "scanner" "lp" ];
    openssh.authorizedKeys.keys = [
      # TODO: add your SSH public key here
    ];
  };
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
    dates = "04:00";
    randomizedDelaySec = "2h";
    allowReboot = false;
  };

  # SD card longevity
  boot.tmp.useTmpfs = true;
  services.journald.extraConfig = "Storage=volatile";
  fileSystems."/".options = [ "noatime" ];

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
