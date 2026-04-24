{ pkgs }:
let
  # Wrap oauth2c with xdg-utils so it can open a browser
  # (nixpkgs doesn't include this yet)
  oauth2c-wrapped = pkgs.symlinkJoin {
    name = "oauth2c-wrapped";
    paths = [ pkgs.oauth2c ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/oauth2c \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.xdg-utils ]}
    '';
  };
in
pkgs.writeShellApplication {
  name = "space-git-credential";
  excludeShellChecks = [ "SC1091" ];
  runtimeInputs = [ oauth2c-wrapped pkgs.jq pkgs.curl pkgs.coreutils ];
  text = builtins.readFile ./space-git-credential.sh;
}
