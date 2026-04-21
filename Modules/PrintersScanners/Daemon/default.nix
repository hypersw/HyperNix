{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-daemon;
  sharedPackage = import ../Shared/package.nix { inherit pkgs; };
  daemonPackage = import ./package.nix { inherit pkgs sharedPackage; };
in
{
  options.services.printscan-daemon = {
    enable = lib.mkEnableOption "Print/Scan daemon with Unix socket API";

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/printscan/api.sock";
      description = "Path to the Unix domain socket";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "printscan";
      description = "Group that can connect to the daemon socket";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = {};
    users.users.printscan-daemon = {
      isSystemUser = true;
      group = cfg.group;
      description = "PrintScan daemon service user";
    };

    # Socket unit — systemd creates the socket with correct ownership/permissions
    # declaratively, then passes the fd to the daemon via socket activation.
    systemd.sockets.printscan-daemon = {
      description = "Print/Scan Daemon Socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketMode = "0660";
        SocketUser = "printscan-daemon";
        SocketGroup = cfg.group;
        RuntimeDirectory = "printscan";
        RuntimeDirectoryMode = "0755";
      };
    };

    systemd.services.printscan-daemon = {
      description = "Print/Scan Daemon";
      # Long-running state-holding service — pulled into multi-user.target
      # rather than purely socket-activated. The socket is still primary
      # (Kestrel binds fd 3 from it via systemd activation), but we no
      # longer rely on "first connection starts the service" semantics.
      # Explicit Requires on the socket so we never start without the fd.
      wantedBy = [ "multi-user.target" ];
      requires = [ "printscan-daemon.socket" ];
      after = [ "printscan-daemon.socket" "cups.service" ];
      wants = [ "cups.service" ];

      # StartLimit* belong in [Unit] (NixOS unitConfig), not [Service].
      # With serviceConfig they're silently ignored.
      unitConfig = {
        StartLimitIntervalSec = "60s";
        StartLimitBurst = 5;
      };

      environment = {
        PRINTSCAN_SOCKET = cfg.socketPath;
        # ASPNETCORE_URLS deliberately unset. Kestrel picks up fd 3 from
        # systemd (UseSystemd + ConfigureKestrel.ListenHandle in code).
        # If LISTEN_FDS is missing the daemon now fails fast rather than
        # silently TCP-binding to :5000 — see src/Program.cs.

        # EpkowaScanner module sets SANE_CONFIG_DIR globally via
        # environment.variables (which populates login-shell env only —
        # systemd services don't inherit it). Without this the daemon's
        # spawned scanimage uses the default /etc/sane.d which lacks the
        # usb 04b8:0142 → "Perfection V33" mapping needed to unlock the
        # scanner, and reports "no SANE devices found" despite the
        # scanner being physically present and working from a shell.
        SANE_CONFIG_DIR = "/etc/sane-config-epkowa";
      };

      serviceConfig = {
        # notify: UseSystemd() sends sd_notify(READY=1) when the app is ready
        Type = "notify";
        ExecStart = "${daemonPackage}/bin/PrintScan.Daemon";

        # Always restart. We want this daemon continuously running; if it
        # exits for any reason (crash, clean-exit-we-didn't-ask-for, OOM,
        # misread config), bring it back. Bounded retry burst below keeps
        # runaway loops from consuming the CPU or beating the SD card.
        Restart = "always";
        RestartSec = "5s";  # cooldown between crashes
        # StartLimit* are in unitConfig above (they belong to [Unit]).

        User = "printscan-daemon";
        Group = cfg.group;
        SupplementaryGroups = [ "lp" "scanner" ];

        # Session store — systemd creates /var/lib/printscan owned by our
        # user, exports STATE_DIRECTORY into the environment.
        StateDirectory = "printscan";
        StateDirectoryMode = "0750";

        # Give in-flight scan + TG upload time to finish on SIGTERM.
        # 5 min upper-bounds a 1200dpi A4 color scan + delivery. Past
        # that, systemd SIGKILLs; the service unit's Restart=always
        # brings it back within RestartSec.
        TimeoutStopSec = "5min";
        KillSignal = "SIGTERM";
        SendSIGHUP = false;

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Belt-and-braces against "daemon silently binds TCP" bugs:
        # put the daemon in its own empty network namespace. It literally
        # cannot bind a TCP port, cannot resolve DNS, cannot talk to the
        # LAN. Unix sockets still work (namespace-local transport) — the
        # activated fd 3 comes through fine. CUPS/lp uses its own Unix
        # socket, scanimage talks USB not network, so nothing legitimate
        # breaks. If a future bug tries to bind something on a TCP port,
        # it fails at syscall level instead of quietly listening on the
        # wrong transport.
        PrivateNetwork = true;
      };
    };
  };
}
