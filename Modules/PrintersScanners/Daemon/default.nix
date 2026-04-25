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

    mediaSize = lib.mkOption {
      type = lib.types.str;
      default = "A4";
      description = ''
        Default paper size the printer is loaded with. Reported via
        the daemon's /status endpoint and consumed by clients (the
        Telegram bot today) to decide whether an image fits 1:1
        and to render the print preview at correct aspect. The
        daemon itself is content-dumb and does not act on this
        value beyond reporting it. Common values: "A4", "Letter",
        "A3", "Legal".
      '';
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
        PRINTSCAN_MEDIA_SIZE = cfg.mediaSize;
        # ASPNETCORE_URLS deliberately unset. Kestrel picks up fd 3 from
        # systemd (UseSystemd + ConfigureKestrel.ListenHandle in code).
        # If LISTEN_FDS is missing the daemon now fails fast rather than
        # silently TCP-binding to :5000 — see src/Program.cs.

        # Disable the CLR managed-debugger transport. Addresses a .NET 10
        # shutdown hang: CoreCLR spawns a native pthread ("DebugPipe") that
        # opens FIFOs at /tmp/clr-debug-pipe-<pid>-<disambig>-{in,out} and
        # blocks in open() waiting for a partner (Linux FIFO open blocks
        # until both ends are opened). In prod no debugger attaches, so
        # the thread is parked forever. It's a raw pthread — not a managed
        # thread, so Thread.IsBackground doesn't apply; it's also not
        # pthread_detach'd, and CoreCLR shutdown waits for it.
        #
        # Why this only hurts on .NET 10: earlier runtimes installed a
        # default SIGTERM handler that ultimately called _exit() and
        # steamrolled stuck native threads. .NET 10 removed it (see
        # https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/10.0/sigterm-signal-handler),
        # so SIGTERM now runs a cooperative shutdown via ConsoleLifetime /
        # UseSystemd — Main returns, CLR then sits waiting for the
        # DebugPipe thread that never wakes, TimeoutStopSec=5min SIGKILLs.
        #
        # Correct env var: *_Debugger (managed-debugger FIFO transport),
        # NOT *_IPC. DOTNET_EnableDiagnostics_IPC controls a different
        # channel — the dotnet-diagnostic-<pid>-<ts>-socket UDS used by
        # dotnet-trace / dotnet-counters / dotnet-dump attach — which we
        # keep on so we can still introspect a live process. Trade-off:
        # we lose IDE Attach-to-Process (VS/VS Code/Rider managed stacks
        # over the FIFO protocol). We keep: core dumps via createdump,
        # dotnet-dump collect (over the IPC UDS), dotnet-trace,
        # dotnet-counters, native lldb + SOS (ptrace + DAC — doesn't use
        # any CLR-owned IPC). Upstream bug: coreclr#8844 (open since 2017).
        DOTNET_EnableDiagnostics_Debugger = "0";
      }
      # SANE backend lookup vars (SANE_CONFIG_DIR + LD_LIBRARY_PATH).
      # Must be service-level, not globalEnvironment, to avoid triggering
      # systemd PID 1 reexec on switch-to-configuration.
      // config.services.epkowa-scanner.serviceEnvironment;

      serviceConfig = {
        # Pin CWD to a guaranteed-empty read-only dir. systemd's default is
        # CWD=/ for system services, which is the worst case: a buggy file-
        # system op rooted at CWD can walk the entire filesystem (see the
        # ContentRootPath pin in src/Program.cs — a real incident from this
        # codebase). /var/empty on NixOS is mode 0555 root:root with +i
        # immutable; any accidental CWD-relative write fails immediately.
        WorkingDirectory = "/var/empty";

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

        # Hardening.
        #
        # This daemon is "second-hop exposed": it has no direct internet
        # surface (Unix socket only, PrivateNetwork=true below enforces
        # that), but it receives JSON forwarded verbatim from the Telegram
        # bot — scan params, session PATCHes, print payloads — originating
        # from Telegram users. If the bot is ever owned, the daemon is the
        # next target. We apply the "real protection, no fallout" bundle,
        # skipping anything that would conflict with our need for /dev/bus/usb
        # (scanner) and /run/cups/cups.sock (printer).
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;   # block writes to /proc/sys, /sys
        ProtectKernelModules = true;    # no kernel module load
        ProtectKernelLogs = true;       # no /dev/kmsg (we don't read kernel log)
        ProtectControlGroups = true;    # cgroup ro — closes cgroup-escape
        ProtectClock = true;            # no settime()/adjtimex()
        ProtectHostname = true;         # no sethostname()
        LockPersonality = true;         # block personality() ASLR-disable
        RestrictSUIDSGID = true;        # no setuid/setgid file creation
        RestrictRealtime = true;        # no SCHED_FIFO/RR DoS
        RestrictNamespaces = true;      # no unshare()/setns()
        # Skipped: PrivateDevices (need /dev/bus/usb for the scanner),
        # MemoryDenyWriteExecute (breaks .NET JIT), ProtectProc=invisible
        # (our in-process shutdown diagnostic reads /proc/<self>/task/*;
        # self-proc is visible under "invisible" so it *should* work, but
        # pending verification).

        # Needed for the in-process shutdown diagnostic in Program.cs to
        # (a) read /proc/<pid>/task/<tid>/stack of sibling threads and
        # (b) invoke createdump on the hung process. yama.ptrace_scope=1
        # blocks even same-process peeking without this cap. Scoped to
        # ambient so no setuid shenanigans are possible.
        AmbientCapabilities = [ "CAP_SYS_PTRACE" ];
        CapabilityBoundingSet = [ "CAP_SYS_PTRACE" ];

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
