#
# Looking Glass client — machine-wide defaults, hypervisor-side setup,
# and per-VM profile wrappers.
#
# What this module does, all on the hypervisor (Linux) host side:
#   1. Installs `looking-glass-client` (the viewer; NOT to be confused
#      with the LG SERVER service that runs inside the Windows guest —
#      see SETUP.md in this directory for the guest side).
#   2. Writes /etc/looking-glass-client.ini — the file LG reads as its
#      machine-wide defaults (path is hard-coded in the binary; verified
#      via `strings looking-glass-client | rg 'looking-glass-client.ini'`).
#   3. Sets up the kvmfr kernel module + udev + kvm-group + per-VM
#      `/dev/kvmfr*` devices (opt-out).
#   4. Extends libvirt's cgroup_device_acl to whitelist `/dev/kvmfr*`
#      (opt-out).
#   5. Optionally generates per-VM wrapper scripts that pass instance-
#      specific settings (shm file, SPICE socket, window title) as CLI
#      args — CLI args override the .ini, so this gives you stable
#      machine-wide policy plus dynamic per-VM overrides.
#
# Defaults were assembled from real-world LG-with-Windows-guest
# experience: SPICE relative-motion + Windows mouse curves accelerate
# unpredictably without the rawMouse/mouseSens/mouseSmoothing trio;
# jitRender + a shorter framePollInterval are zero-cost latency wins
# that no one has a reason to opt out of. See option descriptions
# below for the per-setting "why".
#
# See SETUP.md in this directory for the guest-side counterpart: LG
# SERVER service, IVSHMEM Windows driver, Virtual Display Driver,
# NVIDIA control panel settings, and the MouseFix.reg companion file.
#

{ config, lib, pkgs, ... }:

let
  cfg = config.hypersw.programs.lookingGlassClient;

  # ── Helpers ───────────────────────────────────────────────────────

  # LG accepts "yes"/"no" for booleans (not "true"/"false"). Numbers
  # and strings pass through as-is.
  toLgValue = v:
    if v == true then "yes"
    else if v == false then "no"
    else toString v;

  # Render { sectionName = { key = value; ... }; ... } as LG .ini text.
  # Empty sections are dropped to keep the file readable.
  renderIni = sections:
    let
      renderSection = name: kvs:
        if kvs == {} then ""
        else
          "[${name}]\n"
          + lib.concatStringsSep "\n"
              (lib.mapAttrsToList (k: v: "${k}=${toLgValue v}") kvs)
          + "\n";
      pieces = lib.mapAttrsToList renderSection sections;
    in lib.concatStringsSep "\n" (lib.filter (s: s != "") pieces);

  # Flatten { section = { key = v; }; ... } into CLI arg list
  # ("section:key=value" tokens), suitable for `looking-glass-client`'s
  # bare-named option form (no leading dashes — confirmed empirically).
  toCliArgs = sections:
    lib.concatLists (lib.mapAttrsToList (sec: kvs:
      lib.mapAttrsToList (k: v: "${sec}:${k}=${toLgValue v}") kvs
    ) sections);

  # Deep-merge two {section.key = value} attrsets; later sections win
  # at the value level (not section level — both sides' keys survive).
  mergeSettings = a: b:
    let allSections = lib.unique (lib.attrNames a ++ lib.attrNames b);
    in lib.listToAttrs (map (sec: {
      name = sec;
      value = (a.${sec} or {}) // (b.${sec} or {});
    }) allSections);

  # Derived: list of /dev/kvmfrN device paths matching `kvmfrSizesMb`.
  kvmfrDevices = lib.genList
    (i: "/dev/kvmfr${toString i}")
    (lib.length cfg.kvmfrSizesMb);

  # ── Built-in defaults ─────────────────────────────────────────────
  # Each block is a discrete logical group, gated by its own enable/
  # disable option below. Comments document the WHY of each setting,
  # not just the WHAT.

  # Opt-out: fixes the non-linear mouse acceleration that anyone using
  # LG with a Windows guest hits on day one. The Windows pointer curve
  # is applied to SPICE relative-motion deltas which arrive at a
  # different effective DPI than a physical USB mouse would; the
  # result is that fast moves over-travel and slow moves under-travel.
  # `rawMouse` makes LG send raw deltas without its own pre-scaling,
  # `mouseSens=0` is the neutral multiplier, `mouseSmoothing=no`
  # disables intra-frame interpolation that reads as drift when
  # pixel-targeting. `mouseRedraw=yes` forces a frame redraw on
  # cursor motion even if the FPS-min throttle would otherwise pause
  # rendering — it's LG's upstream default but we pin it explicitly
  # so the file documents intent and the behaviour survives any
  # future upstream default change. Pair with MouseFix.reg in the
  # guest (see SETUP.md) to flatten the Windows-side curve too.
  mouseFixSettings = {
    input = {
      rawMouse = true;
      mouseSens = 0;
      mouseSmoothing = false;
      mouseRedraw = true;
    };
  };

  # Opt-out: zero-CPU-cost latency reductions. `jitRender=yes` makes
  # the client render on frame arrival from the host instead of on its
  # own redraw timer (kills a buffer-induced frame of latency).
  # `framePollInterval=500` halves the default 1000 µs poll for
  # frame-ready signals from IVSHMEM. Neither has a downside.
  lowLatencySettings = {
    win = { jitRender = true; };
    app = { framePollInterval = 500; };
  };

  # Opt-in: replaces LG's default "manual toggle" grab model with an
  # auto-grab-on-focus / release-on-focus-loss model. Better when
  # you're using the VM as a desktop and tabbing between it and host
  # apps frequently; worse for exclusive gaming where any focus loss
  # would steal input mid-action.
  # `releaseKeysOnFocusLoss` defaults to yes upstream but we set it
  # explicitly here for completeness — without it you can get a
  # "stuck Alt" state on tab-out.
  autoCaptureSettings = {
    input = {
      autoCapture = true;
      captureOnFocus = true;
      grabKeyboardOnFocus = true;
      releaseKeysOnFocusLoss = true;
    };
  };

  # ── Compose the final settings dictionary ─────────────────────────

  baseSettings = lib.foldl' mergeSettings {} (
    (lib.optional (!cfg.dontApplyMouseFixes) mouseFixSettings)
    ++ (lib.optional (!cfg.dontApplyLowLatencyDefaults) lowLatencySettings)
    ++ (lib.optional cfg.enableAutoCapture autoCaptureSettings)
  );

  finalSettings = mergeSettings baseSettings cfg.extraSettings;

  iniHeader = ''
    ; ────────────────────────────────────────────────────────────────
    ; /etc/looking-glass-client.ini
    ; Generated by hypersw.programs.lookingGlassClient.
    ; DO NOT EDIT BY HAND — changes will be lost on the next rebuild.
    ; To customize: set `hypersw.programs.lookingGlassClient.extraSettings`
    ; in your NixOS config.
    ;
    ; Active feature groups (toggle via module options):
    ;   - mouseFixes:        ${if cfg.dontApplyMouseFixes then "OFF" else "ON"}
    ;   - lowLatencyDefaults:${if cfg.dontApplyLowLatencyDefaults then "OFF" else "ON"}
    ;   - autoCapture:       ${if cfg.enableAutoCapture then "ON" else "OFF"}
    ;
    ; Precedence (low→high): compiled-in defaults < this file <
    ; ~/.config/looking-glass/client.ini < CLI args.
    ; Per-profile `looking-glass-client-<name>` wrappers (also generated
    ; by this module) inject their settings as CLI args, so profile
    ; settings override anything written here.
    ; ────────────────────────────────────────────────────────────────
  '';

  iniText = iniHeader + "\n" + renderIni finalSettings;

  # ── Profile wrappers ──────────────────────────────────────────────

  mkProfileWrapper = name: profileSettings:
    pkgs.writeShellScriptBin "looking-glass-client-${name}" ''
      # Auto-generated by hypersw.programs.lookingGlassClient.profiles.${name}
      # CLI args take precedence over /etc/looking-glass-client.ini,
      # which in turn overrides compiled-in defaults.
      # Any args passed by the user are appended last and override everything.
      exec ${cfg.package}/bin/looking-glass-client \
        ${lib.concatMapStringsSep " \\\n        "
            (a: lib.escapeShellArg a)
            (toCliArgs profileSettings)} \
        "$@"
    '';

  profilePackages = lib.mapAttrsToList mkProfileWrapper cfg.profiles;

in {

  options.hypersw.programs.lookingGlassClient = {

    enable = lib.mkEnableOption "Looking Glass client with machine-wide defaults";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.looking-glass-client;
      defaultText = lib.literalExpression "pkgs.looking-glass-client";
      description = ''
        The looking-glass-client package to install. Override if you've
        built a patched binary (e.g. with the MBRD-filter removed for
        WARP-only guests, see SETUP.md).
      '';
    };

    # ── Default-ON behaviours: skip them with `dontXxx = true` ─────
    # Naming follows the nixpkgs stdenv `dontStrip` / `dontPatch` /
    # `dontUnpack` convention: default `false` means "the action
    # happens by default"; set to `true` to skip the action.

    dontApplyMouseFixes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skip applying the mouse-acceleration fixes
        (`rawMouse=yes`, `mouseSens=0`, `mouseSmoothing=no`).
        These exist because the combination of SPICE relative-motion
        delivery + Windows' pointer curve produces unpredictable
        non-linear acceleration inside the LG window — fast moves
        over-travel, slow moves under-travel. Default is to apply
        them; skip only if you intentionally want Windows pointer
        acceleration to affect the LG window (rare).

        Pair with the MouseFix.reg companion file in the guest to
        flatten the Windows-side curve too — see SETUP.md.
      '';
    };

    dontApplyLowLatencyDefaults = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skip applying the latency-reduction defaults
        (`jitRender=yes`, `framePollInterval=500`). Both are
        zero-CPU-cost wins with no known downsides; the option exists
        only to allow opting out for diagnostic purposes.
      '';
    };

    # ── Default-OFF behaviour: enable with `enableXxx = true` ──────

    enableAutoCapture = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Replace LG's default "manual toggle" grab model with
        auto-grab-on-focus + release-on-focus-loss
        (`autoCapture=yes`, `captureOnFocus=yes`,
        `grabKeyboardOnFocus=yes`, `releaseKeysOnFocusLoss=yes`).

        Better when the VM is a desktop and you tab in/out of it
        frequently; worse for exclusive-fullscreen gaming where any
        host-side focus event would steal input mid-action. Pure
        workflow preference, so opt-in.
      '';
    };

    # ── Hypervisor-side setup (default ENABLED; skip with dontXxx) ──
    # Both groups below are required for the standard kvmfr-backed
    # LG path. /dev/shm-backed LG (cheaper alternative for non-gaming
    # VMs) needs neither — set both `dont*` to true if you've gone
    # fully shm.

    dontSetupKvmfr = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skip the kernel-side kvmfr setup (module package, kernelModules
        entry, modprobe options, udev rule, kvm-group membership).
        The module otherwise:
          - Pulls `config.boot.kernelPackages.kvmfr` into extraModulePackages
          - Adds "kvmfr" to boot.kernelModules
          - Sets `options kvmfr static_size_mb=...` from kvmfrSizesMb
          - Creates `SUBSYSTEM=="kvmfr", OWNER="root", GROUP="kvm", MODE="0660"`
          - Adds every entry of `interactiveUsers` to the `kvm` group

        Skip if you're managing kvmfr externally or using the
        /dev/shm-only LG path everywhere.
      '';
    };

    dontExtendLibvirtCgroupAcl = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skip extending libvirt's qemu cgroup_device_acl with
        `/dev/kvmfr*` entries. Without this extension, libvirt's
        per-domain cgroup blocks QEMU's open() on the kvmfr node and
        you get EPERM at VM start — even with `runAsRoot=true`, since
        the cgroup `devices` controller doesn't honour root.

        The module rewrites the full ACL (libvirt has no append
        syntax for this option); it replicates the default list from
        libvirt's `qemu.conf.in` and appends `/dev/kvmfr0`,
        `/dev/kvmfr1`, ... based on `kvmfrSizesMb` length.

        Skip only if you've already configured this elsewhere or
        you're going /dev/shm-only.
      '';
    };

    kvmfrSizesMb = lib.mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [ 64 ];
      example = [ 64 32 32 ];
      description = ''
        One element per kvmfr device. Default is a single 64 MiB
        device at `/dev/kvmfr0` — enough for 4K @ 32bpp
        double-buffered (rule of thumb: `2 * w * h * 4 + 10 MiB`,
        rounded up to a power of two). Add more entries to allocate
        additional devices for additional VMs: `[ 64 32 32 ]` →
        kvmfr0=64MiB, kvmfr1=32MiB, kvmfr2=32MiB.

        Changes require a host reboot or `rmmod kvmfr && modprobe kvmfr`
        with no VM holding the device — kvmfr allocates at module load.

        Each kvmfr device is 1:1 with one VM (ivshmem-plain has one
        writer per region). Has no effect when
        `dontSetupKvmfr = true`.
      '';
    };

    interactiveUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "alice" "bob" ];
      description = ''
        Local users who will run `looking-glass-client`. Each is added
        to the `kvm` group so they can mmap `/dev/kvmfr*`.

        At least one entry is REQUIRED when `dontSetupKvmfr = false`
        (the default); the assertion fires at eval time if the list
        is empty. Leave `[]` only when kvmfr setup is being skipped.
      '';
    };

    # ── Free-form overrides ────────────────────────────────────────

    extraSettings = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (oneOf [ str int bool ]));
      default = {};
      example = lib.literalExpression ''
        {
          win = { fullScreen = true; showFPS = true; };
          input = { escapeKey = "KEY_PAUSE"; };
        }
      '';
      description = ''
        Additional sections/keys to merge into the generated
        /etc/looking-glass-client.ini. Merged on top of the
        feature-group defaults selected via the toggles above —
        if you set the same key here it wins.

        Use this for settings that aren't covered by a built-in
        feature group, or for per-machine overrides.
      '';
    };

    # ── Per-profile wrappers ───────────────────────────────────────

    profiles = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (attrsOf (oneOf [ str int bool ])));
      default = {};
      example = lib.literalExpression ''
        {
          stm = {
            app = { shmFile = "/dev/kvmfr0"; };
            spice = { host = "127.0.0.1"; port = 5910; };
            win = { title = "LG: stm"; };
          };
          warp = {
            app = { shmFile = "/dev/shm/lg-warp"; };
            spice = { host = "127.0.0.1"; port = 5911; };
            win = { title = "LG: warp-test"; };
          };
        }
      '';
      description = ''
        Named profiles, each producing a `looking-glass-client-<name>`
        wrapper at PATH that invokes the base client with the profile's
        settings appended as CLI arguments (`section:key=value`).

        CLI args override the /etc/looking-glass-client.ini, so use
        profiles for instance-specific things that shouldn't bake into
        machine-wide policy — typically `app:shmFile`, `spice:host`,
        `spice:port`, `win:title`. Any args the user passes to the
        wrapper at invocation time append AFTER the profile's args
        and override them in turn.

        Wrappers are installed via `environment.systemPackages`, so
        they appear on PATH for all users when the module is enabled.
      '';
    };

    # ── Read-only template paths ───────────────────────────────────

    templates = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      readOnly = true;
      default = {
        mouseFix = ./Template/MouseFix.reg;
        serverIni = ./Template/looking-glass-host.ini;
      };
      description = ''
        Paths to template files that go into the Windows guest:
          - `mouseFix`: registry merge that flattens the Windows
            pointer curve to linear (companion to
            `dontApplyMouseFixes = false` on the client side).
          - `serverIni`: example `looking-glass-host.ini` to copy
            to the guest at
            `C:\ProgramData\Looking Glass (host)\looking-glass-host.ini`.
            Filename matches the destination — no rename needed.
        See SETUP.md in this module's directory for usage.
      '';
    };

  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Client install + machine-wide .ini + profile wrappers ───────
    {
      environment.etc."looking-glass-client.ini".text = iniText;
      environment.systemPackages = [ cfg.package ] ++ profilePackages;

      assertions = [{
        assertion = cfg.dontSetupKvmfr || (lib.length cfg.interactiveUsers > 0);
        message = ''
          hypersw.programs.lookingGlassClient.interactiveUsers must list
          at least one user when dontSetupKvmfr is false (the default).
          Each listed user is added to the "kvm" group so they can open
          /dev/kvmfr*. Alternatively set dontSetupKvmfr = true if you're
          managing kvmfr externally.
        '';
      }];
    }

    # ── Hypervisor: kvmfr kernel module + udev + group ──────────────
    (lib.mkIf (!cfg.dontSetupKvmfr) {
      boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];
      boot.kernelModules = [ "kvmfr" ];
      boot.extraModprobeConfig = ''
        options kvmfr static_size_mb=${
          lib.concatStringsSep "," (map toString cfg.kvmfrSizesMb)
        }
      '';
      services.udev.extraRules = ''
        SUBSYSTEM=="kvmfr", OWNER="root", GROUP="kvm", MODE="0660"
      '';
      users.users = lib.genAttrs cfg.interactiveUsers
        (_: { extraGroups = [ "kvm" ]; });
    })

    # ── Hypervisor: libvirt cgroup_device_acl extension ─────────────
    # No append syntax in libvirt → replicate the default list verbatim
    # and append our /dev/kvmfr* entries.
    (lib.mkIf (!cfg.dontExtendLibvirtCgroupAcl) {
      virtualisation.libvirtd.qemu.verbatimConfig = ''
        cgroup_device_acl = [
          "/dev/null", "/dev/full", "/dev/zero",
          "/dev/random", "/dev/urandom",
          "/dev/ptmx", "/dev/userfaultfd",
          ${lib.concatMapStringsSep ",\n  "
              (d: ''"${d}"'') kvmfrDevices}
        ]
      '';
    })
  ]);
}
