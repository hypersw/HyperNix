# Patched Remmina: Looking-Glass / mstsc-style focus-driven keyboard
# capture. This is the single source of truth for the derivation, shared
# by two consumers so they are byte-identical:
#   * the NixOS module ./default.nix (installs it into systemPackages)
#   * the flake output packages.<system>.Modules-Programs-RemminaAutograb
#     (so you can `nix run` it directly without writing an overrideAttrs)
#
# See ./default.nix for the full behavioural writeup and ./autograb.patch
# for the rcw.c change. The patch targets code that is byte-stable across
# the 1.4.30..1.4.43 series, so `base` is whatever the caller's nixpkgs
# ships (deliberately unpinned); a future GTK4 / Remmina 2.0 rewrite
# fails the build loudly ("hunk FAILED") instead of silently dropping the
# behaviour.

{ pkgs
, base ? pkgs.remmina
, grabByDefault ? false
}:

let
  lib = pkgs.lib;
in
base.overrideAttrs (old: {
  # Keep pname/sources untouched; just tag the version so the store path
  # is identifiable as the patched build. Changing version without src is
  # intentional, so opt out of nixpkgs' warning.
  version = "${old.version}-autograb";
  __intentionallyOverridingVersion = true;

  patches = (old.patches or []) ++ [ ./autograb.patch ];

  # grabByDefault flips the COMPILED default of the per-profile
  # "keyboard_grab" flag from off to on — but only the absent-key default;
  # profiles that explicitly disabled grab keep their value. The read
  # sites all share the identical text below; we deliberately leave the
  # set_int(...) calls alone. --replace-fail turns a future Remmina bump
  # that moves this code into a loud build failure rather than a silent
  # no-op.
  postPatch = (old.postPatch or "")
    + lib.optionalString grabByDefault ''
      substituteInPlace src/rcw.c \
        --replace-fail 'remmina_file_get_int(cnnobj->remmina_file, "keyboard_grab", FALSE)' \
                       'remmina_file_get_int(cnnobj->remmina_file, "keyboard_grab", TRUE)'
    '';
})
