{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-telegram-bot;
  daemonCfg = config.services.printscan-daemon;
in
{
  options.services.printscan-telegram-bot = {
    enable = lib.mkEnableOption "Telegram bot for print/scan operations";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Telegram bot API token (via sops-nix/agenix)";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [];
      description = "Telegram user IDs allowed to use the bot (whitelist)";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = daemonCfg.enable;
      message = "services.printscan-telegram-bot requires services.printscan-daemon to be enabled";
    }];

    systemd.services.printscan-telegram-bot = {
      description = "Print/Scan Telegram Bot";
      after = [ "printscan-daemon.socket" "network-online.target" ];
      wants = [ "printscan-daemon.socket" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity"; # placeholder
        Restart = "on-failure";
        RestartSec = "10s";
        LoadCredential = "telegram-token:${cfg.tokenFile}";
        DynamicUser = true;
        SupplementaryGroups = [ daemonCfg.group ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      environment = {
        PRINTSCAN_SOCKET = daemonCfg.socketPath;
        PRINTSCAN_ALLOWED_USERS = lib.concatMapStringsSep "," toString cfg.allowedUsers;
      };
    };
  };
}
