#!/usr/bin/env bash
# bump.sh — refresh the GitHub pin for `programs.btm.fork.src`.
#
# Resolves the current tip of `f/strict-overcommit-mode` on
# github.com/hypersw/bottom (or a user-specified rev), prefetches its
# tarball, and patches the rev/sha256 in default.nix in place.
#
# Usage:
#   ./bump.sh           # pin to the branch tip on GitHub
#   ./bump.sh <REV>     # pin to a specific 40-char SHA
#
# Run after pushing new commits to the fork. Then `git diff` on the
# module will show the rev/sha256 churn — commit it with a message
# like "btm: bump fork pin to <short-sha>".

set -euo pipefail

OWNER=hypersw
REPO=bottom
BRANCH=f/strict-overcommit-mode
MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
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

echo "→ rev:    $REV"

# nix-prefetch-url --unpack returns the NAR hash of the unpacked
# tarball, which is exactly what fetchzip / fetchFromGitHub want
# in `sha256`.
SHA=$(nix-prefetch-url --unpack --type sha256 \
      "https://github.com/${OWNER}/${REPO}/archive/${REV}.tar.gz" 2>/dev/null)
if [ -z "$SHA" ]; then
  echo "nix-prefetch-url failed" >&2
  exit 1
fi

echo "→ sha256: $SHA"

# Defensive: there should be exactly one rev/sha256 pair in the
# module. If there are none or several, something has been
# refactored and the simple sed below would silently miss or
# clobber. Bail rather than guess.
rev_count=$(grep -c '^[[:space:]]*rev = "[0-9a-f]\{40\}";' "$SOURCE" || true)
sha_count=$(grep -c '^[[:space:]]*sha256 = "[0-9a-z]\+";'  "$SOURCE" || true)
if [ "$rev_count" != "1" ] || [ "$sha_count" != "1" ]; then
  echo "expected 1 rev + 1 sha256 line in $MODULE; got $rev_count + $sha_count" >&2
  echo "(source.nix layout probably changed; update bump.sh accordingly)" >&2
  exit 1
fi

# Anchor on leading whitespace so we don't match an unrelated
# rev/sha256 elsewhere if more get added later.
sed -i \
  -e "s|^\([[:space:]]*\)rev = \"[0-9a-f]\{40\}\";|\1rev = \"${REV}\";|" \
  -e "s|^\([[:space:]]*\)sha256 = \"[0-9a-z]\+\";|\1sha256 = \"${SHA}\";|" \
  "$SOURCE"

# Sanity-check the replacement actually happened.
if ! grep -q "\"${REV}\"" "$SOURCE"; then
  echo "rev replacement failed; source.nix is in an unknown state" >&2
  exit 1
fi
if ! grep -q "\"${SHA}\"" "$SOURCE"; then
  echo "sha256 replacement failed; source.nix is in an unknown state" >&2
  exit 1
fi

echo "→ patched $SOURCE"
echo
git -C "$MODULE_DIR" --no-pager diff -- "$SOURCE" || true
