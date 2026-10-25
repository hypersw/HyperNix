#!/usr/bin/env bash
# Runs the IDE from the flake in this script's own folder, from any working directory; arguments go to the IDE.
# `path:` takes the folder as a plain directory, where a bare path would make Nix look for a parent git repo and miss the untracked tarball.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
exec nix run "path:$here" -- "$@"
