-- Shared by the watcher and the shell acknowledgement bridge. A PID alone
-- is not an identity, even within a single server run.
local f = io.open("/proc/sys/kernel/random/boot_id")
local boot = f and f:read("*a") or ""
if f then f:close() end

return function(server, process)
  f = io.open("/proc/" .. process.pid .. "/stat")
  local start
  if f then
    local stat = f:read("*a")
    f:close()
    local fields = {}
    for field in (stat:match("^%d+ %(.+%) (.*)$") or ""):gmatch("%S+") do
      fields[#fields + 1] = field
    end
    start = fields[20] -- Linux field 22, after pid and comm
  else
    local result = rex.exec({ "ps", "-o", "lstart=", "-p", tostring(process.pid) }, { stderr = false })
    start = result and result.ok and result.stdout or nil
  end
  if not start or start == "" then return nil end
  return server.instance_id .. ":" .. boot .. ":" .. process.pid .. ":" .. start .. ":" .. process.name
end
