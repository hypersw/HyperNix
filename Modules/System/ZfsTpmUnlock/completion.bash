# bash completion for zfs-tpm-key
#
# Installed at $out/share/bash-completion/completions/zfs-tpm-key by
# package.nix; bash-completion auto-loads it on demand when the
# user types `zfs-tpm-key <TAB>` (NixOS turns this on by default
# via programs.bash.completion.enable). Works the same in any
# bash-completion-aware shell, including far2l's command line
# which delegates to bash.
#
# Self-contained — does not rely on the bash-completion library's
# helper functions (_init_completion, _filedir) so it works even
# when those aren't loaded yet.

_zfs_tpm_key() {
    local cur prev words cword
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD

    # Find the chosen subcommand, if any, by scanning the words
    # before our cursor position.
    local sub="" i
    for ((i=1; i<cword; i++)); do
        case "${words[i]}" in
            gen-key|seal|test|help) sub="${words[i]}"; break ;;
        esac
    done

    # Value completion for the option immediately before the cursor.
    case "$prev" in
        --output-dir|--input-dir)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return
            ;;
        --out|--key)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return
            ;;
        --hierarchy)
            COMPREPLY=( $(compgen -W "o p e n" -- "$cur") )
            return
            ;;
        --pcr-list)
            # A handful of commonly-used PCR-list patterns. Bash
            # treats ':' as a word break by default so partial
            # completion after typing past a colon is awkward;
            # offering whole patterns from the start works best.
            COMPREPLY=( $(compgen -W "sha256:0 sha256:0,7 sha256:0,2,7 sha256:7" -- "$cur") )
            return
            ;;
        --name)
            # Suggest names of existing sealed blobs found in the
            # usual locations. Strips the .pub suffix so completing
            # `--name h<TAB>` for /var/lib/volumes/home.pub yields
            # `home`, matching what `seal`/`test --name` expects.
            local dir f candidates=()
            for dir in /var/lib/volumes /var/lib/zfs-tpm-keys; do
                [[ -d $dir ]] || continue
                for f in "$dir"/*.pub; do
                    [[ -e $f ]] && candidates+=( "$(basename "$f" .pub)" )
                done
            done
            COMPREPLY=( $(compgen -W "${candidates[*]}" -- "$cur") )
            return
            ;;
    esac

    # No subcommand picked yet → complete the subcommand list (plus
    # the top-level --help). Otherwise, complete that subcommand's
    # option set.
    if [[ -z $sub ]]; then
        COMPREPLY=( $(compgen -W "gen-key seal test help --help" -- "$cur") )
        return
    fi

    case "$sub" in
        gen-key)
            COMPREPLY=( $(compgen -W "--to-clip --out --help" -- "$cur") )
            ;;
        seal)
            COMPREPLY=( $(compgen -W \
                "--name --key --force --pcr-list --hierarchy --output-dir --help" \
                -- "$cur") )
            ;;
        test)
            COMPREPLY=( $(compgen -W \
                "--name --pcr-list --hierarchy --input-dir --help" \
                -- "$cur") )
            ;;
    esac
}

complete -F _zfs_tpm_key zfs-tpm-key
