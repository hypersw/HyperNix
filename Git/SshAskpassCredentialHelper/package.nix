{ pkgs, closefrom3 }:
let
  flakeName = import ../../flake-name.nix;
  envPrefix = "${pkgs.lib.toUpper flakeName}_SSH_ASKPASS";
  timeoutVar      = "${envPrefix}_TIMEOUT";
  perTokenPinVar  = "${envPrefix}_PER_TOKEN_PIN";
in
pkgs.writeShellScriptBin "ssh-askpass-credential-helper" ''
  # SSH_ASKPASS helper that caches prompts via git credential-cache.
  #
  # PKCS#11 PIN prompts ("Enter PIN for '...':") are recognized specially.
  # All other prompts (passphrases, passwords) are also cached, each
  # under its own full prompt string as cache key.
  #
  # Cache miss prompts via zenity (GUI dialog) since SSH runs askpass
  # detached from the terminal.
  #
  # Uses closefrom3 to prevent git credential-cache's daemon from inheriting
  # the SSH pipe fd (which would keep the pipe open and hang SSH).
  #
  # Config is read from env vars, which the NixOS module sets locally via
  # `makeWrapper --set` on this binary (so no global env pollution, and the
  # names are namespaced to this flake):
  #   ${timeoutVar}         Cache timeout in seconds (default: 3600)
  #   ${perTokenPinVar}     Non-empty → each PIN prompt is its own cache
  #                         slot; empty → all PIN prompts share "pkcs11-pin"
  #
  # See: TpmSshSetup.md in this repo for context.

  prompt="''${1:-}"
  timeout="''${${timeoutVar}:-3600}"
  per_token_pin="''${${perTokenPinVar}:-}"

  # Determine cache key
  case "$prompt" in
    "Enter PIN for '"*)
      if [ -n "$per_token_pin" ]; then
        cache_key="$prompt"
      else
        cache_key="pkcs11-pin"
      fi
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
  value=$(${pkgs.zenity}/bin/zenity --password --title="$prompt" 2>/dev/null) || exit 1

  # Output to SSH
  echo "$value"

  # Store in cache — closefrom3 closes all fds >= 3 via close_range(2)
  # before exec'ing git, preventing credential-cache's daemon from
  # inheriting the SSH pipe fd
  printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$value" \
    | ${closefrom3}/bin/closefrom3 \
      ${pkgs.git}/bin/git credential-cache --timeout="$timeout" store \
      >/dev/null 2>/dev/null
''
