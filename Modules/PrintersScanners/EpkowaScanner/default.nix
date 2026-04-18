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
    # Without the specific USB-ID line, epkowa detects the scanner as
    # "Epson (unknown model)" and sane_open fails with EINVAL. The ID line
    # maps 04b8:0142 to the Perfection V33 model so the interpreter plugin
    # loads correctly.
    environment.etc."sane-config-epkowa/epkowa.conf".text = lib.strings.concatLines [
      "usb"
      ''usb 0x04b8 0x0142 "Perfection V33" "Epson Perfection V33/V330"''
    ];
    environment.variables.SANE_CONFIG_DIR = lib.mkForce "/etc/sane-config-epkowa";

    services.saned.enable = true;
    networking.firewall.allowedTCPPorts = [ 6566 ];
  };
}
