#!/usr/bin/env bash
# A conflict on a file outside the sparse cone is not written to the working tree
# when that file was materialized (present, not skip-worktree) before the merge.
# Usage: GIT=/path/to/git repro.sh   (defaults to the git on PATH)
set -e
GIT=${GIT:-git}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
g() { "$GIT" -c user.name=t -c user.email=t@t -c advice.mergeConflict=false "$@"; }

g init -q -b main
mkdir -p dir
printf 'a\nb\nc\nd\ne\n' >dir/file
echo top >top
g add . && g commit -qm base

g checkout -qb topic
sed -i 's/^a$/a-topic/' dir/file && g commit -qam "topic: change a"
sed -i 's/^c$/c-topic/' dir/file && g commit -qam "topic: change c"

g checkout -q main
sed -i 's/^a$/a-main/; s/^c$/c-main/' dir/file && g commit -qam "main: change a and c"

g sparse-checkout set --cone   # top-level files only; dir/ is outside the cone
echo "before:            $(g ls-files -t dir/file), on disk: $(test -e dir/file && echo yes || echo no)"

# First conflict: dir/file is skip-worktree, and merge-ort writes the conflict out.
g cherry-pick topic~1 >/dev/null 2>&1 || true
echo "1st conflict:      $(g ls-files -t dir/file | sort -u), on disk: $(test -e dir/file && echo yes || echo no)"

# Resolve and commit; dir/file stays on disk, now without SKIP_WORKTREE.
printf 'a-main-topic\nb\nc-main\nd\ne\n' >dir/file
g add --sparse dir/file
g -c core.editor=true cherry-pick --continue >/dev/null
echo "after commit:      $(g ls-files -t dir/file), on disk: $(test -e dir/file && echo yes || echo no)"

# Second conflict on the same file: it is removed from disk, and the conflict is never written.
g cherry-pick topic >/dev/null 2>&1 || true
echo "2nd conflict:      $(g ls-files -t dir/file | sort -u), on disk: $(test -e dir/file && echo yes || echo no)"
g status --porcelain
if test -e dir/file; then echo "RESULT: ok"; else echo "RESULT: BUG, conflicted file missing from the working tree"; exit 1; fi
