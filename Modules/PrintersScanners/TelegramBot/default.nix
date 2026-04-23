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

      # StartLimit* go in [Unit] = unitConfig, not [Service]. See daemon.
      unitConfig = {
        StartLimitIntervalSec = "60s";
        StartLimitBurst = 5;
      };

      # Token provided via systemd LoadCredential → $CREDENTIALS_DIRECTORY/telegram-token
      environment = {
        PRINTSCAN_SOCKET = daemonCfg.socketPath;
        PRINTSCAN_ALLOWED_USERS = builtins.toJSON (map (u: { inherit (u) id name; }) cfg.allowedUsers);
      };

      serviceConfig = {
        # Defense-in-depth CWD pin (see Daemon/default.nix for rationale).
        WorkingDirectory = "/var/empty";

        Type = "simple";
        ExecStart = "${botPackage}/bin/PrintScan.TelegramBot";

        # Always restart — long-running loop consuming TG long-poll.
        # Any exit we don't ask for should bounce back; bounded by
        # StartLimit* in unitConfig above so we don't hot-loop on a
        # broken token etc.
        Restart = "always";
        RestartSec = "5s";

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

        # Hardening.
        #
        # First-hop exposed: this process talks HTTPS to Telegram's Bot API
        # and long-polls for messages. Every inbound message is attacker-
        # shaped until the allowedUsers check passes (and deserialisation /
        # callback-data parsing runs *before* that check). Apply the whole
        # kitchen-sink bundle — we have no need for exotic syscalls, no JIT
        # concerns beyond what .NET itself needs, and no device access.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";      # /proc/<other-pid> invisible
        PrivateDevices = true;          # no /dev/* beyond /dev/null, /dev/zero etc.
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        # Narrow the network syscalls: the bot needs IPv4/IPv6 for HTTPS to
        # api.telegram.org and AF_UNIX for the daemon socket. Explicitly
        # deny AF_NETLINK (no interface enumeration), AF_PACKET (no raw
        # sockets), and every other family.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        # Skipped: MemoryDenyWriteExecute (breaks .NET JIT). SystemCallFilter
        # is another option but .NET's syscall footprint is broad enough that
        # @system-service-with-exclusions needs case-by-case tuning; leave
        # for a follow-up if we decide we want it.
      };
    };
  };
}
