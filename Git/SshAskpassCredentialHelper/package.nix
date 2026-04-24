{ pkgs, closefrom3, timeout ? 3600, perTokenPin ? false }:
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
  value=$(${pkgs.zenity}/bin/zenity --password --title="$prompt" 2>/dev/null) || exit 1

  # Output to SSH
  echo "$value"

  # Store in cache — closefrom3 closes all fds >= 3 via close_range(2)
  # before exec'ing git, preventing credential-cache's daemon from
  # inheriting the SSH pipe fd
  printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$value" \
    | ${closefrom3}/bin/closefrom3 \
      ${pkgs.git}/bin/git credential-cache --timeout=${toString timeout} store \
      >/dev/null 2>/dev/null
''
