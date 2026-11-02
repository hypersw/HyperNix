{
  description = "A JetBrains IDE built from the newest *.tar.gz next to this flake.nix";

  # Put this file in a folder with JetBrains Linux tarballs of one product, then `nix run path:.`; the highest version wins.
  # Nix copies the whole folder into the store on every change, so delete old tarballs once they are no longer needed.
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
      # Highest version first: builtins.compareVersions orders build numbers such as 271.999 before 271.1325.
      tarballs = lib.sort (a: b: builtins.compareVersions a b > 0) (
        lib.filter (lib.hasSuffix ".tar.gz") (lib.attrNames (builtins.readDir ./.))
      );
      tarball =
        if tarballs != [ ] then
          # A string carrying the flake source's context, so the tarball is not copied into the store a second time.
          "${self}/${lib.head tarballs}"
        else
          throw "Expected a *.tar.gz next to flake.nix";
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
