{
  description = "SSH_ASKPASS helper that caches PKCS#11 PINs via git credential-cache";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    closefrom3 = {
      url = "path:../../Util/CloseFrom3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, closefrom3 }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      mkScript = pkgs: { timeout, perTokenPin }:
        let
          closefrom = closefrom3.packages.${pkgs.system}.default;
          zenity = pkgs.zenity;
        in
        pkgs.writeShellScriptBin "ssh-askpass-credential-helper" ''
        # SSH_ASKPASS helper that caches prompts via git credential-cache.
        #
        # PKCS#11 PIN prompts ("Enter PIN for '...':") are recognized specially.
        # All other prompts (passphrases, passwords) are also cached, each
        # under its own full prompt string as cache key.
        #
        # PIN cache key behavior (compile-time choice):
        #   per-token-pin=false (default): all PIN prompts share one cache slot
        #   per-token-pin=true: each token gets its own cached PIN
        #
        # Cache miss prompts via zenity (GUI dialog) since SSH runs askpass
        # detached from the terminal.
        #
        # Uses closefrom3 to prevent git credential-cache's daemon from inheriting
        # the SSH pipe fd (which would keep the pipe open and hang SSH).
        #
        # See: TpmSshSetup.md in this repo for context.

        prompt="''${1:-}"

        # Determine cache key
        case "$prompt" in
          "Enter PIN for '"*)
            ${if perTokenPin then ''
            # Per-token mode: each PIN prompt is a separate cache key
            cache_key="$prompt"
            '' else ''
            # Unified mode: all PIN prompts share one cache slot
            cache_key="pkcs11-pin"
            ''}
            ;;
          *)
            # Non-PIN prompts: always keyed by full prompt
            cache_key="$prompt"
            ;;
        esac

        # Check cache
        cached=$(printf 'protocol=pkcs11\nhost=%s\n' "$cache_key" \
          | ${pkgs.git}/bin/git credential-cache get 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep '^password=' | cut -d= -f2-)

        if [ -n "$cached" ]; then
          echo "$cached"
          exit 0
        fi

        # Cache miss — prompt via GUI dialog (askpass has no terminal)
        value=$(${zenity}/bin/zenity --password --title="$prompt" 2>/dev/null) || exit 1

        # Output to SSH
        echo "$value"

        # Store in cache — closefrom3 closes all fds >= 3 via close_range(2)
        # before exec'ing git, preventing credential-cache's daemon from
        # inheriting the SSH pipe fd
        printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$value" \
          | ${closefrom}/bin/closefrom3 \
            ${pkgs.git}/bin/git credential-cache --timeout=${toString timeout} store \
            >/dev/null 2>/dev/null
      '';
    in
    {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = mkScript pkgs { timeout = 3600; perTokenPin = false; };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.ssh-askpass-credential-helper;
        in
        {
          options.programs.ssh-askpass-credential-helper = {
            enable = lib.mkEnableOption "SSH_ASKPASS helper that caches PKCS#11 PINs via git credential-cache";

            timeout = lib.mkOption {
              type = lib.types.int;
              default = 3600;
              description = "Cache timeout in seconds";
            };

            perTokenPin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Cache PINs per token (true) or use one shared PIN for all tokens (false)";
            };
          };

          config = lib.mkIf cfg.enable (let pkg = mkScript pkgs {
            inherit (cfg) timeout perTokenPin;
          }; in {
            environment.systemPackages = [ pkg ];

            # Use programs.ssh.askPassword instead of setting SSH_ASKPASS directly —
            # NixOS's programs/ssh.nix owns that env var and conflicts otherwise
            programs.ssh.enableAskPassword = true;
            programs.ssh.askPassword = "${pkg}/bin/ssh-askpass-credential-helper";

            # "prefer": try askpass first (hits cache silently), fall back to terminal.
            # Without this, SSH only uses askpass when there's no controlling terminal,
            # bypassing the cache in interactive sessions.
            environment.sessionVariables.SSH_ASKPASS_REQUIRE = "prefer";
          });
        };
    };
}
