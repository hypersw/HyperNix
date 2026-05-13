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

    # Pi 4 + Pi 5 NixOS support. Carries Pi-vendor kernels
    # (linuxPackages_rpi{4,5}) plus a bootloader module that
    # supports direct EEPROM kernel boot
    # (`boot.loader.raspberry-pi.bootloader = "kernel"`) with
    # multi-generation retention in the firmware partition.
    #
    # Required for Pi 5 specifically: upstream u-boot's Pi 5
    # USB-MSD support is broken (RP1/PCIe issues — SUSE engineers'
    # explicit position 2025-11), so any USB-booting Pi 5 must
    # skip u-boot. We use the same loader uniformly on Pi 4 too
    # for fleet consistency.
    #
    # Follow our nixpkgs (nixos-unstable) rather than nvmd's
    # pinned 25.11. Cost: we miss nvmd's binary cache for the
    # Pi-vendor kernel (their cache is keyed on 25.11 builds), so
    # the kernel rebuilds from source on each nixpkgs bump — the
    # same property we used to avoid by going mainline. We accept
    # the rebuild cost in exchange for not having to track two
    # nixpkgs versions across the fleet; telemetry alerts on
    # rebuild failure already cover us if a kernel rev breaks.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, microvm, sops-nix, nixos-raspberrypi }:
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
          # Bottom (`btm`) patched for strict-overcommit hosts: per-process
          # PrivCmt + Fp columns and a Committed_AS/CommitLimit gauge,
          # auto-shown when vm.overcommit_memory == 2. Same derivation the
          # NixOS module installs. Run directly via:
          #   nix run github:hypersw/HyperNix#Modules-System-Btm-Fork
          Modules-System-Btm-Fork = import ./Modules/System/Btm/package.nix { inherit pkgs; };
          # Machine runner packages
          Machines-MicroVM-VmSshFront =
            self.nixosConfigurations.VmSshFront.config.microvm.declaredRunner or null;
          Machines-PhysicalServers-PrintScanServerPi4-sdImage =
            self.nixosConfigurations.PrintScanServerPi4-sdImage.config.system.build.sdImage or null;
          Machines-PhysicalServers-PrintScanServerPi4-provisioning-sdImage =
            self.nixosConfigurations.PrintScanServerPi4-provisioning-sdImage.config.system.build.sdImage or null;
          Machines-PhysicalServers-GhostHome-sdImage =
            self.nixosConfigurations.GhostHome-sdImage.config.system.build.sdImage or null;
          Machines-PhysicalServers-GhostHome-provisioning-sdImage =
            self.nixosConfigurations.GhostHome-provisioning-sdImage.config.system.build.sdImage or null;
        });

      # ── NixOS Modules ──
      # Single entry point: `default` imports the
      # `Modules/default.nix` module-list which transitively loads
      # every module HyperNix ships. Mirrors nixpkgs' pattern
      # (everything reachable through one well-known import,
      # consumers activate via option-setting, no enumeration on
      # the consumer side).
      #
      # See `Modules/default.nix` for the full discussion of why
      # we expose only the bundle rather than a per-module map.
      nixosModules = {
        default = import ./Modules;
      };

      # ── Checks (automated tests) ──
      # `nix build .#checks.x86_64-linux.first-boot-log` boots a
      # NixOS VM with the provisioning profile enabled, triggers
      # a deliberately-failing first-boot-switch (bogus readiness
      # ref), then curls the status HTTP endpoint and asserts
      # it returns the failure journal. Catches regressions in
      # the endpoint without a Pi roundtrip.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          first-boot-log = pkgs.testers.nixosTest {
            name = "first-boot-log-endpoint";
            nodes.machine = { ... }: {
              imports = [ ./Modules ];
              hypersw.profiles.physicalServerProvisioning = {
                enable = true;
                # Deliberately bogus ref — first-boot-switch
                # tries the rebuild, fails, the failure lands in
                # the journal where the endpoint can serve it.
                targetFlakeUri = "github:hypersw/HyperNix?ref=does-not-exist-test-marker";
                targetConfigName = "GhostHome";
              };
              # The default openssh+sudo+root-lock from the
              # profile is fine for the test VM; nothing to
              # override.
            };
            testScript = ''
              machine.wait_for_unit("first-boot-log.service")
              machine.wait_for_open_port(80)

              # Trigger first-boot-switch synchronously (no
              # `--no-block`). systemctl `start` on a Type=oneshot
              # blocks until the unit exits. We pipe through
              # `|| true` because we EXPECT it to fail (bogus
              # ref / sandboxed test VM has no network anyway).
              # The point is to land SOMETHING in the journal/log
              # that the endpoint can serve back.
              machine.execute("systemctl start first-boot-switch.service || true", timeout=120)
              machine.execute("journalctl --sync")

              output = machine.succeed("${pkgs.curl}/bin/curl --silent --max-time 5 http://localhost/")
              print("=== endpoint output ===")
              print(output)
              print("=== end ===")

              # HTML structure assertions.
              assert "<!DOCTYPE html>" in output, \
                f"endpoint should return HTML, got: {output[:500]}"
              assert "first-boot-switch.service journal" in output, \
                f"endpoint should label the journal pane, got: {output[:500]}"
              assert "/var/log/first-boot-switch.log" in output, \
                f"endpoint should label the log pane, got: {output[:500]}"

              # SSH host key + age conversion must appear in the
              # header — the whole point is the operator can
              # grab the age recipient straight off the page.
              assert "SSH host key (raw)" in output, \
                f"endpoint should label the raw SSH key section, got: {output[:1000]}"
              assert "SSH host key (age)" in output, \
                f"endpoint should label the age key section, got: {output[:1000]}"
              assert "ssh-ed25519 AAAA" in output, \
                f"endpoint should embed the raw SSH ed25519 host key, got: {output[:1500]}"
              assert "age1" in output, \
                f"endpoint should embed the age-converted host key (prefix `age1`), got: {output[:1500]}"

              # The readiness-ref + repo + target-config must
              # also surface so the operator knows what to push.
              assert "Target GitHub repo" in output, \
                f"endpoint should label the target repo, got: {output[:1500]}"
              assert "hypersw/HyperNix" in output, \
                f"endpoint should show the target repo, got: {output[:1500]}"
              assert "Readiness ref" in output, \
                f"endpoint should label the readiness ref, got: {output[:1500]}"
              assert "does-not-exist-test-marker" in output, \
                f"endpoint should embed the readiness ref name parsed from targetFlakeUri, got: {output[:1500]}"
              assert "Target nixosConfiguration" in output, \
                f"endpoint should label the target configuration name, got: {output[:1500]}"
              assert "GhostHome" in output, \
                f"endpoint should show the target config name (`GhostHome`), got: {output[:1500]}"

              # After triggering the service, either the journal
              # has entries OR the tee'd log file does — at
              # least one must show evidence of activity. Pure
              # "no content anywhere" means the wiring is broken.
              has_journal_content = "-- No entries --" not in output
              has_log_content = "(no log file yet" not in output
              assert has_journal_content or has_log_content, \
                f"after triggering first-boot-switch, neither journal nor log file has content; endpoint wiring is broken. Got: {output[:1500]}"
            '';
          };
        });

      # ── NixOS Configurations ──
      nixosConfigurations = {
        VmSshFront = import ./Machines/MicroVM/VmSshFront/nixos.nix {
          inherit nixpkgs microvm;
        };

        # ── PrintScanServerPi4 — Pi 4 print/scan deployment.
        # Currently not running (the original board took 5 V damage
        # 2026-04-21 and was retired) but the configuration is
        # actively maintained — a fresh-flashed Pi 4 boots straight
        # into the same role via the provisioning image below.
        PrintScanServerPi4 = nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            sops-nix.nixosModules.sops
            {
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
              # Forward the revision strings into the alerts profile
              # surface — those values come out of the flake (where
              # `self.rev` is available) and nowhere else.
              hypersw.profiles.anyMachineBase.alerts.configRevision =
                self.rev or self.dirtyRev or "dirty";
              hypersw.profiles.anyMachineBase.alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };
        PrintScanServerPi4-sdImage = nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            sops-nix.nixosModules.sops
            # nvmd's sd-image module, not stock sd-image-aarch64.nix:
            # it bumps the firmware partition to 1 GB (kernel +
            # initrd + multiple generations live there), wires
            # `boot.loader.raspberry-pi.{firmware,boot}PopulateCmd`
            # into `sdImage.populate{Firmware,Root}Commands`, and
            # imports the underlying `sd-image.nix` partition-layout
            # module from nixpkgs. Replaces the upstream module
            # 1-for-1, no need to keep both.
            nixos-raspberrypi.nixosModules.sd-image
            ./Machines/PhysicalServers/PrintScanServerPi4/configuration.nix
          ];
        };

        # ── PrintScanServerPi4-provisioning — first-boot image for a
        # fresh Pi 4 SD card. Mirrors GhostHome's provisioning
        # pattern; see the long comment above the GhostHome variant
        # below for the complete workflow rationale. Bakes
        # `printscan-ready-<shortRev>` as the readiness ref, flips
        # into `PrintScanServerPi4`. Kernel + boot loader come from
        # nvmd (`linuxPackages_rpi4`, direct-EEPROM-kernel boot via
        # `bootloader = "kernel"` — see the live config for the
        # full rationale).
        PrintScanServerPi4-provisioning-sdImage = let
          printScanReadySuffix = self.shortRev or self.dirtyShortRev or "dirtyManual";
          printScanReadyRef = "printscan-ready-${printScanReadySuffix}";
        in nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-4.base
            # nvmd's sd-image module, not stock sd-image-aarch64.nix:
            # it bumps the firmware partition to 1 GB (kernel +
            # initrd + multiple generations live there), wires
            # `boot.loader.raspberry-pi.{firmware,boot}PopulateCmd`
            # into `sdImage.populate{Firmware,Root}Commands`, and
            # imports the underlying `sd-image.nix` partition-layout
            # module from nixpkgs. Replaces the upstream module
            # 1-for-1, no need to keep both.
            nixos-raspberrypi.nixosModules.sd-image
            ./Modules
            ({ lib, ... }: {
              networking.hostName = "printscan-provisioning";
              system.stateVersion = "25.05";

              # Match the live Pi 4 config: direct EEPROM kernel
              # boot with N-generation retention. sd-image-aarch64
              # turns on extlinux unconditionally; override.
              boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
              boot.loader.raspberry-pi.bootloader = lib.mkForce "kernel";
              boot.loader.raspberry-pi.configurationLimit = 3;

              # `__ref=…__` (double-underscore bracketing) is a
              # bash-safe stand-in for the parens we'd reach for —
              # parens leak through `image.fileName` into stdenv
              # build hooks that `eval` filenames unquoted and
              # break with "syntax error near unexpected token `('".
              # Underscores have no special meaning in any shell
              # and don't appear elsewhere in the rev → still
              # extracts cleanly: `grep -oP '(?<=__ref=)[^_]+'`.
              image.baseName = lib.mkForce
                "printscan-provisioning__ref=${printScanReadyRef}__";

              hypersw.profiles.physicalServerProvisioning = {
                enable = true;
                targetFlakeUri =
                  "github:hypersw/HyperNix?ref=${printScanReadyRef}";
                targetConfigName = "PrintScanServerPi4";
              };
            })
          ];
        };

        # ── GhostHome — Pi 5 home-automation server. Inherits the
        # print/scan stack as a guest workload until a dedicated
        # home-automation role takes its place as the headline.
        GhostHome = nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            sops-nix.nixosModules.sops
            {
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
              hypersw.profiles.anyMachineBase.alerts.configRevision =
                self.rev or self.dirtyRev or "dirty";
              hypersw.profiles.anyMachineBase.alerts.nixpkgsRevision = nixpkgs.rev;
            }
            ./Machines/PhysicalServers/GhostHome/configuration.nix
          ];
        };
        GhostHome-sdImage = nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            sops-nix.nixosModules.sops
            # nvmd's sd-image module, not stock sd-image-aarch64.nix:
            # it bumps the firmware partition to 1 GB (kernel +
            # initrd + multiple generations live there), wires
            # `boot.loader.raspberry-pi.{firmware,boot}PopulateCmd`
            # into `sdImage.populate{Firmware,Root}Commands`, and
            # imports the underlying `sd-image.nix` partition-layout
            # module from nixpkgs. Replaces the upstream module
            # 1-for-1, no need to keep both.
            nixos-raspberrypi.nixosModules.sd-image
            # Imported only when an sd-image module is in scope;
            # not in the universal `./Modules` bundle because the
            # `sdImage.*` options it references don't exist on
            # live (non-sd-image) machine configs. Inert by
            # default — gated on
            # `hypersw.hardware.raspberryPi5SdImage.enable`.
            ./Modules/Hardware/RaspberryPi5SdImage
            ./Machines/PhysicalServers/GhostHome/configuration.nix
          ];
        };

        # ── GhostHome-provisioning — minimalist first-boot image
        # the operator flashes to a fresh Pi 5 SD card. Boots,
        # generates ssh host keys, retries `nixos-rebuild boot`
        # against the readiness ref every minute until upstream
        # has it, then reboots into the full GhostHome config.
        #
        # The readiness ref is pinned to the COMMIT THAT BUILT THE
        # IMAGE — name `ghosthome-ready-<shortRev>`. That gives
        # each image a unique ref name so old images flashed
        # months ago don't accidentally pick up a fresh
        # `ghosthome-ready` branch the operator pushed for a
        # different image. Workflow:
        #
        #   1. Commit on master, pushed → CI (or manual) builds
        #      the image. The image bakes
        #      `?ref=ghosthome-ready-<shortRev>` and its filename
        #      embeds the same shortRev so the operator can grep
        #      images by ref.
        #   2. Operator flashes that specific image, boots, gets
        #      the host age key, encrypts secrets, commits.
        #   3. Operator pushes a branch (or tag) named exactly
        #      `ghosthome-ready-<shortRev>` pointing at the new
        #      commit. The image's first-boot service then finds
        #      it on its next retry.
        #
        # Manual / dirty-tree builds get `<shortRev>` →
        # `dirtyManual` so they're easy to spot and won't collide
        # with a real CI-built image.
        GhostHome-provisioning-sdImage = let
          ghostReadySuffix = self.shortRev or self.dirtyShortRev or "dirtyManual";
          ghostReadyRef = "ghosthome-ready-${ghostReadySuffix}";
        in nixos-raspberrypi.lib.nixosSystem {
          system = "aarch64-linux";
          # nvmd's `lib.nixosSystem` is a drop-in wrapper around
          # `nixpkgs.lib.nixosSystem` that injects their Pi-vendor
          # overlays (kernel, firmware, raspberrypi-utils,
          # bootloader bits) onto `pkgs` so their modules can
          # reference packages like `pkgs.raspberrypi-utils`
          # unconditionally. Defaults to using nvmd's pinned
          # nixpkgs (currently nixos-25.11), which matches the
          # builds in their binary cache.
          specialArgs = { inherit nixos-raspberrypi; };
          modules = [
            nixos-raspberrypi.nixosModules.raspberry-pi-5.base
            # nvmd's sd-image module, not stock sd-image-aarch64.nix:
            # it bumps the firmware partition to 1 GB (kernel +
            # initrd + multiple generations live there), wires
            # `boot.loader.raspberry-pi.{firmware,boot}PopulateCmd`
            # into `sdImage.populate{Firmware,Root}Commands`, and
            # imports the underlying `sd-image.nix` partition-layout
            # module from nixpkgs. Replaces the upstream module
            # 1-for-1, no need to keep both.
            nixos-raspberrypi.nixosModules.sd-image
            # Imported only here (sd-image scope), not in the
            # universal `./Modules` bundle — its `sdImage.*`
            # option references would otherwise blow up live
            # configs. Inert by default.
            ./Modules/Hardware/RaspberryPi5SdImage
            ./Modules
            ({ lib, ... }: {
              # Match the live Pi 5 config: direct EEPROM kernel
              # boot via nvmd's loader. No need for u-boot or
              # extlinux on Pi 5 USB (u-boot's RP1/USB support
              # isn't there in upstream 2026.01); EEPROM loads
              # the kernel directly from the firmware partition.
              # sd-image-aarch64 turns on extlinux unconditionally;
              # override.
              boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
              boot.loader.raspberry-pi.bootloader = "kernel";
              boot.loader.raspberry-pi.configurationLimit = 3;

              networking.hostName = "ghosthome-provisioning";
              system.stateVersion = "25.05";

              # Bake the expected ref name into the image filename
              # so an operator looking at downloaded artifacts
              # knows exactly which branch/tag they need to push
              # for the first-boot switch to succeed. The new
              # `image.baseName` option (sd-image renamed it from
              # `sdImage.imageBaseName` in 25.05) feeds
              # `image.fileName` — final filename ends up as
              # `<base>.img.zst`.
              #
              # Format: `__ref=<value>__` so the value extracts
              # unambiguously regardless of how many dashes either
              # side carries — `grep -oP '(?<=__ref=)[^_]+'` lifts
              # it out cleanly. Double-underscore brackets rather
              # than parens because parens leak through into
              # stdenv build hooks that `eval` filenames unquoted
              # and break with "syntax error near unexpected
              # token `('"; underscores are special-meaning-free
              # in every shell.
              image.baseName = lib.mkForce
                "ghosthome-provisioning__ref=${ghostReadyRef}__";

              hypersw.profiles.physicalServerProvisioning = {
                enable = true;
                targetFlakeUri =
                  "github:hypersw/HyperNix?ref=${ghostReadyRef}";
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
