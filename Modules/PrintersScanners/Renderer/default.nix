{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-renderer;
  rendererPackage = import ./package.nix { inherit pkgs; };
in
{
  options.services.printscan-renderer = {
    enable = lib.mkEnableOption ''
      Document → PDF rendering daemon (Telegram bot's "I sent a .docx,
      please print it" path). Spawns headless LibreOffice per request,
      runs in a hardened systemd jail with no network and no /home
      access.
    '';

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/printscan-renderer/api.sock";
      description = "Path to the Unix domain socket clients connect on.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "printscan-renderer";
      description = ''
        Group that can connect to the renderer socket. The Telegram bot
        service should be a SupplementaryGroups member of this group.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = {};
    users.users.printscan-renderer = {
      isSystemUser = true;
      group = cfg.group;
      description = "PrintScan renderer service user";
    };

    # Socket-activated. The .socket unit creates the listening fd with
    # correct ownership/permissions; the .service binds it via fd 3.
    systemd.sockets.printscan-renderer = {
      description = "PrintScan Renderer socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketMode = "0660";
        SocketUser = "printscan-renderer";
        SocketGroup = cfg.group;
        RuntimeDirectory = "printscan-renderer";
        RuntimeDirectoryMode = "0755";
      };
    };

    systemd.services.printscan-renderer = {
      description = "PrintScan document → PDF renderer";
      wantedBy = [ "multi-user.target" ];
      requires = [ "printscan-renderer.socket" ];
      after = [ "printscan-renderer.socket" ];

      unitConfig = {
        StartLimitIntervalSec = "60s";
        StartLimitBurst = 5;
      };

      environment = {
        # Disable the CLR managed-debugger transport — same .NET 10
        # shutdown-hang fix as the print/scan daemon. See the long
        # comment in ../Daemon/default.nix for the full story.
        DOTNET_EnableDiagnostics_Debugger = "0";
      };

      serviceConfig = {
        Type = "notify";
        ExecStart = "${rendererPackage}/bin/PrintScan.Renderer";

        # Unconditional restart — a libreoffice crash inside an HTTP
        # request bubbles up as a 502 to the caller; if soffice
        # somehow takes the daemon process out, systemd brings it
        # back inside RestartSec.
        Restart = "always";
        RestartSec = "5s";

        User = "printscan-renderer";
        Group = cfg.group;

        # systemd-managed scratch space at /var/lib/printscan-renderer.
        # Per-job dirs (see Program.cs) live under here; cleaned up
        # at the end of each request.
        StateDirectory = "printscan-renderer";
        StateDirectoryMode = "0750";

        # Pin CWD to a guaranteed-empty read-only dir so any accidental
        # CWD-relative write fails immediately. Same pattern as the
        # main daemon.
        WorkingDirectory = "/var/empty";

        # Hard cap on stop time. soffice processes that hang past this
        # get SIGKILLed by systemd; service Restart=always brings the
        # daemon back. 30 s comfortably exceeds our in-process render
        # timeout (2 min cap inside Program.cs is for individual jobs;
        # this is daemon-shutdown).
        TimeoutStopSec = "30s";
        KillSignal = "SIGTERM";

        # ── Hardening ─────────────────────────────────────────────
        # This service exists specifically to handle hostile input,
        # so we apply the strictest bundle that's still compatible
        # with libreoffice. The bundle is informed by systemd's own
        # "production hardening" doc plus the libreoffice forum's
        # known-good set for headless conversion farms.

        # No network at all — soffice doesn't need one for local
        # file conversion, and we want a worm-prevention guarantee
        # for any CVEs in libreoffice's parsers.
        PrivateNetwork = true;
        IPAddressDeny = "any";
        RestrictAddressFamilies = [ "AF_UNIX" ];

        # No /home, no /root, /tmp is private per-service.
        ProtectHome = true;
        PrivateTmp = true;
        ProtectSystem = "strict";

        # No new privileges; drop every capability.
        NoNewPrivileges = true;
        CapabilityBoundingSet = [];
        AmbientCapabilities = [];

        # Block kernel/control-plane mutations.
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;

        # Skipped intentionally:
        # * MemoryDenyWriteExecute — would break the .NET JIT in the
        #   parent and (likely) parts of LibreOffice/Java integration
        #   in the child. Re-enabling this requires NativeAOT for the
        #   parent and a confirmation that soffice tolerates it.
        # * SystemCallFilter — narrowing it tight enough for libre-
        #   office without breakage is a research project; the
        #   default + above bundle already removes the highest-value
        #   syscalls (mount, swap, ptrace targeting other procs, …)
        #   indirectly via the cap-bounding-set + NoNewPrivileges.
        # * PrivateDevices — needed if soffice ever wants /dev/shm
        #   for its JVM bridge; default systemd PrivateTmp gives us
        #   a per-service /dev/shm anyway.
      };
    };
  };
}
