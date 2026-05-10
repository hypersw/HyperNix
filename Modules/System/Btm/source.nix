# Pinned source for the bottom strict-overcommit fork.
#
# Single source of truth — consumed by:
#   * package.nix              (the derivation builder)
#   * default.nix              (NixOS module's fork.src default)
#   * flake.nix                (packages.<system>.Modules-System-Btm-Fork)
#
# Bump with ./bump.sh, which sed-updates rev/sha256 in place.
{
  owner = "hypersw";
  repo = "bottom";
  rev = "4545166a013a12c13317cce3b9468a6944fc191c";
  sha256 = "1n0q9r52gfs90h3whag3ywda6pky1imyviax8lyivhdj6whlf9qd";
}
