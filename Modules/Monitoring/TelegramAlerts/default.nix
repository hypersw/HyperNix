{ config, lib, pkgs, ... }:
let
  cfg = config.services.telegram-alerts;

  # ─── Alert pipeline ──────────────────────────────────────────────────────
  #
  # Notifications are never sent inline by individual notify services. The
  # media-agnostic `sendAlert` / `sendLog` fan out over every configured
  # medium; each medium has its own persistent outbox and async drainer.
  # This decouples event emission from network status — services always
  # succeed locally, messages accumulate (with original event timestamps)
  # until the medium's transport works. When one medium's network is down
  # but another's isn't, delivery still happens via the healthy path.
  #
  # Today only Telegram is implemented. To add a medium (email, Pushover,
  # etc.), define a new `<medium>Enqueue` helper + `<medium>Drain` script
  # + per-medium spool + service/path/timer triplet, and append the
  # enqueue call to `sendAlert` / `sendLog` below.

  telegramSpool = "/var/spool/alert-telegram-outbox";

  # Per-medium enqueue: severity-aware (maps to this medium's channel),
  # atomic write (mktemp+rename), no network required. File format:
  #   line 1: unix timestamp (event time, not delivery time)
  #   line 2: chat id (medium-specific routing key)
  #   line 3+: body (may contain newlines)
  # Filename: <ts>-<nonce>.msg — ts prefix makes lexicographic sort
  # equivalent to chronological sort.
  telegramEnqueue = pkgs.writeShellScript "alert-telegram-enqueue" ''
    set -eu
    SEV="$1"      # alert | log
    shift
    TEXT="$*"
    case "$SEV" in
      alert) CHAT_ID_FILE=${cfg.alertsChatIdFile} ;;
      log)   CHAT_ID_FILE=${cfg.logChatIdFile} ;;
      *) echo "alert-telegram-enqueue: unknown severity '$SEV'" >&2; exit 1 ;;
    esac
    TS=$(${pkgs.coreutils}/bin/date +%s)
    # 2>/dev/null on tr: head -c 8 closes the pipe which sends SIGPIPE to
    # tr; without stderr suppression that writes a cosmetic "tr: write
    # error: Broken pipe" to the journal even though the script works.
    NONCE=$(${pkgs.coreutils}/bin/tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | ${pkgs.coreutils}/bin/head -c 8)
    CHAT_ID=$(${pkgs.coreutils}/bin/cat "$CHAT_ID_FILE" 2>/dev/null || true)
    if [ -z "$CHAT_ID" ]; then
      echo "alert-telegram-enqueue: no chat id from $CHAT_ID_FILE" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/mkdir -p "${telegramSpool}"
    TMP=$(${pkgs.coreutils}/bin/mktemp -p "${telegramSpool}" ".tmp.XXXXXX")
    # mktemp creates 0600; relax to 0644 — queue content is no more
    # sensitive than the journal (chat ids + event descriptions).
    ${pkgs.coreutils}/bin/chmod 0644 "$TMP"
    {
      ${pkgs.coreutils}/bin/printf '%s\n' "$TS"
      ${pkgs.coreutils}/bin/printf '%s\n' "$CHAT_ID"
      ${pkgs.coreutils}/bin/printf '%s' "$TEXT"
    } > "$TMP"
    ${pkgs.coreutils}/bin/mv "$TMP" "${telegramSpool}/$TS-$NONCE.msg"
  '';

  # Media-agnostic entry points. Every call fans out to every configured
  # medium's enqueue. Callers just pick severity (alert vs log). Currently
  # only the telegram medium is hooked in; add more lines when media are added.
  sendAlert = pkgs.writeShellScript "send-alert" ''
    ${telegramEnqueue} alert "$@" || true
    # ${"$"}{emailEnqueue} alert "$@" || true     # when configured
  '';

  sendLog = pkgs.writeShellScript "send-log" ''
    ${telegramEnqueue} log "$@" || true
    # ${"$"}{emailEnqueue} log "$@" || true       # when configured
  '';

  # Drain: process spool oldest-first, send to Telegram, delete on success.
  # On any send failure we break out (don't burn retries on a likely-down
  # network) and exit non-zero so systemd treats the run as failed — the
  # timer will re-fire in 30s. Crash-resilient locking via flock on fd 9:
  # if the drain dies mid-flight (signal, panic, whatever) the kernel
  # releases the lock automatically — unlike a .lock marker file which
  # would wedge future drains until manual cleanup.
  telegramDrain = pkgs.writeShellScript "alert-telegram-outbox-drain" ''
    set -u
    DIR="${telegramSpool}"
    LOCK="$DIR/.drain.lock"

    ${pkgs.coreutils}/bin/mkdir -p "$DIR"

    # Exclusive flock on fd 9. -n: bail if another drain is active;
    # Path/Timer will fire another attempt shortly.
    exec 9>>"$LOCK"
    ${pkgs.util-linux}/bin/flock -n 9 || { echo "drain: busy, skipping" >&2; exit 0; }

    TOKEN=$(${pkgs.coreutils}/bin/cat ${cfg.tokenFile} 2>/dev/null || true)
    if [ -z "$TOKEN" ]; then
      echo "drain: no bot token — aborting" >&2
      exit 1
    fi

    # Purge messages older than 7 days — historical at this point.
    ${pkgs.findutils}/bin/find "$DIR" -maxdepth 1 -name '*.msg' -mtime +7 -delete 2>/dev/null || true

    # Cap queue at 1000 files. Drop oldest beyond that.
    count=$(${pkgs.coreutils}/bin/ls -1 "$DIR"/*.msg 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo 0)
    if [ "$count" -gt 1000 ]; then
      excess=$((count - 1000))
      ${pkgs.coreutils}/bin/ls -1 "$DIR"/*.msg | ${pkgs.coreutils}/bin/head -n "$excess" | ${pkgs.findutils}/bin/xargs -r rm -f
    fi

    rc=0
    for msg in $(${pkgs.coreutils}/bin/ls -1 "$DIR"/*.msg 2>/dev/null || true); do
      [ -f "$msg" ] || continue

      ts=$(${pkgs.coreutils}/bin/head -n 1 "$msg")
      chat=$(${pkgs.gnused}/bin/sed -n '2p' "$msg")
      text=$(${pkgs.coreutils}/bin/tail -n +3 "$msg")

      # Stale-message decoration: if the event is older than 60s at
      # delivery time, prepend queued-ago so the reader sees event time,
      # not delivery time.
      now=$(${pkgs.coreutils}/bin/date +%s)
      age=$((now - ts))
      if [ "$age" -gt 60 ]; then
        if [ "$age" -ge 86400 ]; then
          dur="$((age / 86400))d $((age / 3600 % 24))h"
        elif [ "$age" -ge 3600 ]; then
          dur="$((age / 3600))h $((age / 60 % 60))m"
        else
          dur="$((age / 60))m"
        fi
        text="⏱ queued $dur ago — $text"
      fi

      # --data-urlencode so message text can contain any chars without
      # breaking the curl command line.
      if ${pkgs.curl}/bin/curl -sf --max-time 10 -X POST \
          "https://api.telegram.org/bot$TOKEN/sendMessage" \
          --data-urlencode "chat_id=$chat" \
          --data-urlencode "text=$text" \
          -d "parse_mode=HTML" >/dev/null 2>&1; then
        ${pkgs.coreutils}/bin/rm -f "$msg"
        # Per-chat rate limit: ~1 msg/sec. Sleep 1.1s/send to stay safe
        # even if all queued messages target the same chat.
        ${pkgs.coreutils}/bin/sleep 1.1
      else
        echo "drain: send failed for $(${pkgs.coreutils}/bin/basename "$msg") — leaving for retry" >&2
        rc=1
        break
      fi
    done

    exit $rc
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

  # Build a config-switch notification and enqueue it.
  # The old implementation sent a basic message, fetched GitHub details,
  # and edited the message in place — which couldn't work with the outbox
  # (no message_id until delivery). New approach: fetch everything up-front
  # (best-effort, ~10s worst case per GitHub lookup), compose one final
  # message, hand it to the outbox. GitHub being unreachable at enqueue
  # time just means the message says "details unavailable"; no retry
  # dance, no in-place edits.
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

    PREV_CFG_SHORT="''${PREV_CFG_REV:+$(echo "$PREV_CFG_REV" | ${pkgs.coreutils}/bin/cut -c1-7)}"
    NEW_CFG_SHORT="''${NEW_CFG_REV:+$(echo "$NEW_CFG_REV" | ${pkgs.coreutils}/bin/cut -c1-7)}"
    PREV_LABEL="''${PREV_CFG_SHORT:-n/a} $PREV_STORE"
    NEW_LABEL="''${NEW_CFG_SHORT:-n/a} $NEW_STORE"

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

    if [ -z "$PREV_NIXPKGS_REV" ] || [ -z "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_CHANGED="n/a"
    elif [ "$PREV_NIXPKGS_REV" = "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_CHANGED="unchanged"
    else
      NIXPKGS_CHANGED="updated"
    fi

    # Build final message body. Uses newlines (not %0A) since enqueue
    # preserves newlines; Telegram parses them as-is.
    MSG="🔄 <b>$HOST</b>: config switched"$'\n'"<code>$PREV_LABEL</code> → <code>$NEW_LABEL</code>"

    if [ -n "$CFG_INFO" ]; then
      MSG="$MSG"$'\n\n'"⚙️ Config: <code>$CFG_INFO</code>"
    elif [ -n "$NEW_CFG_SHORT" ]; then
      MSG="$MSG"$'\n\n'"⚙️ Config: <code>$NEW_CFG_SHORT</code> (details unavailable)"
    else
      MSG="$MSG"$'\n\n'"⚙️ Config: n/a"
    fi

    if [ -n "$NIXPKGS_INFO" ]; then
      MSG="$MSG"$'\n'"📦 Nixpkgs ($NIXPKGS_CHANGED): <code>$NIXPKGS_INFO</code>"
    elif [ -n "$NEW_NIXPKGS_REV" ]; then
      NIXPKGS_SHORT=$(echo "$NEW_NIXPKGS_REV" | ${pkgs.coreutils}/bin/cut -c1-7)
      MSG="$MSG"$'\n'"📦 Nixpkgs ($NIXPKGS_CHANGED): <code>$NIXPKGS_SHORT</code>"
    else
      MSG="$MSG"$'\n'"📦 Nixpkgs: n/a"
    fi

    ${sendLog} "$MSG"
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

  # Custom notification script for netdata. Routes by $NETDATA_ALARM_ROLE
  # through the media-agnostic sendLog/sendAlert so rate limits and the
  # outbox fan-out work identically to every other notify in this module.
  notifyScript = pkgs.writeShellScript "netdata-telegram-notify" ''
    # Netdata passes alarm info via environment variables:
    # $NETDATA_ALARM_STATUS (CRITICAL, WARNING, CLEAR)
    # $NETDATA_ALARM_NAME, $NETDATA_ALARM_CHART, $NETDATA_ALARM_INFO
    # $NETDATA_ALARM_ROLE

    HOST=$(${pkgs.hostname}/bin/hostname)
    MSG="<b>$HOST [$NETDATA_ALARM_STATUS]</b> $NETDATA_ALARM_NAME
$NETDATA_ALARM_INFO
Chart: $NETDATA_ALARM_CHART"

    case "$NETDATA_ALARM_ROLE" in
      log) ${sendLog} "$MSG" ;;
      *)   ${sendAlert} "$MSG" ;;
    esac
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

    # ── Telegram outbox: spool + drain service/path/timer ──────────────
    #
    # Every notify in this module enqueues into this per-medium spool via
    # `sendAlert` / `sendLog` (which fan out over all configured media).
    # This drainer handles Telegram delivery specifically. When more media
    # are added (email, Pushover, etc.), each gets its own parallel set
    # of units named alert-<medium>-outbox-* so queues don't collide.
    #
    # Spool is world-readable (0755 dir, 0644 files) — content is no
    # more sensitive than the journal (chat ids + event descriptions,
    # no secrets). Writes are root-only.
    systemd.tmpfiles.rules = [
      "d ${telegramSpool} 0755 root root -"
    ];

    systemd.services.alert-telegram-outbox-drain = {
      description = "Deliver pending Telegram alerts from the outbox";
      # No After=network-online.target — drain tolerates network-down by
      # failing (systemd re-runs per timer). Boot never waits for this.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = telegramDrain;
      };
    };

    systemd.paths.alert-telegram-outbox-drain = {
      description = "Fire drain when a message lands in the Telegram outbox";
      wantedBy = [ "multi-user.target" ];
      # PathChanged fires on CLOSE_WRITE in the directory. enqueue's
      # mktemp+rename triggers a CLOSE_WRITE on the final .msg file.
      pathConfig.PathChanged = telegramSpool;
    };

    systemd.timers.alert-telegram-outbox-drain = {
      description = "Periodic retry drain (covers downtime past Path events)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };

    # Boot notification → log channel.
    #
    # Dedupe by /proc/sys/kernel/random/boot_id — a UUID the kernel assigns
    # at boot. Stamp file in /run (tmpfs, cleared on reboot) remembers which
    # boot we've already notified about. This replaces the earlier "uptime
    # < 5 min" heuristic which misfired on switch-to-configuration within
    # the first 5 min of boot: Type=oneshot without RemainAfterExit goes
    # inactive after each run, so wantedBy=multi-user.target re-triggers it
    # on every switch, and if uptime was still < 300s the guard passed.
    #
    # Also emits a persistent sequence number so gaps in the Telegram log
    # are visible at a glance — if you see "#100" then "#103", two boots
    # were missed entirely (we enqueue unconditionally; a persistent
    # counter that ticks in a proper early-boot unit is the next step).
    # StateDirectory creates /var/lib/boot-notify.
    systemd.services.boot-notify = {
      description = "Enqueue Telegram boot notification";
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "boot-notify";
        ExecStart = pkgs.writeShellScript "boot-notify" ''
          BOOT_ID=$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/random/boot_id)
          STAMP=/run/boot-notify.stamp
          if [ -f "$STAMP" ] && [ "$(${pkgs.coreutils}/bin/cat "$STAMP" 2>/dev/null)" = "$BOOT_ID" ]; then
            exit 0
          fi

          COUNTER=/var/lib/boot-notify/counter
          COUNT=$(${pkgs.coreutils}/bin/cat "$COUNTER" 2>/dev/null || ${pkgs.coreutils}/bin/echo 0)
          COUNT=$((COUNT + 1))
          ${pkgs.coreutils}/bin/echo "$COUNT" > "$COUNTER"
          ${pkgs.coreutils}/bin/echo "$BOOT_ID" > "$STAMP"

          UPTIME_S=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.coreutils}/bin/cut -d. -f1)
          HOST=$(${pkgs.hostname}/bin/hostname)
          KERNEL=$(${pkgs.coreutils}/bin/uname -r)
          UPTIME=$(${formatUptime} "$UPTIME_S")
          ${sendLog} "🟢 <b>$HOST</b> booted #$COUNT
Kernel: $KERNEL
Uptime: $UPTIME"
        '';
      };
    };

    # Shutdown notification → log channel.
    # Runs on graceful shutdown/reboot via ExecStop. Enqueues the message
    # AND forces a synchronous drain (bounded by timeout) so delivery
    # happens before shutdown continues rather than "on next boot".
    #
    # Ordering: After=network.target means we start AFTER network at boot,
    # and during shutdown systemd stops units in REVERSE order — so our
    # ExecStop runs BEFORE network.target stops, i.e., network is still up
    # for the drain call. If drain times out anyway (e.g., Wi-Fi AP gone),
    # the message stays in the spool and delivers on next boot with an
    # automatic "⏱ queued Xm ago" prefix.
    systemd.services.shutdown-notify = {
      description = "Enqueue + force-drain Telegram shutdown notification";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
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
          ${sendLog} "🔴 <b>$HOST</b> shutting down
Uptime: $UPTIME"
          # Force synchronous drain — bounded by timeout so we don't hold
          # up shutdown on a dead network. If it fails, message remains in
          # spool and delivers on next boot with "queued ago" decoration.
          ${pkgs.coreutils}/bin/timeout 10 ${telegramDrain} || true
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
      after = [ "multi-user.target" ];
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
            ${sendAlert} "💥 <b>$HOST</b>: previous boot ended abruptly (no shutdown marker). Streak of $STREAK unclean boots back — suspect power / USB-peripheral / hardware.
Last failing boot ended with:
<pre>$LAST_UNCLEAN_TAIL</pre>"
          else
            ${sendAlert} "⚠️ <b>$HOST</b>: previous boot ended abruptly (no shutdown marker). Isolated event — worth noting only if it recurs.
Last failing boot ended with:
<pre>$LAST_UNCLEAN_TAIL</pre>"
          fi

          # Separately: genuine kernel panics in the immediately previous
          # boot. Narrow patterns only — don't alert on userspace noise.
          PANIC=$("$JCTL" -b -1 -k --no-pager -q 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -E 'Oops|Kernel panic|BUG:|stack-protector|end Kernel panic|unable to handle kernel' \
            | ${pkgs.coreutils}/bin/head -5)
          if [ -n "$PANIC" ]; then
            ${sendAlert} "☠️ <b>$HOST</b>: kernel panic/oops in previous boot:
<pre>$PANIC</pre>"
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
          ${sendAlert} "❌ <b>$HOST</b>: NixOS upgrade FAILED
<pre>$LOG</pre>"
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
      after = [ "multi-user.target" ];
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

    # SSH login notifications — follows journal, enqueues on each event.
    systemd.services.ssh-login-notify = {
      description = "Notify Telegram on SSH logins";
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
