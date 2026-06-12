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

  # ── Master-branch source pin ──────────────────────────────────────
  # Default source for `master.enable = true`. Bump rev+hash to pull
  # later master fixes; reproduce the hash with:
  #   nix-prefetch-github gnif LookingGlass --rev <sha> --fetch-submodules
  # LG uses submodules (lgmp etc.), so fetchSubmodules MUST be true.
  defaultMasterSrc = pkgs.fetchFromGitHub {
    owner = "gnif";
    repo = "LookingGlass";
    rev = "4bb2c58fb6d0df9e863ad45924dd4decc7e9cf4e"; # 2026-06-09 master tip
    hash = "sha256-Dc0sFnJVM0xJ0FfIQqGQKxFUj6mhp3qgB772h3Dgowc=";
    fetchSubmodules = true;
  };

  # Master build: reuse the nixpkgs derivation (which carries all the
  # buildInputs / cmake flags), just swap the source.
  masterPackage = pkgs.looking-glass-client.overrideAttrs (old: {
    version = "git-master";
    src = cfg.master.src;
  });

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

  # Opt-in: focus-based capture flow (mstsc model). Click/tab into the
  # LG window → capture engages and keyboard grabs (via the LG default
  # `grabKeyboard=yes` which kicks in *in capture mode*). Press Scroll
  # Lock → capture exits and the keyboard ungrabs; window keeps focus
  # but the WM can see Alt+Tab again. `releaseKeysOnFocusLoss` is the
  # safety net: tabbing away with held keys (Alt+Tab itself, for one)
  # sends key-up events to the guest so nothing stays "stuck pressed."
  #
  # IMPORTANT — two LG flags we deliberately do NOT set despite the
  # user-facing option being called `enableAutoCapture`:
  #
  #   * `input:autoCapture=yes` — documented as "Try to keep the mouse
  #     captured." In practice fights any release: Scroll Lock releases
  #     capture, autoCapture immediately re-grabs as soon as the
  #     cursor re-enters the window.
  #   * `input:grabKeyboardOnFocus=yes` — documented as "Grab the
  #     keyboard when focused" (i.e., regardless of capture mode).
  #     Defeats Scroll Lock release: capture exits but the keyboard
  #     stays grabbed because the window still has focus, so Alt+Tab
  #     still goes to the guest.
  #
  # The combination kept (`captureOnFocus` + `releaseKeysOnFocusLoss`
  # + LG's default `grabKeyboard`) is the mstsc-equivalent flow.
  autoCaptureSettings = {
    input = {
      captureOnFocus = true;
      releaseKeysOnFocusLoss = true;
    };
  };

  # evdev capture: requires master client. CSV of device paths becomes
  # `input:evdev`; `evdevExclusiveOnCapture` becomes `input:evdevExclusive`.
  evdevSettings = {
    input = {
      evdev = lib.concatStringsSep "," cfg.evdevDevices;
      evdevExclusive = cfg.evdevExclusiveOnCapture;
    };
  };

  # ── Compose the final settings dictionary ─────────────────────────

  baseSettings = lib.foldl' mergeSettings {} (
    (lib.optional (!cfg.dontApplyMouseFixes) mouseFixSettings)
    ++ (lib.optional (!cfg.dontApplyLowLatencyDefaults) lowLatencySettings)
    ++ (lib.optional cfg.enableAutoCapture autoCaptureSettings)
    ++ (lib.optional (cfg.evdevDevices != []) evdevSettings)
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
      default = if cfg.master.enable then masterPackage else pkgs.looking-glass-client;
      defaultText = lib.literalExpression
        "if master.enable then (pkgs.looking-glass-client built from master.src) else pkgs.looking-glass-client";
      description = ''
        The looking-glass-client package to install. Defaults to the
        nixpkgs B7 release, or to a master-built variant when
        `master.enable = true`. Override explicitly if you need a
        patched binary that's neither (e.g. the MBRD-filter-removed
        WARP build).
      '';
    };

    master = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Build the LG client from upstream master instead of the
          nixpkgs B7 release. Needed for features added since B7 —
          notably `input:evdev` keyboard capture (forwards bare
          Super past WM grabs, since LG bypasses the X11/Wayland
          input layer entirely), Wayland fractional-scale support,
          and a handful of IDD helper improvements.

          B7 server and master client share `KVMFR_VERSION = 20` at
          the time of writing, so they pair without changes to the
          in-guest server. The version check is a strict equality
          on both sides — if upstream ever bumps `KVMFR_VERSION` in
          master (B8 prep), this option becomes incompatible until
          the guest server is upgraded too. Track with:
            curl -sS https://raw.githubusercontent.com/gnif/LookingGlass/master/common/include/common/KVMFR.h \
              | grep KVMFR_VERSION
        '';
      };

      src = lib.mkOption {
        type = lib.types.path;
        default = defaultMasterSrc;
        defaultText = lib.literalExpression ''
          pkgs.fetchFromGitHub {
            owner = "gnif"; repo = "LookingGlass";
            rev = "<pinned tip of master>";
            hash = "<pinned hash>";
            fetchSubmodules = true;
          }
        '';
        description = ''
          Source used when `master.enable = true`. Defaults to a
          pinned `fetchFromGitHub`. Override with a local path
          (e.g. `/home/work/Projects/External/LookingGlass`) while
          iterating locally, or with your own `fetchFromGitHub`
          pinning a different commit. Reproduce the hash for a new
          rev with:

            nix-prefetch-github gnif LookingGlass \
              --rev <sha> --fetch-submodules
        '';
      };
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
        Replace LG's default "manual toggle" grab model with the
        mstsc-equivalent flow: focus the LG window (click or tab to
        it) → capture engages, keyboard grabs. Press Scroll Lock →
        capture exits, keyboard ungrabs, window stays focused, the
        WM sees Alt+Tab again. Tabbing back into LG re-engages
        capture. Held keys are released cleanly on focus loss so
        nothing stays "stuck pressed" on the guest side.

        Note: deliberately does NOT enable LG's `input:autoCapture`
        or `input:grabKeyboardOnFocus` flags despite the name —
        both fight against releasing the keyboard via Scroll Lock
        (the first re-grabs the mouse aggressively; the second
        keeps the keyboard grabbed as long as the window has focus,
        regardless of capture mode). The applied set is
        `captureOnFocus=yes` + `releaseKeysOnFocusLoss=yes`, with
        the keyboard grabbed by LG's default `grabKeyboard=yes`
        which is gated on capture mode.

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
        to the `kvm` group so they can mmap `/dev/kvmfr*`, and to the
        `input` group when `evdevDevices` is non-empty so they can
        open `/dev/input/event*`.

        At least one entry is REQUIRED when `dontSetupKvmfr = false`
        (the default); the assertion fires at eval time if the list
        is empty. Leave `[]` only when kvmfr setup is being skipped.
      '';
    };

    # ── evdev keyboard/mouse capture (master only) ──────────────────

    evdevDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "/dev/input/by-id/usb-Logitech_K810-event-kbd" ];
      description = ''
        List of `/dev/input/` device paths LG should read directly via
        the kernel evdev interface, bypassing the X11/Wayland keyboard
        path entirely. Becomes the comma-joined `input:evdev=...`
        setting in the generated .ini. There is no auto-discovery; if
        you want multiple keyboards or a mouse covered, list each path
        explicitly. Use the stable `/dev/input/by-id/...` names —
        `/dev/input/eventN` numbers shuffle on hotplug.

        Purpose: the bare Super key isn't deliverable through standard
        X11/Wayland grabs on most Linux compositors (Mutter, KWin and
        friends reserve it for overlay/launcher actions above the
        application's keyboard grab). Reading evdev raw bypasses that
        entirely — the WM never sees the keys at all while LG holds
        them. See `evdevExclusiveOnCapture` for the strict-grab toggle.

        REQUIRES the master client build (`master.enable = true`); the
        B7 release doesn't include the evdev backend. When this list
        is non-empty, `interactiveUsers` are automatically added to
        the `input` group.

        Setting empty (default) keeps LG on the standard keyboard
        path. No partial behavior — there's no "evdev for all
        keyboards" mode upstream.
      '';
    };

    evdevExclusiveOnCapture = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        While in capture mode, take EVIOCGRAB-exclusive ownership of
        each device in `evdevDevices` — the keyboard/mouse stops
        emitting any events to the host (no Super to the WM, no
        Ctrl+C anywhere local) until capture is released. That's the
        point: it's what makes bare Super reach the guest reliably.

        Set to false to keep events shared between host and guest
        (LG reads evdev but doesn't grab — the WM still sees the same
        events). Useful only as a diagnostic; capture-mode exclusivity
        is the intended mode of operation.

        No effect when `evdevDevices = []`.
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
        patchServerForWarp = ./Template/Patch-LookingGlassServer.ps1;
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
          - `patchServerForWarp`: idempotent PowerShell binary
            patcher that disables LG server's hardcoded refusal of
            the "Microsoft Basic Render Driver" (WARP) adapter.
            Needed only on guests with no real or passed-through
            GPU; the standard kvmfr+passthrough path doesn't need it.
            See SETUP.md "WARP-only guests" for usage.
        See SETUP.md in this module's directory for the full guest
        setup walkthrough.
      '';
    };

  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Client install + machine-wide .ini + profile wrappers ───────
    {
      environment.etc."looking-glass-client.ini".text = iniText;
      environment.systemPackages = [ cfg.package ] ++ profilePackages;

      assertions = [
        {
          assertion = cfg.dontSetupKvmfr || (lib.length cfg.interactiveUsers > 0);
          message = ''
            hypersw.programs.lookingGlassClient.interactiveUsers must list
            at least one user when dontSetupKvmfr is false (the default).
            Each listed user is added to the "kvm" group so they can open
            /dev/kvmfr*. Alternatively set dontSetupKvmfr = true if you're
            managing kvmfr externally.
          '';
        }
        {
          assertion = cfg.evdevDevices == [] || (lib.length cfg.interactiveUsers > 0);
          message = ''
            hypersw.programs.lookingGlassClient.evdevDevices is set, but
            interactiveUsers is empty. Each listed user is added to the
            "input" group so they can open /dev/input/event*. Add the
            user who will run looking-glass-client to interactiveUsers,
            or clear evdevDevices.
          '';
        }
      ];
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

    # ── Hypervisor: input group when evdev capture is enabled ───────
    (lib.mkIf (cfg.evdevDevices != []) {
      users.users = lib.genAttrs cfg.interactiveUsers
        (_: { extraGroups = [ "input" ]; });
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
