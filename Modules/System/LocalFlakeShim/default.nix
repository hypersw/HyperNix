{ config, lib, pkgs, ... }:
#
# Local-flake shim: writes /etc/nixos/flake.nix, a small flake whose
# `upstream` input is the HyperNix flake, so the update lanes
# (AutoRebuildOnPush, AutoUpgradeTransactional) can run from a local lock.
# AnyMachineBase enables it through its `localFlake` options; a host
# without that profile (VdsRuOne) enables it directly.
#
# ## What this writes
#
# A pair of files at /etc/nixos/:
#
#   - flake.nix  — rewritten on every activation. A MULTI-input shim:
#     nixpkgs, nixos-hardware, optionally nixos-raspberrypi, and
#     upstream, with follows directives wiring upstream's copies to the
#     shim's top-level ones. See "Why multi-input" below. Optionally a
#     parallel candidate quartet (`<name>-candidate`) drives
#     `nixosConfigurations.candidate` for Pi try-boot probes.
#
#   - flake.lock — only if absent: pre-baked by a jq transform of
#     upstream's own flake.lock (in-store via pin.sourcePath). Avoids
#     the first-boot chicken-and-egg where the auto-rebuild checker
#     would have to do anonymous full-graph flake-locking from GitHub on
#     its first tick — and trip the secondary rate limit before any tick
#     can win and persist a lock to disk.
#
# If the pin is null (dirty tree, build without self.rev), only
# flake.nix is written; the first checker tick will generate the lock
# the slow way.
#
# ## Why multi-input (the load-bearing design point)
#
# The shim's top-level nixpkgs / nixos-hardware are MOVABLE HANDLES,
# separable from whatever upstream pinned in its own lock. Two distinct
# refresh modes ride on top:
#
#   - Routine "update from github" (the auto-rebuild-on-push loop,
#     ~every 5 min) runs:
#       nix flake update upstream --flake /etc/nixos
#     This refreshes only the `upstream` input. Because of the follows
#     directives, upstream's view of nixpkgs is pinned to the shim's
#     top-level nixpkgs — which DIDN'T change. No kernel rebuild, no
#     nixpkgs-rooted derivation hash churn. Fast incremental switches on
#     every push.
#
#   - Periodic system upgrade (the transactional weekly upgrade, or the
#     stock system.autoUpgrade in AnyMachineBase) advances the
#     production inputs — including the shim's top-level nixpkgs, which
#     moves to the current head of nixos-unstable. The follows
#     directives then carry that new nixpkgs into upstream's evaluation.
#     Result: fresh kernel + security patches + glibc / openssl / etc.
#     updates, even if upstream's own flake.lock has been stale for
#     months.
#
# The single-input variant (shim has only `upstream`) is simpler but
# eliminates this asymmetry — the box's nixpkgs is then frozen to
# whatever upstream pins, and security upgrades require a HyperNix
# commit. We want the box to be able to grab the freshest kernel
# autonomously.
#
# ## The jq lock transform
#
# `nix flake metadata` on the multi-input shim would compute the whole
# lock (root + nixpkgs + nixos-hardware + upstream + each transitive
# flake of upstream). The same data is already in upstream's own
# flake.lock — we just need to restructure it for the shim's
# perspective:
#
#   1. Walk every non-root node, prepend "upstream" to array-typed
#      (follows) input entries. Targets that were root-relative in
#      upstream's lock are now reachable via upstream from the shim
#      root.
#
#   2. Build an "upstream" node from upstream's old root data + the
#      pin's locked/original. Override its nixpkgs / nixos-hardware
#      entries to follows-pointers to the shim root (matching the
#      `upstream.inputs.X.follows = "X"` directives in the shim's
#      flake.nix below).
#
#   3. Replace "root" with the shim's 3-input form.
#
# Inputs the baked lock lacks (nixos-raspberrypi, the candidates) are
# locked lazily by the first `nix flake update`.
#
# Build-time runCommand keeps the jq invocation off the boot critical
# path — it runs once per system generation, not on every activation.
let
  cfg = config.hypersw.system.localFlakeShim;

  pin = cfg.upstreamPin;

  # Parse upstreamUrl ("github:owner/repo") for the baked lock's
  # `original` block on the upstream node.
  urlNoScheme = lib.removePrefix "github:" cfg.upstreamUrl;
  urlParts = lib.splitString "/" urlNoScheme;
  upstreamOwner = lib.head urlParts;
  upstreamRepo  = lib.elemAt urlParts 1;

  # Root inputs of one quartet, in the order the update lanes name them.
  quartet = suffix:
    [ "nixpkgs${suffix}" "nixos-hardware${suffix}" ]
    ++ lib.optional cfg.raspberryPiInput "nixos-raspberrypi${suffix}"
    ++ [ "upstream${suffix}" ];
  productionInputs = quartet "";
  candidateInputs = lib.optionals cfg.candidates (quartet "-candidate");

  # The rendered flake.nix, built from lines so each optional block keeps
  # its exact indentation (Nix strips indentation per '' string).
  description =
    if cfg.candidates then ''
      Multi-input shim with parallel main and candidate quartets. Each quartet is `{nixpkgs, nixos-hardware, nixos-raspberrypi, upstream}`. The main quartet drives `nixosConfigurations.default` (production); the candidate quartet drives `nixosConfigurations.candidate` (the try-boot staging slot — see Modules/System/BootOnceRaspberryPi/). Every input uses a moving branch-ref URL (nixos-unstable for nixpkgs, the upstream-repo HEAD for HyperNix, the upstream branches for nixos-hardware and nixos-raspberrypi). Each input's `original` block descriptor is identical across the two quartets, but each input locks to a separate rev. Result: main and candidate hold independent revisions of the same branches at the same time.

      nixos-raspberrypi is locally-managed alongside nixpkgs and nixos-hardware (not delegated to whatever HyperNix's flake.lock pinned) so monthly upgrades advance it in lockstep with the rest of userland — that's where the Pi-vendor kernel + its security patches arrive from.

      This file is regenerated by the activation script on every nixos-rebuild switch — content is module-owned. Operator edits go through the template in Modules/System/LocalFlakeShim (options in AnyMachineBase), not through this file. /etc/nixos/flake.lock is operator state (mutated by `nix flake update`, `nixos-rebuild-promote-candidate`, etc.) and is left alone.

      Lock-update commands (each touches only the named inputs; others are left as they were):

      sudo nix flake update --flake /etc/nixos upstream
          Bumps the production HyperNix snapshot. Wired into the ~5-minute auto-rebuild-on-push timer.

      sudo nix flake update --flake /etc/nixos
          Advances every input (both trios + upstream) to current branch HEAD. Wired as the preStart of nixos-upgrade.service (monthly or per-cadence timer). The candidate trio auto-rolls forward along with the production trio at the monthly tick — promote or discard within the cadence window if you want a probe to outlive that.

      sudo nix flake update --flake /etc/nixos nixpkgs-candidate nixos-hardware-candidate nixos-raspberrypi-candidate upstream-candidate
          Starts a fresh major-upgrade probe at current branch HEADs without touching production.

      Try-boot the candidate (Pi 5 EEPROM one-shot; failure auto-reverts on the next power cycle):

      sudo nixos-rebuild-boot-once --flake /etc/nixos#candidate
      sudo reboot-tryboot

      Promote a successful candidate without any rebuild — full local cache reuse, branch-ref descriptors on the main trio preserved so subsequent monthly upgrades advance normally:

      sudo nixos-rebuild-promote-candidate

      Promotes the tested candidate lock graph through the root input handles, then offers a 1-4 apply prompt (nothing / switch / boot / boot + reboot). See Modules/System/BootOnceRaspberryPi/.
    '' else ''
      Local update shim: ${lib.concatStringsSep ", " productionInputs}. `upstream` follows the shim's own nixpkgs and nixos-hardware, so an upstream push changes only HyperNix, while the periodic upgrade advances the rest.

      This file is regenerated by the activation script on every nixos-rebuild switch — content is module-owned (Modules/System/LocalFlakeShim). /etc/nixos/flake.lock is operational state, changed by the update services, and is left alone.

      sudo nix flake update --flake /etc/nixos upstream
          Bumps the production HyperNix snapshot. Wired into the ~5-minute auto-rebuild-on-push timer.
    '';

  upstreamBlock = suffix: [
    "    upstream${suffix} = {"
    "      url = \"${cfg.upstreamUrl}\";"
    "      inputs.nixpkgs.follows = \"nixpkgs${suffix}\";"
    "      inputs.nixos-hardware.follows = \"nixos-hardware${suffix}\";"
  ] ++ lib.optional cfg.raspberryPiInput
    "      inputs.nixos-raspberrypi.follows = \"nixos-raspberrypi${suffix}\";"
  ++ [
    "    };"
  ];

  productionLines = [
    "    nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";"
    "    nixos-hardware.url = \"github:NixOS/nixos-hardware\";"
  ] ++ lib.optionals cfg.raspberryPiInput [
    "    # FORKED to hypersw/nixos-raspberrypi (develop branch)."
    "    # Fork carries a single-line patch to the raspberrypi"
    "    # boot-loader module that hardcodes kernelFile=\"Image\""
    "    # instead of reading fragile nvmd/nixpkgs attribute"
    "    # paths. See HyperNix's flake.nix for the full story"
    "    # and the unpin path (fork can be dropped once nvmd"
    "    # accepts an equivalent upstream fix)."
    "    nixos-raspberrypi.url = \"github:hypersw/nixos-raspberrypi/develop\";"
  ] ++ upstreamBlock "";

  candidateLines = [
    ""
    "    nixpkgs-candidate.url = \"github:NixOS/nixpkgs/nixos-unstable\";"
    "    nixos-hardware-candidate.url = \"github:NixOS/nixos-hardware\";"
  ] ++ lib.optionals cfg.raspberryPiInput [
    "    # Keep the candidate on the same maintained loader fork as"
    "    # production. Upstream currently evaluates its kernel filename"
    "    # through a vendor-kernel passthru (`kernel.target`) that is"
    "    # absent with current nixpkgs; the fork fixes this as `Image`."
    "    nixos-raspberrypi-candidate.url = \"github:hypersw/nixos-raspberrypi/develop\";"
  ] ++ upstreamBlock "-candidate";

  outputLines =
    if cfg.candidates then [
      "  outputs = { upstream, upstream-candidate, ... }: {"
      "    nixosConfigurations.default ="
      "      upstream.nixosConfigurations.${cfg.configurationName};"
      "    nixosConfigurations.candidate ="
      "      upstream-candidate.nixosConfigurations.${cfg.configurationName};"
      "  };"
    ] else [
      "  outputs = { upstream, ... }: {"
      "    nixosConfigurations.default ="
      "      upstream.nixosConfigurations.${cfg.configurationName};"
      "  };"
    ];

  flakeText = lib.concatStringsSep "\n" ([
    "{"
    "  description = ''"
  ] ++ lib.splitString "\n" (lib.removeSuffix "\n" description) ++ [
    "  '';"
    ""
    "  inputs = {"
  ] ++ productionLines ++ lib.optionals cfg.candidates candidateLines ++ [
    "  };"
    ""
  ] ++ outputLines ++ [
    "}"
  ]) + "\n";

  # jq transform — see the header comment for the three-step derivation.
  jqProgram = ''
    .nodes |= with_entries(
      if .key == "root" then .
      else .value |= (
        if .inputs == null then .
        else .inputs |= with_entries(
          .value |= (if type == "array" then ["upstream"] + . else . end)
        )
        end
      )
      end
    ) |
    .nodes.upstream = (.nodes.root + {
      locked: {
        type: "github",
        owner: $upstream_owner,
        repo: $upstream_repo,
        rev: $upstream_rev,
        narHash: $upstream_narHash,
        lastModified: ($upstream_lastModified | tonumber)
      },
      original: {
        type: "github",
        owner: $upstream_owner,
        repo: $upstream_repo
      }
    } | .inputs.nixpkgs = ["nixpkgs"]
      | .inputs["nixos-hardware"] = ["nixos-hardware"]) |
    .nodes.root = {
      inputs: {
        nixpkgs: "nixpkgs",
        "nixos-hardware": "nixos-hardware",
        upstream: "upstream"
      }
    }
  '';

  bakedLock =
    if pin == null then null
    # buildPackages.* runs on the build platform, not the target. Lets
    # x86 dev hosts pre-verify the transform without cross-building for
    # aarch64; the Pi itself runs everything native so this is a no-op
    # there.
    else pkgs.buildPackages.runCommand "shim-flake.lock" {} ''
      ${pkgs.buildPackages.jq}/bin/jq \
        --arg upstream_rev          "${pin.rev}" \
        --arg upstream_narHash      "${pin.narHash}" \
        --arg upstream_lastModified "${toString pin.lastModified}" \
        --arg upstream_owner        "${upstreamOwner}" \
        --arg upstream_repo         "${upstreamRepo}" \
        '${jqProgram}' \
        ${pin.sourcePath}/flake.lock > $out
    '';
in
{
  options.hypersw.system.localFlakeShim = {
    enable = lib.mkEnableOption "the module-owned /etc/nixos/flake.nix shim over the upstream HyperNix flake";

    configurationName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the upstream nixosConfiguration to default to (e.g.
        "PrintScanServerPi4", "GhostHome"). The shim exposes it as
        <literal>nixosConfigurations.default</literal>.
      '';
    };

    upstreamUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:hypersw/HyperNix";
      description = "Flake URL to use as the local flake's upstream input.";
    };

    upstreamPin = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          rev          = lib.mkOption { type = lib.types.str;  };
          narHash      = lib.mkOption { type = lib.types.str;  };
          lastModified = lib.mkOption { type = lib.types.int;  };
          sourcePath   = lib.mkOption { type = lib.types.path; };
        };
      });
      default = null;
      description = ''
        When non-null, the activation script writes
        <literal>/etc/nixos/flake.lock</literal> if it is absent, derived
        from <literal>sourcePath/flake.lock</literal> by the jq transform in
        this module's header. Wire from <literal>self</literal>:
        <literal>{ rev = self.rev; narHash = self.narHash;
        lastModified = self.lastModified; sourcePath = self; }</literal>,
        conditional on <literal>self ? rev</literal>.
      '';
    };

    raspberryPiInput = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Render a local nixos-raspberrypi input that upstream follows, so
        the periodic upgrade advances the Pi vendor kernel with the rest
        of userland. Off for hosts that never use it: the input would cost
        sources and store space for nothing.
      '';
    };

    candidates = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Render the parallel candidate quartet and
        <literal>nixosConfigurations.candidate</literal>, the
        operator-managed probe slot used by
        Modules/System/BootOnceRaspberryPi.
      '';
    };

    productionInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = productionInputs;
      defaultText = lib.literalMD "the production root inputs of the rendered shape";
      description = "Production root inputs of the rendered shim.";
    };

    candidateInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = candidateInputs;
      defaultText = lib.literalMD "the candidate root inputs of the rendered shape, or none";
      description = "Candidate root inputs of the rendered shim; empty without candidates.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The update lanes act on exactly the inputs this shim renders.
    hypersw.system.autoUpgradeTransactional = {
      productionInputs = lib.mkDefault productionInputs;
      candidateInputs = lib.mkDefault candidateInputs;
    };

    system.activationScripts.localFlake = ''
      mkdir -p /etc/nixos

      # /etc/nixos/flake.nix is module-owned (the template in
      # Modules/System/LocalFlakeShim). Rewrite on every activation,
      # atomically via temp+rename so a power-loss mid-write can't
      # corrupt the file.
      FLAKE_TMP=$(mktemp /etc/nixos/.flake.nix.XXXXXX)
      cat > "$FLAKE_TMP" << 'FLAKE'
      ${flakeText}FLAKE
      chmod 0644 "$FLAKE_TMP"
      mv -f "$FLAKE_TMP" /etc/nixos/flake.nix

      # /etc/nixos/flake.lock is operator state — mutated by
      # `nix flake update`, `promote-candidate`, etc. Bake on
      # first boot when the upstream pin is known; never overwrite
      # afterwards.
    '' + lib.optionalString (pin != null) ''
      if [ ! -f /etc/nixos/flake.lock ]; then
        install -m 0644 ${bakedLock} /etc/nixos/flake.lock
      fi
    '';
  };
}
