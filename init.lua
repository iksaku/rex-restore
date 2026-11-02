-- Loaded from Rex's init.lua with require("rex-restore"). Starts watch.lua
-- once per server; watch.lua exits early if another copy is already running.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]*$")

rex.exec.start({
  "sh", "-c", [[
    rex=$(command -v rex) || rex="$REX_BIN_DIR/rex"
    [ -x "$rex" ] || rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-restore"
    mkdir -p -m 700 "$state" && exec "$rex" do --all "$1" >>"$state/watch.log" 2>&1
  ]],
  "rex-restore", dir .. "/watch.lua",
}, {
  detach = true,
  env = { REX_SESSION = false, REX_BLOCK = false, REX_CLIENT = false },
})
