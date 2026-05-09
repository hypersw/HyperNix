{ config, lib, pkgs, ... }:
let
  cfg = config.programs.btm;

  # Optional fork build: bottom (btm) patched to surface Private Commit per
  # process and (later) a Committed_AS gauge in the memory widget. Driven
  # only when cfg.useStrictOvercommitFork is on. When the source path
  # doesn't yet exist on the host, we fall through to the upstream package
  # and emit a warning at eval time, so a fresh deploy doesn't crash.
  forkPackage =
    let
      src = cfg.fork.src;
      # Validate at module-eval time (not as a derivation): if the path
      # doesn't exist, fall back. This lets the same config land on
      # machines that don't have the fork checked out yet.
      srcExists = builtins.pathExists src;
    in
      if srcExists
      then pkgs.bottom.overrideAttrs (old: {
        # Use cargoHash from upstream; the patch surface here is small
        # enough that re-using the same vendored deps is fine (no Cargo.lock
        # changes). If upstream bumps cargoHash, override will still work
        # because the vendored content is keyed off Cargo.lock, which we
        # didn't touch.
        version = "${old.version}-strict-overcommit";
        src = src;
        # Fork uses the same Cargo.lock as upstream 0.12.3, so re-use the
        # cargoHash from nixpkgs. If that ever drifts, set this to
        # `lib.fakeHash` and `nix build` to learn the new hash.
      })
      else lib.warn
        ("programs.btm.fork.src does not exist at ${toString src}; "
         + "falling back to upstream pkgs.bottom. Clone the fork first.")
        pkgs.bottom;

  # The actual binary the rest of the module wires up.
  pkg =
    if cfg.useStrictOvercommitFork
    then forkPackage
    else pkgs.bottom;

  # TOML rendering of cfg.settings. We use formats.toml so attrset → TOML
  # serialization mirrors upstream `programs.bottom` (home-manager) output.
  tomlFormat = pkgs.formats.toml { };

  configFile = tomlFormat.generate "bottom.toml" cfg.settings;

in {
  options.programs.btm = {
    enable = lib.mkEnableOption "the bottom (btm) system monitor";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkg;
      defaultText = lib.literalExpression
        "if cfg.useStrictOvercommitFork then forkPackage else pkgs.bottom";
      description = ''
        The btm package to install. Defaults to the upstream
        `pkgs.bottom`, or to a locally-built fork if
        `useStrictOvercommitFork` is enabled and `fork.src` exists.
      '';
    };

    useStrictOvercommitFork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use the locally-built fork that adds a Private Commit (`PrivCmt`)
        column to the process widget by default when the kernel runs
        `vm.overcommit_memory=2` (strict no-overbooking). The fork source
        path is read from `programs.btm.fork.src`; if that path does not
        exist on the host, the upstream `pkgs.bottom` is used and a build
        warning is emitted so a fresh-clone machine doesn't break.
      '';
    };

    fork.src = lib.mkOption {
      type = lib.types.path;
      default = /home/work/Projects/External/bottom;
      description = ''
        Path to the local clone of the bottom fork. Only consulted when
        `useStrictOvercommitFork` is true. The default points at the
        author's working copy; override per-host if your layout differs.
      '';
    };

    security.wrap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, install a setuid-style wrapper at `/run/wrappers/bin/btm`
        with `cap_sys_ptrace+ep` so btm can read `/proc/<pid>/smaps_rollup`
        for processes owned by other users. This is required for accurate
        Pss / private-resident accounting in the process widget when run
        unprivileged. Trade-off: the wrapped binary path is owned by
        root and the cap is granted to that exact path; the unwrapped
        binary in the user profile remains uncapped. The path
        `/run/wrappers/bin` precedes `~/.nix-profile/bin` in the default
        NixOS PATH, so the wrapped one wins.
      '';
    };

    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          flags = {
            rate = "1s";
            process_command = true;
            process_memory_as_value = true;
            tree = true;
            default_widget_type = "proc";
          };
        }
      '';
      description = ''
        TOML settings rendered to `bottom.toml`. When `users` is non-empty
        the file is symlinked into each listed user's
        `~/.config/bottom/bottom.toml` via systemd-tmpfiles. Set this to
        `{}` (the default) to leave each user's config untouched.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "work" ];
      description = ''
        Users whose `~/.config/bottom/bottom.toml` should be replaced with
        the rendered `settings`. Empty list = no per-user files written
        (just install the package, optionally with the security wrapper).
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ cfg.package ];
    }

    (lib.mkIf cfg.security.wrap {
      # Wrap the *configured* package (fork or upstream) so the cap is on
      # whatever binary is actually being run. If the user later flips
      # `useStrictOvercommitFork`, the wrapper rebuilds against the new
      # path automatically.
      security.wrappers.btm = {
        source = lib.getExe cfg.package;
        capabilities = "cap_sys_ptrace+ep";
        owner = "root";
        group = "root";
        permissions = "u+rx,g+rx,o+rx";
      };
    })

    (lib.mkIf (cfg.users != [ ] && cfg.settings != { }) {
      # tmpfiles "L+" symlinks into $HOME bypass the user's ownership of
      # ~/.config/bottom — fine because the file is read-only Nix-store
      # content and bottom doesn't try to write back to it. Re-runs of
      # `nixos-rebuild switch` re-link, so config edits propagate without
      # the user having to do anything.
      systemd.tmpfiles.rules = lib.flatten (map (user: [
        "d /home/${user}/.config 0755 ${user} users -"
        "d /home/${user}/.config/bottom 0755 ${user} users -"
        "L+ /home/${user}/.config/bottom/bottom.toml - - - - ${configFile}"
      ]) cfg.users);
    })
  ]);
}
