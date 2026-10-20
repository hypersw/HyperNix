# git whose merges write out a conflicted file outside the sparse cone even
# when that file was present before the merge (./README.md).
#
# A separate derivation over a given base, never an overlay over `pkgs.git`,
# so nothing else in nixpkgs rebuilds.
#
# The patch touches merge-ort.c and t/t6428; a git bump that already carries
# the fix, or moves the code, fails the build with "hunk FAILED", which is the
# cue to drop it.
{ pkgs
, base ? pkgs.git
}:

base.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./merge-ort-write-out-present-conflict.patch ];
})
