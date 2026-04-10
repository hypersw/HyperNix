{ config, lib, pkgs, ... }:
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
    hardware.sane = {
      enable = true;
      extraBackends = [ pkgs.epkowa ];
    };

    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0142", MODE="0660", GROUP="scanner"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0143", MODE="0660", GROUP="scanner"
    '';

    environment.etc."sane-config-epkowa/dll.conf".text = "epkowa";
    environment.etc."sane-config-epkowa/epkowa.conf".text = "usb";
    environment.variables.SANE_CONFIG_DIR = lib.mkForce "/etc/sane-config-epkowa";

    services.saned.enable = true;
    networking.firewall.allowedTCPPorts = [ 6566 ];
  };
}
