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

        UMask = "0007"; # socket: 0770 → group-accessible

        # Fix socket ownership after Kestrel creates it.
        # Kestrel creates the socket as the service user, but within ProtectSystem
        # namespace the ownership may not propagate correctly to the host view.
        ExecStartPost = pkgs.writeShellScript "fix-socket-perms" ''
          # Wait for socket to exist
          for i in $(seq 1 30); do
            [ -S ${cfg.socketPath} ] && break
            sleep 1
          done
          ${pkgs.coreutils}/bin/chgrp ${cfg.group} ${cfg.socketPath} 2>/dev/null || true
          ${pkgs.coreutils}/bin/chmod 0770 ${cfg.socketPath} 2>/dev/null || true
        '';
      };
    };
  };
}
