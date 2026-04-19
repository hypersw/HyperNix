{ config, lib, pkgs, nixpkgs-old-x86 ? null, ... }:
let
  cfg = config.services.epkowa-scanner;

  # x86_64 SANE stack for aarch64 hosts — Epson's esci-interpreter plugin is
  # x86_64-only, so we run scanimage (and the whole SANE stack) under
  # binfmt (box64). See useX86Backends option below for rationale.
  #
  # Pinned to an older nixpkgs (passed via specialArgs) so the resulting
  # x86_64 libraries reference only glibc symbols that box64's wrapper table
  # knows about. Without this pin, modern libudev.so would reference fsmount,
  # pidfd_spawn, mount_setattr, etc. that aren't in box64's wrapper.
  pkgsX86 =
    if nixpkgs-old-x86 != null
    then import nixpkgs-old-x86 { system = "x86_64-linux"; config.allowUnfree = true; }
    else import pkgs.path { system = "x86_64-linux"; config.allowUnfree = true; };

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

  # Wrapper that invokes the x86_64 scanimage via box64 (not binfmt).
  #
  # Why box64 directly: qemu-user (the default binfmt handler) can't handle
  # libusb's async USBDEVFS ioctls — scans fail with EPROTO. box64's libusb
  # path works. But box64's dynarec is unstable on NixOS; BOX64_DYNAREC=0
  # (interpreter mode) is needed for any non-trivial app.
  #
  # Why not make box64 the binfmt handler: box64 isn't robust enough for
  # arbitrary build-time x86_64 invocations (nix builds of pinned pkgsX86
  # will call sh/bash/gcc, which box64 fumbles). Keep qemu-user as the
  # global binfmt handler (for build time) and invoke box64 explicitly
  # only for our runtime scanner path.
  # Assemble a directory of aarch64-native libraries that box64 wraps.
  # Box64's wrapper layer calls out to native-arch implementations of common
  # libs (libudev, libusb, libpng, libz, libxml2, libatomic) instead of
  # emulating them, for performance. It looks them up at system paths that
  # NixOS doesn't populate, so we stage them into a single dir and point
  # BOX64_LD_LIBRARY_PATH at it. Symlinks also cover the extra soname aliases
  # box64 checks for (e.g. libudev.so.0 for libudev-proper).
  box64NativeLibs = pkgs.runCommandLocal "box64-native-libs" {} ''
    mkdir -p $out/lib
    ln -sf ${pkgs.libpng}/lib/libpng16.so.16 $out/lib/libpng16.so.16
    ln -sf ${pkgs.libpng}/lib/libpng16.so.16 $out/lib/libpng16.so
    ln -sf ${pkgs.zlib}/lib/libz.so.1 $out/lib/libz.so.1
    ln -sf ${pkgs.zlib}/lib/libz.so.1 $out/lib/libz.so
    ln -sf ${pkgs.libusb1}/lib/libusb-1.0.so.0 $out/lib/libusb-1.0.so.0
    ln -sf ${pkgs.libusb1}/lib/libusb-1.0.so.0 $out/lib/libusb-1.0.so
    ln -sf ${pkgs.libxml2.out}/lib/libxml2.so.2 $out/lib/libxml2.so.2
    ln -sf ${pkgs.libxml2.out}/lib/libxml2.so.2 $out/lib/libxml2.so
    ln -sf ${pkgs.systemdLibs}/lib/libudev.so.1 $out/lib/libudev.so.1
    ln -sf ${pkgs.systemdLibs}/lib/libudev.so.1 $out/lib/libudev.so.0
    ln -sf ${pkgs.stdenv.cc.cc.lib}/lib/libatomic.so.1 $out/lib/libatomic.so.1
  '';

  scanimageX86 = pkgs.writeShellScriptBin "scanimage-x86" ''
    export BOX64_NOBANNER=1
    export BOX64_DYNAREC=0
    export BOX64_ALLOWMISSINGLIBS=1
    export BOX64_LD_LIBRARY_PATH=${box64NativeLibs}/lib
    export SANE_CONFIG_DIR=${saneConfX86}/etc/sane.d
    export LD_LIBRARY_PATH=${saneLibsX86}/lib/sane:${saneLibsX86}/lib
    exec ${pkgs.box64}/bin/box64 ${pkgsX86.sane-backends}/bin/scanimage "$@"
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
