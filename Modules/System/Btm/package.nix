# Derivation builder for the bottom strict-overcommit fork.
#
# Given an `pkgs` set (and optionally a custom `src`), produces a
# `pkgs.bottom`-equivalent derivation with the fork's source. Used by
# both the NixOS module (`default.nix`, with `src = cfg.fork.src`) and
# the flake's packages output (no override → uses the pinned source).
#
# The fork shares `Cargo.lock` with upstream 0.12.3, so nixpkgs's
# cargoHash continues to validate without override. If a future fork
# rebase touches Cargo.lock, set `cargoHash = lib.fakeHash;` here, run
# `nix build` once, and paste the printed hash.
{ pkgs
, src ? pkgs.fetchFromGitHub (import ./source.nix)
}:
pkgs.bottom.overrideAttrs (_old: {
  # NB: don't change `version` here — nixpkgs's bottom uses
  # `versionCheckHook`, which runs `$out/bin/btm --version` and greps
  # for the derivation's `version` attribute. The binary's compiled
  # version string comes from `CARGO_PKG_VERSION` in the fork's
  # unchanged Cargo.toml (= upstream "0.12.3"), so any suffix here
  # would fail the check. Two derivations with the same human name
  # but different src produce different store-path hashes, so the
  # fork is still distinct from upstream pkgs.bottom — just not
  # labeled differently in the store path.
  src = src;
})
