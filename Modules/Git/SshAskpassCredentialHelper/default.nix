{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ssh-askpass-credential-helper;
  closefrom3 = import ../../../Util/CloseFrom3/package.nix { inherit pkgs; };
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

  config = lib.mkIf cfg.enable (let
    pkg = import ../../../Git/SshAskpassCredentialHelper/package.nix {
      inherit pkgs closefrom3;
      inherit (cfg) timeout perTokenPin;
    };
  in {
    environment.systemPackages = [ pkg ];
    programs.ssh.enableAskPassword = true;
    programs.ssh.askPassword = "${pkg}/bin/ssh-askpass-credential-helper";
    environment.sessionVariables.SSH_ASKPASS_REQUIRE = "prefer";
  });
}
