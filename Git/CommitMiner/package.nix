# The patched git and its miner on one bin/, so the patch's default
# `mine.program` ("git-mine-commit" on PATH) resolves wherever this git runs.
#
# The two stay separate derivations underneath: rebuilding the miner does
# not rebuild git.
{ pkgs
, git ? import ./git.nix { inherit pkgs; }
, miner ? pkgs.callPackage ./Miner/package.nix { }
}:

pkgs.symlinkJoin {
  name = "git-${git.version}-with-miner";
  paths = [ git miner ];
  passthru = { inherit git miner; };
  meta = git.meta // {
    description = "git that mines commit hashes with a chosen prefix";
    mainProgram = "git";
  };
}
