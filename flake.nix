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
          printScanRenderer = import ./Modules/PrintersScanners/Renderer/package.nix { inherit pkgs; };
        in {
          Util-CloseFrom3 = closefrom3;
          Git-SshAskpassCredentialHelper = import ./Git/SshAskpassCredentialHelper/package.nix { inherit pkgs closefrom3; };
          Git-SpaceGitCredential = import ./Git/SpaceGitCredential/package.nix { inherit pkgs; };
          Modules-PrintersScanners-Shared = printScanShared;
          Modules-PrintersScanners-Daemon = printScanDaemon;
          Modules-PrintersScanners-TelegramBot = printScanBot;
          Modules-PrintersScanners-Renderer = printScanRenderer;
          # Machine runner packages
          Machines-MicroVM-VmSshFront =
            self.nixosConfigurations.VmSshFront.config.microvm.declaredRunner or null;
          Machines-PhysicalServers-PrintScanServerPi4-sdImage =
            self.nixosConfigurations.PrintScanServerPi4-sdImage.config.system.build.sdImage or null;
        });

      # ── NixOS Modules ──
      nixosModules = {
        Git-SshAskpassCredentialHelper = import ./Modules/Git/SshAskpassCredentialHelper;
        Modules-PrintersScanners-LaserJetPrinter = import ./Modules/PrintersScanners/LaserJetPrinter;
        Modules-PrintersScanners-EpkowaScanner = import ./Modules/PrintersScanners/EpkowaScanner;
        Modules-PrintersScanners-Daemon = import ./Modules/PrintersScanners/Daemon;
        Modules-PrintersScanners-TelegramBot = import ./Modules/PrintersScanners/TelegramBot;
        Modules-PrintersScanners-Renderer = import ./Modules/PrintersScanners/Renderer;
        Modules-Monitoring-TelegramAlerts = import ./Modules/Monitoring/TelegramAlerts;
        Modules-System-AutoRebuildOnPush = import ./Modules/System/AutoRebuildOnPush;
        Modules-System-AvahiPerInterfaceNames = import ./Modules/System/AvahiPerInterfaceNames;
        Modules-System-BootStabilityProbe = import ./Modules/System/BootStabilityProbe;
        # Profile meta-modules — single-import "make this host be X"
        # bundles. Compose to apply both at once on the same machine.
        Profiles-PhysicalServerBase = import ./Modules/Profiles/PhysicalServerBase;
        Profiles-PrintScanServer = import ./Modules/Profiles/PrintScanServer;
      };

      # ── NixOS Configurations ──
      nixosConfigurations = {
        VmSshFront = import ./Machines/MicroVM/VmSshFront/nixos.nix {
          inherit nixpkgs microvm;
        };

        # The running system config — used by nixos-rebuild on the Pi.
        # Does NOT include the SD image/installer module (that's only
        # for CI image builds).
        PrintScanServerPi4 = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            sops-nix.nixosModules.sops
            {
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
              # Forward the revision strings into the alerts profile
              # surface — those values come out of the flake (where
              # `self.rev` is available) and nowhere else.
              profiles.physicalServerBase.alerts.configRevision =
                self.rev or self.dirtyRev or "dirty";
              profiles.physicalServerBase.alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };

        # SD image variant — includes the installer module for building
        # flashable images. Only used by CI (GitHub Actions) and the
        # sdImage package below.
        PrintScanServerPi4-sdImage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            sops-nix.nixosModules.sops
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };

        # Backwards-compatibility alias: the deployed Pi 4 has a
        # /etc/nixos/flake.nix that references
        # `upstream.nixosConfigurations.PrintScanServer` (the pre-
        # rename name). Keep that name alive so the auto-rebuild on
        # the live machine doesn't fail with "no such configuration"
        # the moment this commit lands. The activation script
        # generates the new name on freshly-flashed images.
        PrintScanServer = self.nixosConfigurations.PrintScanServerPi4;
      };
    };
}
