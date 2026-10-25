{
  description = "A JetBrains IDE built from the single *.tar.gz next to this flake.nix";

  # Put this file in a folder with exactly one JetBrains Linux tarball, then `nix run path:.`.
  # `path:` matters inside a git repo, where a git flake would not see an untracked tarball.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Only the builder file is needed, so HyperNix's own inputs are never fetched.
    hypernix = {
      url = "github:hypersw/HyperNix";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, hypernix }:
    let
      inherit (nixpkgs) lib;
      tarballs = lib.filter (lib.hasSuffix ".tar.gz") (lib.attrNames (builtins.readDir ./.));
      tarball =
        if lib.length tarballs == 1 then
          # A string carrying the flake source's context, so the tarball is not copied into the store a second time.
          "${self}/${lib.head tarballs}"
        else
          throw "Expected exactly one *.tar.gz next to flake.nix, found ${toString (lib.length tarballs)}: ${toString tarballs}";
    in
    {
      packages = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        default = import "${hypernix}/Modules/Programs/JetBrainsTarballIde/package.nix" {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          src = tarball;
        };
      });
    };
}
