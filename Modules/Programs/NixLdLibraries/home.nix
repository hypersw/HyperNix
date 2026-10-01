{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nix-ld-libraries;

  userLibraries = pkgs.buildEnv {
    name = "nix-ld-user-libraries";
    pathsToLink = [ "/lib" ];
    paths = map lib.getLib cfg.libraries;
    ignoreCollisions = true;
  };

  systemLibraries = "/run/current-system/sw/share/nix-ld/lib";
  helper = pkgs.writeTextFile {
    name = "nix-ld-libs";
    destination = "/bin/nix-ld-libs";
    executable = true;
    text = ''
      #!/usr/bin/env bash
      if [[ "''${BASH_SOURCE[0]}" == "$0" ]]; then
        printf '%s\n' 'nix-ld-libs: this helper must be sourced, not executed.' >&2
        exit 1
      fi

      export NIX_LD_LIBRARY_PATH='${lib.concatStringsSep ":" (
        [ "${userLibraries}/lib" ]
        ++ lib.optional cfg.inheritSystemLibraries systemLibraries
      )}'
    '';
  };
in
{
  # The user half of nix-ld. The container turns the loader on
  # (`hypersw.containers.UserContainers.Guest.NixLd.Enable`, or plain
  # `programs.nix-ld.enable` elsewhere) and, in our containers, deliberately
  # no libraries at all; this decides what the binaries *this user* runs can
  # find through it.
  #
  # The split exists because a library list is a property of an application,
  # not of a machine. Enabling this module installs an on-demand helper;
  # source it in the shell or launcher that needs the selected libraries.
  options.programs.nix-ld-libraries = {
    enable = lib.mkEnableOption ''
      a user-scoped nix-ld library path. Requires nix-ld itself to be enabled
      in the system configuration; this decides what it resolves
    '';

    libraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = ''
        Libraries to put on NIX_LD_LIBRARY_PATH when the installed helper is
        sourced. Empty by default; select the packages for each user profile.
      '';
    };

    inheritSystemLibraries = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Append the system nix-ld library path after the selected libraries
        when the helper is sourced. Off by default; turn it on for a host
        whose system configuration provides libraries users should still see.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ helper ];
  };
}
