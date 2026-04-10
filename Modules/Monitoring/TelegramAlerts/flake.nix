{
  description = "System monitoring with Telegram alerts — failed units, health checks, boot confirmation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.telegram-alerts;
      in
      {
        options.services.telegram-alerts = {
          enable = lib.mkEnableOption "System monitoring with Telegram alerts";

          tokenFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to file containing the Telegram bot API token";
          };

          chatId = lib.mkOption {
            type = lib.types.str;
            description = "Telegram chat ID to send alerts to";
          };

          healthCheckInterval = lib.mkOption {
            type = lib.types.str;
            default = "15min";
            description = "How often to run health checks";
          };

          temperatureThreshold = lib.mkOption {
            type = lib.types.int;
            default = 70;
            description = "CPU temperature (Celsius) above which to alert";
          };

          diskThreshold = lib.mkOption {
            type = lib.types.int;
            default = 80;
            description = "Disk usage percentage above which to alert";
          };

          memoryThreshold = lib.mkOption {
            type = lib.types.int;
            default = 85;
            description = "Memory usage percentage above which to alert";
          };
        };

        config = lib.mkIf cfg.enable (let
          sendTelegram = pkgs.writeShellScript "send-telegram" ''
            TOKEN=$(cat "$CREDENTIALS_DIRECTORY/telegram-token" 2>/dev/null || cat ${cfg.tokenFile})
            ${pkgs.curl}/bin/curl -s -X POST \
              "https://api.telegram.org/bot$TOKEN/sendMessage" \
              -d "chat_id=${cfg.chatId}" \
              -d "text=$1" \
              -d "parse_mode=HTML" >/dev/null
          '';
        in {
          # Template service for OnFailure= — called with failed unit name as %i
          systemd.services."notify-telegram@" = {
            description = "Send Telegram alert for failed unit %i";
            serviceConfig = {
              Type = "oneshot";
              LoadCredential = "telegram-token:${cfg.tokenFile}";
              ExecStart = pkgs.writeShellScript "notify-failure" ''
                UNIT="$1"
                HOST=$(${pkgs.hostname}/bin/hostname)
                STATUS=$(${pkgs.systemd}/bin/systemctl status "$UNIT" --no-pager 2>&1 | head -20)
                TOKEN=$(cat "$CREDENTIALS_DIRECTORY/telegram-token")
                ${pkgs.curl}/bin/curl -s -X POST \
                  "https://api.telegram.org/bot$TOKEN/sendMessage" \
                  -d "chat_id=${cfg.chatId}" \
                  -d "text=<b>$HOST: $UNIT failed</b>%0A<pre>$STATUS</pre>" \
                  -d "parse_mode=HTML" >/dev/null
              '';
            };
            scriptArgs = "%i";
          };

          # Hook upgrade service to alert on failure
          systemd.services.nixos-upgrade.unitConfig.OnFailure =
            lib.mkIf config.system.autoUpgrade.enable "notify-telegram@%n.service";

          # Boot confirmation — announce successful boot
          systemd.services.boot-notify = {
            description = "Notify Telegram on successful boot";
            after = [ "multi-user.target" "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              LoadCredential = "telegram-token:${cfg.tokenFile}";
              ExecStart = pkgs.writeShellScript "boot-notify" ''
                HOST=$(${pkgs.hostname}/bin/hostname)
                UPTIME=$(${pkgs.coreutils}/bin/uptime -p)
                KERNEL=$(${pkgs.coreutils}/bin/uname -r)
                TOKEN=$(cat "$CREDENTIALS_DIRECTORY/telegram-token")
                ${pkgs.curl}/bin/curl -s -X POST \
                  "https://api.telegram.org/bot$TOKEN/sendMessage" \
                  -d "chat_id=${cfg.chatId}" \
                  -d "text=$HOST booted: $KERNEL ($UPTIME)" >/dev/null
              '';
            };
          };

          # Periodic health check
          systemd.timers.health-check = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "5min";
              OnUnitActiveSec = cfg.healthCheckInterval;
            };
          };

          systemd.services.health-check = {
            description = "Periodic system health check with Telegram alerts";
            serviceConfig = {
              Type = "oneshot";
              LoadCredential = "telegram-token:${cfg.tokenFile}";
            };
            path = [ pkgs.systemd pkgs.curl pkgs.gawk pkgs.coreutils pkgs.procps ];
            script = ''
              HOST=$(hostname)
              MSG=""

              # Check for failed units
              FAILED=$(systemctl --failed --no-legend --no-pager | head -10)
              if [ -n "$FAILED" ]; then
                MSG="$MSG<b>Failed units:</b>%0A<pre>$FAILED</pre>%0A"
              fi

              # CPU temperature (RPi thermal zone)
              if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
                TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
                if [ "$TEMP" -gt ${toString cfg.temperatureThreshold} ]; then
                  MSG="$MSG CPU: ''${TEMP}C%0A"
                fi
              fi

              # Disk usage
              DISK_PCT=$(df / --output=pcent | tail -1 | tr -dc '0-9')
              if [ "$DISK_PCT" -gt ${toString cfg.diskThreshold} ]; then
                MSG="$MSG Disk: ''${DISK_PCT}%%0A"
              fi

              # Memory usage
              MEM_PCT=$(free | awk '/Mem:/ {printf "%d", $3/$2*100}')
              if [ "$MEM_PCT" -gt ${toString cfg.memoryThreshold} ]; then
                MSG="$MSG RAM: ''${MEM_PCT}%%0A"
              fi

              # Send if anything to report
              if [ -n "$MSG" ]; then
                TOKEN=$(cat "$CREDENTIALS_DIRECTORY/telegram-token")
                curl -s -X POST \
                  "https://api.telegram.org/bot$TOKEN/sendMessage" \
                  -d "chat_id=${cfg.chatId}" \
                  -d "text=<b>$HOST health alert</b>%0A$MSG" \
                  -d "parse_mode=HTML" >/dev/null
              fi
            '';
          };
        });
      };
  };
}
