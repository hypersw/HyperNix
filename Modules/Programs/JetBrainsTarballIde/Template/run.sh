#!/usr/bin/env bash
# Builds the IDE from the flake in this script's own folder and starts it detached, from any working directory; arguments go to the IDE.
# `path:` takes the folder as a plain directory, where a bare path would make Nix look for a parent git repo and miss the untracked tarball.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
name=$(basename "$here")

# The build stays in the terminal, so its progress and errors are seen.
# No GC root: a garbage collection spares the running IDE anyway, and otherwise only costs one rebuild.
# A result link inside the folder would be worse still: it changes the flake's source and so forces a rebuild on every run.
out=$(nix build "path:$here" --print-out-paths --no-link)

# The one launcher in bin/, beside the remote-dev-server wrapper.
for exe in "$out"/bin/*; do
  [[ $exe == *-remote-dev-server ]] && continue
  logs="${XDG_STATE_HOME:-$HOME/.local/state}/jetbrains-tarball-ide"
  mkdir -p "$logs"
  echo "run.sh: started $exe, launcher output in $logs/$name.log" >&2
  # setsid -f: a new session with no controlling terminal, outside the shell's job control.
  # So the IDE and everything it spawns can neither stall on terminal reads nor die with the terminal.
  setsid -f "$exe" "$@" </dev/null >"$logs/$name.log" 2>&1
  exit 0
done
echo "run.sh: no launcher in $out/bin" >&2
exit 1
