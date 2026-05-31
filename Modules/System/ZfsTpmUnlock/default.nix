#
# TPM-sealed ZFS encryption-key unlock at boot.
#
# Each entry under `hypersw.services.zfs-tpm-unlock.keys.<name>` becomes
# a `zfs-tpm-unlock-<name>.service` oneshot that, after pool import:
#
#   1. tpm2_createprimary in the configured hierarchy
#   2. tpm2_load <sealedPublic> + <sealedPrivate> under that parent
#   3. tpm2_startauthsession + tpm2_policypcr with the configured PCR list
#   4. tpm2_unseal --output - | zfs load-key -L file:///dev/stdin <dataset>
#      (key bytes never touch disk — pipeline only)
#   5. tpm2_flushcontext on the policy session
#
# Downstream systemd.mounts / fileSystems gate on the service via
# `after = [ <serviceName-of-the-entry> ]`, or on the aggregate target
# `after = [ <targetName> ]` for "all configured keys loaded".
# Both names are exposed as read-only module options so consumers can
# reference them by attribute path instead of hardcoding strings.
#
# The on-disk .pub / .priv blobs are useless without this specific TPM
# and a matching PCR state, so storing them plaintext on the rootfs is
# fine — that's the whole point of TPM sealing.
#
# Sealing the key in the first place is out of scope of this NixOS
# module; the paired CLI `zfs-tpm-key` (in package.nix) handles
# both first-time `seal` and post-PCR-change re-`seal`, plus
# random-key `gen-key` and unseal `test`.

{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.services.zfs-tpm-unlock;
  inherit (lib) mkIf mkOption types
                mapAttrs' nameValuePair attrNames
                elemAt splitString optionalString literalExpression;

  # Sealing/resealing CLI — same defaults as the module, so
  # `zfs-tpm-key seal --name foo` produces blobs the `keys.foo`
  # entry can unseal without further config.
  keyTool = import ./package.nix { inherit pkgs; };

  hasKeys = cfg.keys != { };
  # Tri-state activation: by default ("auto") the module is fully
  # passive until at least one `keys.<name>` entry exists, in line
  # with the "all modules always available but passive until
  # triggered" principle of the HyperNix bundle. The "on" override
  # exists to break the bootstrap chicken-and-egg — you need the
  # `zfs-tpm-key` CLI on PATH to seal a *first* key, but with pure
  # `auto` the CLI only appears once `keys` has an entry that
  # references blobs you don't have yet. "off" is the escape
  # hatch: disable everything even when entries are declared.
  active =
       cfg.enable == "on"
    || (cfg.enable == "auto" && hasKeys);

  entryType = types.submodule ({ name, config, ... }: {
    options = {
      dataset = mkOption {
        type = types.str;
        example = "tank/encrypted";
        description = ''
          The ZFS dataset whose encryption key should be loaded.
          May be a pool root (e.g. "tank") or any encryption-root
          child (e.g. "tank/encrypted"). The dataset must already
          exist with its keyformat / encryption set up; this
          module only loads the key, it does not create or encrypt
          the dataset.
        '';
      };

      pool = mkOption {
        type = types.str;
        default = elemAt (splitString "/" config.dataset) 0;
        defaultText = literalExpression "first path component of `dataset`";
        description = ''
          The pool to import before loading the key. Defaults to the
          first path component of `dataset`, which is the right
          answer when the dataset is `pool` or `pool/child/...`.
        '';
      };

      sealedPublic = mkOption {
        type = types.str;
        example = "/var/lib/volumes/home.pub";
        description = ''
          Runtime filesystem path to the TPM-sealed object's public
          blob (output of `tpm2_create --public`). Typed as `str`,
          not `path`, to keep this out of the Nix store — the blob
          is harmless without the TPM but there's no reason to copy
          it into a world-readable store entry.
        '';
      };

      sealedPrivate = mkOption {
        type = types.str;
        example = "/var/lib/volumes/home.priv";
        description = ''
          Runtime path to the sealed object's private blob (output
          of `tpm2_create --private`). Same plaintext-OK + keep-out-
          of-store rationale as `sealedPublic`.
        '';
      };

      pcrList = mkOption {
        type = types.str;
        default = "sha256:0";
        example = "sha256:0,2,7";
        description = ''
          The PCR list passed to `tpm2_policypcr --pcr-list` when
          building the unseal session — must match the policy the
          key was sealed under. The default `sha256:0` is firmware
          measurement only; widen (e.g. `sha256:0,7` to include
          Secure Boot state) for stricter tamper-evidence at the
          cost of brittleness across firmware updates.
        '';
      };

      tpmHierarchy = mkOption {
        type = types.enum [ "o" "p" "e" "n" ];
        default = "o";
        description = ''
          TPM hierarchy under which the primary key is created at
          load time: o(wner) | p(latform) | e(ndorsement) | n(ull).
          Must match the hierarchy used when the object was sealed.
        '';
      };

      importPoolIfNeeded = mkOption {
        type = types.bool;
        default = true;
        description = ''
          If `zpool list <pool>` shows the pool isn't imported when
          the service runs, run `zpool import <pool>` first. Set
          false when pool import is handled elsewhere (e.g.
          `boot.zfs.extraPools`) and you want this service to fail
          loudly rather than paper over a missing import.
        '';
      };

      # ── computed, read-only ────────────────────────────────────
      serviceName = mkOption {
        type = types.str;
        readOnly = true;
        default = "zfs-tpm-unlock-${name}.service";
        defaultText = literalExpression ''"zfs-tpm-unlock-''${name}.service"'';
        description = ''
          Computed name of the systemd service that unseals this
          key. Reference this in downstream `after`/`wants`/`requires`
          (`after = [ config.hypersw.services.zfs-tpm-unlock.keys.<name>.serviceName ]`)
          instead of hardcoding the literal string.
        '';
      };
    };
  });

in {
  options.hypersw.services.zfs-tpm-unlock = {
    enable = mkOption {
      type = types.enum [ "auto" "on" "off" ];
      default = "auto";
      description = ''
        Activation mode:

        - `"auto"` (default) — the module activates iff `keys` has
          at least one entry. With no entries, nothing is added to
          the system (no PATH binary, no services, no target, no
          assertion). Matches "modules always available but
          passive until triggered."

        - `"on"` — force activation even with no `keys` entries.
          Adds the `zfs-tpm-key` CLI to PATH and the
          `security.tpm2.enable` assertion. Use this to break the
          bootstrap chicken-and-egg: you need the CLI to seal a
          first key before declaring the `keys.<name>` entry that
          references the still-to-be-produced blobs.

        - `"off"` — force-disable everything even when `keys`
          entries are declared. Escape hatch for temporarily
          shutting the module down without removing the per-key
          declarations from your config.
      '';
    };

    keys = mkOption {
      type = types.attrsOf entryType;
      default = { };
      example = literalExpression ''
        {
          data = {
            dataset       = "tank/encrypted";
            sealedPublic  = "/var/lib/volumes/data.pub";
            sealedPrivate = "/var/lib/volumes/data.priv";
          };
          home = {
            dataset       = "rpool/home";
            sealedPublic  = "/var/lib/volumes/home.pub";
            sealedPrivate = "/var/lib/volumes/home.priv";
            pcrList       = "sha256:0,7";
          };
        }
      '';
      description = ''
        Map of TPM-sealed-key entries. Each attribute name `<name>`
        produces a `zfs-tpm-unlock-<name>.service` oneshot whose
        unit name is exposed at `.<name>.serviceName`. Define one
        entry per pool or encryption-root dataset.
      '';
    };

    # ── computed, read-only ────────────────────────────────────
    targetName = mkOption {
      type = types.str;
      readOnly = true;
      default = "zfs-tpm-unlock.target";
      description = ''
        Computed name of the aggregate systemd target that pulls in
        every `zfs-tpm-unlock-<name>.service` defined in `keys`.
        Reference this from any consumer that needs "all configured
        ZFS keys loaded" gating without enumerating individual
        entries:

            after = [ config.hypersw.services.zfs-tpm-unlock.targetName ];
      '';
    };
  };

  config = mkIf active {
    assertions = [
      {
        # The bare `security.tpm2.enable = true` gives us everything
        # this module needs: kernel TPM driver, /dev/tpmrm0 with the
        # tss group owning it (0660), and tpm2-tools on PATH. We
        # don't care whether the host additionally runs abrmd or
        # has tctiEnvironment switched on — tpm2-tools auto-find a
        # working TCTI (default `/dev/tpmrm0` if present, else
        # `tabrmd:`) and we never pass `--tcti` so we don't fight
        # whichever the host picked. Hence: single assertion, no
        # extra requirements, no `mkDefault` opinions about
        # neighbouring tpm2 sub-options.
        assertion = config.security.tpm2.enable;
        message = ''
          hypersw.services.zfs-tpm-unlock requires `security.tpm2.enable = true`
          on the host. That single option is sufficient: it loads the
          kernel TPM driver, owns /dev/tpm* under tss, and provides
          tpm2-tools. Whether the host additionally uses abrmd or
          kernel-RM, and whether PKCS#11 is enabled, doesn't matter
          to this module.
        '';
      }
    ];

    # Make the seal/reseal CLI available on activated hosts.
    # Activation is gated by `active`, so `enable = "on"` brings
    # the CLI even with no `keys` entries (bootstrap mode), and
    # `enable = "off"` removes it even with entries declared.
    environment.systemPackages = [ keyTool ];

    # Per-key services materialise from `cfg.keys`; an empty
    # `keys` (e.g. `enable = "on"` with no entries) yields no
    # services and no aggregate target — only the CLI surfaces.
    systemd.services = mapAttrs'
      (name: keyCfg: nameValuePair "zfs-tpm-unlock-${name}" {
        description = "Unseal TPM key and zfs load-key for ${keyCfg.dataset}";

        # zfs-import.target so any auto-imported pools are already up;
        # sysinit.target so /run etc. are ready for our scratch files.
        after    = [ "zfs-import.target" "sysinit.target" ];
        before   = [ "multi-user.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type            = "oneshot";
          RemainAfterExit = "yes";
          Restart         = "on-failure";
          RestartSec      = "32s";
        };

        script = ''
          set -euo pipefail

          # Default TCTI to the kernel resource manager so tpm2-tools
          # don't waste a probe trying tabrmd (and emit noisy
          # ServiceUnknown D-Bus errors) on hosts that don't run
          # abrmd. Respects an existing setting.
          : "''${TPM2TOOLS_TCTI:=device:/dev/tpmrm0}"
          export TPM2TOOLS_TCTI

          ${optionalString keyCfg.importPoolIfNeeded ''
            echo Import Pool If Needed
            ${pkgs.zfs}/bin/zpool list "${keyCfg.pool}" >/dev/null 2>&1 \
              || ${pkgs.zfs}/bin/zpool import "${keyCfg.pool}"
          ''}

          echo Check Key Status
          if [ "$(${pkgs.zfs}/bin/zfs get -H -o value keystatus "${keyCfg.dataset}")" = "available" ]; then
            echo Key Already Loaded — Nothing to Do
            exit 0
          fi

          # TPM session contexts only — the key bytes never touch
          # disk; we pipe tpm2_unseal's stdout straight into
          # zfs load-key via /dev/stdin.
          TMP_CTX_PRIMARY=$(${pkgs.coreutils}/bin/mktemp /run/zfs-tpm-${name}.ctx.primary.XXXXXX)
          TMP_CTX_LOADED=$(${pkgs.coreutils}/bin/mktemp  /run/zfs-tpm-${name}.ctx.loaded.XXXXXX)
          TMP_CTX_SESSION=$(${pkgs.coreutils}/bin/mktemp /run/zfs-tpm-${name}.ctx.session.XXXXXX)
          trap '${pkgs.coreutils}/bin/rm -f "$TMP_CTX_PRIMARY" "$TMP_CTX_LOADED" "$TMP_CTX_SESSION"' EXIT

          echo Create Primary
          ${pkgs.tpm2-tools}/bin/tpm2_createprimary --hierarchy   ${keyCfg.tpmHierarchy} \
                                                    --key-context "$TMP_CTX_PRIMARY"

          echo Load
          ${pkgs.tpm2-tools}/bin/tpm2_load --public         ${keyCfg.sealedPublic} \
                                            --private        ${keyCfg.sealedPrivate} \
                                            --parent-context "$TMP_CTX_PRIMARY" \
                                            --key-context    "$TMP_CTX_LOADED"

          echo Start Auth Session
          ${pkgs.tpm2-tools}/bin/tpm2_startauthsession --policy-session \
                                                       --session "$TMP_CTX_SESSION"

          echo Policy PCR
          ${pkgs.tpm2-tools}/bin/tpm2_policypcr --session  "$TMP_CTX_SESSION" \
                                                 --pcr-list ${keyCfg.pcrList}

          echo Unseal Into Load-Key Pipe
          ${pkgs.tpm2-tools}/bin/tpm2_unseal --object-context "$TMP_CTX_LOADED" \
                                              --auth           "session:$TMP_CTX_SESSION" \
                                              --output         - \
            | ${pkgs.zfs}/bin/zfs load-key -L file:///dev/stdin "${keyCfg.dataset}"

          echo Flush Context
          ${pkgs.tpm2-tools}/bin/tpm2_flushcontext "$TMP_CTX_SESSION"
        '';
      })
      cfg.keys;

    # Aggregate target — consumers wanting "all configured keys
    # loaded" gate on this fixed name (referenced via `targetName`)
    # instead of enumerating per-entry service names. Only defined
    # when there's actually something to aggregate.
    systemd.targets = mkIf hasKeys {
      zfs-tpm-unlock = {
        description = "All TPM-sealed ZFS keys loaded";
        wants    = map (n: "zfs-tpm-unlock-${n}.service") (attrNames cfg.keys);
        after    = map (n: "zfs-tpm-unlock-${n}.service") (attrNames cfg.keys);
        wantedBy = [ "multi-user.target" ];
      };
    };
  };
}
