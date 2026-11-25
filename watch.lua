-- Rex owns the layout; this watcher owns only recoverable activity. Delivery,
-- execution and omp handover are separate, persisted transitions.
local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
local STATE = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/rex-restore"
local OMP_CRUMBS = (os.getenv("PI_CODING_AGENT_DIR") or HOME .. "/.omp/agent") .. "/terminal-sessions/"
local CLEAR_DELAY = 3
local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]*$") or "."
local identity = dofile(dir .. "/process_identity.lua")

local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function exists(path)
  local f = io.open(path)
  if not f then return false end
  f:close()
  return true
end

local function write(path, text)
  local f, err = io.open(path .. ".tmp", "w")
  if not f then return nil, err end
  local ok
  ok, err = f:write(text)
  local closed, close_err = f:close()
  if not ok or not closed then
    os.remove(path .. ".tmp")
    return nil, err or close_err
  end
  return os.rename(path .. ".tmp", path)
end

local function exec(argv)
  local r = rex.exec(argv, { stderr = false })
  return r and r.ok and r.stdout or nil
end

assert(exec({ "mkdir", "-p", "-m", "700", STATE }))

-- Keep the existing launcher/installer PID-file contract. Watcher supervision
-- and an atomic singleton are separate from recovery state.
do
  local lock = STATE .. "/watch.pid"
  local pid = read(lock)
  if pid and exec({ "kill", "-0", pid }) then rex.stop(0) end
  assert(write(lock, assert(exec({ "sh", "-c", "echo $PPID" })):match("%d+")))
end

local function record_path(id)
  return STATE .. "/" .. id:gsub("^block:", "") .. ".json"
end

local function load(id)
  local text = read(record_path(id))
  if not text then return nil end
  local rec = rex.json.decode(text)
  if type(rec) ~= "table" or type(rec.command) ~= "string" then
    rex.log("error", "invalid recovery record: " .. id)
    return nil
  end
  return rec
end

local function save(id, rec)
  local text, err = rex.json.encode(rec)
  local ok
  if text then ok, err = write(record_path(id), text) end
  if not ok then rex.log("error", "cannot persist " .. id .. ": " .. tostring(err)) end
  return ok
end

local function remove(id)
  os.remove(record_path(id))
  os.remove(record_path(id) .. ".executed")
end

local function quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local shells = { sh = true, bash = true, zsh = true, dash = true, ksh = true,
  fish = true, csh = true, tcsh = true, nu = true }
local function is_shell(p)
  return p and shells[p.name:gsub("^-", "")] == true
end

-- Never infer an idle shell from a missing ancestor chain or a directly
-- launched program. On macOS the terminal child can be login.
local function split(proc)
  if not proc or not proc.foreground or not proc.child then return nil end
  local fg, child = proc.foreground, proc.child
  local chain = { fg }
  for _, p in ipairs(proc.ancestors or {}) do chain[#chain + 1] = p end
  local shell
  if is_shell(child) then
    if fg.pid ~= child.pid and chain[#chain].pid ~= child.pid then return nil end
    shell = child
  elseif child.name == "login" and chain[#chain].pid == child.pid then
    shell = chain[#chain - 1]
    if not is_shell(shell) then return nil end
  else
    return nil
  end
  local job
  for i, p in ipairs(chain) do
    if p.pid == shell.pid then job = chain[i - 1]; break end
  end
  return shell, job
end

local function ps(pid)
  local out = exec({ "ps", "-o", "tty=,args=", "-p", tostring(pid) })
  if out then return out:match("^%s*(%S+)%s+(.-)%s*$") end
end

local function omp_session(tty)
  local crumb = tty and read(OMP_CRUMBS .. tty:gsub("/", "-"))
  local file = crumb and crumb:match("^[^\n]*\n([^\n]+)")
  return file and exists(file) and file or nil
end

local function terminal(session, id, method, data)
  return rex.block.call(TERMINAL, method, { session_id = session, block_id = id, data = data })
end

local function owner(rec, server, session, block)
  rec.session_id, rec.window_id = session, block.window_id
  rec.host_id, rec.instance_id = server.host_id, server.instance_id
end

local idle = {}
local function capture(server, session, block, proc, rec, child)
  local id = block.block_id
  local shell, job = split(proc)
  -- A direct child (including an exec-replaced shell) is activity, not a
  -- place to type. It can still be captured for a future fresh shell.
  if not shell and proc.child and proc.foreground and proc.child.pid == proc.foreground.pid
      and not is_shell(proc.child) and proc.child.name ~= "login" then
    shell, job = proc.child, proc.foreground
  end
  if not shell then return end
  local shell_key = identity(server, shell)
  if not shell_key then return end
  local accepted = read(record_path(id) .. ".executed")
  accepted = accepted and rex.json.decode(accepted)
  if rec and not rec.omp_tty and type(accepted) == "table"
      and accepted.command == rec.command and accepted.shell_pid == shell.pid
      and accepted.shell_key == shell_key then
    rec.pending, rec.delivery, rec.typed = nil, nil, nil
    rec.shell_key, rec.executed = shell_key, true
    if not save(id, rec) then return end
    os.remove(record_path(id) .. ".executed")
  end
  if not job then
    -- A shutdown can look idle. Require the same live server and process
    -- identity on a later observation; never clear pending recovery intent.
    if rec and not rec.pending and not rec.delivery and rec.shell_key == shell_key
        and not (rec.omp_tty and not rec.omp_session) then
      idle[id] = idle[id] or os.time()
      if os.time() - idle[id] >= CLEAR_DELAY then remove(id) end
    end
    return
  end
  idle[id] = nil
  local tty, args = ps(job.pid)
  local job_key = identity(server, job)
  if not args or not job_key then return end
  -- Ignore the preexec bridge and other helpers between submission and the
  -- actual job. A fast command/builtin is consumed on the later idle check.
  if rec and rec.executed and args ~= rec.command then return end
  local session_file = job.name == "omp" and omp_session(tty) or nil
  if rec and (rec.pending or rec.delivery or rec.shell_key ~= shell_key) then
    if rec.omp_tty then
      -- A live omp and the *intended* breadcrumb are both required. Neither
      -- queued bytes nor a different chat is proof of successful recovery.
      if job.name ~= "omp" or not session_file or session_file ~= rec.omp_session then return end
      -- Breadcrumbs outlive processes and tty names are reused. A title
      -- emitted by this live omp supplies a fresh runtime acknowledgement.
      local title = terminal(session, id, "title")
      if not title or not title.owner or title.owner.pid ~= job.pid or title.owner.name ~= "omp" then return end
    elseif not (not rec.pending and not rec.delivery and not rec.shell_key
        and rec.job_pid == job.pid and args == rec.command) then
      -- Even identical process arguments can belong to a prompt helper.
      -- Only an accepted-command acknowledgement consumes retained input.
      return
    end
  end
  if rec and not rec.pending and not rec.delivery and rec.job_key == job_key
      and rec.omp_session == session_file then return end
  local next_rec = { command = args, shell_pid = shell.pid, shell_key = shell_key,
    job_pid = job.pid, job_key = job_key, child = child }
  owner(next_rec, server, session, block)
  if job.name == "omp" then
    next_rec.omp_tty, next_rec.omp_session = tty, session_file
  end
  save(id, next_rec)
end

local function rejected(err)
  -- Only an explicit rejection proves no side effect. Unknown errors and
  -- transport failures are ambiguous, even when they don't say "timeout".
  local text = tostring(err)
  local code = text:match("code=([%w_]+)%)") or text:match("^([%w_]+):") or text
  return code == "busy" or code == "unavailable" or code == "not_found"
    or code == "session_not_found" or code == "conflict" or code == "bad_request"
    or code == "forbidden"
end

local function restore(server, session, block, proc, rec)
  local id = block.block_id
  local shell, job = split(proc)
  if not shell or job then return end -- busy/unavailable stays in the backlog
  local key = identity(server, shell)
  if not key then return end
  -- Migrate old records without mistaking equal PIDs for equal generations.
  -- All new records use the random server instance and process start identity.
  if not rec.shell_key and rec.typed and rec.shell_pid == shell.pid then
    -- Legacy files cannot distinguish PID reuse from already-queued input.
    -- Adopt conservatively once, rather than append duplicate input on upgrade.
    rec.shell_key, rec.pending = key, true
    rec.delivery = { shell_key = key, complete = true, offset = #rec.command }
    owner(rec, server, session, block)
    save(id, rec)
    return
  end
  if rec.shell_key == key and not rec.pending then return end
  rec.pending = true
  if rec.delivery and rec.delivery.shell_key == key then
    if rec.delivery.uncertain or rec.delivery.complete then return end
  else
    rec.delivery = { shell_key = key, offset = 0 }
  end
  local data = rec.command
  if rec.omp_tty then
    if not rec.omp_session or not exists(rec.omp_session) then return end
    data = "omp --resume " .. quote(rec.omp_session) .. "\r"
  end
  -- Raw control bytes (especially LF/CR) could execute generic input. Refuse
  -- unsafe snapshots rather than silently changing or submitting a command.
  if rec.command:find("[%z\1-\31\127]") or (rec.omp_session and rec.omp_session:find("[%z\1-\31\127]")) then
    return
  end
  local delivery = rec.delivery
  local offset = delivery.offset or 0
  local suffix = data:sub(offset + 1)
  -- Persist *before* the side effect. A crash during write must not cause an
  -- automatic omp replay on a watcher reload in the same live shell.
  delivery.uncertain = true
  owner(rec, server, session, block)
  if not save(id, rec) then return end
  local result, err = terminal(session, id, "write", suffix)
  if not result then
    delivery.uncertain = not rejected(err) or nil
    save(id, rec)
    rex.log("warn", "delivery deferred for " .. id .. ": " .. tostring(err))
    return
  end
  local bytes = result.bytes_written
  if type(bytes) ~= "number" or bytes < 0 or bytes > #suffix or bytes % 1 ~= 0 then return end
  delivery.offset, delivery.uncertain = offset + bytes, nil
  local next_byte = data:byte(delivery.offset + 1)
  if next_byte and next_byte >= 128 and next_byte < 192 then
    -- A suffix starting inside a UTF-8 character cannot be represented by
    -- the write API's JSON string. Preserve intent instead of corrupting it.
    delivery.uncertain = true
  end
  if delivery.offset == #data then
    delivery.complete = true
    rec.typed = not rec.omp_tty or nil
    rex.log("info", "input queued for " .. id .. (rec.omp_tty and "; awaiting omp tracking" or "; retained until execution"))
  end
  save(id, rec)
end

local function records()
  local out = exec({ "ls", "-1", STATE }) or ""
  local result = {}
  for file in out:gmatch("[^\n]+") do
    local name = file:match("^([^/]+)%.json$")
    if name then result["block:" .. name] = load("block:" .. name) end
  end
  return result
end

local function scan()
  local server = rex.call("server.status")
  if not server or not server.instance_id then return end
  local sessions = rex.call("session.list")
  if not sessions then return end
  for _, s in ipairs(sessions.sessions or {}) do
    local blocks = rex.call("session.list_blocks", { session_id = s.session_id })
    if blocks then
      for _, b in ipairs(blocks.blocks or {}) do
        if b.creator_name == TERMINAL and (not b.host_id or b.host_id == server.host_id) then
          local rec = load(b.block_id)
          local proc = terminal(s.session_id, b.block_id, "process")
          local child = proc and proc.child
          local child_key = child and identity(server, child)
          child = child_key and { pid = child.pid, name = child.name, key = child_key } or nil
          if rec and (rec.session_id ~= s.session_id or rec.window_id ~= b.window_id
              or rec.instance_id ~= server.instance_id
              or (child and (not rec.child or rec.child.key ~= child.key))) then
            owner(rec, server, s.session_id, b)
            if child then rec.child = child end
            save(b.block_id, rec)
          end
          if proc then
            capture(server, s.session_id, b, proc, rec, child)
            rec = load(b.block_id)
            if rec then restore(server, s.session_id, b, proc, rec) end
          end
        end
      end
    end
  end
  -- Hidden undoable blocks/sessions return not_found while their programs
  -- still run. Reconcile only local children observed in this server run,
  -- after both an absent block and the end of that child's identity are proven.
  -- Across restart, or with unreadable identity, preserve recovery intent.
  local live_pids
  for id, rec in pairs(records()) do
    local child = rec.child
    if rec.instance_id == server.instance_id and rec.host_id == server.host_id
        and rec.session_id and child and child.key:match("^([^:]+):") == server.instance_id then
      local result, err = rex.call("session.describe_block", { session_id = rec.session_id, block_id = id })
      if not result and (tostring(err):match("code=not_found%)") or tostring(err):match("code=session_not_found%)")) then
        local key = identity(server, child)
        if key and key ~= child.key then
          remove(id) -- the PID now belongs to another process
        elseif not key then
          -- An unreadable start identity alone is not proof of exit. Require
          -- a successful process inventory that no longer contains the PID.
          if live_pids == nil then live_pids = exec({ "ps", "-A", "-o", "pid=" }) or false end
          if live_pids and not ("\n" .. live_pids):match("\n%s*" .. child.pid .. "%s*\n") then remove(id) end
        end
      end
    end
  end
end

local function closed(ctx, ev)
  local id = ev.block_id or ctx.block_id
  if id then remove(id); idle[id] = nil end
end

rex.on("block_closed", closed)
-- Placement changes and reversible session destruction are not final closes.
-- Query current state, retaining hidden intent until the local child is gone.
rex.on("window_closed", scan)
rex.on("session_destroyed", scan)
-- Query current state rather than trusting delayed process-event payloads.
rex.on("terminal.process_changed", scan)
rex.on("terminal.title_changed", scan)
rex.on("block_created", scan)
rex.on("session_created", scan)
scan()
-- Keep discovery and retries alive, including initially empty inventories.
-- Deadlines and age/count eviction must never discard valid recovery intent.
rex.every(1, scan)
