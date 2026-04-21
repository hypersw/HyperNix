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

      # Package builders — parameterized by pkgs
      mkClosefrom3 = pkgs: pkgs.stdenv.mkDerivation {
        pname = "closefrom3";
        version = "1.0.0";
        src = ./Util/CloseFrom3;
        buildPhase = "$CC -O2 -Wall -o closefrom3 closefrom3.c";
        installPhase = "mkdir -p $out/bin; cp closefrom3 $out/bin/";
        meta.platforms = pkgs.lib.platforms.linux;
      };

      mkSshAskpass = pkgs: { timeout ? 3600, perTokenPin ? false }:
        let closefrom = mkClosefrom3 pkgs;
        in pkgs.writeShellScriptBin "ssh-askpass-credential-helper" ''
          prompt="''${1:-}"

          case "$prompt" in
            "Enter PIN for '"*)
              ${if perTokenPin then ''
              cache_key="$prompt"
              '' else ''
              cache_key="pkcs11-pin"
              ''}
              ;;
            *)
              cache_key="$prompt"
              ;;
          esac

          cached=$(printf 'protocol=pkcs11\nhost=%s\n' "$cache_key" \
            | ${pkgs.git}/bin/git credential-cache get 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep '^password=' | cut -d= -f2-)

          if [ -n "$cached" ]; then
            echo "$cached"
            exit 0
          fi

          value=$(${pkgs.zenity}/bin/zenity --password --title="$prompt" 2>/dev/null) || exit 1
          echo "$value"

          printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$value" \
            | ${closefrom}/bin/closefrom3 \
              ${pkgs.git}/bin/git credential-cache --timeout=${toString timeout} store \
              >/dev/null 2>/dev/null
        '';

      mkSpaceGitCredential = pkgs:
        let
          oauth2c-wrapped = pkgs.symlinkJoin {
            name = "oauth2c-wrapped";
            paths = [ pkgs.oauth2c ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/oauth2c \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.xdg-utils ]}
            '';
          };
        in pkgs.writeShellApplication {
          name = "space-git-credential";
          excludeShellChecks = [ "SC1091" ];
          runtimeInputs = [ oauth2c-wrapped pkgs.jq pkgs.curl pkgs.coreutils ];
          text = builtins.readFile ./Git/SpaceGitCredential/space-git-credential.sh;
        };
    in
    {
      # ── Packages ──
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          printScanShared = import ./Modules/PrintersScanners/Shared/package.nix { inherit pkgs; };
          printScanDaemon = import ./Modules/PrintersScanners/Daemon/package.nix { inherit pkgs; sharedPackage = printScanShared; };
          printScanBot = import ./Modules/PrintersScanners/TelegramBot/package.nix { inherit pkgs; sharedPackage = printScanShared; };
        in {
          Util-CloseFrom3 = mkClosefrom3 pkgs;
          Git-SshAskpassCredentialHelper = mkSshAskpass pkgs {};
          Git-SpaceGitCredential = mkSpaceGitCredential pkgs;
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
