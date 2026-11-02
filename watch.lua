-- Remembers what each Rex terminal is running and puts it back after the Rex
-- server restarts: omp is resumed on the same session, any other command is
-- typed at the prompt without being run. Started by init.lua; see README.md.
--
-- Rex keeps block IDs across restarts and starts a fresh shell in each pane,
-- so a record whose shell PID differs from the pane's current shell means the
-- pane was interrupted mid-command.

local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
local STATE = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/rex-restore"
local OMP_CRUMBS = (os.getenv("PI_CODING_AGENT_DIR") or HOME .. "/.omp/agent") .. "/terminal-sessions/"
-- Panes go idle while the server shuts down; waiting past that keeps the
-- record of a command the shutdown interrupted.
local CLEAR_DELAY = 3
local RESTORE_WINDOW = 30

rex.exec({ "mkdir", "-p", "-m", "700", STATE })

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function write(path, text)
  local f = assert(io.open(path .. ".tmp", "w"))
  f:write(text)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end

do
  local lock = STATE .. "/watch.pid"
  local pid = read(lock)
  if pid and rex.exec({ "kill", "-0", pid }, { stderr = false }).ok then
    rex.log("info", "rex-restore already running as " .. pid)
    rex.stop(0)
  end
  local self = rex.exec({ "sh", "-c", "echo $PPID" }).stdout:match("%d+")
  write(lock, self)
end

local function record_path(block_id)
  return STATE .. "/" .. block_id:gsub("^block:", "") .. ".json"
end

local function load(block_id)
  local text = read(record_path(block_id))
  return text and rex.json.decode(text)
end

local function save(block_id, rec)
  write(record_path(block_id), rex.json.encode(rec))
end

local function quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- `ancestors` runs from the foreground's parent outward. The pane's shell is
-- the outermost one below login; the job is the process just inside it.
local function split(foreground, ancestors)
  local chain = { foreground }
  for _, p in ipairs(ancestors or {}) do
    if p.name ~= "login" then chain[#chain + 1] = p end
  end
  local shell = chain[#chain]
  return shell, chain[#chain - 1]
end

local function ps(pid)
  local out = rex.exec({ "ps", "-o", "tty=,args=", "-p", tostring(pid) }).stdout
  return out:match("^%s*(%S+)%s+(.-)%s*$")
end

-- omp names its breadcrumb after the tty with slashes replaced: ttys005, pts-3.
local function omp_session(tty)
  local crumb = tty and read(OMP_CRUMBS .. tty:gsub("/", "-"))
  local file = crumb and crumb:match("^[^\n]*\n([^\n]+)")
  return file and exists(file) and file or nil
end

local function on_process(ctx, ev)
  if not ev.foreground then return end
  local session_id, block_id = ctx.session_id, ctx.block_id
  local shell, job = split(ev.foreground, ev.ancestors)
  if not job then
    rex.after(CLEAR_DELAY, function()
      local rec = load(block_id)
      if not rec or rec.typed or rec.shell_pid ~= shell.pid then return end
      local now = rex.block.call(TERMINAL, "process", { session_id = session_id, block_id = block_id })
      local s, j = split(now.foreground, now.ancestors)
      if not j and s.pid == shell.pid then os.remove(record_path(block_id)) end
    end)
    return
  end
  local prev = load(block_id)
  if prev and prev.job_pid == job.pid then return end
  local tty, args = ps(job.pid)
  if not args then return end
  local rec = { shell_pid = shell.pid, job_pid = job.pid, command = args }
  if job.name == "omp" then
    rec.omp_tty = tty
    rec.omp_session = omp_session(tty)
  end
  save(block_id, rec)
end

-- omp writes its terminal breadcrumb after startup and again on /new or
-- /resume; it retitles the terminal around both.
local function on_title(ctx)
  local rec = load(ctx.block_id)
  if not rec or not rec.omp_tty then return end
  local session = omp_session(rec.omp_tty)
  if session and session ~= rec.omp_session then
    rec.omp_session = session
    save(ctx.block_id, rec)
  end
end

rex.on("terminal.process_changed", on_process)
rex.on("terminal.title_changed", on_title)

local pending = {}

local function try_restore(session_id, block_id, rec)
  local ok, proc = pcall(rex.block.call, TERMINAL, "process", { session_id = session_id, block_id = block_id })
  if not ok or not proc.foreground then return false end
  local shell, job = split(proc.foreground, proc.ancestors)
  if job then return true end
  if shell.pid == rec.shell_pid then return true end
  local data
  if rec.omp_tty then
    data = (rec.omp_session and "omp --resume " .. quote(rec.omp_session) or "omp") .. "\r"
    os.remove(record_path(block_id))
  else
    data = rec.command
    -- Kept until something else runs in the pane, across further restarts.
    rec.shell_pid, rec.job_pid, rec.typed = shell.pid, nil, true
    save(block_id, rec)
  end
  rex.block.call(TERMINAL, "write", { session_id = session_id, block_id = block_id, data = data })
  rex.log("info", "restored " .. block_id .. ": " .. data)
  return true
end

local function scan()
  local done = true
  for _, s in ipairs(rex.call("session.list").sessions or {}) do
    for _, b in ipairs(rex.call("session.list_blocks", { session_id = s.session_id }).blocks or {}) do
      local id = b.block_id
      if b.creator_name == TERMINAL and not pending[id] then
        local rec = load(id)
        if rec then
          if try_restore(s.session_id, id, rec) then pending[id] = true else done = false end
        end
      end
    end
  end
  return done
end

local deadline = os.time() + RESTORE_WINDOW
local timer
timer = rex.every(1, function()
  if scan() or os.time() > deadline then timer:cancel() end
end)
