{ config, lib, pkgs, ... }:
let
  cfg = config.services.telegram-alerts;

  # Script to send a Telegram message — reads token and chat ID from files at runtime
  sendTelegram = pkgs.writeShellScript "send-telegram" ''
    CHAT_ID_FILE="$1"
    shift
    MESSAGE="$*"
    CHAT_ID=$(cat "$CHAT_ID_FILE")
    TOKEN=$(cat ${cfg.tokenFile})
    ${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d "chat_id=$CHAT_ID" \
      -d "text=$MESSAGE" \
      -d "parse_mode=HTML" >/dev/null
  '';

  sendAlert = pkgs.writeShellScript "send-alert" ''
    ${sendTelegram} ${cfg.alertsChatIdFile} "$@"
  '';

  sendLog = pkgs.writeShellScript "send-log" ''
    ${sendTelegram} ${cfg.logChatIdFile} "$@"
  '';

  # Custom notification script for netdata — reads secrets from files at runtime.
  # Netdata's built-in health_alarm_notify.conf can't read from files,
  # so we use a custom script that netdata calls for all alarm transitions.
  notifyScript = pkgs.writeShellScript "netdata-telegram-notify" ''
    # Netdata passes alarm info via environment variables:
    # $NETDATA_ALARM_STATUS (CRITICAL, WARNING, CLEAR)
    # $NETDATA_ALARM_NAME, $NETDATA_ALARM_CHART, $NETDATA_ALARM_INFO
    # $NETDATA_ALARM_ROLE

    TOKEN=$(cat ${cfg.tokenFile} 2>/dev/null) || exit 0

    # Route by role: "log" → low-priority, everything else → alerts
    case "$NETDATA_ALARM_ROLE" in
      log) CHAT_ID=$(cat ${cfg.logChatIdFile} 2>/dev/null) ;;
      *)   CHAT_ID=$(cat ${cfg.alertsChatIdFile} 2>/dev/null) ;;
    esac
    [ -z "$CHAT_ID" ] && exit 0

    HOST=$(hostname)
    MSG="<b>$HOST [$NETDATA_ALARM_STATUS]</b> $NETDATA_ALARM_NAME%0A$NETDATA_ALARM_INFO%0AChart: $NETDATA_ALARM_CHART"

    ${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d "chat_id=$CHAT_ID" \
      -d "text=$MSG" \
      -d "parse_mode=HTML" >/dev/null
  '';

  notifyConf = pkgs.writeText "health_alarm_notify.conf" ''
    # Use custom notification script — reads tokens/chat IDs from sops secrets at runtime
    custom_sender="${notifyScript}"

    # Disable all built-in methods — we handle everything in the custom script
    SEND_CUSTOM="YES"
    SEND_TELEGRAM="NO"
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

    alertsChatIdFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing Telegram chat ID for high-priority alerts";
    };

    logChatIdFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing Telegram chat ID for low-priority events";
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

    # NixOS upgrade failure → alert (keep OnFailure for the upgrade service specifically,
    # since activation scripts don't run on failed builds)
    systemd.services.nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
      unitConfig.OnFailure = "upgrade-failure-notify.service";
      unitConfig.OnSuccess = "upgrade-success-notify.service";
    };

    systemd.services.upgrade-success-notify = {
      description = "Notify Telegram that upgrade service completed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "upgrade-success-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          ${sendLog} "$HOST: auto-upgrade completed"
        '';
      };
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

    # System activation notification → fires on EVERY nixos-rebuild switch,
    # regardless of how it was triggered (manual, auto-upgrade, auto-rebuild-on-push).
    # Compares current system with the new one; only notifies if actually changed.
    system.activationScripts.notifyConfigChange = ''
      PREV=$(readlink /run/current-system 2>/dev/null || echo "none")
      NEW=$(readlink $systemConfig 2>/dev/null || echo "unknown")
      if [ "$PREV" != "$NEW" ]; then
        HOST=$(hostname)
        PREV_NAME=$(basename "$PREV" | sed 's/^[^-]*-//')
        NEW_NAME=$(basename "$NEW" | sed 's/^[^-]*-//')
        ${sendLog} "$HOST: config switched%0A<code>$PREV_NAME</code>%0A→ <code>$NEW_NAME</code>" &
      fi
    '';

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
