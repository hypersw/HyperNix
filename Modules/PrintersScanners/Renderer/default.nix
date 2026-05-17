{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.services.printscan-renderer;
  rendererPackage = import ./package.nix { inherit pkgs; };
in
{
  options.hypersw.services.printscan-renderer = {
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

        # Vulkan wiring for Real-ESRGAN-ncnn-vulkan.
        #
        # The binary calls vkCreateInstance unconditionally at startup,
        # before the -g flag is consulted, so even "CPU mode" demands a
        # working Vulkan ICD on disk. On a fresh GhostHome (no
        # hardware.graphics.enable) there is no ICD registered, hence
        # the production failure pattern:
        #     vkCreateInstance failed -9 / invalid gpu device
        # in 0.0 s on both attempts.
        #
        # We can't turn on hardware.graphics.enable globally — it stalls
        # stage-1 init on this Pi 5 image (suspected race between v3d/vc4
        # KMS init and the rest of stage 1). So this is a renderer-
        # service-local Vulkan setup: bind the loader's library into
        # LD_LIBRARY_PATH and point VK_ICD_FILENAMES at the LLVM-pipe ICD
        # only. Mesa's v3dv driver (hardware Vulkan on the Pi 5's V3D 7)
        # was tested — it fails to compile the realesr-animevideov3
        # compute shaders ("MESA: error: Failed to pack instruction …
        # utof t197.l, t196; thrsw") and core-dumps in ~17 s. Until that
        # Mesa-v3dv-vs-ncnn-vulkan-compute issue is fixed upstream, the
        # only viable ICD on the Pi is llvmpipe.
        #
        # Llvmpipe is pure CPU Vulkan — needs no /dev/dri access, no
        # video/render group, no kernel modules. Benchmarked on a
        # 500x647 → 2000x2588 (×4) realesr-animevideov3 run: ~30 s
        # on Pi 5 four-core, vs ~10 s on a desktop x86 with the same
        # llvmpipe.
        LD_LIBRARY_PATH = "${rendererPackage.vulkanLoader}/lib";
        VK_ICD_FILENAMES =
          "${rendererPackage.mesa}/share/vulkan/icd.d/lvp_icd."
          + "${pkgs.stdenv.hostPlatform.parsed.cpu.name}.json";
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
        # daemon back. 15 min picked to accommodate /image-upscale
        # being mid-flight when a service swap (e.g. auto-rebuild)
        # hits the renderer — on Pi 5 CPU Vulkan, neural pass 1 alone
        # takes ~6 min for a A4-engine-grid target. The host's
        # ShutdownTimeout (Program.cs) is set to 14 min, 1 min shorter
        # than this, so Kestrel finishes draining naturally before
        # systemd's SIGKILL would land. soffice itself is bounded by
        # the 2-min per-job cap in Program.cs and doesn't need any of
        # this headroom — the long tail is neural upscale only.
        TimeoutStopSec = "15min";
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
        # * PrivateDevices — left off so realesrgan-ncnn-vulkan can
        #   reach /dev/dri/renderD128 for the Vulkan path on Pi 5
        #   (V3DV driver). The neural-upscaler endpoint falls back
        #   to CPU mode on Vulkan failure, so the worst-case impact
        #   of /dev/dri being unavailable is a slower render, not a
        #   broken job.

        # Allow access to GPU render nodes for Vulkan compute. /dev/dri
        # by default is exposed because PrivateDevices=false, but be
        # explicit about the only character-device class we want
        # reachable — keeps the cgroup device-allowlist tight.
        DeviceAllow = [ "char-drm rw" ];
      };
    };
  };
}
