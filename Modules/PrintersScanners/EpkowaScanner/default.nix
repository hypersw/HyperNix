{ config, lib, pkgs, ... }:
let
  cfg = config.services.epkowa-scanner;

  # x86_64 SANE stack for aarch64 hosts — Epson's esci-interpreter plugin is
  # x86_64-only, so we run scanimage (and the whole SANE stack) under
  # qemu-user binfmt. See useX86Backends option below for rationale.
  pkgsX86 = import pkgs.path { system = "x86_64-linux"; config.allowUnfree = true; };

  # Combined x86_64 SANE lib dir — mirrors what hardware.sane does natively:
  # symlink libsane-epkowa.so and its interpreter plugin where scanimage finds them.
  saneLibsX86 = pkgs.symlinkJoin {
    name = "sane-libs-x86";
    paths = [ pkgsX86.sane-backends pkgsX86.epkowa ];
  };

  # x86_64 SANE config dir: only epkowa enabled, V33 USB ID mapped to model name.
  saneConfX86 = pkgs.runCommandLocal "sane-config-x86" {} ''
    mkdir -p $out/etc/sane.d
    echo epkowa > $out/etc/sane.d/dll.conf
    cat > $out/etc/sane.d/epkowa.conf <<'EOF'
    usb
    usb 0x04b8 0x0142 "Perfection V33" "Epson Perfection V33/V330"
    EOF
  '';

  # Wrapper that invokes the x86_64 scanimage. Kernel's binfmt_misc handler
  # transparently runs it via qemu-x86_64. SANE env vars point at x86_64 libs
  # and configs so the whole dlopen chain (libsane-epkowa → interpreter) uses
  # the emulated-arch binaries.
  scanimageX86 = pkgs.writeShellScriptBin "scanimage-x86" ''
    export SANE_CONFIG_DIR=${saneConfX86}/etc/sane.d
    export LD_LIBRARY_PATH=${saneLibsX86}/lib/sane:${saneLibsX86}/lib
    exec ${pkgsX86.sane-backends}/bin/scanimage "$@"
  '';
in
{
  options.services.epkowa-scanner = {
    enable = lib.mkEnableOption "Epson Perfection V33 scanning via SANE/epkowa";

    airsane.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose scanner to LAN via eSCL/AirScan (iOS/macOS/Android native)";
    };

    useX86Backends = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install an x86_64 scanimage (invoked as `scanimage-x86`) alongside the
        native one. Epson's esci-interpreter plugin is x86_64-only, so on
        aarch64 we run the whole SANE stack under qemu-user via binfmt to be
        able to use V33/V330 scanners.

        Requires boot.binfmt.emulatedSystems = [ "x86_64-linux" ] on the host.
      '';
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

    environment.systemPackages = lib.mkIf cfg.useX86Backends [ scanimageX86 ];
  };
}
