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

  # Tiny Python HTTP server that re-renders a 2-pane HTML status
  # page on every request: journal of first-boot-switch in the
  # left pane, the tee'd verbose log in the right, plus a header
  # showing the host's SSH ed25519 public key and its age-key
  # form so the operator can copy it straight into `.sops.yaml`
  # without ssh-keyscanning from another box. Python rather than
  # busybox httpd / nginx / darkhttpd because we want one dynamic
  # endpoint, no static-file routing — stdlib http.server gives
  # us proper HTTP semantics in a few dozen lines; closure cost
  # is a one-time ~30 MB hit on a short-lived 3 GB image.
  logServer = pkgs.writeTextFile {
    name = "first-boot-log-server.py";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      """
      Read-only HTTP endpoint rendering first-boot-switch progress
      as a 2-pane HTML page. No auth — the data is just journal
      lines + the switch's stdout tee'd to a log file + the host's
      SSH public key (which is meant to be public). Image is
      short-lived and meant to expose this info to the operator
      on the LAN.
      """
      import http.server
      import subprocess
      import os
      import html

      JOURNALCTL = "${pkgs.systemd}/bin/journalctl"
      SSH_TO_AGE = "${pkgs.ssh-to-age}/bin/ssh-to-age"
      SSH_HOST_PUBKEY = "/etc/ssh/ssh_host_ed25519_key.pub"
      LOG_FILE = "${switchLogFile}"
      TARGET_FLAKE_URI = os.environ.get("FIRST_BOOT_TARGET_FLAKE_URI", "")
      TARGET_CONFIG_NAME = os.environ.get("FIRST_BOOT_TARGET_CONFIG_NAME", "")

      def parse_target():
          """Pull (repo_short, repo_url, ref_name) out of TARGET_FLAKE_URI.

          Recognises the `github:owner/repo?ref=NAME` flake-URI form
          which is what the provisioning profile is wired for. For
          anything else (gitlab:, sourcehut:, plain git+ssh URLs)
          we fall back to displaying the raw URI as the repo and
          leaving ref empty.
          """
          uri = TARGET_FLAKE_URI
          if not uri.startswith("github:"):
              return (uri, "", "")
          body = uri[len("github:"):]
          repo, _, query = body.partition("?")
          ref = ""
          for param in query.split("&"):
              if param.startswith("ref="):
                  ref = param[len("ref="):]
                  break
          url = f"https://github.com/{repo}"
          return (repo, url, ref)

      def read_journal():
          try:
              out = subprocess.check_output([
                  JOURNALCTL, "--no-pager", "--output=short-iso",
                  "-u", "first-boot-switch.service",
                  "-n", "5000",
              ]).decode("utf-8", errors="replace")
          except subprocess.CalledProcessError as e:
              out = ((e.output or b"").decode("utf-8", errors="replace")
                     + "\n(journalctl exited non-zero)")
          return out

      def read_log():
          if os.path.exists(LOG_FILE):
              with open(LOG_FILE, "rb") as f:
                  return f.read().decode("utf-8", errors="replace")
          # ASCII only -- avoids any encoding-edge-case issues.
          return "(no log file yet -- first-boot-switch hasn't run a full attempt)"

      def read_ssh_pubkey():
          try:
              with open(SSH_HOST_PUBKEY, "r") as f:
                  return f.read().strip()
          except OSError as e:
              return f"(could not read {SSH_HOST_PUBKEY}: {e})"

      def ssh_to_age(ssh_pubkey):
          try:
              out = subprocess.check_output(
                  [SSH_TO_AGE],
                  input=ssh_pubkey.encode() + b"\n",
                  stderr=subprocess.STDOUT,
                  timeout=5,
              )
              return out.decode("utf-8", errors="replace").strip()
          except Exception as e:
              return f"(ssh-to-age failed: {e})"

      # Programmatic HTML render — avoiding str.format because CSS
      # has `{` / `}` that would otherwise need escaping.
      def render(ssh_pubkey, age_pubkey, journal, log_text):
          esc = html.escape
          repo, repo_url, ref = parse_target()
          repo_html = (
              f"<a href='{esc(repo_url)}' target='_blank'>{esc(repo)}</a>"
              if repo_url else esc(repo)
          )
          ref_html = (
              esc(ref) if ref
              else "<em>(no ref= in target URI)</em>"
          )
          return (
              "<!DOCTYPE html><html><head>"
              "<title>first-boot-switch status</title>"
              "<meta charset='utf-8'>"
              "<style>"
              "html,body{height:100%;margin:0;padding:0;"
              "font-family:ui-monospace,Menlo,Consolas,monospace}"
              "body{display:flex;flex-direction:column;height:100vh}"
              "header{padding:.4em .7em;background:#222;color:#ddd;"
              "border-bottom:1px solid #555;font-size:.85em}"
              "header dl{margin:0;display:grid;"
              "grid-template-columns:max-content 1fr;column-gap:.7em;row-gap:.15em}"
              "header dt{color:#fc6;white-space:nowrap}"
              "header dd{margin:0;word-break:break-all;user-select:all}"
              "header dd code{background:#000;color:#fdd;padding:0 .25em;border-radius:.15em}"
              "header a{color:#9cf}"
              "main{display:flex;flex-direction:row;flex:1;overflow:hidden}"
              ".pane{flex:1;height:100%;overflow:auto;"
              "border-right:1px solid #888}"
              ".pane:last-child{border-right:none}"
              "h2{margin:0;padding:.4em .7em;background:#eee;"
              "position:sticky;top:0;font-size:.95em;"
              "border-bottom:1px solid #ccc}"
              "pre{margin:0;padding:.5em .7em;white-space:pre-wrap;"
              "word-break:break-word;font-size:.85em}"
              "</style></head><body>"
              "<header><dl>"
              "<dt>Target GitHub repo:</dt><dd>" + repo_html + "</dd>"
              "<dt>Readiness ref to push:</dt><dd><code>" + ref_html + "</code></dd>"
              "<dt>Target nixosConfiguration:</dt><dd><code>" + esc(TARGET_CONFIG_NAME) + "</code></dd>"
              "<dt>SSH host key (raw):</dt><dd>" + esc(ssh_pubkey) + "</dd>"
              "<dt>SSH host key (age):</dt><dd>" + esc(age_pubkey) + "</dd>"
              "</dl></header>"
              "<main>"
              "<div class='pane'>"
              "<h2>first-boot-switch.service journal</h2>"
              "<pre>" + esc(journal) + "</pre>"
              "</div>"
              "<div class='pane'>"
              "<h2>" + esc(LOG_FILE) + "</h2>"
              "<pre>" + esc(log_text) + "</pre>"
              "</div>"
              "</main>"
              # Scroll each pane to its bottom on load so the most
              # recent log lines are visible without manual scroll.
              # No auto-refresh — operator triggers reload.
              "<script>document.querySelectorAll('.pane')"
              ".forEach(p=>{p.scrollTop=p.scrollHeight});</script>"
              "</body></html>"
          )

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              ssh_pubkey = read_ssh_pubkey()
              age_pubkey = ssh_to_age(ssh_pubkey)
              journal = read_journal()
              log_text = read_log()
              body = render(ssh_pubkey, age_pubkey, journal, log_text).encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "text/html; charset=utf-8")
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
      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        # No internal download retries. `nix flake metadata`
        # otherwise hits GitHub up to 5 times with exponential
        # backoff (0.35s → 0.55s → 1.3s → 2.0s) per
        # `nixos-rebuild` invocation, which spams the API + the
        # status HTTP feed before the systemd timer's 60s gap
        # kicks in. Transient failures (network blip, GitHub
        # rate limit) are still handled at the systemd-timer
        # level: the service exits, the timer fires again in
        # `retryIntervalSec`. One probe per attempt, not five.
        download-attempts = 1;
      };
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
        # Surface the target flake URI + config name to the
        # endpoint so the header can show the operator which
        # readiness ref they need to push and where.
        FIRST_BOOT_TARGET_FLAKE_URI = cfg.targetFlakeUri;
        FIRST_BOOT_TARGET_CONFIG_NAME = cfg.targetConfigName;
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
    # rebuild. ssh-to-age is also exposed on PATH so the
    # operator can manually convert a key on the shell if the
    # HTTP endpoint isn't reachable (the endpoint already shows
    # the converted age key, this is the fallback).
    environment.systemPackages = with pkgs; [ htop ssh-to-age ];

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
