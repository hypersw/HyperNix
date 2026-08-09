{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  managedUserServiceStopTimeout = "1min";
  managedSystemServiceStopTimeout = "2min";
in
{
  config = lib.mkIf cfg.Enable {
    # Shutdown deadlines deliberately expand outwards. A managed user service
    # gets at most one minute by default, guest PID 1 allows two minutes for
    # its system services, and HostSide gives the nspawn container unit three
    # minutes. Individual latency-sensitive user services may set a shorter
    # TimeoutStopSec, as the isolated KDE RDP profile does.
    systemd = {
      settings.Manager.DefaultTimeoutStopSec = managedSystemServiceStopTimeout;
      user.settings.Manager.DefaultTimeoutStopSec = managedUserServiceStopTimeout;
    };

    environment = {
      systemPackages = [
        pkgs.htop
        pkgs.far2l
      ];

      sessionVariables = {
        NIX_CONFIG = "experimental-features = nix-command flakes";
        NIXPKGS_ALLOW_UNFREE = "1";
      };

      variables = {
        EDITOR = "far2ledit";
        VISUAL = "far2ledit";
      };

      interactiveShellInit = ''
        bind "set completion-ignore-case on"

        command_not_found_handle() {
          if [[ $- == *i* ]]; then
            ${pkgs.comma}/bin/, "$@"
            return $?
          else
            echo "$1: command not found" >&2
            return 127
          fi
        }
      '';
    };

    nix = {
      settings.experimental-features = [ "nix-command" "flakes" ];
      # TODO: once this module is passed flake inputs through specialArgs, set
      # nix.registry and nix.nixPath here so shells/home-manager/agents all see
      # the same pinned nixpkgs instead of channels.
    };

    nixpkgs.config.allowUnfree = true;
    system.stateVersion = lib.mkIf (cfg.StateVersion != null) cfg.StateVersion;

    users.users = lib.mkIf (cfg.User != null) {
      "${cfg.User}" = {
        isNormalUser = true;
        description = cfg.User;
        uid = lib.mkIf (cfg.UserUid != null) cfg.UserUid;
      };
    };
  };
}
