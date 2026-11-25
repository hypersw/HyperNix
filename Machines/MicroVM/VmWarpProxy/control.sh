# Control program for one VmWarpProxy instance; configuration.nix fills in the
# @…@ placeholders, and writeShellApplication adds the shebang and
# `set -euo pipefail`. The VM runs as a systemd --user unit: a transient one
# started here, or, with IsUnitDeclared, one a home-manager or NixOS module
# declares (home.nix next to this file), which start and stop then drive.
#
#   <name> start | stop | restart | status | log [n] | ssh [cmd…] | enroll [link] | prepare
#
# start exits 0 once WARP is connected, 3 when the VM is up but not enrolled
# yet, and 1 on any failure. enroll starts a registration, prints the sign-in
# URL, then reads the com.cloudflare.warp:// link from stdin (an argument works
# too, but stays visible in the process list).
# The instance's parameters, single-quoted by configuration.nix, so literal.
Unit=@unit@
Runner=@runner@
Team=@team@
State=@stateDir@
Identity=@sshIdentityFile@
SshPort=@sshPort@
SocksPort=@socksPort@
IsTpmStateSealed=@isTpmStateSealed@
IsUnitDeclared=@isUnitDeclared@

# A leading "~/" means $HOME; nothing else in a path is interpreted.
ExpandHome()
{
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#"~/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
if [ -z "$State" ]; then State="${XDG_STATE_HOME:-$HOME/.local/state}/$Unit"; else State=$(ExpandHome "$State"); fi
Identity=$(ExpandHome "$Identity")
Profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/$Unit-runner"

# The guest's host key lives on its tmpfs root and changes every boot, so it is
# not checked; see the trust note in nixos.nix.
SshOpts=(-i "$Identity" -p "$SshPort" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

# Automation: no prompts, and a hard deadline for the whole call (SshDeadline,
# in seconds), because a stalled remote command keeps the connection alive.
Ssh()
{
  timeout --kill-after=5 "${SshDeadline:-30}" \
    ssh "${SshOpts[@]}" -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=2 warp@127.0.0.1 "$@"
}

# `<name> ssh`: interactive, so neither timeout (its own process group stalls a
# terminal read) nor BatchMode. The caller's words are the remote command.
# shellcheck disable=SC2029
SshInteractive() { ssh "${SshOpts[@]}" warp@127.0.0.1 "$@"; }

# Reads the unit's ActiveState into St, one snapshot per decision. Called
# directly, never in $(…), so a failed query ends the program: an unreadable
# state must never pass for "inactive", which would let start reuse live state.
ReadState()
{
  if ! St=$(systemctl --user show "$Unit" -p ActiveState --value); then
    echo "cannot query systemd --user for $Unit" >&2
    exit 1
  fi
}
IsGone() { ReadState; case "$St" in inactive|failed) return 0 ;; *) return 1 ;; esac; }
IsActive() { ReadState; [ "$St" = active ]; }

WaitGone()
{
  for _ in $(seq 1 "$1"); do
    if IsGone; then return 0; fi
    sleep 1
  done
  return 1
}

# Serialises start, stop, restart and enroll per instance, so two callers cannot
# unlink each other's QMP socket or repoint the runner's GC root under a running
# VM. Keyed by the unit name, not the state directory, since controllers of two
# builds with different StateDir values still share one unit and one profile.
# Taken once per invocation: restart holds it across its stop and its start.
Locked=0
Lock()
{
  if [ "$Locked" = 1 ]; then return; fi
  exec 9>"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$Unit.control.lock"
  flock -w 300 9
  Locked=1
}

# One bounded look at the guest: Connected, Unenrolled, Waiting (WARP not up yet) or NoSsh.
Probe()
{
  local Out
  if ! Out=$(SshDeadline="$1" Ssh 'sudo warp-cli --accept-tos status' 2>/dev/null); then echo NoSsh; return; fi
  case "$Out" in
    *Connected*) echo Connected ;;
    *"Registration Missing"*) echo Unenrolled ;;
    *) echo Waiting ;;
  esac
}

WaitReady()
{
  # One overall deadline: sshd answers after ~20 s under TCG and WARP a few
  # seconds later. Each probe gets at most what is left of it, minus timeout's
  # 5 s kill grace.
  local Deadline=$((SECONDS + 180)) Left Ready
  while true; do
    ReadState
    case "$St" in
      active|activating) ;;
      *) echo "$Unit is not running (failed at start?); see: $Unit log" >&2; return 1 ;;
    esac
    Left=$((Deadline - SECONDS - 5))
    if ((Left <= 0)); then break; fi
    Ready=$(Probe $((Left < 20 ? Left : 20)))
    case "$Ready" in
      Connected)  echo "$Unit up, WARP connected"; return 0 ;;
      Unenrolled) echo "$Unit up, not enrolled: run $Unit enroll" >&2; return 3 ;;
    esac
    Left=$((Deadline - SECONDS))
    if ((Left > 0)); then sleep $((Left < 2 ? Left : 2)); fi
  done
  echo "$Unit running, but WARP is not connected after 180 s; see: $Unit status / $Unit log" >&2
  return 1
}

# Readies the state directory for a start, in both modes: a transient start
# calls it, and a declared unit runs `<name> prepare` from a oneshot unit
# ordered before it, because systemd loads credentials when a unit starts, so
# the sealed key must already exist. It takes no lock: the declared path runs
# it while start holds the lock, and at autostart without any control call.
#
# IsTpmStateSealed: the swtpm key is 32 random bytes, sealed once by
# systemd-creds with the host's TPM and the user's scope, and stored next to
# the state it unlocks; systemd decrypts it into the unit's private credential
# directory at start. Sealed and unsealed TPM state never mix: either
# direction needs an empty swtpm/.
Prepare()
{
  local Cred="$State/swtpm-key.cred"
  install -d -m 0700 "$State"
  rm -f "$State/VmControl.$Unit.socket"
  if [ -z "$IsTpmStateSealed" ]; then
    if [ -e "$Cred" ]; then
      echo "$Cred exists, but sealing is off: the TPM state in $State/swtpm is encrypted. Turn sealing on again, or remove both to start with an empty TPM." >&2
      return 1
    fi
    return 0
  fi
  if [ ! -e "$Cred" ]; then
    if [ -e "$State/swtpm/tpm2-00.permall" ]; then
      echo "$State/swtpm holds an unsealed TPM state; remove it to start sealed (its contents, keys included, are lost)." >&2
      return 1
    fi
    (umask 077 && head -c 32 /dev/urandom | systemd-creds --user encrypt --with-key=host+tpm2 --name=swtpm-key - "$Cred")
  fi
}

Start()
{
  Lock
  # A stop still in progress must finish before its QMP socket is reused.
  ReadState
  if [ "$St" = deactivating ] && ! WaitGone 90; then
    echo "$Unit is still stopping after 90 s" >&2
    return 1
  fi
  if IsGone && [ -n "$IsUnitDeclared" ]; then
    # The declared unit pulls in its prepare unit; its store paths are rooted
    # by the generation which declares it, so no profile root here.
    systemctl --user reset-failed "$Unit" "$Unit-prepare" 2>/dev/null || true
    if ! systemctl --user start "$Unit"; then
      echo "$Unit did not start; see: journalctl --user -u $Unit-prepare -u $Unit" >&2
      return 1
    fi
  elif IsGone; then
    if ! Prepare; then return 1; fi
    # A GC root for the runner: a running QEMU keeps only its own binary alive, not the
    # runner, and without it a garbage collection deletes the microvm-shutdown which ExecStop runs.
    # A profile, not `nix-store --add-root`: inside a container the indirect root's path does
    # not resolve on the host, whose GC drops it as stale, while profile HEADs can be synced.
    install -d "$(dirname "$Profile")"
    nix-env --profile "$Profile" --set "$Runner" >/dev/null
    nix-env --profile "$Profile" --delete-generations old >/dev/null 2>&1 || true
    local CredArgs=()
    if [ -n "$IsTpmStateSealed" ]; then CredArgs=(--property="LoadCredentialEncrypted=swtpm-key:$State/swtpm-key.cred"); fi
    systemctl --user reset-failed "$Unit" 2>/dev/null || true
    systemd-run --user --unit="$Unit" --description="$Unit WARP proxy microVM (SOCKS5 on 127.0.0.1:$SocksPort)" \
      --working-directory="$State" \
      --property=KillMode=mixed \
      --property=TimeoutStopSec=60 \
      --property=ExecStop="$Runner/bin/microvm-shutdown" \
      "${CredArgs[@]}" \
      "$Runner/bin/microvm-run"
  fi
  WaitReady
}

Stop()
{
  Lock
  if IsGone; then echo "$Unit not running"; return; fi
  # A guest poweroff is the clean path: QEMU exits, swtpm follows via `terminate`.
  if IsActive; then SshDeadline=15 Ssh 'sudo systemctl poweroff' 2>/dev/null || true; fi
  if ! WaitGone 60; then
    # systemd owns the last word: ExecStop asks QEMU over QMP, then KillMode=mixed.
    # The stop job blocks until the unit is down.
    systemctl --user stop "$Unit"
  fi
  echo "$Unit stopped"
}

Enroll()
{
  local Input Link
  Lock
  if ! IsActive; then echo "$Unit not running: start it first" >&2; exit 1; fi
  # Starts the enrollment session and prints its sign-in URL. Its stdin is
  # closed, so it cannot swallow a link piped into this program.
  # shellcheck disable=SC2029
  SshDeadline=60 Ssh "sudo warp-cli --accept-tos registration new $(printf '%q' "$Team")" </dev/null
  # The token inside the link lives 60 s from the sign-in, so paste it at once.
  # Every wait is bounded, since it holds the lifecycle lock.
  if [ -n "${1:-}" ]; then
    Input=$1
  elif [ -t 0 ]; then
    printf 'Sign in at the URL above, then paste the com.cloudflare.warp:// link (or its location.href line): ' >&2
    read -r -t 300 Input || true
  else
    Input=$(timeout 30 cat || true)
  fi
  Link=$(grep -o "com\.cloudflare\.warp://[^'\" ]*" <<<"$Input" | head -1 || true)
  if [ -z "$Link" ]; then echo "no com.cloudflare.warp:// link in the input" >&2; exit 1; fi
  # The link goes over SSH's stdin, so it shows up in neither the host's process
  # list nor the guest's sudo log. $Link expands in the guest's shell.
  printf '%s\n' "$Link" | SshDeadline=60 Ssh 'sudo sh -c '\''read -r Link && exec warp-cli --accept-tos registration token "$Link"'\'''
  SshDeadline=30 Ssh 'sudo warp-cli --accept-tos connect' </dev/null
  WaitReady
}

case "${1:-status}" in
  start)   Start ;;
  stop)    Stop ;;
  restart) Lock; Stop; Start ;;
  status)  systemctl --user status "$Unit" --no-pager -n 0 || true
           if IsActive; then SshDeadline=20 Ssh 'sudo warp-cli --accept-tos status' || true; fi ;;
  log)     journalctl --user -u "$Unit" --no-pager -n "${2:-60}" ;;
  ssh)     shift; SshInteractive "$@" ;;
  enroll)  Enroll "${2:-}" ;;
  prepare) Prepare ;;
  *)       echo "usage: $Unit start | stop | restart | status | log [n] | ssh [cmd…] | enroll [link] | prepare" >&2; exit 2 ;;
esac
