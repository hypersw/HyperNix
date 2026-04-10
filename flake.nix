{
  description = "HyperNix — personal nix tools, modules, and machine configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Utilities
    closefrom3 = {
      url = "path:./Util/CloseFrom3";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Git tools
    ssh-askpass = {
      url = "path:./Git/SshAskpassCredentialHelper";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.closefrom3.follows = "closefrom3";
    };

    # Machines
    vm-ssh-front = {
      url = "path:./Machines/MicroVM/VmSshFront";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    print-scan-server = {
      url = "path:./Machines/RPi4/PrintScanServer";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Modules — PrintersScanners
    laserjet = {
      url = "path:./Modules/PrintersScanners/LaserJetPrinter";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    epkowa = {
      url = "path:./Modules/PrintersScanners/EpkowaScanner";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    printscan-daemon = {
      url = "path:./Modules/PrintersScanners/Daemon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    printscan-telegram = {
      url = "path:./Modules/PrintersScanners/TelegramBot";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Modules — Monitoring
    telegram-alerts = {
      url = "path:./Modules/Monitoring/TelegramAlerts";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs
            , closefrom3, ssh-askpass
            , vm-ssh-front, print-scan-server
            , laserjet, epkowa, printscan-daemon, printscan-telegram
            , telegram-alerts }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # Packages — path-based naming: folder path with hyphens
      packages = forAllSystems (system:
        let
          cf3 = closefrom3.packages.${system} or {};
          askpass = ssh-askpass.packages.${system} or {};
          vm = vm-ssh-front.packages.${system} or {};
          pss = print-scan-server.packages.${system} or {};
        in
        {
          Util-CloseFrom3 = cf3.default or null;
          Git-SshAskpassCredentialHelper = askpass.default or null;
          Machines-MicroVM-VmSshFront = vm.VmSshFront or null;
          Machines-RPi4-PrintScanServer-sdImage = pss.sdImage or null;
        });

      # NixOS modules — same naming convention
      nixosModules = {
        Git-SshAskpassCredentialHelper = ssh-askpass.nixosModules.default;
        Modules-PrintersScanners-LaserJetPrinter = laserjet.nixosModules.default;
        Modules-PrintersScanners-EpkowaScanner = epkowa.nixosModules.default;
        Modules-PrintersScanners-Daemon = printscan-daemon.nixosModules.default;
        Modules-PrintersScanners-TelegramBot = printscan-telegram.nixosModules.default;
        Modules-Monitoring-TelegramAlerts = telegram-alerts.nixosModules.default;
      };

      # NixOS configurations
      nixosConfigurations =
        (vm-ssh-front.nixosConfigurations or {}) //
        (print-scan-server.nixosConfigurations or {});
    };
}
