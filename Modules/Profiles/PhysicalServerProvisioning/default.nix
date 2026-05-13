{ config, lib, pkgs, ... }:
#
# PhysicalServerProvisioning profile — minimalist first-boot image
# that flips itself onto a target nixosConfiguration once that
# configuration is "ready" upstream.
#
# Workflow (B2 in the design discussion of 2026-05-09):
#
#   1. Operator builds the SD image from this profile + the target
#      machine's hardware module + sd-image-aarch64. The resulting
#      image is small (no soffice, no realesrgan, no Mono runtime
#      — just Linux + sshd + this script). Cross-compilable from
#      x86_64 because the closure is small enough to fit in
#      cache.nixos.org's aarch64 binaries without falling back to
#      qemu-user.
#   2. Flash, boot. sshd starts, ssh host-keys generate. The
#      `first-boot-switch` systemd timer fires `OnBootSec=1m` and
#      runs the service.
#   3. The service does:
#        nixos-rebuild boot --refresh --flake <targetFlakeUri>#<name>
#        systemctl reboot
#      `--refresh` re-fetches the flake input each attempt, so a
#      previously-cached "ref doesn't exist yet" lookup gets
#      replaced by the now-pushed ref the moment the operator
#      lands the secrets. `boot` doesn't activate the new
#      generation; the reboot picks it up cleanly.
#   4. If the target ref doesn't exist (operator hasn't pushed
#      the readiness tag yet), nix returns 404 from GitHub and
#      the rebuild errors. systemd marks the service failed; the
#      timer's `OnUnitInactiveSec=1m` fires it again in a minute.
#      The image keeps retrying until the readiness signal is
#      live, then flips itself.
#
# Readiness gating via flake ref. The recommended pattern is to
# use a tag or a branch in <targetFlakeUri> that you push only
# after the target machine's secrets are encrypted to its host
# age key:
#   targetFlakeUri = "github:hypersw/HyperNix?ref=ghosthome-ready"
# Until that branch / tag exists, the rebuild fails cleanly with
# a 404. Once you push it, the next retry succeeds.
#
# After the switch lands, the new system's localFlake activation
# (from AnyMachineBase) writes /etc/nixos/flake.nix pointing at
# `github:hypersw/HyperNix` (master, no ref filter), so the
# auto-rebuild-on-push loop tracks master from then on. The
# readiness ref is one-shot — only used by the provisioning
# image's first-boot script.
#
# What the image carries: Pi-hardware module + openssh + this
# service. Deliberately not AnyMachineBase — that pulls in
# auto-rebuild + telegram-alerts + sops which we don't need on
# the provisioning side and would only fail noisily without
# secrets. The whole point is "boot, retry until success, reboot
# into the real config".
#
let
  cfg = config.hypersw.profiles.physicalServerProvisioning;

  # Log file that first-boot-switch tees its stdout+stderr to, so
  # the HTTP status endpoint can serve verbose nix-build output
  # (which journalctl truncates) alongside the journal.
  switchLogFile = "/var/log/first-boot-switch.log";

  # Tiny Python HTTP server that re-renders the journal + log on
  # every request. Python rather than busybox httpd / nginx /
  # darkhttpd because (a) we just want one dynamic endpoint, no
  # static-file routing, (b) Python's stdlib http.server gives us
  # proper HTTP semantics in ~30 lines, (c) closure cost is a
  # one-time ~30 MB hit on a provisioning image that's already
  # ~3 GB and short-lived.
  logServer = pkgs.writeTextFile {
    name = "first-boot-log-server.py";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      """
      Read-only HTTP endpoint streaming a snapshot of
      first-boot-switch's progress on every GET. No auth — the
      data is just systemd journal lines + the switch's stdout
      tee'd to a log file, neither sensitive, and the
      provisioning image isn't supposed to live past the first
      successful switch.
      """
      import http.server
      import subprocess
      import os

      JOURNALCTL = "${pkgs.systemd}/bin/journalctl"
      LOG_FILE = "${switchLogFile}"

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              parts = [b"=== first-boot-switch.service journal (last 5000 lines) ===\n"]
              try:
                  parts.append(subprocess.check_output([
                      JOURNALCTL, "--no-pager", "--output=short-iso",
                      "-u", "first-boot-switch.service",
                      "-n", "5000",
                  ]))
              except subprocess.CalledProcessError as e:
                  parts.append(b"(journalctl exited non-zero)\n")
                  parts.append(e.output or b"")
              parts.append(("\n=== %s ===\n" % LOG_FILE).encode())
              if os.path.exists(LOG_FILE):
                  with open(LOG_FILE, "rb") as f:
                      parts.append(f.read())
              else:
                  # Plain ASCII -- Python bytes literals reject non-ASCII chars.
                  parts.append(b"(no log file yet -- first-boot-switch hasn't run a full attempt)\n")
              body = b"".join(parts)
              self.send_response(200)
              self.send_header("Content-Type", "text/plain; charset=utf-8")
              self.send_header("Cache-Control", "no-store")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, fmt, *args):
              # Quiet the per-request access log — uninteresting,
              # and would clutter the journal we're serving.
              pass

      addr = os.environ.get("FIRST_BOOT_LOG_BIND", "0.0.0.0")
      port = int(os.environ.get("FIRST_BOOT_LOG_PORT", "80"))
      server = http.server.HTTPServer((addr, port), Handler)
      print(f"first-boot-log-server: listening on {addr}:{port}", flush=True)
      server.serve_forever()
    '';
  };
in
{
  options.hypersw.profiles.physicalServerProvisioning = {
    enable = lib.mkEnableOption "Minimalist first-boot provisioning image";

    targetFlakeUri = lib.mkOption {
      type = lib.types.str;
      description = ''
        Flake URI the first-boot service rebuilds against. Should
        include a ref (branch or tag) the operator only pushes
        once the target machine's secrets are encrypted upstream
        — e.g.
        <literal>github:hypersw/HyperNix?ref=ghosthome-ready</literal>.
        Until the ref exists, the rebuild errors with 404 and the
        timer keeps retrying.
      '';
    };

    targetConfigName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the upstream nixosConfiguration to switch into
        (e.g. "GhostHome"). This becomes the `#name` part of the
        `nixos-rebuild boot --flake URI#name` invocation.
      '';
    };

    retryIntervalSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Seconds between rebuild attempts. The timer fires once
        OnBootSec from boot, then OnUnitInactiveSec from the
        service's last completion. 60 s is a sensible default
        that doesn't hammer GitHub but reacts within a minute
        of the operator landing the readiness ref.
      '';
    };

    administrator = {
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Optional ssh keys for an "operator" account on the
          provisioning image. Strictly for emergency access if
          the auto-switch keeps failing and the operator wants
          to ssh in to look. The image is designed to never need
          interactive login — leave this empty unless debugging.
        '';
      };
    };

    statusHttp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Expose first-boot-switch's progress over a read-only
          HTTP endpoint on the LAN. Useful because the first
          successful switch on a Pi rebuilds the live system's
          kernel from source (we don't get nvmd's cache hits
          when following our own nixpkgs pin), which can take
          30–60 min on a Pi 5. The operator points a browser at
          the Pi's IP and sees the live journal + log of the
          retry attempts, no auth needed — the data is just
          systemd journal lines + nix-build stdout, nothing
          sensitive. Image is short-lived anyway; the moment the
          switch succeeds we reboot into the real config which
          doesn't carry this endpoint.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "TCP port for the status HTTP endpoint.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking = {
      # DHCP on every Ethernet interface; no WiFi (the operator
      # hasn't supplied a PSK, this image is short-lived anyway).
      useDHCP = true;
      firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ]
          ++ lib.optional cfg.statusHttp.enable cfg.statusHttp.port;
      };
    };

    # sshd's only purpose here is to let the operator pull the
    # host's just-generated ssh ed25519 public key with
    # `ssh-keyscan` (or convert via ssh-to-age) so they can
    # encrypt the target machine's sops file to it without
    # logging in.
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
    };
    security.sudo.wheelNeedsPassword = false;
    users.users.root.hashedPassword = "!";

    # Optional emergency-access account. Empty by default — the
    # image isn't supposed to need login.
    users.users.operator = lib.mkIf (cfg.administrator.authorizedKeys != []) {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.administrator.authorizedKeys;
    };

    nix = {
      settings.experimental-features = [ "nix-command" "flakes" ];
    };

    # The first-boot service. Runs once per timer trigger. Type=
    # oneshot + no Restart=on-failure — we rely on the timer's
    # OnUnitInactiveSec to re-trigger, which gives a cleaner
    # "service failed, will retry in 1m" signal in journalctl
    # than systemd's restart counter.
    systemd.services.first-boot-switch = {
      description = "Switch to the target nixosConfiguration once the readiness ref is live";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Run from /var/empty — defensive CWD pin in case of any
        # CWD-relative writes inside nixos-rebuild.
        WorkingDirectory = "/var/empty";
        ExecStart = pkgs.writeShellScript "first-boot-switch" ''
          # `pipefail` is CRITICAL — without it, the `… | tee` at
          # the end of the rebuild pipeline below masks
          # `nixos-rebuild`'s non-zero exit and the script
          # proceeds to `systemctl reboot` on every failed
          # attempt. That bricks the retry loop and (in the
          # nixosTest VM) kills the test-driver shell mid-run.
          set -euo pipefail
          # Tee stdout+stderr into a log file the HTTP status
          # endpoint serves alongside the journal. journalctl
          # truncates long lines so verbose `nix-build` output
          # would be hard to read straight from the journal —
          # the file gives the operator the full firehose.
          ${pkgs.coreutils}/bin/mkdir -p $(${pkgs.coreutils}/bin/dirname ${switchLogFile})
          {
            echo "[$(${pkgs.coreutils}/bin/date -Iseconds)] starting first-boot-switch attempt → ${cfg.targetFlakeUri}#${cfg.targetConfigName}"
            # --refresh: ignore any cached "ref doesn't exist"
            # entry so the moment the operator pushes the
            # readiness ref, the next retry picks it up.
            # --no-write-lock-file: don't try to write a
            # flake.lock anywhere (the image's rootfs is
            # read-only at activation time anyway).
            # --print-build-logs: surface each derivation's
            # build progress in real time rather than waiting
            # for the whole thing to finish.
            ${pkgs.nixos-rebuild}/bin/nixos-rebuild boot \
              --refresh \
              --no-write-lock-file \
              --print-build-logs \
              --flake "${cfg.targetFlakeUri}#${cfg.targetConfigName}"
            echo "[$(${pkgs.coreutils}/bin/date -Iseconds)] switch succeeded — syncing + rebooting"
            ${pkgs.coreutils}/bin/sync
          } 2>&1 | ${pkgs.coreutils}/bin/tee -a ${switchLogFile}
          # systemctl reboot returns immediately; the kernel
          # handles the rest.
          ${pkgs.systemd}/bin/systemctl reboot
        '';
      };
    };

    # Read-only HTTP status endpoint. Serves the journal of
    # first-boot-switch.service + the verbose tee'd log from
    # the ExecStart above, regenerated on every GET.
    systemd.services.first-boot-log = lib.mkIf cfg.statusHttp.enable {
      description = "Read-only HTTP endpoint serving first-boot-switch progress";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        FIRST_BOOT_LOG_PORT = toString cfg.statusHttp.port;
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${logServer}";
        Restart = "always";
        RestartSec = "5s";
        # Run unprivileged via systemd's DynamicUser. The script
        # only needs to read the journal (systemd-journal group)
        # and read the log file. Low-port bind needs the cap.
        DynamicUser = true;
        SupplementaryGroups = [ "systemd-journal" ];
        AmbientCapabilities = lib.optionals (cfg.statusHttp.port < 1024) [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = lib.optionals (cfg.statusHttp.port < 1024) [ "CAP_NET_BIND_SERVICE" ];
        # Hardening — endpoint reads journal + log, nothing else.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
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
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        # The tee'd log file lives outside the journal — grant
        # explicit read access since DynamicUser otherwise can't
        # see it under ProtectSystem=strict.
        ReadOnlyPaths = [ switchLogFile ];
      };
    };

    systemd.timers.first-boot-switch = {
      description = "Trigger first-boot-switch ${toString cfg.retryIntervalSec}s after boot, retry every ${toString cfg.retryIntervalSec}s on failure";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.retryIntervalSec}s";
        # Re-fire OnUnitInactiveSec after the service deactivates
        # (whether by success or failure). On success the reboot
        # happens before this matters; on failure it's the retry.
        OnUnitInactiveSec = "${toString cfg.retryIntervalSec}s";
        Unit = "first-boot-switch.service";
      };
    };

    # Tiny systemPackages — htop is enough for the operator to
    # `top` if they ssh in to see what's chewing CPU during a
    # rebuild. Everything else lands with the full configuration
    # on first reboot.
    environment.systemPackages = with pkgs; [ htop ];

    # Avahi for mDNS publication so the operator can reach the
    # box at `<hostname>.local` from any LAN device with mDNS
    # support (most modern Macs/Linux, Windows w/ Bonjour, etc.)
    # — much friendlier than scanning the LAN by ARP to find the
    # DHCP-assigned IP. Publication-only; no service browsing
    # needed on the provisioning image.
    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        addresses = true;       # publish A/AAAA records for the hostname
        workstation = false;    # no "workstation" SRV record clutter
        userServices = false;
      };
      nssmdns4 = true;          # also resolves .local locally
    };
    # mDNS uses UDP/5353 — needs the firewall open. The Avahi
    # NixOS module flips `openFirewall` on automatically when
    # `publish.enable = true`, but be explicit so it survives a
    # firewall option override.
    networking.firewall.allowedUDPPorts = [ 5353 ];

    # Heartbeat ACT LED. Pi 4's activity LED defaults to the
    # `mmc0` trigger which conveniently blinks on every SD-card
    # read, giving an "I'm alive" signal incidentally. Pi 5 + USB
    # boot doesn't drive ACT on disk reads (USB storage doesn't
    # hook the same trigger), and the operator stares at a steady
    # green LED for an hour wondering if the box has hung. Switch
    # the LED to a `heartbeat` trigger so it pulses regularly as
    # long as the kernel scheduler is alive — a visible liveness
    # signal independent of any service running.
    systemd.services.rpi-act-led-heartbeat = {
      description = "Set the Pi activity LED to the heartbeat trigger";
      after = [ "sysinit.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "rpi-act-led-heartbeat" ''
          set -eu
          # /sys/class/leds/ACT/trigger only exists on Pi (and a
          # few other ARM SBCs). Skip silently elsewhere.
          if [ -e /sys/class/leds/ACT/trigger ]; then
            echo heartbeat > /sys/class/leds/ACT/trigger
            echo "rpi-act-led-heartbeat: ACT trigger set to heartbeat"
          else
            echo "rpi-act-led-heartbeat: no /sys/class/leds/ACT — skipping"
          fi
        '';
      };
    };
  };
}
