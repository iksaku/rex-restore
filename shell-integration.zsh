# Source from ~/.zshrc. Native preexec distinguishes submission from prompts.
[[ -n ${REX_BLOCK:-} && -z ${__rex_restore_hooked:-} ]] || return
__rex_restore_helper="${${(%):-%x}:A:h}/executed.lua"
__rex_restore_preexec() {
    REX_RESTORE_COMMAND="$1" rex do "$__rex_restore_helper" shell_pid="$$" >/dev/null 2>&1
    return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec __rex_restore_preexec
__rex_restore_hooked=1
