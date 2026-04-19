{ config, lib, pkgs, nixpkgs-old-x86 ? null, ... }:
let
  cfg = config.services.epkowa-scanner;

  # ──────────────────────────────────────────────────────────────────────
  # x86_64 side of the proxy/stub split.
  #
  # Epson's esci-interpreter plugin (libesci-interpreter-perfection-v330.so
  # and siblings) is x86_64-only — no aarch64 build exists. Emulating the
  # whole SANE stack under qemu-user fails at libusb's async USBDEVFS ioctls;
  # box64 fails in its variadic libc wrappers. See repo history for receipts.
  #
  # Solution: keep libsane-epkowa.so aarch64-native (USB stays on this arch),
  # and isolate the proprietary plugin inside a short-lived x86_64 helper
  # process spawned per-scan. The aarch64 iscan and the x86_64 helper talk
  # over an inherited Unix socket; USB callbacks are forwarded back over the
  # same socket to the aarch64 side. See PROTOCOL.md in EpkowaStubX64/.
  #
  # Pinned old nixpkgs for the x86_64 side: the interpreter plugin and its
  # loader were built against a specific libc era. Modern nixpkgs x86_64
  # binaries work fine for computational code, but pinning keeps the
  # surface stable.

  pkgsX86 =
    if nixpkgs-old-x86 != null
    then import nixpkgs-old-x86 { system = "x86_64-linux"; config.allowUnfree = true; }
    else import pkgs.path       { system = "x86_64-linux"; config.allowUnfree = true; };

  # Rust stub, cross-compiled to x86_64 (rustPlatform uses native cross-
  # compilation — no qemu at build time). Loads the proprietary plugin
  # inside its own x86_64 process and serves IPC over inherited fd 3.
  stubBinary = pkgs.pkgsCross.gnu64.callPackage ../EpkowaStubX64/package.nix {};

  # The stub binary alone can't find the x86_64 interpreter .so files — they
  # live in pkgsX86.epkowa's esci bundle dir. Wrap the stub in a shell script
  # that points the x86_64 ld.so at the right directories before exec.
  # Inherited fds (fd 3) survive this kind of bash exec chain.
  stubWrapper = pkgs.writeShellScriptBin "epkowa-stub-x64" ''
    export LD_LIBRARY_PATH=${pkgsX86.epkowa}/lib/esci:${pkgsX86.epkowa}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    exec ${stubBinary}/bin/epkowa-stub-x64 "$@"
  '';

  # ──────────────────────────────────────────────────────────────────────
  # aarch64 side — patched iscan / libsane-epkowa.so.
  #
  # Apply our IPC proxy patch on top of stock nixpkgs epkowa. The patch
  # adds a --enable-ipc-proxy configure flag; when set, epkowa_ip.c's
  # _load() routes through Unix-socket IPC to our stub instead of
  # lt_dlopen'ing the plugin directly.
  #
  # autoreconfHook regenerates configure/Makefile.in after our patch
  # touches configure.ac and Makefile.am.

  iscanWithIpcProxy = pkgs.epkowa.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ../EpkowaStubX64/iscan-ipc-proxy.patch ];
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoreconfHook ];
    configureFlags = (old.configureFlags or []) ++ [
      "--enable-ipc-proxy"
      "--with-ipc-stub=${stubWrapper}/bin/epkowa-stub-x64"
    ];
  });
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
      extraBackends = [ iscanWithIpcProxy ];
    };

    # Permissions: keep /dev/bus/usb/*/* for the scanner accessible to the
    # "scanner" group regardless of whether upstream udev rules shipped.
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0142", MODE="0660", GROUP="scanner"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0143", MODE="0660", GROUP="scanner"
    '';

    # Custom SANE config dir: only epkowa enabled, V33 USB ID mapped to
    # model name. Without the ID line, epkowa detects the scanner as
    # "Epson (unknown model)" and sane_open fails with EINVAL.
    environment.etc."sane-config-epkowa/dll.conf".text = "epkowa";
    environment.etc."sane-config-epkowa/epkowa.conf".text = lib.strings.concatLines [
      "usb"
      ''usb 0x04b8 0x0142 "Perfection V33" "Epson Perfection V33/V330"''
    ];
    environment.variables.SANE_CONFIG_DIR = lib.mkForce "/etc/sane-config-epkowa";

    services.saned.enable = true;
    networking.firewall.allowedTCPPorts = [ 6566 ];
  };
}
