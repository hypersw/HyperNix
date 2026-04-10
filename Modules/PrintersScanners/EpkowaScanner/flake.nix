{
  description = "Epson Perfection V33 scanner module — SANE/epkowa + AirSane (eSCL)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.epkowa-scanner;
      in
      {
        options.services.epkowa-scanner = {
          enable = lib.mkEnableOption "Epson Perfection V33 scanning via SANE/epkowa";

          airsane.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Expose scanner to LAN via eSCL/AirScan (iOS/macOS/Android native)";
          };
        };

        config = lib.mkIf cfg.enable {
          # SANE with epkowa backend (proprietary Epson driver, includes V33 plugin)
          hardware.sane = {
            enable = true;
            extraBackends = [ pkgs.epkowa ];
          };

          # Epson's packaged udev rules are broken on NixOS — set manually
          services.udev.extraRules = ''
            SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0142", MODE="0660", GROUP="scanner"
            SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0143", MODE="0660", GROUP="scanner"
          '';

          # Override SANE config: only load epkowa backend for fast enumeration
          environment.etc."sane-config-epkowa/dll.conf".text = "epkowa";
          environment.etc."sane-config-epkowa/epkowa.conf".text = "usb";
          environment.variables.SANE_CONFIG_DIR = lib.mkForce "/etc/sane-config-epkowa";

          # User must be in scanner group for SANE access
          # (the machine flake adds the service user to this group)

          # AirSane: bridge SANE to eSCL for iOS/macOS/Android native scanning
          # TODO: AirSane is not in nixpkgs — package it or use a custom derivation
          # services.airsane.enable = cfg.airsane.enable;

          # saned for Linux-to-Linux network scanning
          services.saned.enable = true;
          networking.firewall.allowedTCPPorts = [ 6566 ]; # saned
        };
      };
  };
}
