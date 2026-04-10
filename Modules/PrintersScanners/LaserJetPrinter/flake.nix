{
  description = "HP LaserJet P2015n printer module — CUPS + foo2zjs + Avahi/AirPrint";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.laserjet-printer;
      in
      {
        options.services.laserjet-printer = {
          enable = lib.mkEnableOption "HP LaserJet P2015n USB printing via CUPS + foo2zjs";
        };

        config = lib.mkIf cfg.enable {
          # CUPS printing service
          services.printing = {
            enable = true;
            drivers = [ pkgs.foo2zjs ];
            # Listen on network for IPP/AirPrint sharing
            listenAddresses = [ "*:631" ];
            allowFrom = [ "all" ];
            browsing = true;
            defaultShared = true;
          };

          # Avahi for AirPrint/IPP Everywhere/Mopria auto-discovery
          services.avahi = {
            enable = true;
            nssmdns4 = true;
            openFirewall = true;
            publish = {
              enable = true;
              userServices = true;
            };
          };

          # Blacklist usblp to avoid conflict with CUPS USB backend
          boot.blacklistedKernelModules = [ "usblp" ];

          # Open CUPS port
          networking.firewall.allowedTCPPorts = [ 631 ];
        };
      };
  };
}
