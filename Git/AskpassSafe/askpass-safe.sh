#!/usr/bin/env bash
# askpass-safe - SSH_ASKPASS / SUDO_ASKPASS prompter that never hangs, with
# git credential-cache memoization. Successor to ssh-askpass-credential-helper,
# whose single unconditional `zenity` call wedges forever on a dead X display.
#
# Two ways to use it, and it tells them apart by itself:
#
#   . …/bin/askpass-safe            sourced: installs itself into the shell
#                                   (exports SSH_ASKPASS/SUDO_ASKPASS, repairs
#                                   a dead DISPLAY, prints a short summary)
#   askpass-safe "prompt"           executed: acts as the askpass prompter
#   askpass-safe --forget           drops cached secrets, stops the cache daemon
#
# On a cache miss it prompts through a ladder of tiers, each time-bounded
# (override the order with ASKPASS_SAFE_ORDER):
#   tty  - prompt on /dev/tty (works over a plain terminal session)
#   gui  - zenity, but only after a bounded probe proves the X display answers
#   fifo - broadcast the prompt to the user's terminals and read the answer
#          from a FIFO, so it can be answered from any later-attached shell
#
# Why the probe exists: a dead X display (a stale xpra session, an orphaned
# ssh -X forward) accepts connect() and then never answers the X11 setup
# request, so a GTK client blocks inside XOpenDisplay before it can create a
# window or print a diagnostic. Socket existence proves nothing; only a
# completed handshake does. Under machinectl+xpra several displays behave that
# way at once, which is why picking a live one is worth doing at login.
#
# The @-delimited tokens are filled in by package.nix. An unsubstituted copy of
# this file (installed ad hoc, outside Nix) still runs: every one of them
# falls back to a PATH lookup or a built-in default. That is deliberate - the
# same file serves as the Nix source and as a standalone script.

# ------------------------------------------------------------- sourced ----
# This must stay above `set -u` and the config block: neither may leak into
# an interactive shell. The real work is delegated to a child in exec mode,
# which prints exports on stdout and the human summary on stderr, so nothing
# here needs the definitions further down.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  __askpass_safe_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_EVAL_CONTEXT:-}" ] && case "$ZSH_EVAL_CONTEXT" in *:file) true ;; *) false ;; esac; then
  __askpass_safe_self="${(%):-%x}"
fi
if [ -n "${__askpass_safe_self:-}" ]; then
  __askpass_safe_self="$(cd "$(dirname "$__askpass_safe_self")" && pwd)/$(basename "$__askpass_safe_self")"
  case "$-" in
    *i*) eval "$("$__askpass_safe_self" --bootstrap-env --intro)" ;;
    *)   eval "$("$__askpass_safe_self" --bootstrap-env 2>/dev/null)" ;;
  esac
  unset __askpass_safe_self
  return 0
fi

set -u

# A build-time value, or the fallback when this copy was never substituted.
subst() { case "$1" in @*@) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
# Same, for tool paths: an unsubstituted or missing path defers to PATH.
tool() {
  case "$1" in @*@) ;; *) [ -x "$1" ] && { printf '%s' "$1"; return 0; } ;; esac
  command -v "$2" 2>/dev/null || ls /nix/store/*/bin/"$2" 2>/dev/null | head -1
}

: "${ASKPASS_SAFE_ORDER:=$(subst '@order@' 'tty,gui,fifo')}"
: "${ASKPASS_SAFE_X_TIMEOUT:=$(subst '@xTimeout@' '2')}"        # wait for the X handshake
: "${ASKPASS_SAFE_GUI_TIMEOUT:=$(subst '@guiTimeout@' '120')}"  # wait for the dialog to be answered
: "${ASKPASS_SAFE_FIFO_TIMEOUT:=$(subst '@fifoTimeout@' '300')}"
: "${ASKPASS_SAFE_CACHE:=1}"                                    # 0 disables caching entirely
: "${ASKPASS_SAFE_CACHE_TIMEOUT:=$(subst '@cacheTimeout@' '3600')}"
: "${ASKPASS_SAFE_PER_TOKEN_PIN:=$(subst '@perTokenPin@' '')}"  # non-empty: one slot per PIN prompt
: "${ASKPASS_SAFE_FIX_DISPLAY:=$(subst '@fixDisplay@' '1')}"    # on bootstrap, move off a dead DISPLAY

log() { [ -n "${ASKPASS_SAFE_DEBUG:-}" ] && printf '[askpass-safe] %s\n' "$*" >&2; return 0; }

XDPYINFO="$(tool '@xdpyinfo@' xdpyinfo)"
ZENITY="$(tool '@zenity@' zenity)"
GIT="$(tool '@git@' git)"
# git credential-cache forks a daemon that would inherit ssh's askpass pipe and
# hold it open, hanging ssh; closefrom3 close_range()s fds >= 3 before the exec.
# Without it, caching is skipped rather than risk that hang.
CLOSEFROM3="$(tool '@closefrom3@' closefrom3)"

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
prompt="${1:-Password:}"

# ---------------------------------------------------------------- cache ----

# PIN prompts share one slot by default, so unlocking a second key on the same
# token does not re-prompt; everything else is keyed by its full prompt string.
case "$prompt" in
  "Enter PIN for '"*) [ -n "$ASKPASS_SAFE_PER_TOKEN_PIN" ] && cache_key="$prompt" || cache_key="pkcs11-pin" ;;
  *)                  cache_key="$prompt" ;;
esac
cache_key="${cache_key//$'\n'/ }"  # the credential protocol is line-based

cache_usable() {
  [ "$ASKPASS_SAFE_CACHE" != 0 ] || { log "cache disabled"; return 1; }
  [ -n "$GIT" ]        || { log "no git; cache off"; return 1; }
  [ -n "$CLOSEFROM3" ] || { log "no closefrom3; cache off (would risk hanging ssh)"; return 1; }
}

cache_get() {
  cache_usable || return 1
  local v
  v="$(printf 'protocol=pkcs11\nhost=%s\n' "$cache_key" \
       | "$GIT" credential-cache get 2>/dev/null \
       | sed -n 's/^password=//p')"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

cache_store() {
  cache_usable || return 0
  printf 'protocol=pkcs11\nhost=%s\nusername=tpm\npassword=%s\n' "$cache_key" "$1" \
    | "$CLOSEFROM3" "$GIT" credential-cache --timeout="$ASKPASS_SAFE_CACHE_TIMEOUT" store \
      >/dev/null 2>&1
}

cache_forget() {
  cache_usable || return 1
  printf 'protocol=pkcs11\nhost=%s\n' "$cache_key" | "$CLOSEFROM3" "$GIT" credential-cache erase >/dev/null 2>&1
  "$CLOSEFROM3" "$GIT" credential-cache exit >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------- tiers ----

# Only a completed handshake proves a display is alive, and it must be capped:
# the whole point is that a dead one never answers. The braces+redirect swallow
# the shell's own "Killed"/"Terminated" job notice.
display_alive() {
  local d="$1"
  [ -n "$d" ] || return 1
  [ -n "$XDPYINFO" ] || return 0   # cannot probe; let the tier's own timeout catch it
  { DISPLAY="$d" timeout -s KILL "$ASKPASS_SAFE_X_TIMEOUT" "$XDPYINFO" >/dev/null 2>&1; } 2>/dev/null
}

x_alive() {
  [ -n "${DISPLAY:-}" ] || { log "DISPLAY unset"; return 1; }
  display_alive "$DISPLAY" && return 0
  log "display $DISPLAY did not answer within ${ASKPASS_SAFE_X_TIMEOUT}s"
  return 1
}

try_tty() {
  { exec 3<>/dev/tty; } 2>/dev/null || { log "no /dev/tty"; return 1; }
  printf '%s ' "$prompt" >&3
  local v
  IFS= read -rs v <&3 || { printf '\n' >&3; exec 3>&-; return 1; }
  printf '\n' >&3
  exec 3>&-
  printf '%s\n' "$v"
}

try_gui() {
  [ -n "$ZENITY" ] || { log "no zenity"; return 1; }
  x_alive || return 1
  local v
  v="$( { timeout -s KILL "$ASKPASS_SAFE_GUI_TIMEOUT" "$ZENITY" --password --title="$prompt" 2>/dev/null; } 2>/dev/null )" || return 1
  printf '%s\n' "$v"
}

# Last resort: no tty and no display. Announce on every terminal this user
# owns, then wait for someone to write the answer into the FIFO.
try_fifo() {
  local dir="${XDG_RUNTIME_DIR:-/tmp}/askpass-safe"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  local f="$dir/$$.fifo"
  rm -f "$f"
  mkfifo -m 600 "$f" || return 1
  local notice="askpass-safe: $prompt
  answer with:  cat > $f"
  local d
  for d in /dev/pts/[0-9]* /dev/tty[0-9]*; do
    [ -w "$d" ] && printf '\n%s\n' "$notice" > "$d" 2>/dev/null
  done
  log "$notice"
  local v
  v="$(timeout "$ASKPASS_SAFE_FIFO_TIMEOUT" cat "$f")" || { rm -f "$f"; return 1; }
  rm -f "$f"
  printf '%s\n' "$v"
}

# ------------------------------------------------------------ bootstrap ----

# Candidates to fall back to when the inherited DISPLAY is a black hole:
# whatever the container recorded, plus every server socket present.
display_candidates() {
  local c s
  [ -r "$HOME/.Xauth/display.env" ] && c="$(sed -n 's/^DISPLAY=//p' "$HOME/.Xauth/display.env" 2>/dev/null)"
  for s in /tmp/.X11-unix/X[0-9]*; do [ -S "$s" ] && c="$c :${s##*/X}"; done
  printf '%s\n' $c | awk '!seen[$0]++' | head -4
}

quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

bootstrap_env() {
  local intro="" ; [ "${1:-}" = "--intro" ] && intro=1
  local notes=() d live=""

  printf 'export SSH_ASKPASS=%s\n' "$(quote "$self")"
  printf 'export SUDO_ASKPASS=%s\n' "$(quote "$self")"
  # "prefer" routes prompts through this ladder even when a tty exists, so the
  # cache is consulted and the tty tier answers in-terminal. A value the user
  # set deliberately is left alone.
  [ -n "${SSH_ASKPASS_REQUIRE:-}" ] || printf 'export SSH_ASKPASS_REQUIRE=prefer\n'

  if [ "$ASKPASS_SAFE_FIX_DISPLAY" != 0 ] && [ -n "${DISPLAY:-}" ]; then
    if display_alive "$DISPLAY"; then
      notes+=("display $DISPLAY responds")
    else
      for d in $(display_candidates); do
        [ "$d" = "$DISPLAY" ] && continue
        if display_alive "$d"; then live="$d"; break; fi
      done
      if [ -n "$live" ]; then
        printf 'export DISPLAY=%s\n' "$(quote "$live")"
        notes+=("display $DISPLAY was dead (accepts, never answers) -> switched to $live")
      else
        notes+=("display $DISPLAY is dead and no live one found -> tty/fifo tiers only")
      fi
    fi
  fi

  [ -n "$intro" ] || return 0
  {
    printf 'askpass-safe applied to this shell: SSH_ASKPASS, SUDO_ASKPASS -> %s\n' "$self"
    for d in "${notes[@]}"; do printf '  %s\n' "$d"; done
    if cache_usable 2>/dev/null; then
      printf '  cache on, %ss (askpass-safe --forget to clear)\n' "$ASKPASS_SAFE_CACHE_TIMEOUT"
    else
      printf '  cache off\n'
    fi
    printf '  tiers: %s\n' "$ASKPASS_SAFE_ORDER"
  } >&2
}

# ----------------------------------------------------------------- main ----

case "${1:-}" in
  --bootstrap-env) shift; bootstrap_env "${1:-}"; exit 0 ;;
  --forget)
    cache_forget && { echo "askpass-safe: cache cleared" >&2; exit 0; }
    echo "askpass-safe: no usable cache to clear" >&2
    exit 1 ;;
esac

if secret="$(cache_get)"; then
  log "cache hit for '$cache_key'"
  printf '%s\n' "$secret"
  exit 0
fi
log "cache miss for '$cache_key'"

IFS=, read -ra tiers <<<"$ASKPASS_SAFE_ORDER"
for t in "${tiers[@]}"; do
  secret=""
  case "$t" in
    tty)  secret="$(try_tty)"  || secret="" ;;
    gui)  secret="$(try_gui)"  || secret="" ;;
    fifo) secret="$(try_fifo)" || secret="" ;;
    *) log "unknown tier '$t'"; continue ;;
  esac
  if [ -n "$secret" ]; then
    log "tier '$t' answered"
    printf '%s\n' "$secret"   # hand it to ssh first; caching must never delay that
    cache_store "$secret"
    exit 0
  fi
  log "tier '$t' declined"
done
log "all tiers exhausted"
exit 1
