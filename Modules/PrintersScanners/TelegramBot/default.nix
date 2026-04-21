{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-telegram-bot;
  daemonCfg = config.services.printscan-daemon;
  sharedPackage = import ../Shared/package.nix { inherit pkgs; };
  botPackage = import ./package.nix { inherit pkgs sharedPackage; };
in
{
  options.services.printscan-telegram-bot = {
    enable = lib.mkEnableOption "Telegram bot for print/scan operations";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Telegram bot API token (via sops-nix/agenix)";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption { type = lib.types.int; description = "Telegram user ID"; };
          name = lib.mkOption { type = lib.types.str; description = "Display name (for logging and accounting)"; };
        };
      });
      default = [];
      description = "Telegram users allowed to use the bot";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.printscan-bot = {
      isSystemUser = true;
      group = daemonCfg.group;
      description = "PrintScan Telegram bot service user";
    };

    assertions = [{
      assertion = daemonCfg.enable;
      message = "services.printscan-telegram-bot requires services.printscan-daemon to be enabled";
    }];

    systemd.services.printscan-telegram-bot = {
      description = "Print/Scan Telegram Bot";
      after = [ "printscan-daemon.service" "network-online.target" ];
      wants = [ "printscan-daemon.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Token provided via systemd LoadCredential → $CREDENTIALS_DIRECTORY/telegram-token
      environment = {
        PRINTSCAN_SOCKET = daemonCfg.socketPath;
        PRINTSCAN_ALLOWED_USERS = builtins.toJSON (map (u: { inherit (u) id name; }) cfg.allowedUsers);
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${botPackage}/bin/PrintScan.TelegramBot";

        # Always restart — long-running loop consuming TG long-poll.
        # Any exit we don't ask for should bounce back; bounded by
        # StartLimit* so we don't hot-loop on a broken token etc.
        Restart = "always";
        RestartSec = "5s";
        StartLimitIntervalSec = "60s";
        StartLimitBurst = 5;

        # systemd credential — decrypted file available at $CREDENTIALS_DIRECTORY/telegram-token
        LoadCredential = "telegram-token:${cfg.tokenFile}";

        # Staging dir for scans mid-upload. On tmpfs (/run) so no SD wear;
        # survives bot-process restarts, cleared on reboot.
        RuntimeDirectory = "printscan-bot";
        RuntimeDirectoryMode = "0700";
        # Keep the staging dir across restarts — systemd would otherwise
        # delete it on service stop. RuntimeDirectoryPreserve=yes keeps it
        # until the host reboots.
        RuntimeDirectoryPreserve = "yes";

        # Allow graceful drain of in-flight TG uploads on SIGTERM.
        # 5min upper bound on a single upload (TG's 50MB cap / typical
        # LAN speeds).
        TimeoutStopSec = "5min";
        KillSignal = "SIGTERM";
        SendSIGHUP = false;

        User = "printscan-bot";
        Group = daemonCfg.group;  # access to daemon's socket

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
