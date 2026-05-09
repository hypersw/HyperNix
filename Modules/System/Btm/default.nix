{ config, lib, pkgs, ... }:
let
  cfg = config.programs.btm;

  # Optional fork build: bottom (btm) patched to surface Private Commit per
  # process and a Committed_AS / CommitLimit gauge in the memory widget,
  # both gated by `vm.overcommit_memory == 2`. Driven by cfg.fork.enable.
  # When the source path doesn't yet exist on the host, we fall through to
  # the upstream package and emit a warning at eval time, so a fresh
  # deploy can't break.
  forkPackage =
    let
      src = cfg.fork.src;
      # Path-existence check at module-eval time (not as a derivation): if
      # the path doesn't exist, fall back. This lets the same config land
      # on machines that don't have the fork checked out yet.
      srcExists = builtins.pathExists src;
    in
      if srcExists
      then pkgs.bottom.overrideAttrs (old: {
        version = "${old.version}-strict-overcommit";
        src = src;
        # Fork uses the same Cargo.lock as upstream 0.12.3, so re-use the
        # cargoHash from nixpkgs. If upstream nixpkgs bumps to a version
        # that bumps Cargo.lock, set this to `lib.fakeHash` and `nix
        # build` once to learn the new hash.
      })
      else lib.warn
        ("programs.btm.fork.src does not exist at ${toString src}; "
         + "falling back to upstream pkgs.bottom. Clone the fork first.")
        pkgs.bottom;

  # The actual binary the rest of the module wires up.
  pkg = if cfg.fork.enable then forkPackage else pkgs.bottom;

  # TOML rendering of cfg.settings.config. Strip the deployment metadata
  # (`users`) so it doesn't leak into the rendered TOML — users is a Nix
  # module concern, not a btm config key.
  tomlFormat = pkgs.formats.toml { };
  tomlContent = builtins.removeAttrs cfg.settings [ "users" ];
  configFile = tomlFormat.generate "bottom.toml" tomlContent;

in {
  options.programs.btm = {
    enable = lib.mkEnableOption "the bottom (btm) system monitor";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkg;
      defaultText = lib.literalExpression
        "if cfg.fork.enable then forkPackage else pkgs.bottom";
      description = ''
        The btm package to install. Defaults to the locally-built fork
        when `fork.enable` is true (the default), or to the upstream
        `pkgs.bottom` otherwise.
      '';
    };

    fork = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Use the locally-built fork that adds a Private Commit
          (`PrivCmt`) column to the process widget and a
          `Committed_AS / CommitLimit` gauge to the memory widget,
          both shown by default when the kernel runs
          `vm.overcommit_memory=2`. The fork source is read from
          `programs.btm.fork.src`; if that path does not exist on the
          host, the upstream `pkgs.bottom` is used instead and a build
          warning is emitted, so a fresh-clone machine doesn't break.

          Default is true: the fork is the point of this module. Flip
          to false to fall back to plain upstream `pkgs.bottom`.
        '';
      };

      src = lib.mkOption {
        type = lib.types.path;
        default = /home/work/Projects/External/bottom;
        description = ''
          Path to the local clone of the bottom fork. Only consulted
          when `fork.enable` is true. The default points at the
          author's working copy; override per-host if your layout
          differs. Once the fork is published to GitHub, replace this
          with `pkgs.fetchFromGitHub { ... }`.
        '';
      };
    };

    security.wrap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, install a wrapper at `/run/wrappers/bin/btm` with
        `cap_sys_ptrace+ep` so btm can read `/proc/<pid>/smaps_rollup`
        for processes owned by other users. Required for accurate Pss
        accounting in the process widget when run unprivileged. The
        path `/run/wrappers/bin` precedes `~/.nix-profile/bin` on the
        default NixOS PATH, so the wrapped binary wins; the unwrapped
        copy in the user profile is left alone.
      '';
    };

    settings = lib.mkOption {
      # We allow the user to put `users = [ ... ]` *next to* the bottom
      # TOML keys here, treating it as deployment metadata that's
      # stripped before serialization. The alternative (sibling-of-
      # `settings` option) made the dependency invisible: `users` only
      # has any effect when `settings` is non-empty, and putting them
      # together makes that obvious at the call site.
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          users = [ "work" ];     # deployment metadata (stripped from TOML)
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
        TOML settings for `bottom.toml`. The reserved key `users` is a
        list of usernames whose `~/.config/bottom/bottom.toml` will be
        replaced with the rendered TOML (everything else under
        `settings`); `users` itself is stripped before serialization
        so it never lands in the file. Set `settings = {}` (the
        default) to leave each user's config alone.

        Note: btm reads only one config file per invocation (no merge
        with a system template). The deployment is therefore
        whole-file replacement, scoped to the explicit user list.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ cfg.package ];
    }

    (lib.mkIf cfg.security.wrap {
      # Wrap the *configured* package (fork or upstream) so the cap is on
      # whatever binary is actually being run. If `fork.enable` flips,
      # the wrapper rebuilds against the new path automatically.
      security.wrappers.btm = {
        source = lib.getExe cfg.package;
        capabilities = "cap_sys_ptrace+ep";
        owner = "root";
        group = "root";
        permissions = "u+rx,g+rx,o+rx";
      };
    })

    (let
       users = cfg.settings.users or [ ];
       hasContent = tomlContent != { };
     in lib.mkIf (users != [ ] && hasContent) {
      # tmpfiles "L+" symlinks into $HOME — bypasses user ownership but
      # bottom never writes to its config so that's fine. Re-runs of
      # `nixos-rebuild switch` re-link, so settings edits propagate
      # without the user touching anything.
      systemd.tmpfiles.rules = lib.flatten (map (user: [
        "d /home/${user}/.config 0755 ${user} users -"
        "d /home/${user}/.config/bottom 0755 ${user} users -"
        "L+ /home/${user}/.config/bottom/bottom.toml - - - - ${configFile}"
      ]) users);
    })
  ]);
}
