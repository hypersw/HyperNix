{ config, lib, pkgs, ... }:
let
  cfg = config.services.epkowa-scanner;

  # Single source of truth for the SANE config directory path. Used below
  # for the /etc files we install, the login-shell env, and anywhere else
  # that needs to point scanimage at our custom dll.conf + epkowa.conf.
  saneConfigDir = "/etc/sane-config-epkowa";

  # NixOS's `hardware.sane` module installs backend libraries (including
  # our iscanWithIpcProxy) into /etc/sane-libs as a symlink farm. Login
  # shells get this path via `environment.variables.LD_LIBRARY_PATH`, but
  # systemd services do NOT inherit login-shell env — so a service running
  # `scanimage` fails with "no SANE devices found" despite the scanner
  # being present. Consumers must add this directory to their own service
  # environment; see `serviceEnvironment` option below.
  saneLibDir = "/etc/sane-libs";

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
  # x86_64 side uses the same nixpkgs as the host — the stub only does pure
  # CPU work (ESC/I byte munging) under qemu-user, which handles arbitrary
  # glibc syscalls fine. No USB ioctl drama since USB stays aarch64-native.

  pkgsX86 = import pkgs.path { system = "x86_64-linux"; config.allowUnfree = true; };

  # Rust stub, cross-compiled to x86_64 (rustPlatform uses native cross-
  # compilation — no qemu at build time). Loads the proprietary plugin
  # inside its own x86_64 process and serves IPC over inherited fd 3.
  stubBinary = pkgs.pkgsCross.gnu64.callPackage ../EpkowaStubX64/package.nix {};

  # The stub binary alone can't find the x86_64 interpreter .so files — they
  # live in per-scanner bundle derivations (pkgsX86.epkowa.plugins.*, each
  # installing its libesci-interpreter-*.so to /lib/esci/). Colon-join all
  # plugin libdirs into one LD_LIBRARY_PATH entry and point the x86_64 ld.so
  # at it before exec'ing the stub. Inherited fds (fd 3) survive this kind
  # of bash exec chain.
  #
  # The interpreter .so is linked against libstdc++.so.6 and libgcc_s.so.1
  # (C++ runtime — the proprietary blob is compiled from C++). Those aren't
  # the interpreter's problem to find, they're ld.so's — add the x86_64 gcc
  # cc.lib/lib path so the linker resolves the transitive deps.
  esciPluginLibs = lib.concatMapStringsSep ":"
    (p: "${p}/lib/esci")
    (lib.attrValues (lib.filterAttrs (_: lib.isDerivation) pkgsX86.epkowa.plugins));

  ccRuntimeX86 = "${pkgsX86.stdenv.cc.cc.lib}/lib";

  stubWrapper = pkgs.writeShellScriptBin "epkowa-stub-x64" ''
    export LD_LIBRARY_PATH=${esciPluginLibs}:${ccRuntimeX86}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
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

    # Env vars that any systemd service calling `scanimage` must set.
    # Exposed here so consumer modules don't hardcode the paths AND so we
    # stay out of `systemd.globalEnvironment` — changing that option
    # forces a PID 1 reexec during switch-to-configuration, which on
    # 2026-04-21 triggered a 74-cycle silent-reset boot loop taking ~4 min
    # to self-recover. Composing into per-service `environment=` blocks
    # keeps switch-time change surface on the affected services only.
    #
    # Usage:
    #   systemd.services.foo.environment =
    #     config.services.epkowa-scanner.serviceEnvironment // { ... };
    serviceEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = {
        SANE_CONFIG_DIR = saneConfigDir;
        LD_LIBRARY_PATH = saneLibDir;
      };
      description = "Env vars for services that run scanimage / open SANE backends.";
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
    #
    # Login shells get SANE_CONFIG_DIR via environment.variables (/etc/profile).
    # Systemd services don't inherit that — they read `serviceEnvironment`
    # (see option above) and compose it into their own `environment=` block.
    environment.etc."${lib.removePrefix "/etc/" saneConfigDir}/dll.conf".text = "epkowa";
    environment.etc."${lib.removePrefix "/etc/" saneConfigDir}/epkowa.conf".text = lib.strings.concatLines [
      "usb"
      ''usb 0x04b8 0x0142 "Perfection V33" "Epson Perfection V33/V330"''
    ];
    environment.variables.SANE_CONFIG_DIR = lib.mkForce saneConfigDir;

    services.saned.enable = true;
    networking.firewall.allowedTCPPorts = [ 6566 ];
  };
}
