{
  description = "Close all file descriptors >= 3, then exec — prevents fd leaks to child daemons";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "closefrom3";
            version = "1.0.0";
            src = ./.;
            buildPhase = ''
              $CC -O2 -Wall -o closefrom3 closefrom3.c
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp closefrom3 $out/bin/
            '';
            meta = {
              description = "Close all fds >= 3 then exec — prevents fd inheritance to child daemons";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.linux;
            };
          };
        });
    };
}
