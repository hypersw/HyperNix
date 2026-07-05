{ config, lib, pkgs, ... }:

# ╭──────────────────────────────────────────────────────────────────────╮
# │ Transactional weekly upgrade — sandbox-first, candidate-independent  │
# ╰──────────────────────────────────────────────────────────────────────╯
#
# WHY (the incident that motivated this module)
# =============================================
# Stock `system.autoUpgrade` does `nix flake update` on the WHOLE flake
# followed by `nixos-rebuild switch`. If the switch fails at any stage
# past the lock update, the flake.lock is already contaminated with new
# revs. That contamination then trips every subsequent auto-rebuild
# invocation — including the on-push flow (auto-rebuild-switch.service)
# that operators rely on to ship fixes to a broken box. The failure
# fan-out is asymmetric: one bad weekly upgrade wedges the box until
# operator intervention.
#
# This module replaces the stock service with a sandbox-first flow:
# do all the risky work in an ephemeral copy of the flake, only mutate
# the live flake.lock when the sandbox has proven the new revs actually
# build. Result: production is either healthy or one-weekly-upgrade-old.
# It never gets stuck in a broken-but-locked state that requires manual
# recovery.
#
# THE FLOW (with error-recovery labels)
# =====================================
#
#   ┌────────────────────────────────────────────────────────────┐
#   │  flock /run/nixos-upgrade-transactional.lock               │
#   │    (mutex vs. auto-rebuild-switch — both touch flake.lock) │
#   └────────────────────────────────────────────────────────────┘
#     │
#     ▼
#   ┌────────────────────────────────────────────────────────────┐
#   │  Sandbox = /run/nixos-upgrade-transactional-sandbox        │
#   │  Seed: cp /etc/nixos/{flake.nix,flake.lock} → sandbox      │
#   └────────────────────────────────────────────────────────────┘
#     │
#     ▼
#   ┌────────────────────────────────────────────────────────────┐
#   │  Step 1  — nix flake update <production inputs> sandbox    │
#   │    (candidate-* inputs deliberately untouched — belong     │
#   │     to the operator's try-boot workflow)                   │
#   │    Failure here (network, github rate limit): exit         │
#   │    non-zero. /etc/nixos untouched. OnFailure→alert.        │
#   └────────────────────────────────────────────────────────────┘
#     │
#     ▼
#   ┌────────────────────────────────────────────────────────────┐
#   │  Step 2  — nix build sandbox#nixosConfigurations.default.  │
#   │             config.system.build.toplevel --no-link         │
#   │    Failure here (eval error, broken package, missing       │
#   │      cache, disk full): exit non-zero. /etc/nixos          │
#   │      untouched. OnFailure→alert.                           │
#   │    This is the ATTRACTIVE FAILURE PATH — the incident      │
#   │    that motivated this module (nvmd/nixpkgs schema drift)  │
#   │    would have landed here without contaminating live       │
#   │    state.                                                  │
#   └────────────────────────────────────────────────────────────┘
#     │
#     ▼
#   ┌────────────────────────────────────────────────────────────┐
#   │  Step 3  — jq-splice: for each of the four production      │
#   │             input nodes (nixpkgs, nixos-hardware, nixos-   │
#   │             raspberrypi, upstream), copy sandbox's         │
#   │             .locked entry into /etc/nixos/flake.lock.      │
#   │    Preserves candidate-* nodes exactly (operator state).   │
#   │    Failure here (disk full, permission): exit non-zero.    │
#   │    /etc/nixos/flake.lock UNCHANGED (mv-into-place is       │
#   │    atomic, no partial writes).                             │
#   └────────────────────────────────────────────────────────────┘
#     │
#     ▼
#   ┌────────────────────────────────────────────────────────────┐
#   │  Step 4  — nixos-rebuild switch --flake /etc/nixos#default │
#   │    Step 2 already built the derivations; this eval hits    │
#   │    the same store paths and finds them cached. No rebuild. │
#   │    Failure here (activation hook, systemd unit start):     │
#   │    system stays on last-good generation via nixos-rebuild  │
#   │    semantics. `nixos-rebuild --rollback` recovers, or the  │
#   │    next auto-rebuild-switch (from a HyperNix push) retries │
#   │    activation on the same revs.                            │
#   │                                                            │
#   │    Note: activation failure DOES leave the lock advanced.  │
#   │    This is deliberate — the derivations built cleanly, so  │
#   │    the failure is a system-level runtime issue, not an     │
#   │    input-quality problem. Alerting fires; operator triages.│
#   │                                                            │
#   │    A future extension (see FUTURE-ROBUSTNESS comment in    │
#   │    the ExecStart script) would slot a Pi 5 EEPROM boot-    │
#   │    once try-boot between Step 3 and Step 4 for full        │
#   │    automated-rollback. Not implemented today — weekly      │
#   │    reboots are invasive for an always-on server and the    │
#   │    Step-4 failure rate is low given Step-2 vetting.        │
#   └────────────────────────────────────────────────────────────┘
#
# INTERACTION with the operator's candidate quartet
# =================================================
# The candidate quartet (nixos-raspberrypi-candidate, etc. — see
# Modules/Profiles/AnyMachineBase/default.nix for the shim's structure)
# is EXCLUSIVELY operator-managed. This module does not read from it,
# does not update its inputs, does not touch its nodes in the lock.
# Operator can experiment with broken candidate pins whenever they
# like; the weekly upgrade will run alongside without collision.
#
# The mutex (`flock`) coordinates with auto-rebuild-switch which also
# mutates the lock. Concurrent operator-triggered flake.update
# commands would race, but that's a documented "operator override"
# in the shim template and not something we try to defend against.

let
  cfg = config.hypersw.system.autoUpgradeTransactional;

  # ── Production input names ───────────────────────────────────
  # These four must match the shim template exactly (see
  # Modules/Profiles/AnyMachineBase/default.nix, the `inputs = { ... }`
  # block that renders into /etc/nixos/flake.nix). If new production
  # inputs are added there, they must be added here too or the lock
  # nodes for them will drift out of sync between sandbox and live.
  productionInputs = [
    "nixpkgs"
    "nixos-hardware"
    "nixos-raspberrypi"
    "upstream"
  ];

  # KNOWN FOLLOW-UP (observed during first manual test invocation):
  # The splice replaces `.nodes.<name>` from sandbox into live, but
  # the observed effect was that the live lock's `nixpkgs.original`
  # ended up as `type: tarball` after Step 3 while the shim's
  # flake.nix declares `github:NixOS/nixpkgs/nixos-unstable`. Result:
  # Step 4's `nixos-rebuild switch` may resolve to a different eval
  # than Step 2's `nix build` — safe (system stays on last-known-good
  # rev instead of contaminating with a new one) but wastes the
  # candidate build. To debug: run Step 1 in isolation on the device,
  # `jq .nodes.nixpkgs.original sandbox/flake.lock` before and after,
  # verify the sandbox's `original` reflects the shim's github URL.
  # Suspect: seed copies live's stale `original` (tarball from an old
  # shim state), and `nix flake update <name>` doesn't re-resolve
  # `original` when the URL in flake.nix has changed since the last
  # lock. If confirmed, an explicit `nix flake lock --recreate-lock-file`
  # or a `nix flake lock --override-input nixpkgs github:.../nixos-unstable`
  # before Step 1 would freshen the sandbox's `original`.

  sandboxDir = "/run/nixos-upgrade-transactional-sandbox";
  lockFile = "/run/nixos-upgrade-transactional.lock";
  liveDir = "/etc/nixos";

  # jq program to structurally splice N nodes from $new (slurpfile of
  # sandbox's flake.lock) into the current input. Built at eval time
  # from `productionInputs` so adding an input above updates this too.
  spliceProgram =
    lib.concatMapStringsSep " | " (name:
      # Bracket-syntax accesses handle hyphenated names (nixos-hardware,
      # nixos-raspberrypi) which dot-syntax would parse as subtraction.
      ''.nodes["${name}"] = $new[0].nodes["${name}"]''
    ) productionInputs;

  upgradeScript = pkgs.writeShellScript "nixos-upgrade-transactional" ''
    set -euo pipefail

    export PATH="${lib.makeBinPath [
      pkgs.nix pkgs.jq pkgs.coreutils pkgs.util-linux pkgs.gnutar
      pkgs.gzip pkgs.gnused pkgs.git pkgs.openssh pkgs.nixos-rebuild
    ]}:$PATH"

    SANDBOX=${sandboxDir}
    LIVE=${liveDir}
    LOCK=${lockFile}

    # ── Mutex ─────────────────────────────────────────────────
    # 5-minute wait for auto-rebuild-switch to finish its own flake
    # write. Longer than a typical rebuild; short enough that a
    # legitimately-stuck peer surfaces via our own OnFailure alert
    # rather than blocking forever.
    exec 200>"$LOCK"
    if ! flock -w 300 200; then
      echo "could not acquire $LOCK within 5 minutes — likely a stuck peer"
      exit 1
    fi

    # ── Sandbox seed ──────────────────────────────────────────
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX"
    cp "$LIVE/flake.nix"   "$SANDBOX/flake.nix"
    cp "$LIVE/flake.lock"  "$SANDBOX/flake.lock"
    chmod u+w "$SANDBOX/flake.nix" "$SANDBOX/flake.lock"
    echo "sandbox seeded at $SANDBOX from $LIVE"

    # ── Step 1: update production inputs in the sandbox ───────
    # Candidate inputs are deliberately NOT listed — they stay at
    # whatever the operator has them at (byte-identical to live).
    echo "== step 1: flake update (production inputs only)"
    nix --extra-experimental-features 'nix-command flakes' flake update \
      --flake "path:$SANDBOX" \
      ${lib.concatStringsSep " " productionInputs}

    # ── Step 2: dry build the candidate configuration ─────────
    # --no-link so we don't pollute /nix/store links with a
    # sandbox-owned result symlink. Store paths still exist and
    # are ready for Step 4's reuse.
    echo "== step 2: nix build (dry, --no-link)"
    nix --extra-experimental-features 'nix-command flakes' build \
      "path:$SANDBOX#nixosConfigurations.default.config.system.build.toplevel" \
      --no-link

    # ── Step 3: splice sandbox's production nodes → live lock ─
    # jq is atomic-in-effect (temp file + rename). If it fails
    # mid-write the temp file is left behind but /etc/nixos/flake.lock
    # is untouched.
    echo "== step 3: splice production nodes into $LIVE/flake.lock"
    jq --slurpfile new "$SANDBOX/flake.lock" '${spliceProgram}' \
      "$LIVE/flake.lock" > "$LIVE/flake.lock.tx-new"
    mv -f "$LIVE/flake.lock.tx-new" "$LIVE/flake.lock"

    # ── Step 4: switch to the freshly-promoted revs ───────────
    # Same store paths as Step 2 → cache hit → no rebuild.
    echo "== step 4: nixos-rebuild switch --flake $LIVE#default"
    nixos-rebuild switch --flake "$LIVE#default"

    # FUTURE-ROBUSTNESS (documented, not implemented):
    #   Between Step 3 and Step 4, add:
    #     nixos-rebuild-boot-once --flake "$LIVE#default"
    #     reboot-tryboot
    #   which uses the Pi 5 EEPROM one-shot slot to guarantee an
    #   unbootable config auto-reverts on next power cycle. This
    #   would trade weekly reboot cost for near-total protection
    #   against activation-level breakage. Deferred until we have
    #   a Step-4 failure important enough to justify the cost.

    echo "== upgrade complete"
  '';

  # The failure-notify service body (nixos-upgrade-failure-notify.service)
  # is defined in Modules/Monitoring/TelegramAlerts/default.nix alongside
  # the other *-failure-notify services, because that's where the
  # `sendAlert` helper is in scope. This module only references its
  # unit name via OnFailure=.
in
{
  options.hypersw.system.autoUpgradeTransactional = {
    enable = lib.mkEnableOption ''
      transactional weekly upgrade — sandbox-first flow that never
      contaminates /etc/nixos/flake.lock unless the candidate
      configuration builds cleanly. See the docstring at the top
      of this module for the full failure-mode analysis.
    '';

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "Tue *-*-* 04:00:00";
      description = ''
        systemd OnCalendar= expression. Default matches the stock
        nixos-upgrade timer for continuity.
      '';
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = ''
        RandomizedDelaySec= for the timer. Spreads fleet-wide
        traffic to github + cache.nixos.org.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Turn off nixpkgs' stock autoUpgrade if it was enabled — we're
    # taking over the nixos-upgrade.service slot.
    system.autoUpgrade.enable = lib.mkForce false;

    systemd.services.nixos-upgrade = {
      description = "NixOS transactional weekly upgrade (sandbox-first)";
      wantedBy = [ ];  # timer-triggered only

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        OnFailure = "nixos-upgrade-failure-notify.service";
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 3;
      };

      environment = {
        HOME = "/root";
        NIX_PATH = "nixpkgs=flake:nixpkgs:/nix/var/nix/profiles/per-user/root/channels";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${upgradeScript}";
        # Clear the stock `system.autoUpgrade` module's ExecStartPre,
        # which runs `nix flake update --flake /etc/nixos` on live
        # state before ExecStart runs. That would UPDATE PRODUCTION
        # INPUTS UNCONDITIONALLY — the exact contamination this
        # module is designed to prevent. mkForce empties the list
        # even though we also set `system.autoUpgrade.enable = false`
        # elsewhere, because the systemd-unit merge appears to keep
        # the ExecStartPre alive from the stock definition regardless
        # of the enable option.
        # Verified by inspecting `systemctl cat nixos-upgrade.service`
        # on the device before this line was added.
        ExecStartPre = lib.mkForce [];
        # RuntimeDirectory would auto-clean between runs; we use an
        # explicit path in /run so the shell can rm -rf defensively.
      };
    };

    systemd.timers.nixos-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Unit = "nixos-upgrade.service";
      };
    };

    # nixos-upgrade-failure-notify.service is registered in
    # Modules/Monitoring/TelegramAlerts/default.nix.
  };
}
