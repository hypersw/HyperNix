{
  description = "HyperNix — personal nix tools, modules, and machine configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # External flake dependencies only — no path: sub-flakes.
    # Internal modules/packages are plain nix files imported directly.
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-hardware, microvm, sops-nix }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # ── Packages ──
      # Each package lives in its own sibling package.nix and is imported here.
      # Not flake `path:` inputs (those need lock entries and break `nix flake
      # check`); plain `import` of a .nix file is just a function call.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          closefrom3 = import ./Util/CloseFrom3/package.nix { inherit pkgs; };
          printScanShared = import ./Modules/PrintersScanners/Shared/package.nix { inherit pkgs; };
          printScanDaemon = import ./Modules/PrintersScanners/Daemon/package.nix { inherit pkgs; sharedPackage = printScanShared; };
          printScanBot = import ./Modules/PrintersScanners/TelegramBot/package.nix { inherit pkgs; sharedPackage = printScanShared; };
        in {
          Util-CloseFrom3 = closefrom3;
          Git-SshAskpassCredentialHelper = import ./Git/SshAskpassCredentialHelper/package.nix { inherit pkgs closefrom3; };
          Git-SpaceGitCredential = import ./Git/SpaceGitCredential/package.nix { inherit pkgs; };
          Modules-PrintersScanners-Shared = printScanShared;
          Modules-PrintersScanners-Daemon = printScanDaemon;
          Modules-PrintersScanners-TelegramBot = printScanBot;
          # Machine runner packages
          Machines-MicroVM-VmSshFront =
            self.nixosConfigurations.VmSshFront.config.microvm.declaredRunner or null;
          Machines-RPi4-PrintScanServer-sdImage =
            self.nixosConfigurations.PrintScanServer-sdImage.config.system.build.sdImage or null;
        });

      # ── NixOS Modules ──
      nixosModules = {
        Git-SshAskpassCredentialHelper = import ./Modules/Git/SshAskpassCredentialHelper;
        Modules-PrintersScanners-LaserJetPrinter = import ./Modules/PrintersScanners/LaserJetPrinter;
        Modules-PrintersScanners-EpkowaScanner = import ./Modules/PrintersScanners/EpkowaScanner;
        Modules-PrintersScanners-Daemon = import ./Modules/PrintersScanners/Daemon;
        Modules-PrintersScanners-TelegramBot = import ./Modules/PrintersScanners/TelegramBot;
        Modules-Monitoring-TelegramAlerts = import ./Modules/Monitoring/TelegramAlerts;
        Modules-System-AutoRebuildOnPush = import ./Modules/System/AutoRebuildOnPush;
        Modules-System-AvahiPerInterfaceNames = import ./Modules/System/AvahiPerInterfaceNames;
        Modules-System-BootStabilityProbe = import ./Modules/System/BootStabilityProbe;
      };

      # ── NixOS Configurations ──
      nixosConfigurations = {
        VmSshFront = import ./Machines/MicroVM/VmSshFront/nixos.nix {
          inherit nixpkgs microvm;
        };

        # The running system config — used by nixos-rebuild on the Pi.
        # Does NOT include the SD image/installer module (that's only for CI image builds).
        PrintScanServer = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            sops-nix.nixosModules.sops
            {
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
              services.telegram-alerts.configRevision = self.rev or self.dirtyRev or "dirty";
              services.telegram-alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/RPi4/PrintScanServer/configuration.nix
          ];
        };

        # SD image variant — includes the installer module for building flashable images.
        # Only used by CI (GitHub Actions) and the sdImage package below.
        PrintScanServer-sdImage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            sops-nix.nixosModules.sops
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./Machines/RPi4/PrintScanServer/configuration.nix
          ];
        };
      };
    };
}
