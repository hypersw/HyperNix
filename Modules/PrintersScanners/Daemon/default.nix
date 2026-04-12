{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-daemon;
  sharedPackage = import ../Shared/package.nix { inherit pkgs; };
  daemonPackage = import ./package.nix { inherit pkgs sharedPackage; };
in
{
  options.services.printscan-daemon = {
    enable = lib.mkEnableOption "Print/Scan daemon with Unix socket API";

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/printscan/api.sock";
      description = "Path to the Unix domain socket";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "printscan";
      description = "Group that can connect to the daemon socket";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = {};
    users.users.printscan-daemon = {
      isSystemUser = true;
      group = cfg.group;
      description = "PrintScan daemon service user";
    };

    systemd.services.printscan-daemon = {
      description = "Print/Scan Daemon";
      after = [ "cups.service" "network.target" ];
      wants = [ "cups.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PRINTSCAN_SOCKET = cfg.socketPath;
        ASPNETCORE_URLS = "http://unix:${cfg.socketPath}";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${daemonPackage}/bin/PrintScan.Daemon";
        Restart = "on-failure";
        RestartSec = "5s";

        # RuntimeDirectory creates /run/printscan/ writable by the service user.
        # Group set to printscan so the bot (in printscan group) can access the socket.
        RuntimeDirectory = "printscan";
        RuntimeDirectoryMode = "0775";
        RuntimeDirectoryPreserve = true;

        User = "printscan-daemon";
        Group = cfg.group;  # socket inherits this group → bot can connect
        SupplementaryGroups = [ "lp" "scanner" ];

        # Hardening — strict but allow writing to /run/printscan/
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Socket created with group-writable permissions so bot can connect
        UMask = "0117"; # files: 0660, dirs: 0770
      };
    };
  };
}
