{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.services.epkowa-scanner;

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
  #
  # ── BUILD-TIME CHICKEN-AND-EGG (read before failing here) ──
  # The store paths derived from pkgsX86 below (notably
  # pkgsX86.epkowa.plugins.*) are x86_64-linux derivations. To
  # MATERIALISE them in the local store during `nixos-rebuild
  # switch`, nix needs one of:
  #
  #   - A cache hit on cache.nixos.org (epkowa plugins are unfree;
  #     Hydra coverage is patchy, so don't assume).
  #   - A remote x86_64 builder configured via nix.buildMachines.
  #   - Local qemu-x86_64 binfmt registration on THIS HOST.
  #
  # The binfmt switch is `boot.binfmt.emulatedSystems` — set below
  # under the `registerX86_64Binfmt` option. The option defaults
  # to whatever `enable` is, so a happy-path one-step switch works
  # when cache substitution succeeds.
  #
  # The hazard case: a host where cache substitution misses AND
  # binfmt isn't already registered. nixos-rebuild build runs on
  # the CURRENT system, before activation, so flipping `enable`
  # → true won't register binfmt in time for the build that
  # depends on it. Result: build fails with "a 'x86_64-linux'
  # builder is required to build /nix/store/...drv".
  #
  # If you hit that here, pre-stage binfmt one auto-rebuild cycle
  # in advance by setting:
  #   hypersw.services.epkowa-scanner.registerX86_64Binfmt = true;
  # WITHOUT setting `enable = true`. Wait for the switch to
  # activate, then flip `enable = true` in a second commit. The
  # second build phase now has qemu-x86_64 available.
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
  #
  # ── PAGE-SHIFT WRAPPER ──
  # Epson's libesci-interpreter-*.so plugins were linked with
  # -z max-page-size=4096. On hosts running a 16 KiB-page kernel
  # (Pi 5 vendor kernel, Asahi on Apple Silicon, etc.) `dlopen`
  # fails with "failed to map segment from shared object" because
  # PT_LOAD#2's file offset (0x4a000 in v330) isn't 16K-aligned.
  # The ElfPageShift package (sibling dir) ships a tool that
  # rewrites every absolute VA in the ELF and inserts padding so
  # all segments end up 16K-aligned. Output is BACKWARDS-COMPATIBLE
  # with 4K-page kernels (16K-aligned ⇒ 4K-aligned), so we apply
  # the shift unconditionally on every plugin bundle, regardless
  # of the host's actual page size — no need to gate on
  # `getconf PAGESIZE`.
  # See ../../../ELF-PAGE-SHIFT.md for the full background and the
  # eight-layer ELF surgery checklist.
  # Run the shifter on the BUILD host (aarch64 / native pkgs) rather
  # than under qemu-x86_64. The tool is pure Python — it only reads
  # and writes bytes — so host arch doesn't matter for correctness.
  # Native pkgs avoids dragging an emulated python3 + pyelftools
  # closure into the build, which would noticeably slow the switch
  # on a Pi.
  pageShift = import ../ElfPageShift/lib.nix { inherit pkgs; };
  shiftedEpkowaPlugins = lib.mapAttrs
    (_: p: pageShift.pageShiftElfBundle { src = p; })
    (lib.filterAttrs (_: lib.isDerivation) pkgsX86.epkowa.plugins);
  esciPluginLibs = lib.concatMapStringsSep ":"
    (p: "${p}/lib/esci")
    (lib.attrValues shiftedEpkowaPlugins);

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

  iscanWithIpcProxy = (pkgs.epkowa.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ../EpkowaStubX64/iscan-ipc-proxy.patch ];
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoreconfHook ];
    configureFlags = (old.configureFlags or []) ++ [
      "--enable-ipc-proxy"
      "--with-ipc-stub=${stubWrapper}/bin/epkowa-stub-x64"
    ];
  })).overrideAttrs (final: {
    # Upstream epkowa bakes the proprietary x86_64 plugin paths into
    # var/lib/iscan/interpreter at build time — each line maps a USB
    # VID:PID to a /nix/store/<HASH>-<plugin-bundle-name>/lib/esci/...
    # path. The IPC patch forwards the path verbatim to the x86_64
    # stub, which dlopens it via qemu-x86_64. On a 16K-page kernel
    # the unshifted .so fails to mmap, so we need the path to point
    # at our page-shifted variant.
    #
    # We can't substitute by exact `passthru.unshifted` outPath —
    # the plugin set referenced at iscan-build time has a different
    # hash than `pkgsX86.epkowa.plugins.${name}` resolves to in this
    # eval (cross-package input churn between when iscan got built
    # and now). Both point to "the same" iscan-v330-bundle in name
    # but different store paths.
    #
    # Match by derivation NAME instead. The interpreter config has
    # paths of the form `/nix/store/<32-char-hash>-<bundle-name>`;
    # rewrite any hash for each known bundle-name to our shifted
    # variant's outPath. Robust across input-hash churn — and an
    # unmatched bundle (no scanner of that model deployed here)
    # just no-ops.
    postFixup = (final.postFixup or "") + ''
      interp=$out/var/lib/iscan/interpreter
      if [ -f "$interp" ]; then
        ${lib.concatMapStringsSep "\n      " (p:
          let origName = p.passthru.unshifted.name; in
          ''sed -i 's|/nix/store/[a-z0-9]\{32\}-${origName}|${p}|g' "$interp" '' )
        (lib.attrValues shiftedEpkowaPlugins)}
        echo "ElfPageShift: rewrote interpreter config:"
        cat "$interp"
      fi
    '';
  });
in
{
  options.hypersw.services.epkowa-scanner = {
    enable = lib.mkEnableOption "Epson Perfection V33 scanning via SANE/epkowa";

    registerX86_64Binfmt = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = ''
        Register qemu-user x86_64-linux binfmt on this host. Needed
        at RUNTIME to execute the x86_64 IPC stub helper that loads
        the proprietary Epson interpreter, and at BUILD time on a
        non-x86_64 host to build the x86_64 plugin derivations that
        appear in the scanner's closure (when those aren't already
        cached on a binary substituter).

        Defaults to whatever <literal>enable</literal> is — happy
        path: one-step switch works when cache substitution covers
        the x86_64 plugins.

        Hazard case: on a host where x86_64 plugins aren't cached
        AND no remote x86_64 builder is configured, the FIRST
        switch to <literal>enable = true</literal> fails because
        the build phase runs on the current system (no binfmt yet,
        the option only activates after the switch completes).
        Pre-stage by setting <literal>registerX86_64Binfmt = true</literal>
        explicitly one auto-rebuild cycle BEFORE flipping
        <literal>enable = true</literal> — the next switch then has
        qemu-x86_64 available during its build phase. See the long
        comment block above <literal>pkgsX86</literal> in this
        module for the full story.
      '';
    };

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
    #     config.hypersw.services.epkowa-scanner.serviceEnvironment // { ... };
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

  config = lib.mkMerge [
    # x86_64 binfmt — opt-in, decoupled from `enable` so an operator
    # can pre-stage it one auto-rebuild cycle ahead of the full
    # enable. Cheap when standalone (just qemu-x86_64 + systemd
    # binfmt registration at boot), so the only reason this isn't
    # always-on is to keep the closure small on hosts that never
    # use the scanner.
    (lib.mkIf cfg.registerX86_64Binfmt {
      boot.binfmt.emulatedSystems = [ "x86_64-linux" ];
    })

    (lib.mkIf cfg.enable {
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
    })
  ];
}
