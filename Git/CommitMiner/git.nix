# git with commit mining: ./git-mine.patch makes every commit-creating path
# (commit, commit-tree, merge, am, rebase/cherry-pick/revert) append a
# fixed-width `nonce` header and ask an external miner for its value, so the
# object name starts with `mine.prefix`. Inert unless `mine.prefix` is set.
# See ./README.md.
#
# Deliberately a separate derivation, never an overlay over `pkgs.git`: half
# of nixpkgs depends on git, and replacing it would rebuild all of that.
#
# The patch touches only commit.c, whose commit_tree_extended() has been
# stable for years; a git bump that moves it fails the build with "hunk
# FAILED" instead of silently losing the feature.
{ pkgs
, base ? pkgs.git
  # git's own suite takes long and never exercises mining (it is off by
  # default, so hashes in the suite are unaffected); opt in when bumping git.
, runGitTests ? false
}:

base.overrideAttrs (old: {
  version = "${old.version}-mine";
  __intentionallyOverridingVersion = true;

  patches = (old.patches or [ ]) ++ [ ./git-mine.patch ];

  doInstallCheck = runGitTests && (old.doInstallCheck or false);
})
