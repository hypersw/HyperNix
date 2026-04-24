{ pkgs }:
pkgs.stdenv.mkDerivation {
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
}
