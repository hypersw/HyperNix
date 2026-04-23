{ config, lib, pkgs, ... }:

# ──────────────────────────────────────────────────────────────────────────────
# Dynamic Avahi primary-interface tracker.
#
# Why this module exists
# ──────────────────────
# Avahi (like systemd-resolved) runs into a wall when a host has multiple
# interfaces on the same L2 segment — the classic eth+Wi-Fi bridged case:
# each interface announces the same name, the AP bridges the multicast
# between them, each interface sees a sibling's announcement as "another
# device claiming my name", runs RFC 6762 conflict resolution, and ends
# up renaming the host to `<name>-2.local` and upward. `<name>.local`
# becomes unreachable.
#
# Static per-interface names via /etc/avahi/hosts don't fix it either:
# Avahi's static-hosts publisher uses AVAHI_IF_UNSPEC, so every static
# entry is still broadcast on every interface. The self-reflection kicks
# in on the `<prefix>-eth.local` / `<prefix>-wifi.local` entries too.
#
# What it does
# ────────────
# Only publishes Avahi's main hostname on ONE interface at a time — the
# current primary default-route interface (usually end0 when up, wlan0
# otherwise). Implemented by:
#  - Running avahi-daemon with a runtime-generated config file that has
#    `allow-interfaces=<primary>` set to a single interface.
#  - A watcher that subscribes to `ip monitor route` and restarts
#    avahi-daemon whenever the primary interface changes (which is
#    rare — cable unplug / Wi-Fi failover etc).
#
# With single-interface publishing, cross-bridge self-reflection still
# happens (the bridge doesn't care what we allow); but since Avahi isn't
# PUBLISHING on the other interface, it doesn't have a registered claim
# for the name there. The remote-looking announcement from the "other"
# interface is just… an announcement, not a conflict.
#
# Startup blackout on interface swap
# ──────────────────────────────────
# Switching allow-interfaces requires a full avahi-daemon restart (SIGHUP
# doesn't pick up server-level options). That's a ~1-2s gap in mDNS
# availability. Interface transitions are rare (cable pull, Wi-Fi AP
# failure) so this is acceptable.
#
# Client side
# ───────────
# Clients continue to use the plain `<hostname>.local` — no per-interface
# SSH config needed. The mDNS record auto-follows whichever interface is
# primary, so the client sees one stable name.
# ──────────────────────────────────────────────────────────────────────────────

let
  cfg = config.services.avahi-per-interface-names;

  # Runtime directory for our generated avahi-daemon.conf.
  runDir = "/run/avahi-primary-interface";
  confFile = "${runDir}/avahi-daemon.conf";

  # Base config — everything except allow-interfaces, which is appended
  # at runtime by the watcher. Matches NixOS's own avahi module defaults
  # as closely as possible for anything that matters (publish, wide-area,
  # rlimits). Host name pulled from networking.hostName.
  baseConf = pkgs.writeText "avahi-daemon.conf.base" ''
    [server]
    host-name=${config.networking.hostName}
    browse-domains=
    use-ipv4=yes
    use-ipv6=yes
    allow-point-to-point=no

    [wide-area]
    enable-wide-area=yes

    [publish]
    disable-publishing=no
    disable-user-service-publishing=no
    publish-addresses=yes
    publish-hinfo=no
    publish-workstation=no
    publish-domain=yes

    [reflector]
    enable-reflector=no

    [rlimits]
    rlimit-core=0
    rlimit-data=4194304
    rlimit-fsize=0
    rlimit-nofile=768
    rlimit-stack=4194304
    rlimit-nproc=3
  '';

  watcherScript = pkgs.writeShellScript "avahi-primary-interface-watcher" ''
    set -u
    CONF=${confFile}

    # Write the conf with a given allow-interfaces value. Idempotent:
    # only diffs + rewrites if content changed, so repeat calls don't
    # rapid-restart avahi.
    write_conf() {
      local iface="$1"
      local tmp="$CONF.new"
      ${pkgs.gawk}/bin/awk -v primary="$iface" '
        /^\[server\]/ { print; print "allow-interfaces=" primary; next }
        { print }
      ' ${baseConf} > "$tmp"

      if ! ${pkgs.diffutils}/bin/diff -q "$tmp" "$CONF" >/dev/null 2>&1; then
        ${pkgs.coreutils}/bin/mv "$tmp" "$CONF"
        echo "avahi-primary-interface: allow-interfaces='$iface', conf regenerated"
        # Kick avahi. Treat `failed` like `active` — it may have crashed
        # earlier (e.g., tried to start before the initial conf was in
        # place). systemctl restart works for both states; is-enabled
        # gates us from trying on a disabled unit.
        if ${pkgs.systemd}/bin/systemctl is-enabled --quiet avahi-daemon.service; then
          ${pkgs.systemd}/bin/systemctl restart avahi-daemon.service &
        fi
      else
        ${pkgs.coreutils}/bin/rm -f "$tmp"
      fi
    }

    regen() {
      local primary
      # Determine the current primary default-route interface. With our
      # DHCP metrics pinned (end0=1002, wlan0=3003), `head -1` gives us
      # the winner — lowest-metric first.
      primary=$(${pkgs.iproute2}/bin/ip -4 route show default 2>/dev/null \
        | ${pkgs.coreutils}/bin/head -n1 \
        | ${pkgs.gawk}/bin/awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
      if [ -z "$primary" ]; then
        # No default route yet (early boot, before DHCP). Write a safe
        # placeholder: allow-interfaces=lo restricts Avahi to loopback,
        # which means no real mDNS announcements — but crucially, the
        # conf file exists so avahi-daemon can start without error.
        # When the real default route arrives, netlink wakes us up and
        # we regenerate with the actual primary interface.
        echo "avahi-primary-interface: no default route yet, writing placeholder (allow-interfaces=lo)"
        write_conf "lo"
        return
      fi
      write_conf "$primary"
    }

    regen
    ${pkgs.systemd}/bin/systemd-notify --ready

    # React to default-route changes via netlink. `ip monitor route`
    # fires on add/remove/change of any route; regen() is idempotent
    # when the primary hasn't actually changed.
    ${pkgs.iproute2}/bin/ip monitor route | while read -r _; do
      regen
    done
  '';
in
{
  options.services.avahi-per-interface-names = {
    enable = lib.mkEnableOption ''
      dynamic Avahi primary-interface tracker.

      Avahi publishes on ONE interface at a time — the current primary
      default-route interface. Watcher swaps it when the default route
      moves (e.g., Ethernet carrier dropped → Wi-Fi becomes primary).
      Restart-cost is ~1-2s of mDNS unavailability on each transition.

      Solves the self-conflict hosts with multiple interfaces on the
      same L2 segment hit with Avahi / systemd-resolved: by publishing
      on only one interface, cross-interface reflections don't look
      like conflicts because the other interface doesn't have a
      registered claim for the name. Requires `services.avahi.enable`.
    '';
  };

  config = lib.mkIf cfg.enable {
    services.avahi = {
      # Make sure Avahi is up with the standard publishing behaviour —
      # single hostname, A+AAAA records. Single-interface publishing
      # (enforced by our dynamic allow-interfaces) means this doesn't
      # self-conflict.
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = lib.mkForce true;
        workstation = lib.mkForce false;
        hinfo = lib.mkForce false;
      };
    };

    # Override ExecStart to point avahi at our runtime-generated conf.
    # The NixOS-generated /etc/avahi/avahi-daemon.conf is still there
    # but ignored — avahi reads what `-f` points to.
    systemd.services.avahi-daemon = {
      serviceConfig.ExecStart = lib.mkForce
        "${config.services.avahi.package}/sbin/avahi-daemon --syslog -f ${confFile}";
      # Wait for the watcher's READY (which fires only after the
      # initial regen writes the conf). Without this ordering, avahi
      # would race the watcher and could try to open a non-existent
      # file on cold boot.
      after = [ "avahi-primary-interface-watcher.service" ];
      requires = [ "avahi-primary-interface-watcher.service" ];
    };

    systemd.services.avahi-primary-interface-watcher = {
      description = "Track primary default-route interface, update avahi allow-interfaces";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-networkd.service" ];
      wants = [ "systemd-networkd.service" ];
      before = [ "avahi-daemon.service" ];
      serviceConfig = {
        WorkingDirectory = "/var/empty";  # safe CWD — see Modules/PrintersScanners/Daemon/default.nix
        Type = "notify";
        NotifyAccess = "all";
        # `always` not `on-failure`: `ip monitor route` running forever
        # means any exit is a failure mode, including clean exit 0
        # when its pipe closes. systemd distinguishes operator stops
        # from process exits, so we don't respawn on `systemctl stop`.
        Restart = "always";
        RestartSec = "5s";
        RuntimeDirectory = "avahi-primary-interface";
        RuntimeDirectoryMode = "0755";
        ExecStart = watcherScript;
      };
    };
  };
}
