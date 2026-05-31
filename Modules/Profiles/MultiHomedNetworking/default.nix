{ config, lib, pkgs, ... }:
#
# MultiHomedNetworking profile — ARP / source-routing / mDNS bundle
# for hosts sitting on multiple interfaces over the same L2 segment
# (a typical home setup: Pi with Ethernet + WiFi, both bridged on the
# AP). Without this bundle the kernel happily lets either interface
# answer ARP for the other's IP, and the AP then drops the resulting
# MAC-IP-mismatched replies — observed empirically on the
# PrintScanServerPi4 box, fixed by the rules this profile installs.
#
# What it sets:
#   * Per-interface arp_ignore=1 / arp_announce=2 sysctls — strict
#     L2 identity. Each interface only ARPs its own subnet identity.
#   * iptables CONNMARK + per-interface fwmark (mangle PREROUTING /
#     OUTPUT) so reply traffic egresses the same interface the
#     request arrived on, regardless of the main routing table's
#     metric ordering.
#   * One systemd-networkd network unit per interface with its own
#     dhcp-installed default route in a per-interface routing
#     table, plus a routing-policy rule keying that table off the
#     fwmark.
#   * Avahi for cross-interface mDNS (with the AvahiPerInterfaceNames
#     module enabled so each interface publishes its own
#     `host-iface.local`, sidestepping Avahi's default same-name-on-
#     all-interfaces self-conflict on bridged segments).
#   * systemd-resolved as the local stub-resolver, with MulticastDNS=no
#     so it doesn't fight Avahi for :5353.
#
# What it does NOT do:
#   * Wireless (wpa_supplicant). Per-machine — the network details
#     vary per box.
#   * Specific DNS servers, hostnames, search domains — DHCP feeds
#     resolved.
#
# The default `interfaces` list matches the Raspberry Pi 4 / Pi 5
# convention when running on nvmd's vendor kernel (`linuxPackages_
# rpi{4,5}`): `end0` for Ethernet, `wld0` for WiFi. The vendor
# kernel + udev predictable-naming combo registers the brcmfmac
# interface as `wlan0` at the driver layer and then renames it to
# `wld0` before any service sees it (dmesg shows
# `brcmfmac …: renamed from wlan0`). Override on x86 hosts with the
# usual `enpXsY` / `wlpXsY` predictable names.
#
let
  cfg = config.hypersw.profiles.multiHomedNetworking;
in
{
  # No `imports` here — `Modules/default.nix` (the module-list)
  # loads AvahiPerInterfaceNames centrally. See `Modules/default.nix`
  # for the rationale.

  options.hypersw.profiles.multiHomedNetworking = {
    enable = lib.mkEnableOption "Multi-homed source-routing + mDNS bundle";

    interfaces = lib.mkOption {
      description = ''
        Per-interface routing/marking config. Order matters: the
        first interface gets the lowest route metric and is the
        kernel's preferred egress for Pi-originated outbound
        connections (which carry no fwmark and fall through to
        the main table). Subsequent interfaces get higher metrics.

        The default matches the Raspberry Pi 4/5 hardware naming;
        x86 hosts typically need to override with the predictable
        names from systemd-networkd (`enpXsY` for Ethernet,
        `wlpXsY` for WiFi).
      '';
      default = [
        { name = "end0"; fwmark = 100; routingTable = 100; routeMetric = 1002; requiredForOnline = true;  }
        { name = "wld0"; fwmark = 200; routingTable = 200; routeMetric = 3003; requiredForOnline = false; }
      ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Linux interface name (must match systemd-networkd predictable name).";
          };
          fwmark = lib.mkOption {
            type = lib.types.int;
            description = ''
              iptables fwmark to tag packets arriving on this
              interface. CONNMARK persists the mark on the
              conntrack entry so reply packets get it back via
              the OUTPUT chain's `--restore-mark`.
            '';
          };
          routingTable = lib.mkOption {
            type = lib.types.int;
            description = ''
              Custom routing-table id for this interface's egress
              path. The networkd config installs the
              DHCP-discovered default route into this table; the
              fwmark-keyed routing-policy rule directs marked
              packets to it.
            '';
          };
          routeMetric = lib.mkOption {
            type = lib.types.int;
            description = ''
              Metric for this interface's default route in the
              main table — used by Pi-originated unmarked
              outbound traffic. Lower wins; gap each interface's
              metric by ≥3× to prevent any tie-breaker from
              equalising them.
            '';
          };
          requiredForOnline = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Whether this interface must come up before the
              network-online.target. Set false on optional
              interfaces (typically WiFi when Ethernet is the
              primary path).
            '';
          };
        };
      });
    };

    firewall = {
      allowedTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [ 22 ];
        description = "TCP ports the host firewall accepts.";
      };
      allowedUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [ 5353 ];
        description = "UDP ports the host firewall accepts (mDNS by default).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = (builtins.length cfg.interfaces) >= 1;
      message = "hypersw.profiles.multiHomedNetworking requires at least one interface.";
    }];

    # ── ARP behaviour: strict per-interface L2 identity ────────────
    # Default (arp_ignore=0) lets every interface answer ARP for
    # every locally-bound IP — broken on multi-NIC same-subnet
    # hosts because the AP's MAC-IP filter then drops the asym
    # replies. arp_ignore=1 + arp_announce=2 enforces the strict
    # identity needed for the CONNMARK source-routing scheme.
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.arp_ignore"     = 1;
      "net.ipv4.conf.all.arp_announce"   = 2;
      "net.ipv4.conf.default.arp_ignore"   = 1;
      "net.ipv4.conf.default.arp_announce" = 2;
    };

    # ── networking stack: networkd, no global DHCP ─────────────────
    networking = {
      useNetworkd = true;
      useDHCP = false;          # per-interface via systemd.network below
      dhcpcd.enable = false;    # networkd has its own DHCP client

      firewall = {
        enable = true;
        allowedTCPPorts = cfg.firewall.allowedTCPPorts;
        allowedUDPPorts = cfg.firewall.allowedUDPPorts;

        # iptables CONNMARK source routing. PREROUTING tags every
        # incoming packet with a per-interface nfmark; CONNMARK
        # persists it onto the conntrack entry; OUTPUT restores it
        # on locally-generated reply packets so the kernel's output-
        # reroute hits our fwmark policy rule and egresses the same
        # interface the request arrived on.
        #
        # The PREROUTING rules MUST be at the top of the chain
        # (-I PREROUTING N) before nixos-fw-rpfilter, otherwise
        # rpfilter evaluates before the mark is set and drops.
        extraCommands = lib.concatStringsSep "\n" (
          (lib.imap1 (i: iface: ''
            iptables -t mangle -I PREROUTING ${toString i} -i ${iface.name} -j MARK --set-mark ${toString iface.fwmark}
          '') cfg.interfaces)
          ++ [
            ''iptables -t mangle -I PREROUTING ${toString (1 + builtins.length cfg.interfaces)} -j CONNMARK --save-mark''
            ''iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark''
          ]);

        extraStopCommands = lib.concatStringsSep "\n" (
          (map (iface: ''
            iptables -t mangle -D PREROUTING -i ${iface.name} -j MARK --set-mark ${toString iface.fwmark} 2>/dev/null || true
          '') cfg.interfaces)
          ++ [
            ''iptables -t mangle -D PREROUTING -j CONNMARK --save-mark 2>/dev/null || true''
            ''iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true''
          ]);
      };
    };

    # ── per-interface networkd config ───────────────────────────────
    systemd.network = {
      # network-online.target is too easy to depend on accidentally;
      # we explicitly want services to start as fast as the local
      # machine is up regardless of WiFi/Ethernet state. Anything
      # that genuinely needs network-online.target should request it
      # itself with explicit retry handling.
      wait-online.enable = false;

      networks = lib.listToAttrs (map (iface: lib.nameValuePair "20-${iface.name}" {
        matchConfig.Name = iface.name;
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = "yes";
        };
        dhcpV4Config.RouteMetric = iface.routeMetric;
        ipv6AcceptRAConfig.RouteMetric = iface.routeMetric;
        # Install a per-interface default route in the dedicated
        # table — the policy-routing rule below directs the
        # interface's marked egress traffic to it. _dhcp4 picks
        # the gateway up from DHCP at lease time.
        routes = [
          { Destination = "0.0.0.0/0"; Gateway = "_dhcp4"; Table = iface.routingTable; }
        ];
        routingPolicyRules = [
          { FirewallMark = iface.fwmark; Table = iface.routingTable; }
        ];
        linkConfig = lib.mkIf (!iface.requiredForOnline) {
          RequiredForOnline = "no";
        };
      }) cfg.interfaces);
    };

    # ── mDNS via Avahi (not resolved) ──────────────────────────────
    # resolved's per-link mDNS scopes don't coordinate across
    # interfaces, which on a bridged L2 looks the same as Avahi's
    # default single-name publish — both self-conflict. We leave
    # mDNS to Avahi (which the AvahiPerInterfaceNames module
    # extends with per-interface naming) and tell resolved to keep
    # off :5353.
    services.resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = "no";
    };
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish.enable = true;
    };
    hypersw.services.avahi-per-interface-names.enable = true;
  };
}
