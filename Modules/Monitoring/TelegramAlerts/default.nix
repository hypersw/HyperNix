{ config, lib, pkgs, ... }:
let
  cfg = config.services.telegram-alerts;

  # Script to send a Telegram message — used by custom event services
  sendTelegram = pkgs.writeShellScript "send-telegram" ''
    CHAT_ID="$1"
    shift
    MESSAGE="$*"
    TOKEN=$(cat ${cfg.tokenFile})
    ${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d "chat_id=$CHAT_ID" \
      -d "text=$MESSAGE" \
      -d "parse_mode=HTML" >/dev/null
  '';

  sendAlert = pkgs.writeShellScript "send-alert" ''
    ${sendTelegram} ${cfg.alertsChatId} "$@"
  '';

  sendLog = pkgs.writeShellScript "send-log" ''
    ${sendTelegram} ${cfg.logChatId} "$@"
  '';

  # Netdata health_alarm_notify.conf — routes by role to different chats
  notifyConf = pkgs.writeText "health_alarm_notify.conf" ''
    # Telegram configuration
    SEND_TELEGRAM="YES"
    TELEGRAM_BOT_TOKEN_FILE="${cfg.tokenFile}"

    # Default goes to alerts chat
    DEFAULT_RECIPIENT_TELEGRAM="${cfg.alertsChatId}"

    # Role-based routing:
    # "alerts" role → high-priority chat (disk full, OOM, temp, service failure)
    # "log" role → low-priority chat (warnings, informational)
    role_recipients_telegram[sysadmin]="${cfg.alertsChatId}"
    role_recipients_telegram[alerts]="${cfg.alertsChatId}"
    role_recipients_telegram[log]="${cfg.logChatId}"

    # Disable all other notification methods
    SEND_EMAIL="NO"
    SEND_SLACK="NO"
    SEND_DISCORD="NO"
    SEND_PUSHOVER="NO"
    SEND_PUSHBULLET="NO"
    SEND_TWILIO="NO"
    SEND_MESSAGEBIRD="NO"
    SEND_KAVENEGAR="NO"
    SEND_FLOCK="NO"
    SEND_IRC="NO"
    SEND_SYSLOG="NO"
    SEND_PD="NO"
    SEND_FLEEP="NO"
    SEND_MATRIX="NO"
    SEND_ROCKETCHAT="NO"
    SEND_MSTEAMS="NO"
    SEND_OPSGENIE="NO"
    SEND_GOTIFY="NO"
    SEND_NTFY="NO"
  '';
in
{
  options.services.telegram-alerts = {
    enable = lib.mkEnableOption "System monitoring with Telegram alerts via netdata";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Telegram bot API token";
    };

    alertsChatId = lib.mkOption {
      type = lib.types.str;
      description = "Telegram chat ID for high-priority alerts (failures, critical thresholds)";
    };

    logChatId = lib.mkOption {
      type = lib.types.str;
      description = "Telegram chat ID for low-priority events (boot, login, info)";
    };

    temperatureThreshold = lib.mkOption {
      type = lib.types.int;
      default = 70;
      description = "CPU temperature warning threshold (Celsius)";
    };

    temperatureCritical = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "CPU temperature critical threshold (Celsius)";
    };

    diskWarning = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "Disk usage warning threshold (percent)";
    };

    diskCritical = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Disk usage critical threshold (percent)";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Netdata: system metrics + built-in alarms + Telegram delivery ──

    services.netdata = {
      enable = true;
      config = {
        global = {
          "memory mode" = "dbengine";
          "dbengine multihost disk space" = 32; # MB — minimal footprint
          "update every" = 5;                   # seconds between samples
        };
        web = {
          "mode" = "none"; # no dashboard, alerts only
        };
      };
      configDir = {
        "health_alarm_notify.conf" = notifyConf;

        # Monitor all systemd services
        "go.d/systemdunits.conf" = pkgs.writeText "systemdunits.conf" ''
          jobs:
            - name: service-units
              include:
                - '*.service'
        '';

        # Disk space — override thresholds, send to alerts role
        "health.d/disk_custom.conf" = pkgs.writeText "disk_custom.conf" ''
          alarm: disk_space_warn
              on: disk.space
          lookup: max -1s foreach *
           units: %
           every: 60s
            warn: $this > ${toString cfg.diskWarning}
              to: log
            info: disk space above ${toString cfg.diskWarning}%

          alarm: disk_space_crit
              on: disk.space
          lookup: max -1s foreach *
           units: %
           every: 60s
            crit: $this > ${toString cfg.diskCritical}
              to: alerts
            info: disk space above ${toString cfg.diskCritical}%
        '';

        # CPU temperature — RPi thermal zone
        "health.d/temperature_custom.conf" = pkgs.writeText "temperature_custom.conf" ''
          alarm: cpu_temperature_warn
              on: sensors.cpu_thermal_zone0_temperature
          lookup: average -30s
           units: Celsius
           every: 10s
            warn: $this > ${toString cfg.temperatureThreshold}
              to: log
            info: CPU temperature above ${toString cfg.temperatureThreshold}C

          alarm: cpu_temperature_crit
              on: sensors.cpu_thermal_zone0_temperature
          lookup: average -30s
           units: Celsius
           every: 10s
            crit: $this > ${toString cfg.temperatureCritical}
              to: alerts
            info: CPU temperature above ${toString cfg.temperatureCritical}C
        '';

        # Systemd failed units — any service entering failed state
        "health.d/systemd_custom.conf" = pkgs.writeText "systemd_custom.conf" ''
          alarm: systemd_service_failed
              on: systemd.service_unit_state
          lookup: average -10s of failed
           units: state
           every: 10s
            crit: $this > 0
              to: alerts
            info: a systemd service entered failed state
        '';

        # RAM usage
        "health.d/ram_custom.conf" = pkgs.writeText "ram_custom.conf" ''
          alarm: ram_usage_warn
              on: system.ram
          lookup: average -1m percentage-of-absolute-row
           units: %
           every: 30s
            warn: $this > 85
              to: log
            info: RAM usage above 85%

          alarm: ram_usage_crit
              on: system.ram
          lookup: average -1m percentage-of-absolute-row
           units: %
           every: 30s
            crit: $this > 95
              to: alerts
            info: RAM usage above 95%
        '';
      };
    };

    # ── Custom NixOS event sources (not covered by netdata) ──

    # Boot notification → log channel
    systemd.services.boot-notify = {
      description = "Notify Telegram on successful boot";
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "boot-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          KERNEL=$(${pkgs.coreutils}/bin/uname -r)
          UPTIME=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.coreutils}/bin/cut -d. -f1)
          ${sendLog} "$HOST booted: $KERNEL (up ''${UPTIME}s)"
        '';
      };
    };

    # Previous boot panic check → alerts channel
    systemd.services.check-previous-boot = {
      description = "Check previous boot for kernel panics or critical errors";
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "check-previous-boot" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          # Check if previous boot had panics or critical errors
          PANICS=$(${pkgs.systemd}/bin/journalctl -b -1 -p 0..2 --no-pager -q 2>/dev/null | head -20)
          if [ -n "$PANICS" ]; then
            ${sendAlert} "<b>$HOST: critical errors in previous boot</b>%0A<pre>$PANICS</pre>"
          fi
        '';
      };
    };

    # NixOS upgrade success/failure notifications
    systemd.services.nixos-upgrade = {
      unitConfig.OnFailure = lib.mkIf config.system.autoUpgrade.enable
        "upgrade-failure-notify.service";
      unitConfig.OnSuccess = lib.mkIf config.system.autoUpgrade.enable
        "upgrade-success-notify.service";
    };

    systemd.services.upgrade-failure-notify = {
      description = "Notify Telegram on upgrade failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "upgrade-failure-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          LOG=$(${pkgs.systemd}/bin/journalctl -u nixos-upgrade --no-pager -n 15 -q 2>/dev/null)
          ${sendAlert} "<b>$HOST: NixOS upgrade FAILED</b>%0A<pre>$LOG</pre>"
        '';
      };
    };

    systemd.services.upgrade-success-notify = {
      description = "Notify Telegram on upgrade success";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "upgrade-success-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          CURRENT=$(${pkgs.coreutils}/bin/readlink /run/current-system | ${pkgs.coreutils}/bin/sed 's|/nix/store/[^-]*-||')
          ${sendLog} "$HOST: NixOS upgrade succeeded%0A$CURRENT"
        '';
      };
    };

    # SSH login notifications → log channel
    # Watch auth journal for successful logins
    systemd.services.ssh-login-notify = {
      description = "Notify Telegram on SSH logins";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = pkgs.writeShellScript "ssh-login-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          ${pkgs.systemd}/bin/journalctl -f -u sshd --no-pager -q -o cat | while read -r line; do
            case "$line" in
              *"Accepted"*)
                ${sendLog} "$HOST: $line"
                ;;
              *"Failed"*|*"Invalid user"*)
                ${sendAlert} "<b>$HOST: $line</b>"
                ;;
            esac
          done
        '';
      };
    };

    # Nix GC results → log channel
    systemd.services.nix-gc = lib.mkIf config.nix.gc.automatic {
      unitConfig.OnSuccess = "nix-gc-notify.service";
    };

    systemd.services.nix-gc-notify = {
      description = "Notify Telegram on nix GC completion";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "nix-gc-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          FREED=$(${pkgs.systemd}/bin/journalctl -u nix-gc --no-pager -n 5 -q 2>/dev/null | ${pkgs.gnugrep}/bin/grep -o '[0-9.]* [MG]iB' | tail -1)
          STORE_SIZE=$(${pkgs.coreutils}/bin/du -sh /nix/store 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
          ${sendLog} "$HOST: nix GC freed ''${FREED:-unknown}. Store: $STORE_SIZE"
        '';
      };
    };
  };
}
