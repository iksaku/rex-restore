# Source from ~/.config/fish/config.fish.
if not set -q REX_BLOCK; or set -q __rex_restore_hooked
    return
end
set -g __rex_restore_helper (path resolve (path dirname (status filename)))/executed.lua
function __rex_restore_preexec --on-event fish_preexec
    env REX_RESTORE_COMMAND="$argv[1]" rex do "$__rex_restore_helper" shell_pid=$fish_pid >/dev/null 2>&1
    return 0
end
set -g __rex_restore_hooked 1
