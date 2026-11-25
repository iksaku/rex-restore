# Source from ~/.bashrc for exact execution detection (Bash 4.4+).
[[ -n ${REX_BLOCK:-} && -z ${__rex_restore_hooked:-} ]] || return
__rex_restore_helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/executed.lua"
__rex_restore_preexec() {
    REX_RESTORE_COMMAND="$1" rex "do" "$__rex_restore_helper" shell_pid="$$" >/dev/null 2>&1
    return 0
}
if declare -p preexec_functions >/dev/null 2>&1; then
    # Cooperate with an existing bash-preexec installation.
    preexec_functions+=(__rex_restore_preexec)
elif [[ -z $(trap -p DEBUG) ]] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    # PS0 runs after an interactive line is accepted, not for prompt helpers.
    # The DEBUG trap consumes that flag on the first command, even a builtin.
    declare __rex_restore_submitted
    PS0="\${__rex_restore_submitted=}${PS0-}"
    trap 'if [[ ${__rex_restore_submitted+x} ]]; then unset __rex_restore_submitted; __rex_restore_preexec "$BASH_COMMAND"; fi' DEBUG
else
    printf '%s\n' 'rex-restore: source after bash-preexec, or use Bash 4.4+ without a DEBUG trap' >&2
    return
fi
__rex_restore_hooked=1
