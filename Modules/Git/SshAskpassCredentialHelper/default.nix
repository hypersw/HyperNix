{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ssh-askpass-credential-helper;

  flakeName = import ../../../flake-name.nix;
  envPrefix = "${lib.toUpper flakeName}_SSH_ASKPASS";

  closefrom3 = import ../../../Util/CloseFrom3/package.nix { inherit pkgs; };
  core = import ../../../Git/SshAskpassCredentialHelper/package.nix {
    inherit pkgs closefrom3;
  };

  # Wrap the core binary with config baked in as scoped env vars. `--set`
  # only sets them for the wrapped exec — never leaks to the parent shell,
  # never visible to sibling processes — and the names are namespaced by
  # flake-name.nix so they can't collide with anyone else's askpass work.
  wrapped = pkgs.runCommand "ssh-askpass-credential-helper" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } ''
    makeWrapper ${core}/bin/ssh-askpass-credential-helper \
      $out/bin/ssh-askpass-credential-helper \
      --set ${envPrefix}_TIMEOUT       "${toString cfg.timeout}" \
      --set ${envPrefix}_PER_TOKEN_PIN "${if cfg.perTokenPin then "1" else ""}"
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

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ wrapped ];
    programs.ssh.enableAskPassword = true;
    programs.ssh.askPassword = "${wrapped}/bin/ssh-askpass-credential-helper";
    environment.sessionVariables.SSH_ASKPASS_REQUIRE = "prefer";
  };
}
