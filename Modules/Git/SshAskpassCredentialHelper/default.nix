{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ssh-askpass-credential-helper;

  closefrom3 = pkgs.stdenv.mkDerivation {
    pname = "closefrom3";
    version = "1.0.0";
    src = ../../../Util/CloseFrom3;
    buildPhase = "$CC -O2 -Wall -o closefrom3 closefrom3.c";
    installPhase = "mkdir -p $out/bin; cp closefrom3 $out/bin/";
  };

  mkScript = { timeout, perTokenPin }:
    pkgs.writeShellScriptBin "ssh-askpass-credential-helper" ''
      prompt="''${1:-}"

      case "$prompt" in
        "Enter PIN for '"*)
          ${if perTokenPin then ''
          cache_key="$prompt"
          '' else ''
          cache_key="pkcs11-pin"
          ''}
          ;;
        *)
          cache_key="$prompt"
          ;;
      esac

      cached=$(printf 'protocol=pkcs11\nhost=%s\n' "$cache_key" \
        | ${pkgs.git}/bin/git credential-cache get 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep '^password=' | cut -d= -f2-)

      if [ -n "$cached" ]; then
        echo "$cached"
        exit 0
      fi

      value=$(${pkgs.zenity}/bin/zenity --password --title="$prompt" 2>/dev/null) || exit 1
      echo "$value"

      printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$value" \
        | ${closefrom3}/bin/closefrom3 \
          ${pkgs.git}/bin/git credential-cache --timeout=${toString timeout} store \
          >/dev/null 2>/dev/null
    '';
in
{
  options.programs.ssh-askpass-credential-helper = {
    enable = lib.mkEnableOption "SSH_ASKPASS helper that caches PKCS#11 PINs via git credential-cache";

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Cache timeout in seconds";
    };

    perTokenPin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Cache PINs per token (true) or use one shared PIN for all tokens (false)";
    };
  };

  config = lib.mkIf cfg.enable (let pkg = mkScript {
    inherit (cfg) timeout perTokenPin;
  }; in {
    environment.systemPackages = [ pkg ];
    programs.ssh.enableAskPassword = true;
    programs.ssh.askPassword = "${pkg}/bin/ssh-askpass-credential-helper";
    environment.sessionVariables.SSH_ASKPASS_REQUIRE = "prefer";
  });
}
