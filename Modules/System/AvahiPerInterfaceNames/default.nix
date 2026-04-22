{ config, lib, pkgs, ... }:

# ──────────────────────────────────────────────────────────────────────────────
# Per-interface mDNS hostnames.
#
# Why this module exists
# ──────────────────────
# Avahi (and systemd-resolved) publish a single hostname on all mDNS-enabled
# interfaces. When a host has multiple interfaces on the same L2 segment —
# most commonly eth + Wi-Fi bridged by the same AP — each interface announces
# `<host>.local` with its own IP. The bridge loops each announcement back to
# the other interface, which sees "another device claiming my name with a
# different IP", triggers RFC 6762 conflict resolution, and renames itself
# to `<host>7.local`, `<host>11.local`, `<host>190.local`, … whereupon
# `<host>.local` is unreachable from anywhere on the LAN. See upstream
# systemd issues #28491, #23910, and Avahi's long-standing lack of
# cross-interface self-detection. Observed on this host 2026-04-22.
#
# What it does
# ────────────
# Instead of publishing one name on N interfaces (which conflicts), this
# publishes N different names — one per interface — via Avahi's static-
# hosts file (/etc/avahi/hosts). Each entry is a name→IP mapping that
# Avahi announces only on interfaces where the target IP is locally
# assigned. Different names for different interfaces means cross-bridge
# echoes are not treated as conflicts.
#
# Names look like <hostname>-<suffix>.local, where the suffix is derived
# from the interface name:
#   end0, eth0, enp0s1  → eth   → e.g. printscan-eth.local
#   wlan0, wlp2s0       → wifi  → e.g. printscan-wifi.local
#   usb0                → usb   → e.g. printscan-usb.local
#   anything else       → the interface name itself
#
# A companion systemd service watches `ip monitor address` for netlink
# events and regenerates /run/avahi-per-interface-names/hosts whenever an
# interface gains or loses an address. A SIGHUP to avahi-daemon reloads
# the file (no service restart, no mDNS blackout).
#
# Client side
# ───────────
# Clients use `ssh -o HostName=<host>-eth.local` or an ssh_config Match-
# exec rule to probe Ethernet first and fall back to Wi-Fi:
#
#   Match host=<alias> exec "ping -c1 -W1 <host>-eth.local >/dev/null 2>&1"
#       HostName <host>-eth.local
#   Match host=<alias>
#       HostName <host>-wifi.local
#
# Nothing about this module is Pi- or PrintScanServer-specific. Any
# multi-NIC host on a bridged L2 segment hits the same problem and can
# use this module.
# ──────────────────────────────────────────────────────────────────────────────

let
  cfg = config.services.avahi-per-interface-names;

  # Runtime path — watcher writes here, /etc/avahi/hosts is a symlink to it.
  hostsPath = "/run/avahi-per-interface-names/hosts";

  watcherScript = pkgs.writeShellScript "avahi-per-interface-names-watcher" ''
    set -u

    F=${hostsPath}

    # Derive a short, human-friendly suffix from the interface name.
    # Predictable-interface-name convention groups Ethernet under en*/eth*
    # and Wi-Fi under wl*; older kernels still use eth0/wlan0.
    name_for() {
      case "$1" in
        en*|eth*|end*) echo eth ;;
        wl*)           echo wifi ;;
        usb*)          echo usb ;;
        *)             echo "$1" ;;
      esac
    }

    host=$(${pkgs.nettools}/bin/hostname)

    regen() {
      local tmp="$F.new"

      # `scope global` excludes loopback 127.0.0.1, IPv4 link-local
      # 169.254.x.y, and IPv6 link-local fe80::/10 — leaves only
      # addresses we'd actually want to advertise. `ip -br` gives
      # one line per link with all its addresses whitespace-separated.
      #
      # Output is piped through `sort` so byte-identical content across
      # runs produces a byte-identical file, even if the kernel reorders
      # interfaces after a link up/down event. Without this, netlink
      # storm during boot would cause spurious diff-detected changes and
      # needless SIGHUPs to avahi.
      ${pkgs.iproute2}/bin/ip -br addr show scope global 2>/dev/null \
        | while read -r iface _state addrs; do
          [ "$iface" = "lo" ] && continue
          [ -z "$addrs" ] && continue
          local suffix
          suffix=$(name_for "$iface")
          # addrs is whitespace-separated CIDR (e.g. "192.168.1.129/24").
          # Emit one A/AAAA-mapping line per address.
          for addr in $addrs; do
            echo "''${addr%/*}  $host-$suffix.local"
          done
        done \
        | ${pkgs.coreutils}/bin/sort > "$tmp"

      # Only update + HUP avahi if content actually changed. Netlink
      # delivers a torrent of events during boot; most don't affect us.
      if ! ${pkgs.diffutils}/bin/diff -q "$tmp" "$F" >/dev/null 2>&1; then
        ${pkgs.coreutils}/bin/mv "$tmp" "$F"
        echo "avahi-per-interface-names: /etc/avahi/hosts regenerated:"
        ${pkgs.gnused}/bin/sed 's/^/  /' "$F"
        # Reload avahi's static-hosts database. SIGHUP is the lightweight
        # path — re-reads /etc/avahi/hosts + /etc/avahi/services/ without
        # a full service restart, no mDNS blackout.
        if ${pkgs.systemd}/bin/systemctl is-active --quiet avahi-daemon.service; then
          ${pkgs.systemd}/bin/systemctl kill -s HUP avahi-daemon.service || true
        fi
      else
        ${pkgs.coreutils}/bin/rm -f "$tmp"
      fi
    }

    # Initial population before avahi starts — we're ordered Before=
    # avahi-daemon so the first file write completes before the daemon
    # opens the file.
    regen
    ${pkgs.systemd}/bin/systemd-notify --ready

    # Long-running: consume netlink address events, regen on any change.
    # `ip monitor address` is edge-triggered; each event is one line.
    ${pkgs.iproute2}/bin/ip monitor address | while read -r _; do
      regen
    done
  '';
in
{
  options.services.avahi-per-interface-names = {
    enable = lib.mkEnableOption ''
      per-interface mDNS hostnames.

      Publishes `<hostname>-<interface-suffix>.local` for every non-loopback
      interface with a global-scope address, instead of Avahi's default
      single `<hostname>.local`. Solves the self-conflict Avahi hits on
      hosts with multiple interfaces on the same L2 segment (eth+wifi
      bridged by the same AP). Requires `services.avahi.enable = true`.
    '';
  };

  config = lib.mkIf cfg.enable {
    # Don't publish the host's primary addresses under the plain hostname
    # — that's exactly the publication that conflicts across interfaces.
    # We publish per-interface-suffixed names via /etc/avahi/hosts instead.
    services.avahi = {
      publish.addresses = lib.mkForce false;
      publish.workstation = lib.mkForce false;
      publish.hinfo = lib.mkForce false;
    };

    # Symlink /etc/avahi/hosts → our runtime file. Avahi reads this file
    # on start and on SIGHUP (via its static_hosts_load()).
    environment.etc."avahi/hosts".source = hostsPath;

    systemd.services.avahi-per-interface-names-watcher = {
      description = "Publish per-interface mDNS hostnames via /etc/avahi/hosts";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-networkd.service" ];
      wants = [ "systemd-networkd.service" ];
      # Startup ordering is load-bearing:
      #   * /etc/avahi/hosts is a symlink into /run/..., created by NixOS
      #     activation (environment.etc.source). At boot the symlink exists
      #     from the start, but its target (our /run file) is absent until
      #     RuntimeDirectory+regen writes it.
      #   * Type=notify + `systemd-notify --ready` AFTER the initial regen
      #     means we only report READY once the file is in place.
      #   * Before= + requiredBy= make avahi-daemon Requires= us AND wait
      #     until we notify. So avahi never opens a broken symlink.
      #   * If we fail, Requires= propagates the failure — avahi stays
      #     down rather than running without its hosts file (mDNS dark
      #     but not misconfigured; fixable by healing the watcher).
      before = [ "avahi-daemon.service" ];
      requiredBy = [ "avahi-daemon.service" ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # `always` not `on-failure`: `ip monitor address` is supposed to
        # run forever, so any exit (including the clean exit 0 that
        # would happen if its pipe closes) is a failure mode for us.
        # systemd correctly distinguishes operator-initiated stops
        # (systemctl stop) from process exits and doesn't re-spawn on
        # the former, so this is safe.
        Restart = "always";
        RestartSec = "5s";
        RuntimeDirectory = "avahi-per-interface-names";
        RuntimeDirectoryMode = "0755";
        ExecStart = watcherScript;
      };
    };
  };
}
