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
  version = "0.12.3";

  # `fetchFromGitHub` arguments.
  src = {
    owner = "hypersw";
    repo = "bottom";
    rev = "4545166a013a12c13317cce3b9468a6944fc191c";
    sha256 = "1n0q9r52gfs90h3whag3ywda6pky1imyviax8lyivhdj6whlf9qd";
  };

  # Hash of the crates vendored from the Cargo.lock at `src.rev`.
  cargoHash = "sha256-miSMcqy4OFZFhAs9M+zdv4OzYgFxN2/uBo6V/kJql90=";
}
