-- Behavioral tests run the actual watcher through Rex's API, event, clock and
-- filesystem boundaries. No private watcher functions are exported for tests.
local count = 0
local function equal(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

local function world()
  local w = { files = {}, objects = {}, now = 100, instance = "server-1", sessions = { "session:a" },
    blocks = {}, processes = {}, commands = {}, starts = {}, writes = {}, failures = {}, handlers = {} }
  local root = "/state/rex-restore/"
  local function encode(v)
    local token = tostring(#w.objects + 1)
    w.objects[#w.objects + 1] = copy(v)
    return token
  end
  local function decode(s) return copy(w.objects[tonumber(s)]) end
  function w:record(id) return decode(self.files[root .. id .. ".json"]) end
  function w:seed(id, rec) self.files[root .. id .. ".json"] = encode(rec) end
  function w:pane(id, session, window, shell_pid)
    self.blocks[id] = { block_id = "block:" .. id, creator_name = "com.superlogical.terminal",
      session_id = session or "session:a", window_id = window or "window:a" }
    self:shell(id, shell_pid or 10)
  end
  function w:shell(id, pid)
    local p = { name = "bash", pid = pid or 10 }
    self.processes["block:" .. id] = { child = p, foreground = p }
  end
  function w:job(id, name, command, pid)
    local proc = self.processes["block:" .. id]
    local p = { name = name, pid = pid or 20 }
    self.commands[p.pid] = command
    self.processes["block:" .. id] = { child = proc.child, foreground = p, ancestors = { proc.child } }
  end
  function w:submit(id, command, pid)
    self.input_block, self.input_command = "block:" .. id, command
    self.env.rex.args = { shell_pid = pid or self.processes["block:" .. id].child.pid }
    setfenv(assert(loadfile("executed.lua")), self.env)()
  end
  function w:event(name, ctx, ev) self.handlers[name](ctx or {}, ev or {}) end
  function w:tick(seconds) self.now = self.now + (seconds or 1); self.timer() end
  function w:start()
    self.handlers = {}
    local env = setmetatable({}, { __index = _G })
    env.dofile = function(path) return setfenv(assert(loadfile(path)), env)() end
    env.os = { getenv = function(k) return ({ HOME = "/home", XDG_STATE_HOME = "/state",
        REX_BLOCK = w.input_block, REX_RESTORE_COMMAND = w.input_command })[k] end,
      time = function() return w.now end,
      remove = function(p) w.files[p] = nil; return true end,
      rename = function(a, b)
        if w.fail_save and b:match("%.json$") then return nil, "disk full" end
        w.files[b], w.files[a] = w.files[a], nil
        return true
      end }
    env.io = { open = function(path, mode)
      if mode == "w" then
        return { write = function(_, text) w.files[path] = text; return true end,
          close = function() return true end }
      end
      local text = w.files[path]
      if not text then return nil end
      return { read = function() return text end, close = function() return true end }
    end }
    env.rex = {
      json = { encode = encode, decode = decode }, log = function() end,
      stop = function() error("unexpected stop") end,
      on = function(name, handler) w.handlers[name] = handler end,
      every = function(_, fn) w.timer = fn; return { cancel = function() error("retry cancelled") end } end,
      exec = function(argv)
        local out = ""
        if argv[1] == "kill" then return { ok = false } end
        if argv[1] == "sh" then out = "12345" end
        if argv[1] == "ls" then
          for path in pairs(w.files) do
            if path:match("%.json$") then out = out .. path:match("([^/]+)$") .. "\n" end
          end
        end
        if argv[1] == "ps" then
          if w.failures.ps then return { ok = false } end
          local live = {}
          for _, proc in pairs(w.processes) do
            for _, p in pairs({ proc.child, proc.foreground }) do live[p.pid] = true end
            for _, p in ipairs(proc.ancestors or {}) do live[p.pid] = true end
          end
          if argv[2] == "-A" then
            for pid in pairs(live) do out = out .. pid .. "\n" end
          else
            local pid = tonumber(argv[5])
            if not live[pid] then return { ok = false } end
            if argv[3] == "lstart=" then out = w.starts[pid] or "start-1"
            else out = "pts/4 " .. (w.commands[pid] or "") end
          end
        end
        return { ok = true, stdout = out }
      end,
      call = function(method, args)
        if w.failures[method] then return nil, w.failures[method] end
        if method == "server.status" then return { instance_id = w.instance, host_id = "host" } end
        if method == "session.list" then
          local result = {}
          for _, id in ipairs(w.sessions) do result[#result + 1] = { session_id = id } end
          return { sessions = result }
        end
        if method == "session.list_blocks" then
          local result = {}
          for _, b in pairs(w.blocks) do
            if b.session_id == args.session_id then result[#result + 1] = b end
          end
          return { blocks = result }
        end
        if method == "session.describe_block" then
          for _, b in pairs(w.blocks) do if b.block_id == args.block_id then return { block = b } end end
          return nil, 'stream response "control-3" failed: block not found (status=404 code=not_found)'
        end
        error(method)
      end,
      block = { call = function(_, method, args)
        if w.failures[method] then return nil, w.failures[method] end
        if method == "process" then return w.processes[args.block_id] end
        if method == "title" then return { owner = w.title_owner or w.processes[args.block_id].foreground } end
        assert(method == "write")
        w.writes[#w.writes + 1] = args.data
        if w.write_reply then return w.write_reply(args) end
        return { bytes_written = #args.data }
      end },
    }
    self.env = env
    local chunk = assert(loadfile(arg[1] or "watch.lua"))
    setfenv(chunk, env)()
  end
  return w
end

local function test(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end

test("startup records existing activity; completion stops future recovery", function()
  local w = world(); w:pane("a"); w:job("a", "sleep", "sleep 599"); w:start()
  equal(w:record("a").command, "sleep 599"); equal(#w.writes, 0)
  w:shell("a"); w:tick(); w:tick(4)
  equal(w:record("a"), nil)
end)

test("generic input survives repeated restores, idle, cleared input and watcher reload", function()
  local w = world(); w:pane("a"); w:job("a", "sleep", "sleep 599"); w:start()
  for i = 2, 5 do
    w.instance = "server-" .. i; w:shell("a", 10) -- deliberately reused PID
    w:start(); equal(w.writes[#w.writes], "sleep 599")
    local n = #w.writes
    w:tick(1000000); w:start(); w:tick()
    equal(#w.writes, n); equal(w:record("a").command, "sleep 599")
    assert(w:record("a").pending)
  end
  equal(#w.writes, 4)
end)

test("failed writes and partial UTF-8 writes retry without consuming input", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "echo café" })
  w.failures.write = "busy: unavailable"; w:start()
  assert(not w:record("a").typed)
  w.failures.write = nil
  w.write_reply = function() return { bytes_written = 6 } end
  w:tick(); equal(w.writes[1], "echo café"); assert(not w:record("a").typed)
  w.write_reply = nil; w:tick(); equal(w.writes[2], "afé")
  assert(w:record("a").typed); equal(w:record("a").command, "echo café")
end)

test("busy/unavailable and initially absent panes remain discoverable", function()
  local w = world(); w:seed("a", { command = "sleep 599" }); w:start(); w:tick(60)
  w:pane("a"); w:job("a", "vim", "vim file"); w:tick()
  equal(#w.writes, 0); equal(w:record("a").command, "sleep 599")
  w:shell("a"); w.failures.process = "unavailable"; w:tick(); equal(#w.writes, 0)
  w.failures.process = nil; w:tick(); equal(w.writes[1], "sleep 599")
end)

test("pending input ignores prompt helpers, then tracks actual execution", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w:start()
  w:job("a", "git", "git status"); w:tick()
  equal(w:record("a").command, "sleep 599"); assert(w:record("a").pending)
  w:job("a", "sleep", "sleep 599", 21); w:tick()
  assert(w:record("a").pending) -- identical helper arguments are not execution evidence
  w:submit("a", "sleep 599"); w:tick()
  equal(w:record("a").job_pid, 21); equal(w:record("a").pending, nil)
  w:shell("a"); w:tick(); w:tick(4); equal(w:record("a"), nil)
end)

test("omp retains intent through delivery and missing/wrong breadcrumbs, then tracks twice", function()
  local w = world(); w:pane("a")
  w.files["/chat"] = "session"; w:seed("a", { command = "omp", omp_tty = "pts/1", omp_session = "/chat" })
  w.failures.write = "busy"; w:start(); equal(w:record("a").omp_session, "/chat")
  w.failures.write = nil; w:tick(); equal(w.writes[1], "omp --resume '/chat'\r")
  assert(w:record("a").pending)
  w:job("a", "omp", "omp --resume /chat"); w:tick(); assert(w:record("a").pending)
  w.files["/other"] = "different"; w.files["/home/.omp/agent/terminal-sessions/pts-4"] = "20\n/other\n"
  w:tick(); equal(w:record("a").omp_session, "/chat"); assert(w:record("a").pending)
  w.files["/home/.omp/agent/terminal-sessions/pts-4"] = "20\n/chat\n"
  w.title_owner = { name = "omp", pid = 19 }; w:tick(); assert(w:record("a").pending)
  w.title_owner = nil
  w.fail_save = true; w:tick(); assert(w:record("a").pending)
  w.fail_save = nil; w:tick(); equal(w:record("a").pending, nil)
  equal(w:record("a").omp_session, "/chat"); equal(w:record("a").job_pid, 20)
  w.instance = "server-2"; w:shell("a"); w:start()
  equal(w.writes[2], "omp --resume '/chat'\r")
  w:job("a", "omp", "omp --resume /chat", 22); w:tick()
  equal(w:record("a").job_pid, 22); equal(w:record("a").pending, nil)
end)

test("missing omp session never falls back to a new chat", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "omp", omp_tty = "pts/1" })
  w:start(); w:tick(60); equal(#w.writes, 0); assert(w:record("a"))
  w:seed("a", { command = "omp", omp_tty = "pts/1", omp_session = "/deleted" })
  w:tick(); equal(#w.writes, 0); equal(w:record("a").omp_session, "/deleted")
end)

test("ambiguous omp write is not replayed in the same shell, even after reload", function()
  local w = world(); w:pane("a"); w.files["/chat"] = "session"
  w:seed("a", { command = "omp", omp_tty = "pts/1", omp_session = "/chat" })
  w.write_reply = function() return nil, "connection timeout" end
  w:start(); equal(#w.writes, 1); assert(w:record("a").delivery.uncertain)
  w.write_reply = nil; w:tick(100); w:start(); equal(#w.writes, 1)
  w.instance = "new-server"; w:start(); equal(#w.writes, 2)
end)

test("process start identity detects shell PID reuse within one server", function()
  local w = world(); w:pane("a"); w:job("a", "sleep", "sleep 599"); w:start()
  w.starts[10] = "start-2"; w:shell("a"); w:tick(); equal(w.writes[1], "sleep 599")
end)

test("accepted builtin/short command is consumed without a process event", function()
  for _, command in ipairs({ "true", "00123", "sleep 0.001" }) do
    local w = world(); w:pane("a"); w:seed("a", { command = command }); w:start()
    w:submit("a", "unrelated command"); w:tick(20); assert(w:record("a").pending)
    w:submit("a", command, 99); w:tick(); assert(w:record("a").pending)
    w:submit("a", command); w:tick(); w:tick(4)
    equal(w:record("a"), nil)
  end
end)

test("execution acknowledgements cannot cross shell/server generations", function()
  for _, reuse_pid in ipairs({ false, true }) do
    local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w:start()
    w:submit("a", "sleep 599")
    if reuse_pid then w.starts[10] = "start-2" else w.instance = "server-2" end
    w:start(); w:tick(20)
    assert(w:record("a").pending); equal(w:record("a").command, "sleep 599")
  end
end)

test("explicit execution before first delivery hands retained intent to tracking", function()
  local w = world(); w:seed("a", { command = "sleep 599" }); w:start()
  w:pane("a"); w:submit("a", "sleep 599"); w:job("a", "sleep", "sleep 599")
  w:tick(); equal(#w.writes, 0); equal(w:record("a").job_pid, 20)
  equal(w:record("a").pending, nil)
end)

test("legacy delivered input is adopted without duplication on upgrade", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599", shell_pid = 10, typed = true })
  w:start(); equal(#w.writes, 0); assert(w:record("a").pending)
  w.instance = "server-2"; w:start(); equal(w.writes[1], "sleep 599")
end)

test("missing ancestry and exec/direct commands are not idle shells", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" })
  local p = { name = "vim", pid = 10 }
  w.processes["block:a"] = { child = p, foreground = p }; w:start(); equal(#w.writes, 0)
  w:shell("a"); w:job("a", "vim", "vim file"); w.processes["block:a"].ancestors = nil
  w:tick(); equal(#w.writes, 0); equal(w:record("a").command, "sleep 599")
end)

test("control bytes cannot submit a generic command", function()
  for _, command in ipairs({ "echo hi\r", "echo hi\nrm file", "echo \27hi", "echo\0hi" }) do
    local w = world(); w:pane("a"); w:seed("a", { command = command }); w:start()
    equal(#w.writes, 0); equal(w:record("a").command, command)
  end
end)

test("partial writes inside UTF-8 and malformed acknowledgements preserve intent without replay", function()
  for _, reply in ipairs({ { bytes_written = 9 }, {}, { bytes_written = -1 }, { bytes_written = 500 } }) do
    local w = world(); w:pane("a"); w:seed("a", { command = "echo café" })
    w.write_reply = function() return reply end
    w:start(); w:tick(); w:start()
    equal(#w.writes, 1); equal(w:record("a").command, "echo café")
    assert(w:record("a").delivery.uncertain)
  end
end)

test("startup captures direct programs without typing into them", function()
  local w = world(); w:pane("a")
  local p = { name = "sleep", pid = 20 }; w.commands[20] = "sleep 596"
  w.processes["block:a"] = { child = p, foreground = p }
  w:start(); equal(w:record("a").command, "sleep 596"); equal(#w.writes, 0)
  w.instance = "server-2"; w:shell("a"); w:start()
  equal(w.writes[1], "sleep 596")
end)

test("failed pre-write persistence prevents delivery", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w.fail_save = true
  w:start(); equal(#w.writes, 0); w.fail_save = nil; w:tick(); equal(#w.writes, 1)
end)

test("detach and reversible pane/window/session closes retain intent through reload and reopen", function()
  for _, mode in ipairs({ "detach", "pane", "window", "session" }) do
    local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w:start()
    local pane = w.blocks.a
    if mode == "detach" then pane.window_id = nil else w.blocks.a = nil end
    if mode == "session" then w.sessions = {} end
    if mode == "detach" or mode == "window" then
      w:event("window_closed", { session_id = "session:a" }, { window_id = "window:a" })
    elseif mode == "session" then
      w:event("session_destroyed", {}, { session_id = "session:a" })
    end
    w:tick(); w:start(); w:tick(1000000)
    equal(w:record("a").command, "sleep 599"); equal(#w.writes, 1)
    w.sessions, w.blocks.a = { "session:a" }, pane
    pane.window_id = "window:reopened"
    w:event("session_created"); w:tick()
    equal(w:record("a").command, "sleep 599"); equal(#w.writes, 1)
  end
end)

test("absent local panes require proof of the observed child's exit or PID reuse", function()
  for _, reused in ipairs({ false, true }) do
    local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w:start()
    w.blocks = {}; w:tick(); assert(w:record("a"))
    if reused then w.starts[10] = "replacement" else w.processes = {} end
    w.failures.ps = true; w:tick(); assert(w:record("a"))
    w.failures.ps = nil; w:tick(); equal(w:record("a"), nil)
  end
end)

test("unobserved and foreign-server records cannot be orphan-collected", function()
  local w = world()
  w:seed("a", { command = "sleep 599", session_id = "session:a", instance_id = "server-1" })
  w:seed("b", { command = "sleep 598", session_id = "session:b", instance_id = "server-1", host_id = "remote" })
  w:pane("c"); w.blocks.c.host_id = "remote"
  w:start(); w:tick(1000000)
  assert(w:record("a")); assert(w:record("b")); equal(w:record("c"), nil); equal(#w.writes, 0)
end)

test("pane, window and session removal are scoped to their owners", function()
  local w = world(); w.sessions = { "session:a", "session:b" }
  w:pane("a"); w:pane("b", nil, nil, 11); w:pane("c", "session:a", "window:b", 12)
  w:pane("d", "session:b", "window:c", 13)
  for _, id in ipairs({ "a", "b", "c", "d" }) do w:seed(id, { command = "sleep " .. id }) end
  w:start(); w:event("block_closed", { session_id = "session:a" }, { block_id = "block:a" })
  equal(w:record("a"), nil); assert(w:record("b")); assert(w:record("d"))
  w.blocks.b, w.processes["block:b"] = nil, nil
  w:event("window_closed", { session_id = "session:a" }, { window_id = "window:a" })
  equal(w:record("b"), nil); assert(w:record("c")); assert(w:record("d"))
  w.blocks.c, w.processes["block:c"], w.sessions = nil, nil, { "session:b" }
  w:event("session_destroyed", {}, { session_id = "session:a" })
  equal(w:record("c"), nil); assert(w:record("d"))
end)

test("disconnects/empty inventories/new generation absence preserve intent; confirmed close cleans up", function()
  local w = world(); w:pane("a"); w:seed("a", { command = "sleep 599" }); w:start()
  w.sessions = {}; w.failures["session.describe_block"] = "connection lost"; w:tick(60)
  assert(w:record("a"))
  w.failures = {}; w:tick(); assert(w:record("a"))
  w.blocks = {}; w.instance = "server-2"; w:start(); assert(w:record("a"))
  w.instance = "server-1"; w:start(); assert(w:record("a"))
  w.processes = {}; w:tick(); equal(w:record("a"), nil)
end)

print("Passed " .. count .. " watcher contract tests")
