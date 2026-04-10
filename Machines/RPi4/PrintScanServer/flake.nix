{
  description = "Print/Scan server on Raspberry Pi 4 — NixOS system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Module flakes — all share nixpkgs
    laserjet.url = "path:../../../Modules/PrintersScanners/LaserJetPrinter";
    epkowa.url = "path:../../../Modules/PrintersScanners/EpkowaScanner";
    daemon.url = "path:../../../Modules/PrintersScanners/Daemon";
    telegram-bot.url = "path:../../../Modules/PrintersScanners/TelegramBot";
    monitoring.url = "path:../../../Modules/Monitoring/TelegramAlerts";
  };

  outputs = { self, nixpkgs, nixos-hardware
            , laserjet, epkowa, daemon, telegram-bot, monitoring }:
    let
      # Build the SD image on x86_64, target aarch64
      buildSystem = "x86_64-linux";
      targetSystem = "aarch64-linux";
    in
    {
      nixosConfigurations.PrintScanServer = nixpkgs.lib.nixosSystem {
        system = targetSystem;
        modules = [
          # Hardware
          nixos-hardware.nixosModules.raspberry-pi-4
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          # Our modules
          laserjet.nixosModules.default
          epkowa.nixosModules.default
          daemon.nixosModules.default
          telegram-bot.nixosModules.default
          monitoring.nixosModules.default

          # Machine-specific configuration
          ({ config, lib, pkgs, ... }: {

            # System identity
            networking.hostName = "printscan";
            system.stateVersion = "25.05";

            # Firmware for WiFi (BCM43455) and GPU
            hardware.enableRedistributableFirmware = true;

            # Networking — Ethernet for initial setup
            networking = {
              useDHCP = true;
              # WiFi (later): EAP-PEAP with Unifi built-in RADIUS
              # networking.wireless.enable = true;
              # networking.wireless.networks."IoT-Secure".auth = ''
              #   key_mgmt=WPA-EAP
              #   eap=PEAP
              #   identity="printscan"
              #   password=<from sops-nix>
              #   ca_cert="/etc/ssl/radius-ca.pem"
              #   phase2="auth=MSCHAPV2"
              # '';

              firewall = {
                enable = true;
                allowedTCPPorts = [
                  22   # SSH
                  # 631 and 6566 opened by module configs when enabled
                ];
              };
            };

            # SSH access
            services.openssh = {
              enable = true;
              settings = {
                PermitRootLogin = "no";
                PasswordAuthentication = false;
              };
            };

            # Service user for SSH access
            users.users.admin = {
              isNormalUser = true;
              extraGroups = [ "wheel" "scanner" "lp" ];
              openssh.authorizedKeys.keys = [
                # TODO: add your SSH public key here
                # "ssh-ed25519 AAAA..."
              ];
            };
            security.sudo.wheelNeedsPassword = false;

            # Nix configuration
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
            nixpkgs.config.allowUnfree = true; # for epkowa

            # Self-update from GitHub
            system.autoUpgrade = {
              enable = true;
              flake = "github:hypersw/HyperNix#nixosConfigurations.PrintScanServer";
              dates = "04:00";
              randomizedDelaySec = "2h";
              allowReboot = false; # manual reboot for now
            };

            # SD card longevity
            boot.tmp.useTmpfs = true;
            services.journald.extraConfig = "Storage=volatile";
            fileSystems."/".options = [ "noatime" ];

            # Essential packages
            environment.systemPackages = with pkgs; [
              htop
              usbutils     # lsusb for debugging
              sane-backends # scanimage CLI
            ];

            # ──── Module enablement ────
            # Printer: enabled — basic functionality
            services.laserjet-printer.enable = true;

            # Scanner: enabled — basic functionality
            services.epkowa-scanner.enable = true;

            # Daemon: disabled — needs the C# binary first
            services.printscan-daemon.enable = false;

            # Telegram bot: disabled — needs daemon + bot token
            services.printscan-telegram-bot.enable = false;
            # services.printscan-telegram-bot.tokenFile = config.sops.secrets.telegram-token.path;
            # services.printscan-telegram-bot.allowedUsers = [ 123456789 ];

            # Monitoring: disabled — needs bot token
            services.telegram-alerts.enable = false;
            # services.telegram-alerts.tokenFile = config.sops.secrets.telegram-token.path;
            # services.telegram-alerts.chatId = "123456789";
          })
        ];
      };

      # SD card image — build on x86_64 for aarch64
      packages.${buildSystem}.sdImage =
        self.nixosConfigurations.PrintScanServer.config.system.build.sdImage;

      # Also expose for the target system (for native builds on the Pi)
      packages.${targetSystem}.sdImage =
        self.nixosConfigurations.PrintScanServer.config.system.build.sdImage;
    };
}
