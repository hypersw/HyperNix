{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.services.laserjet-printer;
in
{
  options.hypersw.services.laserjet-printer = {
    enable = lib.mkEnableOption "HP LaserJet P2015n USB printing via CUPS + foo2zjs";

    serial = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "00CNBW79SBWW";
      description = ''
        Optional USB serial-number pin. Default <literal>null</literal>
        binds the queue by model only — any HP LaserJet P2015 (or
        P2015n) connected via USB on this host matches and prints
        through this queue. That's the right shape for a single-
        printer host: zero per-device setup, just plug it in.
        Set this to the printer's specific serial (e.g. from
        <command>lpinfo -v</command>: the <literal>serial=…</literal>
        parameter on the discovered URI, or
        <filename>/sys/bus/usb/devices/&lt;id&gt;/serial</filename>)
        only when more than one identical printer is attached to
        the same host and you need to pin the queue to one of
        them. Either way the binding is USB-port-independent —
        replug, hub-reordering, and USB renumbering all keep the
        queue working.
      '';
    };

    queueName = lib.mkOption {
      type = lib.types.str;
      default = "HP_LaserJet_P2015n";
      description = ''
        CUPS queue name. Appears in <command>lpstat -p</command>,
        <command>lp -d &lt;name&gt;</command>, and the mDNS service
        advertisement. Defaults to the model designation; use
        underscores rather than spaces (CUPS / IPP queue names
        forbid whitespace).
      '';
    };

    setAsDefault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this queue should be the system default
        destination (the one <command>lp</command> uses with no
        <literal>-d</literal>, and that <command>lpstat -d</command>
        reports). The printscan-daemon's CUPS backend defaults to
        the system default destination when its
        <option>printerName</option> option is null — keep this
        <literal>true</literal> on a single-printer host so the
        daemon works without an explicit queue pin.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.printing = {
      enable = true;
      drivers = [ pkgs.foo2zjs ];
      listenAddresses = [ "*:631" ];
      allowFrom = [ "all" ];
      browsing = true;
      defaultShared = true;
    };

    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    boot.blacklistedKernelModules = [ "usblp" ];
    networking.firewall.allowedTCPPorts = [ 631 ];

    # Tell the print-scan daemon which USB device represents this
    # printer so its /status endpoint can report offline when the
    # device disappears (powered off, unplugged) — `lpstat -p` alone
    # only knows about the queue's enabled/disabled state, not the
    # device-link state. 03f0:3817 is HP / "LaserJet P2015 Series"
    # (the same product string used in the deviceUri above; vendor
    # 03f0 is Hewlett-Packard's IEEE assignment). Set with mkDefault
    # so a host with multiple printers can extend the list:
    #   hypersw.services.printscan-daemon.printerUsbIds =
    #     lib.mkForce "03f0:3817,XXXX:YYYY";
    hypersw.services.printscan-daemon.printerUsbIds = lib.mkDefault "03f0:3817";

    # Declarative CUPS queue. Bound to the physical printer by
    # USB model (manufacturer-reported product string) — and
    # optionally pinned to a specific serial when more than one
    # identical printer is on the same host. Either way the
    # binding is port-independent: replug, hub reorder, or USB
    # bus renumber on reboot — same queue keeps working, no
    # operator action. Activation runs `lpadmin -p <name> -E -v
    # <uri> -m <ppd>` via the standard `hardware.printers.
    # ensurePrinters` machinery and the queue persists in
    # /var/lib/cups/printers.conf.
    hardware.printers = {
      ensureDefaultPrinter = lib.mkIf cfg.setAsDefault cfg.queueName;
      ensurePrinters = [{
        name = cfg.queueName;
        location = "USB-attached on ${config.networking.hostName}";
        # `usb://<MFG>/<MODEL>` matches any P2015-class printer
        # attached over USB; appending `?serial=…` narrows to one
        # specific physical device. The model line ("HP/LaserJet
        # P2015 Series") is the manufacturer-reported USB product
        # string; %20-escaped because URIs.
        deviceUri = "usb://HP/LaserJet%20P2015%20Series"
          + lib.optionalString (cfg.serial != null) "?serial=${cfg.serial}";
        # CUPS' built-in Generic PostScript driver.
        #
        # The "obvious" choice — foo2zjs's `foo2xqx` PPD for the
        # next model down (P2014n) — produces garbage on the
        # P2015: the P2015 actually wants the `foo2xqx-z2` wire
        # protocol variant, slightly different PJL preamble, and
        # nixpkgs' foo2zjs build doesn't ship any P2015 PPD.
        #
        # The P2015n's firmware natively speaks PostScript Level 3
        # (per HP's datasheet — networked variants of P2015 added
        # PCL5e/PCL6/PS3, the bare P2015 is host-based only).
        # Generic-PS bypasses the PJL gymnastics entirely: CUPS'
        # bundled PostScript filter chain produces standard PS,
        # the printer's PS interpreter consumes it directly, no
        # proprietary wrapper needed.
        #
        # Trade-off: PS rendering on the printer is slower than
        # foo2xqx's host-side rasterization (the host pre-rasters
        # to ZjStream/XQX and ships ready-to-image data). For
        # plain text / one-off image jobs the difference is
        # invisible. For high-volume jobs we'd want a real P2015
        # PPD eventually — vendoring one from foo2zjs upstream is
        # the upgrade target.
        model = "drv:///sample.drv/generic.ppd";
        ppdOptions = {
          PageSize = "A4";
        };
      }];
    };
  };
}
