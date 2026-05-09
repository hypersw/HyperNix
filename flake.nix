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
          Machines-PhysicalServers-GhostHome-sdImage =
            self.nixosConfigurations.GhostHome-sdImage.config.system.build.sdImage or null;
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
        # bundles. Compose to apply multiple at once on the same
        # machine.
        Profiles-AnyMachineBase = import ./Modules/Profiles/AnyMachineBase;
        Profiles-PhysicalServerBase = import ./Modules/Profiles/PhysicalServerBase;
        Profiles-PrintScanServer = import ./Modules/Profiles/PrintScanServer;
        Profiles-MultiHomedNetworking = import ./Modules/Profiles/MultiHomedNetworking;
        Profiles-PhysicalServerProvisioning = import ./Modules/Profiles/PhysicalServerProvisioning;
      };

      # ── NixOS Configurations ──
      nixosConfigurations = {
        VmSshFront = import ./Machines/MicroVM/VmSshFront/nixos.nix {
          inherit nixpkgs microvm;
        };

        # ── PrintScanServerPi4 — kept as a reference for the
        # original Pi 4 deployment (now decommissioned). The Pi 4
        # board is no longer running; this configuration would
        # apply to a fresh-flashed Pi 4 with the same role.
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
              profiles.anyMachineBase.alerts.configRevision =
                self.rev or self.dirtyRev or "dirty";
              profiles.anyMachineBase.alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };
        PrintScanServerPi4-sdImage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            sops-nix.nixosModules.sops
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };

        # ── GhostHome — Pi 5 home-automation server. Inherits the
        # print/scan stack as a guest workload until a dedicated
        # home-automation role takes its place as the headline.
        GhostHome = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5
            sops-nix.nixosModules.sops
            {
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
              profiles.anyMachineBase.alerts.configRevision =
                self.rev or self.dirtyRev or "dirty";
              profiles.anyMachineBase.alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/PhysicalServers/GhostHome/configuration.nix
          ];
        };
        GhostHome-sdImage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5
            sops-nix.nixosModules.sops
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./Machines/PhysicalServers/GhostHome/configuration.nix
          ];
        };

        # ── GhostHome-provisioning — minimalist first-boot image
        # the operator flashes to a fresh Pi 5 SD card. Boots,
        # generates ssh host keys, retries `nixos-rebuild boot`
        # against `github:hypersw/HyperNix?ref=ghosthome-ready` on
        # a 1-minute timer until the ref exists upstream, then
        # reboots into the full GhostHome config.
        #
        # The "ghosthome-ready" branch is the readiness signal:
        # operator encrypts secrets to the new Pi's host age key
        # (pulled via `ssh-keyscan host | ssh-to-age`), commits,
        # then either (a) pushes the master commit AND a
        # ghosthome-ready branch pointing at it, or
        # (b) tags the commit `ghosthome-ready` and pushes the
        # tag.  Both forms work with `?ref=ghosthome-ready`.
        GhostHome-provisioning-sdImage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./Modules/Profiles/PhysicalServerProvisioning
            ({ ... }: {
              # Pi 5 needs explicit extlinux opt-in — see comment
              # in GhostHome's configuration.nix for the rationale.
              boot.loader.grub.enable = false;
              boot.loader.generic-extlinux-compatible.enable = true;

              # Generic mainline kernel; same caching reasoning as
              # the live config.
              boot.kernelPackages = nixpkgs.legacyPackages.aarch64-linux.linuxPackages;

              networking.hostName = "ghosthome-provisioning";
              system.stateVersion = "25.05";

              profiles.physicalServerProvisioning = {
                enable = true;
                targetFlakeUri = "github:hypersw/HyperNix?ref=ghosthome-ready";
                targetConfigName = "GhostHome";
                # 60 s default retry interval. Bump on slower
                # networks if needed; not a tight loop anyway.
              };
            })
          ];
        };
      };
    };
}
