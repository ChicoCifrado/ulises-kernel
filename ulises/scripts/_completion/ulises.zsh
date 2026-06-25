#compdef ulises ulises-backup ulises-calendar ulises-contacts ulises-cookbook ulises-docs ulises-gallery ulises-mail ulises-mcp ulises-memory ulises-notes ulises-personal ulises-preset ulises-research ulises-sessions ulises-signature ulises-skills ulises-tasks ulises-theme ulises-webhook
# Zsh tab-completion for the ulises umbrella + sub-CLIs.
#
# Drop in any directory on $fpath, e.g.:
#     fpath=(/path/to/ulises-ui/scripts/_completion $fpath)
#     autoload -U compinit; compinit
#
# Then `ulises <tab>` completes subcommands; `ulises mail <tab>`
# completes mail subcommands; `ulises-mail <tab>` works the same.

_ulises_scripts_dir() {
    local self="${(%):-%x}"
    while [[ -L "$self" ]]; do self="$(readlink "$self")"; done
    cd "${self:h}/.." && pwd
}

typeset -gA _ulises_subs

_ulises_refresh() {
    _ulises_subs=()
    local dir="$(_ulises_scripts_dir)"
    local py="$dir/../venv/bin/python"
    [[ -x "$py" ]] || py="$(command -v python3)"
    local f sub help_out commands
    for f in "$dir"/ulises-*; do
        [[ -x "$f" ]] || continue
        case "$f" in
            *.bak|*.pyc|*.pre-*) continue ;;
        esac
        sub="${${f:t}#ulises-}"
        help_out=$("$py" "$f" --help 2>/dev/null) || continue
        commands=$(echo "$help_out" | grep -oE '\{[a-z0-9_,-]+\}' | head -1 \
            | tr -d '{}' | tr ',' ' ')
        _ulises_subs[$sub]="$commands"
    done
}

_ulises() {
    [[ ${#_ulises_subs} -eq 0 ]] && _ulises_refresh

    local cmd="${words[1]}"

    if [[ "$cmd" == "ulises" ]]; then
        if (( CURRENT == 2 )); then
            local -a subs=(${(k)_ulises_subs} help)
            _describe 'subcommand' subs
            return
        fi
        local sub="${words[2]}"
        if [[ "$sub" == "help" ]] && (( CURRENT == 3 )); then
            local -a subs=(${(k)_ulises_subs})
            _describe 'subcommand' subs
            return
        fi
        if (( CURRENT == 3 )); then
            local -a sc=(${(s/ /)_ulises_subs[$sub]})
            _describe 'command' sc
            return
        fi
        return
    fi

    # ulises-foo <tab>
    local sub="${cmd#ulises-}"
    if (( CURRENT == 2 )); then
        local -a sc=(${(s/ /)_ulises_subs[$sub]})
        _describe 'command' sc
        return
    fi
}

_ulises "$@"
