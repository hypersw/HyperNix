#
# zfs-tpm-key — CLI paired with the hypersw.services.zfs-tpm-unlock
# NixOS module.
#
# Key format: matches ZFS's `keyformat=hex` — 64 hex characters,
# representing 32 random bytes (the AES-256-GCM key). Text-native
# end to end: the clipboard / file / sealed blob / unseal pipe
# / keylocation file all contain the same 64-char hex string,
# so there's no encoding/decoding step between the user-visible
# representation and what ZFS reads. Use `keyformat=hex` on the
# pool/dataset side to match.
#
# Three subcommands cover the lifecycle without ceremony:
#
#   gen-key      generate a fresh 32-byte random key, encoded as
#                64 lowercase hex characters; emit to stdout,
#                terminal clipboard (OSC52, works over SSH and
#                through tmux), and/or a file. Run once before
#                the very first sealing; back up the output
#                OFF-MACHINE, then feed it to `seal`.
#
#   seal         given a 64-hex-char key on stdin (paste) or via
#                --key FILE, produce NAME.pub/NAME.priv sealed
#                under the current PCR policy. Same op for first-
#                time seal and re-seal after a PCR break; if the
#                output blobs already exist it prompts before
#                overwriting (since overwriting is correct only
#                on re-seal).
#
#   test         unseal the current NAME.pub/NAME.priv against
#                current PCR state and print the SHA-256 of the
#                unsealed hex string. Never writes the key
#                anywhere; compare with `sha256sum your-backup.hex`
#                to verify end-to-end integrity.
#
# All key handling avoids disk: the user-side hex string goes on
# stdin, gets piped straight into `tpm2_create --sealing-input -`;
# the unseal side pipes `tpm2_unseal --output -` straight into
# sha256sum (test) or zfs load-key via /dev/stdin (the module's
# unlock service).
#

{ pkgs }:

let
  app = pkgs.writeShellApplication {
    name = "zfs-tpm-key";

    runtimeInputs = with pkgs; [ tpm2-tools coreutils ];

    text = ''
    PROG=zfs-tpm-key

    die() { echo "$PROG: $*" >&2; exit 1; }

    # If the user hasn't already pinned a TCTI, default to the
    # kernel resource manager. Without this, tpm2-tools probes
    # tabrmd (userspace D-Bus broker) first, which fails noisily
    # via "GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown"
    # on hosts that don't run abrmd — before falling through to
    # /dev/tpmrm0 anyway. Setting TPM2TOOLS_TCTI short-circuits
    # the probe; respects an existing setting so hosts that DO
    # run abrmd aren't overridden.
    : "''${TPM2TOOLS_TCTI:=device:/dev/tpmrm0}"
    export TPM2TOOLS_TCTI

    usage() {
      cat <<'EOF'
Usage:
  zfs-tpm-key gen-key [--to-clip] [--out FILE]
  zfs-tpm-key seal    --name NAME [--key FILE] [--force] [common opts]
  zfs-tpm-key test    --name NAME [common opts]

Subcommands:

  gen-key
    Generate a fresh 32-byte random key, encoded as 64 lowercase
    hex characters (matches ZFS's `keyformat=hex`; the file/clip-
    board content IS the key in the form ZFS reads directly).
    Default: prints to stdout.
    --to-clip        push to the terminal clipboard via OSC52 and
                     suppress stdout (works over SSH; tmux-aware
                     via DCS passthrough). Less shoulder-surfing.
    --out FILE       also write to FILE (mode 600). Use this file
                     directly as `keylocation=file://FILE` in
                     `zpool create -O keyformat=hex`.
    Combine flags freely; --to-clip wins on stdout suppression.

  seal
    Seal a 64-char hex key (read from --key FILE or from stdin;
    paste + Ctrl+D works) under the current PCR policy, writing
    <output-dir>/NAME.pub and NAME.priv. The key never touches
    disk on this host — input pipes straight into tpm2_create's
    stdin.

    Whitespace and surrounding newlines in the input are
    tolerated; the inner 64 hex characters must be valid.

    If NAME.pub or NAME.priv already exist, prompts before
    overwriting (correct only when re-sealing after a PCR-policy
    break, e.g. BIOS/firmware/kernel update). --force skips the
    prompt.

  test
    Unseal NAME.pub/NAME.priv with current PCR state, print the
    SHA-256 of the unsealed hex string (compare with
    `sha256sum your-backup.hex` — both hash the same 64 chars)
    and exit. Doesn't write the key anywhere.

Common options:
  --name NAME          Required for seal and test.
  --pcr-list LIST      Default: sha256:0
  --hierarchy CHAR     Default: o    (one of: o p e n)
  --output-dir DIR     Default: /var/lib/volumes  (seal)
  --input-dir  DIR     Default: /var/lib/volumes  (test)

Most operations need root (TPM device access).
EOF
    }

    # ─── arg parsing ──────────────────────────────────────────────
    pcr_list="sha256:0"
    hierarchy="o"
    output_dir="/var/lib/volumes"
    input_dir="/var/lib/volumes"
    name=""
    key_file=""
    out_file=""
    to_clip=0
    force=0

    if [[ $# -lt 1 ]]; then usage; exit 2; fi
    sub="$1"; shift

    if [[ "$sub" == "help" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      usage; exit 0
    fi

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)        name="$2";        shift 2 ;;
        --pcr-list)    pcr_list="$2";    shift 2 ;;
        --hierarchy)   hierarchy="$2";   shift 2 ;;
        --output-dir)  output_dir="$2";  shift 2 ;;
        --input-dir)   input_dir="$2";   shift 2 ;;
        --key)         key_file="$2";    shift 2 ;;
        --out)         out_file="$2";    shift 2 ;;
        --to-clip)     to_clip=1;        shift ;;
        --force)       force=1;          shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
      esac
    done

    case "$sub" in
      gen-key|seal|test) ;;
      *) die "unknown subcommand: $sub (try --help)" ;;
    esac
    [[ "$hierarchy" =~ ^[open]$ ]] || die "--hierarchy must be o, p, e, or n"

    # ─── OSC52 clipboard helper ───────────────────────────────────
    # Pushes stdin to the terminal's clipboard via the OSC52 escape
    # sequence. Wraps in tmux DCS passthrough when running under
    # tmux. Writes to /dev/tty so the escape reaches the terminal
    # even when our stdout is redirected.
    osc52_copy() {
      local b64
      b64=$(base64 -w0)
      if [[ -n "''${TMUX-}" ]]; then
        # tmux passthrough: ESC P tmux ; <doubled-ESC inner> ESC \
        # Inner OSC52 uses BEL terminator to minimise ESCs.
        # shellcheck disable=SC1003 # \\ is printf format syntax, not a quote escape
        printf '\033Ptmux;\033\033]52;c;%s\a\033\\' "$b64" > /dev/tty
      else
        printf '\033]52;c;%s\a' "$b64" > /dev/tty
      fi
    }

    # ─── shared sealing routine ───────────────────────────────────
    # Reads the key bytes to seal on stdin, writes ($1 pub, $2 priv).
    # Called via a pipe: `printf '%s' "$key_hex" | seal_pipe_into_files ...`,
    # so tpm2_create's --sealing-input - inherits the same stdin.
    # We seal the 64 ASCII hex bytes (not 32 decoded binary bytes)
    # so the sealed blob, the unsealed stream, and what ZFS reads
    # under keyformat=hex all stay the same shape.
    seal_pipe_into_files() {
      local pub_dst="$1" priv_dst="$2"
      local tmp primary session policy pub_new priv_new

      tmp=$(mktemp -d /tmp/zfs-tpm-seal.XXXXXX)
      # shellcheck disable=SC2064
      trap "rm -rf '$tmp'" RETURN

      primary="$tmp/primary.ctx"
      session="$tmp/trial.session"
      policy="$tmp/policy.digest"
      pub_new="$tmp/new.pub"
      priv_new="$tmp/new.priv"

      echo "Create primary in hierarchy $hierarchy" >&2
      tpm2_createprimary --hierarchy   "$hierarchy" \
                         --key-context "$primary" >/dev/null

      echo "Compute PCR policy digest ($pcr_list)" >&2
      tpm2_startauthsession --session "$session" >/dev/null
      tpm2_policypcr        --session  "$session" \
                            --pcr-list "$pcr_list" \
                            --policy   "$policy" >/dev/null
      tpm2_flushcontext     "$session" >/dev/null

      echo "Seal key under that policy (key bytes piped, never on disk)" >&2
      # tpm2_create rejects --key-algorithm (-G) together with
      # --sealing-input (-i); when sealing user data, the object
      # type is implicitly keyedhash and -G must be omitted.
      tpm2_create --parent-context "$primary" \
                  --hash-algorithm sha256 \
                  --policy         "$policy" \
                  --sealing-input  - \
                  --public         "$pub_new" \
                  --private        "$priv_new" >/dev/null

      install -m600 "$pub_new"  "$pub_dst"
      install -m600 "$priv_new" "$priv_dst"
    }

    # ─── gen-key ──────────────────────────────────────────────────
    do_gen_key() {
      local key_hex
      # od -An (no addresses) -tx1 (1-byte hex) -v (don't dedup zeros)
      # then strip the column whitespace coreutils inserts → 64 chars.
      key_hex=$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n')

      # Defensive: 32 random bytes → exactly 64 hex chars.
      [[ ''${#key_hex} -eq 64 ]] || \
        die "internal: hex generation produced ''${#key_hex} chars, expected 64"

      if [[ -n $out_file ]]; then
        # Trailing newline — friendly for `cat keyfile`; ZFS strips
        # a single trailing newline from a hex keylocation, so this
        # doesn't break direct use as keylocation=file://...
        printf '%s\n' "$key_hex" > "$out_file"
        chmod 600 "$out_file"
        echo "Wrote 64-hex-char key to $out_file (mode 600)" >&2
      fi

      if [[ $to_clip == 1 ]]; then
        printf '%s' "$key_hex" | osc52_copy
        echo "Key copied to clipboard via OSC52 (not printed to stdout)." >&2
      elif [[ -z $out_file ]]; then
        # Neither --to-clip nor --out — emit to stdout.
        printf '%s\n' "$key_hex"
      fi

      cat >&2 <<EOF

✔ 32-byte random key generated (encoded as 64 hex characters,
  matching ZFS keyformat=hex — the file content IS the key in
  the form ZFS reads directly).

>>> BACK IT UP OFF-MACHINE NOW (password manager, encrypted USB).
>>> Nothing on this host remembers it. Lose it and you lose the
>>> ability to re-seal after any future PCR-policy break.

To seal it:  $PROG seal --name NAME           # paste + Ctrl+D
       or:  $PROG seal --name NAME --key FILE

For zpool create on this same key:
       zpool create … -O keyformat=hex -O keylocation=file://<path-to-hex-file> …
EOF
    }

    # ─── seal ─────────────────────────────────────────────────────
    do_seal() {
      [[ -n $name ]] || die "--name is required"
      mkdir -p "$output_dir"
      local pub="$output_dir/$name.pub"
      local priv="$output_dir/$name.priv"

      if { [[ -e $pub ]] || [[ -e $priv ]]; } && [[ $force != 1 ]]; then
        cat >&2 <<EOF

About to overwrite:
  $pub
  $priv

This is correct ONLY when re-sealing after a PCR-policy change
(e.g. BIOS / firmware / kernel update broke unattended unlock).
For a fresh seal on this host, you shouldn't see this prompt —
either the name is wrong, or a stale seal wasn't cleaned out.

EOF
        local ans
        # Prompt via /dev/tty so we don't fight with stdin holding the key.
        read -r -p "Proceed with overwrite? [y/N] " ans < /dev/tty
        [[ $ans =~ ^[Yy]$ ]] || die "aborted by user"
      fi

      # Read the 64-hex-char key from --key FILE or stdin, validate,
      # then pipe the exact 64 ASCII bytes into tpm2_create. No
      # decoding step: hex IS the format we seal, the format ZFS
      # reads on unlock (keyformat=hex), and the format the user's
      # backup is stored as. End to end consistency.
      local key_hex
      if [[ -n $key_file ]]; then
        [[ -f $key_file ]] || die "--key file not found: $key_file"
        key_hex=$(< "$key_file")
      elif [ -t 0 ]; then
        # Interactive paste: read silently so the key doesn't echo
        # to the terminal (and end up in scrollback or over the
        # shoulder of whoever's behind you). `read -s` reads one
        # line, no echo, returns on Enter.
        echo "Paste 64-hex-char key (silent — no echo), then Enter:" >&2
        IFS= read -rs key_hex
        echo >&2   # visual newline after silent read
      else
        # Stdin is a pipe / redirect — silent-read would block
        # on /dev/tty that may not be available; just consume
        # whatever's on stdin.
        key_hex=$(cat)
      fi
      # Trim leading and trailing whitespace, but DO NOT strip
      # internal whitespace — a solid contiguous 64-char hex block
      # is what we expect; embedded whitespace means a paste glitch
      # or wrong-format input and should be rejected, not silently
      # accepted.
      key_hex="''${key_hex#"''${key_hex%%[![:space:]]*}"}"   # strip leading WS
      key_hex="''${key_hex%"''${key_hex##*[![:space:]]}"}"   # strip trailing WS

      if [[ ! "$key_hex" =~ ^[0-9a-fA-F]{64}$ ]]; then
        die "expected exactly 64 contiguous hex characters (0-9 a-f A-F); \
got ''${#key_hex} chars after trim — paste may have been truncated, \
contained embedded whitespace, or had non-hex characters"
      fi

      printf '%s' "$key_hex" | seal_pipe_into_files "$pub" "$priv"
      # Wipe the variable so the hex isn't lingering in the shell's
      # memory longer than needed (defence in depth; bash's memory
      # is generally not swapped, but no harm).
      key_hex=""

      cat >&2 <<EOF

✔ Sealed under PCR $pcr_list (hierarchy $hierarchy):
   $pub
   $priv

To verify:  $PROG test --name $name
To use:     reboot, or 'systemctl start zfs-tpm-unlock-$name.service'
EOF
    }

    # ─── test ─────────────────────────────────────────────────────
    do_test() {
      [[ -n $name ]] || die "--name is required"
      local pub="$input_dir/$name.pub"
      local priv="$input_dir/$name.priv"
      [[ -f $pub  ]] || die "no such public blob: $pub"
      [[ -f $priv ]] || die "no such private blob: $priv"

      local tmp primary loaded session
      tmp=$(mktemp -d /tmp/zfs-tpm-test.XXXXXX)
      # shellcheck disable=SC2064
      trap "rm -rf '$tmp'" EXIT
      primary="$tmp/primary.ctx"
      loaded="$tmp/loaded.ctx"
      session="$tmp/policy.session"

      tpm2_createprimary    --hierarchy   "$hierarchy" \
                            --key-context "$primary" >/dev/null
      tpm2_load             --public         "$pub" \
                            --private        "$priv" \
                            --parent-context "$primary" \
                            --key-context    "$loaded" >/dev/null
      tpm2_startauthsession --policy-session \
                            --session "$session" >/dev/null
      tpm2_policypcr        --session  "$session" \
                            --pcr-list "$pcr_list" >/dev/null

      # Pipe tpm2_unseal stdout straight into sha256sum.
      # Key bytes never on disk, never in a variable longer than
      # the pipe's kernel buffer takes to drain.
      local fingerprint
      fingerprint=$(tpm2_unseal --object-context "$loaded" \
                                --auth           "session:$session" \
                                --output         - \
                    | sha256sum | cut -d' ' -f1)
      tpm2_flushcontext "$session" >/dev/null

      echo "✔ Unseal succeeded for $name (PCR $pcr_list, hierarchy $hierarchy)"
      echo "  SHA-256 of unsealed hex string: $fingerprint"
      echo "  (verify with: sha256sum <your-backup.hex>)"
    }

    case "$sub" in
      gen-key) do_gen_key ;;
      seal)    do_seal ;;
      test)    do_test ;;
    esac
  '';
  };

in
# Wrap the writeShellApplication output so the package also carries
# the bash-completion file. NixOS auto-sources $out/share/bash-
# completion/completions/<name> when `programs.bash.completion.enable`
# is on (the default). far2l delegates to bash for command-line
# input, so it picks the completion up too.
pkgs.symlinkJoin {
  name = "zfs-tpm-key";
  paths = [ app ];
  postBuild = ''
    install -Dm644 ${./completion.bash} \
      $out/share/bash-completion/completions/zfs-tpm-key
  '';
}
