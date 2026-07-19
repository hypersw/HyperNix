{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers;
in
{
  imports = [
    ./GuestSide
  ];

  options.hypersw.containers.UserContainers = {
    Enable = lib.mkEnableOption "HyperNix user-container support.";

    # Placeholder namespace for the currently deployed, host-evaluated
    # containers in NixConfig. HyperNix intentionally does not implement this
    # yet; it exists to make the migration plan and option tree explicit.
    OldSchool = {
      Enable = lib.mkEnableOption "legacy host-evaluated user containers.";
    };

    Managed = {
      Enable = lib.mkEnableOption "managed self-rebuilding user containers.";
    };
  };

  config = lib.mkIf cfg.Enable { };
}
