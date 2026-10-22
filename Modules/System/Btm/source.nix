# Pinned source for the bottom strict-overcommit fork.
#
# Single source of truth for everything the fork build takes from outside HyperNix — consumed by:
#   * package.nix              (the derivation builder)
#   * default.nix              (NixOS module's fork.src default)
#   * flake.nix                (packages.<system>.Modules-System-Btm-Fork, via package.nix)
#
# Bump with ./bump.sh, which rewrites rev, sha256, version and cargoHash in place.
# The four values only make sense together, so never edit one of them by hand.
{
  # `CARGO_PKG_VERSION` at `src.rev`, which is what `btm --version` prints.
  version = "0.14.9";

  # `fetchFromGitHub` arguments.
  src = {
    owner = "hypersw";
    repo = "bottom";
    rev = "ba171c8e728f0a24dc7b3e3889097f02ab6da070";
    sha256 = "0dfwxhzrq4kwx389dflr0zqap4ym4953rd9fxmvbj3fdncj2004y";
  };

  # Hash of the crates vendored from the Cargo.lock at `src.rev`.
  cargoHash = "sha256-uCbVCJUDmcIzsWfc1pRQ5tLM99yW+TVprKTMBLopnow=";
}
