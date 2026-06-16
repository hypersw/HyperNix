#
# Remmina with Looking-Glass / mstsc-style keyboard capture.
#
# THE PROBLEM (see also Programs/LookingGlassClient for the LG side of
# the exact same UX). Stock Remmina has a "Grab all keyboard events"
# option, and the host key (default Right Ctrl) tapped alone toggles it.
# But that toggle is *modal and hidden*:
#
#   * The grab key flips the PERSISTENT per-profile `keyboard_grab`
#     flag (rcw.c: rcw_toolbar_grab -> remmina_file_set_int). Once you
#     tap it to break out, focus-in no longer re-grabs — you are in an
#     "ungrabbed" mode that survives focus changes.
#   * There is no "capture now" key, only a toggle, and in fullscreen
#     with the toolbar hidden there is no reliable indication of which
#     state you are in. You tab back into the VM and silently either
#     have or don't have the keyboard — a classic hidden-modality trap.
#
# Looking Glass solves this with `captureOnFocus=yes` (focus the window
# -> captured) + a single modeless escape (Scroll Lock) that releases
# *transiently* while the persistent intent stays "capture". Focus the
# window again -> captured again. Capture state == focus state, so it is
# never hidden.
#
# WHAT THIS MODULE DOES. It ships a patched `remmina` (Modules/Programs/
# RemminaAutograb/autograb.patch, against the rcw.c connection-window
# code) that turns the grab shortcut into that Looking-Glass model:
#
#   1. The grab/escape key (host key tapped alone, or whatever
#      `shortcutkey_grab` is set to) becomes a TRANSIENT toggle:
#      grab/ungrab *now* without touching the persistent per-profile
#      `keyboard_grab` flag.
#   2. A transient `autograb_suppressed` flag + `autograb_escape_time`
#      (monotonic) gate re-grab. THE PROBLEM on Wayland: gdk_seat_ungrab()
#      drives a real focus-loss/focus-gain churn that reaches even the WM
#      `window-state-event`, so focus events cannot distinguish "the user
#      genuinely came back" from "we just released." There is no clean
#      focus event to key off — only timing separates them.
#   3. So rcw_keyboard_grab (the single grab chokepoint) blocks grabs that
#      arrive within a GRACE WINDOW (500 ms) after the escape — that is
#      the churn. A grab attempt AFTER the grace window means the user
#      genuinely returned (Alt+Tab back / pointer re-entry), so it resumes
#      autograb automatically. Capture follows focus again, just debounced
#      past the self-inflicted churn.
#   4. deliberate re-grab is immediate, ignoring the grace window: typing
#      a non-modifier key into the session, or re-tapping the grab key.
#      Bare modifiers are skipped so the Alt of an Alt+Tab used to leave
#      can't re-grab. (Mouse-CLICK is not a separate trigger — the RDP
#      plugin's drawing area consumes button events with no
#      connection-window hook — but returning the pointer into the window
#      re-grabs via the grace path, so clicking-back effectively does.)
#   5. visible cue: on escape the auto-hidden floating toolbar is
#      revealed, the way mstsc drops its connection bar when capture is
#      released; it hides again on re-grab — including the grace-path
#      auto-regrab on return (rcw_keyboard_grab), not just the deliberate
#      key/grab-key paths. Addresses "in fullscreen you can't tell whether
#      you're captured."
#   6. Ctrl+Alt+Home is a hardcoded extra "release" chord, in addition to
#      the configured grab key (shared muscle memory). Matched against the
#      live modifier state (the hostkey dispatch is keyval-only and strips
#      modifiers). Unlike the grab key, it FORWARDS Home to the guest
#      rather than consuming it: while grabbed, the Ctrl+Alt were already
#      sent to the guest, and releasing them with Alt last/alone activates
#      the Windows menu bar — letting Home reach the guest puts a
#      non-modifier into the Alt hold and breaks that pattern. (Side
#      effect: the guest app sees Ctrl+Alt+Home, usually harmless; for a
#      fully silent escape use the grab key, which is a single non-Alt key
#      and is never forwarded.)
#
# Stuck-key safety is already upstream and untouched: focus-out fires
# REMMINA_PROTOCOL_FEATURE_TYPE_UNFOCUS -> remmina_rdp_event_unfocus ->
# remmina_rdp_event_release_all_keys, which sends key-up for every held
# key to the guest. That is why running WITH grab (this module) is the
# fix for the "keys misfire after I return" you get when running
# WITHOUT grab: without a grab the host WM eats Alt+Tab/Super key-downs
# and the guest never sees the matching key-up.
#
# STILL REQUIRED, ONCE, PER PROFILE: enable "Grab all keyboard events"
# on each connection profile you want auto-captured (it sets
# `keyboard_grab=1` in the .remmina file). This module changes how that
# flag behaves; it does not turn it on for you — unless you set
# `grabByDefault = true` below, which flips the COMPILED default so
# every profile that hasn't explicitly disabled grab auto-captures.
#
# WAYLAND NOTE: on this machine the grab works correctly under a native
# Wayland session and FAILS under XWayland (the opposite of the usual
# advice). Run Remmina as a native Wayland app here.
#
# The escape key itself is unchanged (upstream default Right Ctrl). To
# mirror LG's Scroll Lock, set BOTH "Host key" and the "Grab keyboard"
# shortcut to Scroll Lock in Remmina > Preferences > Keyboard. Those
# live in ~/.config/remmina/remmina.pref (per-user), so they are not
# managed here.
#

{ config, lib, pkgs, ... }:

let
  cfg = config.hypersw.programs.remminaAutograb;

  # Single source of truth for the patched derivation — same file the
  # flake's packages.<system>.Modules-Programs-RemminaAutograb output
  # imports, so `nix run` and the installed package are identical.
  autograbPackage = import ./package.nix {
    inherit pkgs;
    base = cfg.basePackage;
    inherit (cfg) grabByDefault;
  };

in {

  options.hypersw.programs.remminaAutograb = {

    enable = lib.mkEnableOption
      "Remmina patched with Looking-Glass-style focus-driven keyboard capture";

    basePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.remmina;
      defaultText = lib.literalExpression "pkgs.remmina";
      description = ''
        The stock Remmina derivation to patch. Defaults to
        `pkgs.remmina` — i.e. whatever the channel ships; the version is
        deliberately NOT pinned. The lines autograb.patch touches in
        `src/rcw.c` (the priv-struct flag, the two grab helpers, the
        focus-out reset, and the `shortcutkey_grab && !extrahardening`
        branch in rcw_hostkey_func) have been byte-stable across the
        whole 1.4.30..1.4.43 series (the diff hunks are identical between
        1.4.41 and 1.4.43, only their line offsets move, which `patch`
        absorbs). The toolbar-grab toggle body and the struct field go
        back to the rcw.c rename (~1.4.0). The only thing expected to
        move this code is the eventual GTK4 / Remmina 2.0 rewrite — at
        which point the build fails loudly ("hunk FAILED") and the patch
        gets refreshed. So no version pin is needed; override this only
        to patch a non-channel Remmina build.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = autograbPackage;
      defaultText = lib.literalExpression
        "basePackage.overrideAttrs (patched with autograb.patch)";
      readOnly = true;
      description = ''
        The patched Remmina package this module installs. Read-only;
        set `basePackage` / `grabByDefault` to influence it.
      '';
    };

    grabByDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Flip Remmina's COMPILED default so "Grab all keyboard events" is
        ON for every connection profile that has not explicitly set it,
        instead of OFF. With the autograb patch this means: focus any
        connection window -> captured, no per-profile checkbox needed.

        Default `false` because the flag is global across protocols, and
        grabbing the keyboard for an SSH/SFTP terminal session is rarely
        what you want. Leave it off and enable "Grab all keyboard
        events" per RDP/VNC profile (one-time), or turn it on if you
        want capture-on-focus to be the blanket default and will disable
        grab on the odd profile that shouldn't have it.

        Profiles that explicitly DISABLED grab are unaffected either way
        (only the absent-key default changes).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
