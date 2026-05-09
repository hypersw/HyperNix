{ config, lib, pkgs, ... }:
let
  cfg = config.programs.btm;

  # Default fork source: pin a specific rev on github.com/hypersw/bottom.
  # Bumping requires updating both `rev` and `sha256` here. Override
  # `programs.btm.fork.src` with a local path if you're iterating on the
  # fork before pushing.
  defaultForkSrc = pkgs.fetchFromGitHub {
    owner = "hypersw";
    repo = "bottom";
    rev = "435d3d29f1069c85adc2888bb830a46a36309120"; # f/strict-overcommit-mode tip
    sha256 = "0388d85y55cz894jv5d8ah86af26hlk9qizx5dk6s2kn5zd2rdk0";
  };

  # Build the fork by overriding `pkgs.bottom`'s src. The fork shares
  # `Cargo.lock` with upstream 0.12.3, so the cargoHash from nixpkgs
  # remains valid — no override needed. If a future fork rebase touches
  # Cargo.lock, set `cargoHash = lib.fakeHash;` here, run `nix build`
  # once, and copy the printed hash.
  #
  # Local-path overrides: `cfg.fork.src` can also be set to a path on
  # disk (e.g. /home/foo/Projects/External/bottom). When that path
  # doesn't exist, we fall back to `pkgs.bottom` with a warning so a
  # fresh-clone host can still rebuild.
  forkPackage =
    let
      src = cfg.fork.src;
      srcOk =
        # `fetchFromGitHub` returns a /nix/store path that always exists.
        # `builtins.pathExists` covers both that case and user-supplied
        # filesystem paths during development.
        builtins.pathExists src;
    in
      if srcOk
      then pkgs.bottom.overrideAttrs (old: {
        version = "${old.version}-strict-overcommit";
        src = src;
      })
      else lib.warn
        ("programs.btm.fork.src does not exist at ${toString src}; "
         + "falling back to upstream pkgs.bottom.")
        pkgs.bottom;

  # The actual binary the rest of the module wires up.
  pkg = if cfg.fork.enable then forkPackage else pkgs.bottom;

  # TOML rendering of cfg.settings.config. Strip the deployment metadata
  # (`users`) so it doesn't leak into the rendered TOML — users is a Nix
  # module concern, not a btm config key.
  tomlFormat = pkgs.formats.toml { };
  tomlContent = builtins.removeAttrs cfg.settings [ "deployToUsers" ];
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
        default = defaultForkSrc;
        defaultText = lib.literalExpression ''
          pkgs.fetchFromGitHub {
            owner = "hypersw"; repo = "bottom";
            rev = "<pinned tip of f/strict-overcommit-mode>";
            sha256 = "<...>";
          };
        '';
        description = ''
          Source for the bottom fork. By default a `fetchFromGitHub`
          pin on `hypersw/bottom`; override with a local path (e.g.
          `/home/work/Projects/External/bottom`) while iterating
          locally — anything `lib.types.path` accepts works.
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
      # The `deployToUsers` key sits *inside* settings on purpose: it has no
      # effect unless settings has TOML content, and putting them
      # together makes the dependency obvious at the call site. The
      # serializer strips `deployToUsers` before writing TOML so it never
      # leaks into bottom.toml as a bogus key.
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          deployToUsers = [ "work" ];   # render this settings file for these users
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
        TOML settings for `bottom.toml`. Two kinds of keys:

        * `deployToUsers` — *reserved*, list of usernames. The rendered
          TOML (everything else under `settings`) gets symlinked into
          each listed user's `~/.config/bottom/bottom.toml`. Empty or
          absent ⇒ no per-user files written. This key is stripped
          before serialization so it never lands in bottom.toml.

        * everything else — verbatim btm config, see the
          [bottom config docs](https://bottom.pages.dev/stable/configuration/config-file/).

        Note: btm reads only one config file per invocation, with no
        merge against a system template. The deployment is therefore
        whole-file replacement, scoped to the explicit `deployToUsers`
        list. There is no system → user layering.
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
       deployToUsers = cfg.settings.deployToUsers or [ ];
       hasContent = tomlContent != { };
     in lib.mkIf (deployToUsers != [ ] && hasContent) {
      # tmpfiles "L+" symlinks into $HOME — bypasses user ownership but
      # bottom never writes to its config so that's fine. Re-runs of
      # `nixos-rebuild switch` re-link, so settings edits propagate
      # without the user touching anything.
      systemd.tmpfiles.rules = lib.flatten (map (user: [
        "d /home/${user}/.config 0755 ${user} users -"
        "d /home/${user}/.config/bottom 0755 ${user} users -"
        "L+ /home/${user}/.config/bottom/bottom.toml - - - - ${configFile}"
      ]) deployToUsers);
    })
  ]);
}
