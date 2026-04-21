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

  # Query GitHub API for commit details (owner/repo, rev) → "short_hash date subject"
  # Returns empty on failure. 10s timeout.
  ghCommitInfo = pkgs.writeShellScript "gh-commit-info" ''
    OWNER_REPO="$1"
    REV="$2"
    [ -z "$REV" ] || [ "$REV" = "dirty" ] && exit 0
    RESP=$(${pkgs.curl}/bin/curl -sf --max-time 10 \
      "https://api.github.com/repos/$OWNER_REPO/commits/$REV" 2>/dev/null) || exit 0
    SHORT=$(echo "$REV" | ${pkgs.coreutils}/bin/cut -c1-7)
    DATE=$(echo "$RESP" | ${pkgs.jq}/bin/jq -r '.commit.committer.date // empty' | ${pkgs.coreutils}/bin/cut -c1-16)
    MSG=$(echo "$RESP" | ${pkgs.jq}/bin/jq -r '.commit.message // empty' | ${pkgs.coreutils}/bin/head -1 | ${pkgs.coreutils}/bin/cut -c1-60)
    [ -n "$DATE" ] && echo "$SHORT $DATE $MSG"
  '';

  # Send switch notification: immediate basic message, then edit with enriched git info.
  # Entirely fault-tolerant — failures at any stage don't block activation or lose the message.
  enrichedSwitchNotify = pkgs.writeShellScript "enriched-switch-notify" ''
    LOG_TAG="config-switch-notify"
    PREV="$1"
    NEW="$2"
    HOST=$(${pkgs.hostname}/bin/hostname)

    PREV_STORE=$(${pkgs.coreutils}/bin/basename "$PREV" | ${pkgs.coreutils}/bin/cut -c1-8)
    NEW_STORE=$(${pkgs.coreutils}/bin/basename "$NEW" | ${pkgs.coreutils}/bin/cut -c1-8)

    # Read build-revision metadata — may not exist in older system generations
    REV_FILE="etc/monitoring/build-revisions"
    if ! PREV_INFO=$(${pkgs.coreutils}/bin/cat "$PREV/$REV_FILE" 2>/dev/null); then
      echo "$LOG_TAG: WARNING: previous system has no $REV_FILE" >&2
      PREV_INFO='{}'
    fi
    if ! NEW_INFO=$(${pkgs.coreutils}/bin/cat "$NEW/$REV_FILE" 2>/dev/null); then
      echo "$LOG_TAG: WARNING: new system has no $REV_FILE" >&2
      NEW_INFO='{}'
    fi

    PREV_CFG_REV=$(echo "$PREV_INFO" | ${pkgs.jq}/bin/jq -r '.configRev // empty')
    NEW_CFG_REV=$(echo "$NEW_INFO" | ${pkgs.jq}/bin/jq -r '.configRev // empty')
    PREV_NIXPKGS_REV=$(echo "$PREV_INFO" | ${pkgs.jq}/bin/jq -r '.nixpkgsRev // empty')
    NEW_NIXPKGS_REV=$(echo "$NEW_INFO" | ${pkgs.jq}/bin/jq -r '.nixpkgsRev // empty')
    CFG_REPO=$(echo "$NEW_INFO" | ${pkgs.jq}/bin/jq -r '.configRepo // empty')

    # Read secrets — error if missing (module is enabled, secrets must exist)
    if ! CHAT_ID=$(${pkgs.coreutils}/bin/cat ${cfg.logChatIdFile} 2>/dev/null) || [ -z "$CHAT_ID" ]; then
      echo "$LOG_TAG: ERROR: cannot read chat ID from ${cfg.logChatIdFile}" >&2
      exit 1
    fi
    if ! TOKEN=$(${pkgs.coreutils}/bin/cat ${cfg.tokenFile} 2>/dev/null) || [ -z "$TOKEN" ]; then
      echo "$LOG_TAG: ERROR: cannot read token from ${cfg.tokenFile}" >&2
      exit 1
    fi

    PREV_CFG_SHORT="''${PREV_CFG_REV:+$(echo "$PREV_CFG_REV" | ${pkgs.coreutils}/bin/cut -c1-7)}"
    NEW_CFG_SHORT="''${NEW_CFG_REV:+$(echo "$NEW_CFG_REV" | ${pkgs.coreutils}/bin/cut -c1-7)}"
    PREV_LABEL="''${PREV_CFG_SHORT:-n/a} $PREV_STORE"
    NEW_LABEL="''${NEW_CFG_SHORT:-n/a} $NEW_STORE"
    BASIC_MSG="🔄 <b>$HOST</b>: config switched%0A<code>$PREV_LABEL</code>%0A→ <code>$NEW_LABEL</code>%0A%0ALoading commit details..."
    echo "$LOG_TAG: sending notification (chat=$CHAT_ID, msg length=''${#BASIC_MSG})" >&2

    # Send with retry (3 attempts, 5s delay) — network may not be ready right after switch
    SEND_RESP=""
    for attempt in 1 2 3; do
      SEND_RESP=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot''${TOKEN}/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$BASIC_MSG" \
        -d "parse_mode=HTML" 2>&1)
      CURL_RC=$?
      if [ $CURL_RC -eq 0 ] && echo "$SEND_RESP" | ${pkgs.gnugrep}/bin/grep -q '"ok":true'; then
        echo "$LOG_TAG: sent successfully (attempt $attempt)" >&2
        break
      fi
      echo "$LOG_TAG: send attempt $attempt failed (curl rc=$CURL_RC, resp=$SEND_RESP)" >&2
      [ "$attempt" -lt 3 ] && ${pkgs.coreutils}/bin/sleep 5
    done
    if ! echo "$SEND_RESP" | ${pkgs.gnugrep}/bin/grep -q '"ok":true'; then
      echo "$LOG_TAG: ERROR: all send attempts failed" >&2
      exit 1
    fi
    MSG_ID=$(echo "$SEND_RESP" | ${pkgs.jq}/bin/jq -r '.result.message_id // empty')
    if [ -z "$MSG_ID" ]; then
      echo "$LOG_TAG: ERROR: Telegram API returned no message_id" >&2
      exit 1
    fi

    # Enrich with GitHub commit details (10s timeout per call, warn on failure)
    CFG_INFO=""
    if [ -n "$NEW_CFG_REV" ] && [ "$NEW_CFG_REV" != "dirty" ] && [ -n "$CFG_REPO" ]; then
      if ! CFG_INFO=$(${ghCommitInfo} "$CFG_REPO" "$NEW_CFG_REV"); then
        echo "$LOG_TAG: WARNING: failed to fetch config commit info for $NEW_CFG_REV" >&2
        CFG_INFO=""
      fi
    fi

    NIXPKGS_INFO=""
    if [ -n "$NEW_NIXPKGS_REV" ]; then
      if ! NIXPKGS_INFO=$(${ghCommitInfo} "NixOS/nixpkgs" "$NEW_NIXPKGS_REV"); then
        echo "$LOG_TAG: WARNING: failed to fetch nixpkgs commit info for $NEW_NIXPKGS_REV" >&2
        NIXPKGS_INFO=""
      fi
    fi

    # Determine nixpkgs change status
    if [ -z "$PREV_NIXPKGS_REV" ] || [ -z "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_CHANGED="n/a"
    elif [ "$PREV_NIXPKGS_REV" = "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_CHANGED="unchanged"
    else
      NIXPKGS_CHANGED="updated"
    fi

    # Build enriched message — always show all fields, use n/a for missing
    RICH_MSG="🔄 <b>$HOST</b>: config switched%0A<code>$PREV_LABEL</code> → <code>$NEW_LABEL</code>"

    if [ -n "$CFG_INFO" ]; then
      RICH_MSG="$RICH_MSG%0A%0A⚙️ Config: <code>$CFG_INFO</code>"
    elif [ -n "$NEW_CFG_SHORT" ]; then
      RICH_MSG="$RICH_MSG%0A%0A⚙️ Config: <code>$NEW_CFG_SHORT</code> (details unavailable)"
    else
      RICH_MSG="$RICH_MSG%0A%0A⚙️ Config: n/a"
    fi

    if [ -n "$NIXPKGS_INFO" ]; then
      RICH_MSG="$RICH_MSG%0A📦 Nixpkgs ($NIXPKGS_CHANGED): <code>$NIXPKGS_INFO</code>"
    elif [ -n "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_SHORT=$(echo "$NEW_NIXPKGS_REV" | ${pkgs.coreutils}/bin/cut -c1-7)
      RICH_MSG="$RICH_MSG%0A📦 Nixpkgs ($NIXPKGS_CHANGED): <code>$NIXPKGS_SHORT</code>"
    else
      RICH_MSG="$RICH_MSG%0A📦 Nixpkgs: n/a"
    fi

    # Edit the original message with enriched content
    if ! ${pkgs.curl}/bin/curl -sf -X POST \
      "https://api.telegram.org/bot$TOKEN/editMessageText" \
      -d "chat_id=$CHAT_ID" \
      -d "message_id=$MSG_ID" \
      -d "text=$RICH_MSG" \
      -d "parse_mode=HTML" >/dev/null 2>&1; then
      echo "$LOG_TAG: WARNING: failed to edit message with enriched content" >&2
    fi
  '';

  # Format seconds into human-readable duration (like TimeSpan)
  # 16428 → "4h 33m 48s"
  formatUptime = pkgs.writeShellScript "format-uptime" ''
    S=$1
    D=$((S / 86400))
    H=$(( (S % 86400) / 3600 ))
    M=$(( (S % 3600) / 60 ))
    SEC=$((S % 60))
    if [ "$D" -gt 0 ]; then echo "''${D}d ''${H}h ''${M}m"
    elif [ "$H" -gt 0 ]; then echo "''${H}h ''${M}m ''${SEC}s"
    elif [ "$M" -gt 0 ]; then echo "''${M}m ''${SEC}s"
    else echo "''${SEC}s"
    fi
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

    # Build-time revision info — set from the flake where revisions are available.
    # The module embeds these into a monitoring-specific file at build time.
    configRevision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = "Git revision of the system configuration flake";
    };

    nixpkgsRevision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = "Git revision of the nixpkgs input";
    };

    configRepoOwner = lib.mkOption {
      type = lib.types.str;
      default = "hypersw/HyperNix";
      description = "GitHub owner/repo for the config flake (for commit info queries)";
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

    # ── Build-time revision info (monitoring-internal, not for other modules) ──
    environment.etc."monitoring/build-revisions".text = builtins.toJSON {
      configRev = cfg.configRevision;
      nixpkgsRev = cfg.nixpkgsRevision;
      configRepo = cfg.configRepoOwner;
    };

    # ── Netdata: system metrics + built-in alarms + Telegram delivery ──

    # Delay the netdata spawn by 30 s past service-start to push its
    # CPU/IO-intensive plugin startup past the kernel's peripheral
    # bring-up window (the first ~10-15 s of boot where we've seen
    # this Pi occasionally brown-out-reset silently — see the
    # "Boot-stability tweaks" block in PrintScanServer/configuration.nix
    # for the context). Netdata on startup forks many plugins, reads
    # /proc extensively, does a one-shot hw-discovery pass — if that
    # overlaps with WiFi firmware load + USB enumeration, it's an
    # easy CPU spike to schedule out of that window.
    #
    # This is a pragmatic ExecStartPre=sleep rather than a timer unit;
    # systemd has no `StartDelaySec=` property and a timer-driven
    # variant would require unpinning netdata from multi-user.target.
    # One forked sleep for 30 s is fine.
    systemd.services.netdata.serviceConfig.ExecStartPre = [
      "${pkgs.coreutils}/bin/sleep 30"
    ];

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
        # Disable plugins that don't apply (RPi has no IPMI, IPsec, etc.)
        "plugin:freeipmi" = { enabled = "no"; };
        "plugin:perf" = { enabled = "no"; };
        "plugin:ioping" = { enabled = "no"; };
        "plugin:charts.d" = { enabled = "no"; }; # libreswan, opensips
        "plugin:logs-management" = { enabled = "no"; };
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

        # Disk space — use netdata's built-in disk_space_usage alarm,
        # just disable our broken custom one. Built-in defaults are
        # warn at 80%, crit at 90% which matches our config.
        # To customize further, override the built-in alarm template.

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

        # RAM usage — use calc with system.ram dimensions.
        # system.ram has dimensions: used, free, cached, buffers
        "health.d/ram_custom.conf" = pkgs.writeText "ram_custom.conf" ''
          alarm: ram_usage_warn
              on: system.ram
            calc: $used * 100 / ($used + $free + $cached + $buffers)
           units: %
           every: 30s
            warn: $this > 85
              to: log
            info: RAM usage above 85%

          alarm: ram_usage_crit
              on: system.ram
            calc: $used * 100 / ($used + $free + $cached + $buffers)
           units: %
           every: 30s
            crit: $this > 95
              to: alerts
            info: RAM usage above 95%
        '';
      };
    };

    # ── Custom NixOS event sources (not covered by netdata) ──

    # Emojis per event type:
    #   🟢 boot
    #   🔄 config switch
    #   ✅ upgrade success
    #   ❌ upgrade failure
    #   🔑 SSH login
    #   🚫 SSH failed login
    #   🧹 GC
    #   💥 previous boot panic
    #   ⚠️  netdata warning
    #   🔴 netdata critical

    # Boot notification → log channel (only on real boot, not activation).
    # Detects real boot by checking uptime < 5 minutes.
    systemd.services.boot-notify = {
      description = "Notify Telegram on successful boot";
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "boot-notify" ''
          UPTIME_S=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.coreutils}/bin/cut -d. -f1)
          # Only notify on actual boot (uptime < 300s), not config switches
          if [ "$UPTIME_S" -gt 300 ]; then
            exit 0
          fi
          HOST=$(${pkgs.hostname}/bin/hostname)
          KERNEL=$(${pkgs.coreutils}/bin/uname -r)
          UPTIME=$(${formatUptime} "$UPTIME_S")
          ${sendLog} "🟢 <b>$HOST</b> booted%0AKernel: $KERNEL%0AUptime: $UPTIME"
        '';
      };
    };

    # Shutdown notification → log channel.
    # Runs on graceful shutdown/reboot via ExecStop (ExecStart is a no-op).
    # Must complete while network is still up. systemd stops units in reverse
    # dependency order, so After=network-online.target means network is up
    # when we start AND still up when we stop (network-online waits for us).
    systemd.services.shutdown-notify = {
      description = "Notify Telegram on graceful shutdown";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = pkgs.writeShellScript "shutdown-notify" ''
          # Only notify on actual system shutdown/reboot, not unit restart
          # (ExecStop fires on any stop, including systemctl restart shutdown-notify)
          STATE=$(${pkgs.systemd}/bin/systemctl is-system-running 2>/dev/null || true)
          if [ "$STATE" != "stopping" ]; then
            exit 0
          fi
          HOST=$(${pkgs.hostname}/bin/hostname)
          UPTIME_S=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.coreutils}/bin/cut -d. -f1)
          UPTIME=$(${formatUptime} "$UPTIME_S")
          ${sendLog} "🔴 <b>$HOST</b> shutting down%0AUptime: $UPTIME"
        '';
      };
    };

    # Boot-health check → alerts channel.
    #
    # Trigger semantics: runs at most ONCE per actual boot.
    # RemainAfterExit=true keeps the unit "active" after first completion
    # so nixos-rebuild switches that touch this unit's graph don't
    # re-execute it and re-send the same alert.
    #
    # Alert logic:
    #   - Look at the immediately-previous boot (-1) only. If it ended
    #     without a shutdown-target marker → alert. If it was clean →
    #     silent, whatever happened further back is historical and has
    #     already been surfaced (if at all).
    #   - If (-1) was unclean, walk backwards to report how long the
    #     streak goes for context — "N unclean in a row" — but the
    #     trigger is whether (-1) itself is dirty, not the size of the
    #     historical streak.
    #   - Real kernel panics in (-1) get their own separate alert.
    #     Narrow regex — userspace crit-priority chatter (netdata "No
    #     charts to collect" etc.) is specifically excluded.
    systemd.services.check-previous-boot = {
      description = "Check boot -1 for unclean shutdown or kernel panic, alert once per boot";
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Run once per boot. Stays "active" after first completion so a
        # nixos-rebuild switch that restarts dependencies doesn't re-fire.
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "check-previous-boot" ''
          set -u
          HOST=$(${pkgs.hostname}/bin/hostname)
          JCTL=${pkgs.systemd}/bin/journalctl

          # Boot is "clean" iff its journal contains one of systemd's
          # shutdown-target markers. Anything else = terminated abruptly.
          is_clean_boot() {
            "$JCTL" -b "$1" --no-pager -q 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -q -E \
                'Reached target (Power-Off|Reboot|System Shutdown|Halt|Kexec)|systemd-journald.*Journal stopped' \
              && return 0 || return 1
          }

          # Resolve boot -1's id. If no -1 (fresh install, first boot),
          # nothing to say.
          PREV_BID=$("$JCTL" --list-boots --no-pager 2>/dev/null \
            | ${pkgs.gawk}/bin/awk '$1=="-1" {print $2; exit}')
          [ -z "$PREV_BID" ] && exit 0

          # Trigger: whether boot -1 itself was unclean. Don't alert on
          # old history alone.
          if is_clean_boot "$PREV_BID"; then
            exit 0
          fi

          # Boot -1 was unclean → gather context.
          LAST_UNCLEAN_TAIL=$("$JCTL" -b "$PREV_BID" --no-pager -q 2>/dev/null \
            | ${pkgs.coreutils}/bin/tail -3 \
            | ${pkgs.coreutils}/bin/cut -c1-180)

          # Count streak backwards for context only — bounded safety cap.
          STREAK=1
          for idx in $(seq 2 30); do
            BID=$("$JCTL" --list-boots --no-pager 2>/dev/null \
              | ${pkgs.gawk}/bin/awk -v idx="-$idx" '$1==idx {print $2; exit}')
            [ -z "$BID" ] && break
            if is_clean_boot "$BID"; then break; fi
            STREAK=$((STREAK+1))
          done

          if [ "$STREAK" -ge 2 ]; then
            ${sendAlert} "💥 <b>$HOST</b>: previous boot ended abruptly (no shutdown marker). Streak of $STREAK unclean boots back — suspect power / USB-peripheral / hardware.%0ALast failing boot ended with:%0A<pre>$LAST_UNCLEAN_TAIL</pre>"
          else
            ${sendAlert} "⚠️ <b>$HOST</b>: previous boot ended abruptly (no shutdown marker). Isolated event — worth noting only if it recurs.%0ALast failing boot ended with:%0A<pre>$LAST_UNCLEAN_TAIL</pre>"
          fi

          # Separately: genuine kernel panics in the immediately previous
          # boot. Narrow patterns only — don't alert on userspace noise.
          PANIC=$("$JCTL" -b -1 -k --no-pager -q 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -E 'Oops|Kernel panic|BUG:|stack-protector|end Kernel panic|unable to handle kernel' \
            | ${pkgs.coreutils}/bin/head -5)
          if [ -n "$PANIC" ]; then
            ${sendAlert} "☠️ <b>$HOST</b>: kernel panic/oops in previous boot:%0A<pre>$PANIC</pre>"
          fi
        '';
      };
    };

    # NixOS upgrade failure → alert
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
          ${sendLog} "✅ <b>$HOST</b>: auto-upgrade completed"
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
          ${sendAlert} "❌ <b>$HOST</b>: NixOS upgrade FAILED%0A<pre>$LOG</pre>"
        '';
      };
    };

    # System switch notification — runs as a oneshot service after every activation.
    # Uses activation script to record previous system path (before /run/current-system
    # is updated), then a systemd service sends the notification (after sops secrets
    # are available).
    # Record the current system path BEFORE the switch updates /run/current-system.
    # config-switch-notify reads this to compare old vs new.
    # Same pattern as boot-notify: Type=oneshot without RemainAfterExit goes inactive
    # after each run, so wantedBy=multi-user.target re-triggers it on every switch.
    system.activationScripts.recordPreviousSystem = ''
      ${pkgs.coreutils}/bin/readlink /run/current-system > /run/previous-system-path 2>/dev/null || echo "none" > /run/previous-system-path
    '';

    systemd.services.config-switch-notify = {
      description = "Notify Telegram on config switch";
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Stopped by activation script, then re-triggered by wantedBy on each switch.
      # ExecStart checks if system actually changed before notifying.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "config-switch-notify-check" ''
          PREV=$(${pkgs.coreutils}/bin/cat /run/previous-system-path 2>/dev/null || echo "none")
          NEW=$(${pkgs.coreutils}/bin/readlink /run/current-system 2>/dev/null || echo "unknown")
          if [ "$PREV" != "$NEW" ] && [ "$PREV" != "none" ]; then
            ${enrichedSwitchNotify} "$PREV" "$NEW"
          fi
        '';
      };
    };

    # SSH login notifications — uses journal cursor to avoid replays on service restart
    systemd.services.ssh-login-notify = {
      description = "Notify Telegram on SSH logins";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "ssh-login-notify";
        ExecStart = pkgs.writeShellScript "ssh-login-notify" ''
          HOST=$(${pkgs.hostname}/bin/hostname)
          # Follow journal from NOW — avoids replaying old entries on service restart
          ${pkgs.systemd}/bin/journalctl -f -u sshd --no-pager -q -o cat \
            --since "now" | while read -r line; do
            case "$line" in
              *"Accepted"*)
                # Parse: "Accepted publickey for USER from IP port PORT ..."
                USER=$(echo "$line" | ${pkgs.gnused}/bin/sed -n 's/.*for \([^ ]*\) from.*/\1/p')
                FROM=$(echo "$line" | ${pkgs.gnused}/bin/sed -n 's/.*from \([^ ]*\) port \([^ ]*\).*/\1:\2/p')
                ${sendLog} "🔑 <b>$HOST</b>: incoming ssh user: <code>$USER</code> from: <code>$FROM</code>"
                ;;
              *"Failed"*|*"Invalid user"*)
                USER=$(echo "$line" | ${pkgs.gnused}/bin/sed -n 's/.*for \([^ ]*\) from.*/\1/p')
                FROM=$(echo "$line" | ${pkgs.gnused}/bin/sed -n 's/.*from \([^ ]*\) port \([^ ]*\).*/\1:\2/p')
                ${sendAlert} "🚫 <b>$HOST</b>: failed ssh user: <code>''${USER:-unknown}</code> from: <code>''${FROM:-unknown}</code>"
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
          ${sendLog} "🧹 <b>$HOST</b>: nix GC freed ''${FREED:-unknown}. Store: $STORE_SIZE"
        '';
      };
    };
  };
}
