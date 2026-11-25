-- Called only by a shell's preexec hook, never by restore delivery. Keep the
-- accepted command in an environment variable so CLI argument coercion cannot
-- change strings such as "true" or "00123".
local id = os.getenv("REX_BLOCK")
local command = os.getenv("REX_RESTORE_COMMAND")
if not id or not id:match("^block:[%x%-]+$") or not command then return end
local state = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/rex-restore/"
local path = state .. id:gsub("^block:", "") .. ".json"
local f = io.open(path)
if not f then return end
local rec = rex.json.decode(f:read("*a"))
f:close()
if type(rec) ~= "table" or rec.omp_tty or rec.command ~= command then return end
local server = rex.call("server.status")
local proc = rex.block.call("com.superlogical.terminal", "process", {
  session_id = os.getenv("REX_SESSION"), block_id = id })
if not server or not server.instance_id or not proc then return end
local candidates = { proc.foreground, proc.child }
for _, p in ipairs(proc.ancestors or {}) do candidates[#candidates + 1] = p end
local shell
for _, p in pairs(candidates) do if p.pid == rex.args.shell_pid then shell = p; break end end
if not shell then return end
local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]*$") or "."
local identity = dofile(dir .. "/process_identity.lua")
local key = identity(server, shell)
if not key then return end
local text = rex.json.encode({ command = command, shell_pid = shell.pid, shell_key = key })
if not text then return end
f = io.open(path .. ".executed.tmp", "w")
if not f then return end
local ok = f:write(text)
local closed = f:close()
if ok and closed then os.rename(path .. ".executed.tmp", path .. ".executed") end
