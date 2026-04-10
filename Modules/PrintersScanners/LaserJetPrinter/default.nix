{ config, lib, pkgs, ... }:
let
  cfg = config.services.laserjet-printer;
in
{
  options.services.laserjet-printer = {
    enable = lib.mkEnableOption "HP LaserJet P2015n USB printing via CUPS + foo2zjs";
  };

  config = lib.mkIf cfg.enable {
    services.printing = {
      enable = true;
      drivers = [ pkgs.foo2zjs ];
      listenAddresses = [ "*:631" ];
      allowFrom = [ "all" ];
      browsing = true;
      defaultShared = true;
    };

    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    boot.blacklistedKernelModules = [ "usblp" ];
    networking.firewall.allowedTCPPorts = [ 631 ];
  };
}
