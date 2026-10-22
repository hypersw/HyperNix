#!/usr/bin/env bash
# bump.sh — refresh the GitHub pin for `programs.btm.fork.src`.
#
# Resolves the current tip of `f/strict-overcommit-mode` on github.com/hypersw/bottom (or a user-specified rev).
# It prefetches that tarball and rewrites all four values in source.nix in place:
# rev, sha256, version (from the fork's Cargo.toml) and cargoHash (from the fork's Cargo.lock).
#
# Usage:
#   ./bump.sh           # pin to the branch tip on GitHub
#   ./bump.sh <REV>     # pin to a specific 40-char SHA
#
# Run after pushing new commits to the fork. Then `git diff` on the
# module will show the pin churn — commit it with a message
# like "btm: bump fork pin to <short-sha>".

set -euo pipefail

OWNER=hypersw
REPO=bottom
BRANCH=f/strict-overcommit-mode
MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
SOURCE="$MODULE_DIR/source.nix"

if [ "$#" -gt 1 ]; then
  echo "usage: $(basename "$0") [<rev>]" >&2
  exit 1
fi

REV="${1:-}"

if [ -z "$REV" ]; then
  REV=$(git ls-remote "https://github.com/${OWNER}/${REPO}.git" \
        "refs/heads/${BRANCH}" | cut -f1)
  if [ -z "$REV" ]; then
    echo "could not resolve ${BRANCH} on github.com/${OWNER}/${REPO}" >&2
    exit 1
  fi
fi

# Must be a full 40-char SHA1 — fetchFromGitHub doesn't accept short
# revs and we don't want to silently lock to whatever a short rev
# happens to resolve to today.
if ! [[ "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "rev '$REV' is not a 40-char SHA1" >&2
  echo "(use 'git rev-parse <short>' to expand)" >&2
  exit 1
fi

echo "→ rev:       $REV"

# nix-prefetch-url --unpack returns the NAR hash of the unpacked
# tarball, which is exactly what fetchzip / fetchFromGitHub want
# in `sha256`.
# --print-path adds the unpacked store path as a second line, which the version lookup below reads.
PREFETCH=$(nix-prefetch-url --unpack --print-path --type sha256 \
      "https://github.com/${OWNER}/${REPO}/archive/${REV}.tar.gz" 2>/dev/null) || true
SHA=$(sed -n 1p <<<"$PREFETCH")
SRC_PATH=$(sed -n 2p <<<"$PREFETCH")
if [ -z "$SHA" ] || [ ! -f "$SRC_PATH/Cargo.toml" ]; then
  echo "nix-prefetch-url failed" >&2
  exit 1
fi

echo "→ sha256:    $SHA"

# The first `version =` line of Cargo.toml is the [package] one.
# `btm --version` prints it, and package.nix's install check greps for it.
VERSION=$(grep -m1 '^version = "' "$SRC_PATH/Cargo.toml" | cut -d'"' -f2)
if [ -z "$VERSION" ]; then
  echo "no package version in $SRC_PATH/Cargo.toml" >&2
  exit 1
fi

echo "→ version:   $VERSION"

# Defensive: there should be exactly one line of each pinned value in
# source.nix. If there are none or several, something has been
# refactored and the simple sed below would silently miss or
# clobber. Bail rather than guess.
count() { grep -c "$1" "$SOURCE" || true; }
rev_count=$(count '^[[:space:]]*rev = "[0-9a-f]\{40\}";')
sha_count=$(count '^[[:space:]]*sha256 = "[0-9a-z]\+";')
version_count=$(count '^[[:space:]]*version = "[^"]*";')
cargo_count=$(count '^[[:space:]]*cargoHash = "sha256-[A-Za-z0-9+/=]\+";')
if [ "$rev_count$sha_count$version_count$cargo_count" != "1111" ]; then
  echo "expected 1 rev + 1 sha256 + 1 version + 1 cargoHash line in $SOURCE;" \
       "got $rev_count + $sha_count + $version_count + $cargo_count" >&2
  echo "(source.nix layout probably changed; update bump.sh accordingly)" >&2
  exit 1
fi

# Anchor on leading whitespace so we don't match an unrelated
# rev/sha256 elsewhere if more get added later.
sed -i \
  -e "s|^\([[:space:]]*\)rev = \"[0-9a-f]\{40\}\";|\1rev = \"${REV}\";|" \
  -e "s|^\([[:space:]]*\)sha256 = \"[0-9a-z]\+\";|\1sha256 = \"${SHA}\";|" \
  -e "s|^\([[:space:]]*\)version = \"[^\"]*\";|\1version = \"${VERSION}\";|" \
  "$SOURCE"

# The vendored crates are a fixed-output derivation, so their hash comes from a build that fails on purpose.
# package.nix is built with a fake cargoHash against the source.nix just rewritten above.
# The `got:` line of the hash mismatch is the real value.
# nixpkgs is the one HyperNix's flake.lock pins, so the vendoring code matches what the flake builds with.
EXPR="
let
  lock = builtins.fromJSON (builtins.readFile \"$REPO_ROOT/flake.lock\");
  pkgs = import (builtins.fetchTree lock.nodes.\${lock.nodes.root.inputs.nixpkgs}.locked) { };
in
(import \"$MODULE_DIR/package.nix\" { inherit pkgs; cargoHash = pkgs.lib.fakeHash; }).cargoDeps
"
CARGO_HASH=$(nix build --no-link --impure --expr "$EXPR" 2>&1 \
  | sed -n 's|^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\)[[:space:]]*$|\1|p' \
  | head -n1) || true
if [ -z "$CARGO_HASH" ]; then
  echo "could not compute cargoHash; source.nix has the new rev but the old cargoHash" >&2
  exit 1
fi

echo "→ cargoHash: $CARGO_HASH"

sed -i \
  -e "s|^\([[:space:]]*\)cargoHash = \"sha256-[A-Za-z0-9+/=]\+\";|\1cargoHash = \"${CARGO_HASH}\";|" \
  "$SOURCE"

# Sanity-check the replacements actually happened.
for value in "$REV" "$SHA" "$VERSION" "$CARGO_HASH"; do
  if ! grep -qF "\"${value}\"" "$SOURCE"; then
    echo "replacement of '$value' failed; source.nix is in an unknown state" >&2
    exit 1
  fi
done

echo "→ patched $SOURCE"
echo
git -C "$MODULE_DIR" --no-pager diff -- "$SOURCE" || true
