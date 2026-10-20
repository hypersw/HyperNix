# SparseConflictFix — conflicts outside the sparse cone reach the disk

In a sparse checkout, a merge, cherry-pick or rebase that conflicts on a file
outside the sparse patterns must still write that file, with its conflict
markers, to the working tree. Git's sparse-checkout design doc says so, and
merge-ort has a special case for it.

That special case misses a file which is already present before the merge,
i.e. tracked, on disk, and without `SKIP_WORKTREE`. The usual way to get
there: two commits picked in a row conflict on the same out-of-cone file.
Resolving the first conflict leaves the file present, and the second conflict
then stays in the index only (`UU` in `git status`, no file on disk).

## Cause

`checkout()` in merge-ort runs `unpack_trees()`, which turns the present path
into `SKIP_WORKTREE`, sets `CE_WT_REMOVE` and deletes the file.
`record_conflicted_index_entries()` then calls `checkout_entry()` for the path
because it is `SKIP_WORKTREE`, but `checkout_entry()` obeys the stale
`CE_WT_REMOVE` and deletes the file again instead of writing it.

The patch clears `CE_WT_REMOVE` right before that `checkout_entry()` call and
adds a test to `t/t6428-merge-conflicts-sparse.sh`.

## Status

- Seen on git 2.55.0, 2.56.0 and on master at v2.56.0-186 (2026-10-16).
- The patch is against that master and applies to 2.55.0 and 2.56.0 as well.
- Not reported upstream yet as of 2026-10-19.
- Workaround without the patch: `git sparse-checkout reapply` after resolving
  each conflict, before the next merge.

## Testing it end to end

The package is for trying the fix on real repositories; nothing installs it.
Build it and point the reproduction, or any git command, at its binary:

```sh
out=$(nix-build --no-out-link -E 'import ./git.nix { pkgs = import <nixpkgs> { }; }')
GIT=$out/bin/git ./repro.sh      # RESULT: ok; with a stock git: RESULT: BUG
```

`base` takes any git derivation, e.g. `pkgs.gitFull`, to test with its extras.
