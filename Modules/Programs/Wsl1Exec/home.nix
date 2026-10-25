{ config, lib, pkgs, ... }:
let
  cfg = config.programs.wsl1-exec;
  defaultPackage = pkgs.callPackage ./package.nix { };
in
{
  options.programs.wsl1-exec = {
    enable = lib.mkEnableOption ''
      a pinned, minimal WSL 1 ENOEXEC-rescue preload library for Nix-built
      executables
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The WSL 1 exec-rescue preload library to provision.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.isx86_64;
      message = "programs.wsl1-exec only supports x86_64 Linux.";
    }];

    # This only provisions the immutable, profile-rooted library.  To use it
    # for Nix builds after `home-manager switch`, an administrator must opt in
    # explicitly with:
    #   printf "%s\n" "$HOME/.local/lib/nix-wsl1-exec.so" | sudo tee /etc/ld.so.preload >/dev/null
    # Nix builders discard LD_PRELOAD, so an interactive-only setting cannot
    # work.  Keep that host-wide decision out of a user-level Home Manager
    # module.
    home.file.".local/lib/nix-wsl1-exec.so".source =
      "${cfg.package}/lib/nix-wsl1-exec.so";
  };
}
