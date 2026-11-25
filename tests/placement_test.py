"""Live local-Rex detach, undo and permanent-removal regression tests.

Use an isolated disposable server. Requires the Rex binary on PATH to match
that server. Snapshot undo cases keep a real client connected until undo or
actual expiry (about a minute); Preview skips unsupported undo operations.
No server restart or shell configuration change is performed here.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--server", required=True)
parser.add_argument("--watch", type=Path, default=Path(__file__).resolve().parents[1] / "watch.lua")
args = parser.parse_args()
cli = ["rex", "--autostart=false", "-S", args.server]
leaf = {"block": {"flavor": "com.superlogical.terminal.shell"}}


def api(method, **params):
    return json.loads(subprocess.check_output(cli + ["api", "call", method, json.dumps(params)], text=True))


def wait(fn, label, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = fn()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(label)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


# One attached connection owns the undo history. A succession of short-lived
# `rex api call` processes cannot exercise undoable closes faithfully.
action_source = r'''
io.stdout:setvbuf("no")
local s, b, w, a = rex.args.session, rex.args.block, rex.args.window, rex.args.anchor
local mode = rex.args.mode
local function after(seconds, fn)
  rex.after(seconds, function()
    local ok, err = pcall(fn)
    if not ok then print(tostring(err)); rex.stop(1) end
  end)
end
local function call(method, params)
  local result, err = rex.call(method, params)
  assert(result, tostring(err))
  return result
end
rex.on("block_closed", function(_, ev) if ev.block_id == b then print("FINAL_BLOCK_CLOSED") end end)
rex.on("session_destroyed", function(_, ev) if ev.session_id == s then print("SESSION_DESTROYED") end end)
after(1, function()
  call("session.attach", { session_id = s })
  local undoable = (mode:match("^undo") or mode:match("^expire")) and true or nil
  if mode:match("^detach") then
    call("session.detach_block", { session_id = s, block_id = b })
  elseif mode:match("window") then
    call("session.close_window", { session_id = s, window_id = w, undoable = undoable })
  elseif mode:match("session") then
    call("session.destroy", { session_id = s, undoable = undoable })
  else
    call("block.close", { session_id = s, block_id = b, undoable = undoable })
  end
  print("CLOSED")
  if mode:match("^expire") then after(30, function() print("STILL_HELD") end) end
  after(mode:match("^expire") and 70 or 4, function()
    if mode:match("^detach") then
      call("session.move_block", { session_id = s, block_id = b, anchor_block_id = a })
      print("REOPENED")
    elseif mode:match("^undo") then
      local reopened = call("client.undo_close", {})
      assert(reopened.session_id == s and (mode == "undo_session" or reopened.block_id == b))
      print("REOPENED")
    elseif mode:match("^expire") then
      local reopened, err = rex.call("client.undo_close", {})
      assert(not reopened and tostring(err):match("code=not_found%)"), tostring(err))
      print("UNDO_EXPIRED")
    end
    after(1, function() rex.stop(0) end)
  end)
end)
'''


def case(mode):
    with tempfile.TemporaryDirectory(prefix="rex-placement-") as directory:
        root = Path(directory)
        state = root / "rex-restore"
        state.mkdir()
        (root / "action.lua").write_text(action_source)
        layout = ({"split": {"direction": "horizontal", "before": leaf, "after": leaf}}
                  if mode in {"detach_nonlast", "undo_block_nonlast"} else leaf)
        created = api("session.create", label="placement-" + mode, initial_windows=[{"layout": layout}])
        session = created["session_id"]
        block = created["initial_windows"][0]["block_ids"][0]
        window = created["initial_windows"][0]["window_id"]
        anchor = api("session.new_window", session_id=session, layout=leaf)["block_ids"][0]
        path = state / (block.removeprefix("block:") + ".json")
        # A valid saved-input fixture; delivery and all lifecycle operations use
        # the actual watcher, real shells, persisted files and real Rex API.
        path.write_text(json.dumps({"command": "sleep 593"}))
        log = (root / "watch.log").open("w+")
        watcher = None
        action = None
        destroyed = False

        def record():
            return json.loads(path.read_text()) if path.exists() else None

        def start():
            return subprocess.Popen(cli + ["do", "--all", str(args.watch.resolve())],
                                    env=dict(os.environ, XDG_STATE_HOME=directory), stdout=log, stderr=log)

        try:
            watcher = start()
            wait(lambda: record() and record().get("delivery", {}).get("complete"), "initial delivery: " + mode)
            original = record()
            shell = api("com.superlogical.terminal.process", session_id=session, block_id=block)["child"]["pid"]
            action = subprocess.Popen(cli + ["do", "--all", str(root / "action.lua"), "session=" + session,
                "block=" + block, "window=" + window, "anchor=" + anchor, "mode=" + mode],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            output = []
            closed = False
            for line in action.stdout:
                output.append(line)
                if line.strip() == "STILL_HELD":
                    assert alive(shell) and record(), mode + ": intent must survive the live undo interval"
                if line.strip() == "CLOSED":
                    closed = True
                    time.sleep(1)
                    if mode.startswith("permanent"):
                        wait(lambda: not alive(shell) and record() is None, "permanent cleanup: " + mode)
                    else:
                        assert alive(shell), mode + ": child died before expiry/undo"
                        assert record() and record()["command"] == "sleep 593", mode + ": intent lost while child lives"
                        if mode == "undo_session":
                            # The hidden session cannot be inventoried. Reload
                            # must rely on its persisted local child identity.
                            watcher.terminate()
                            watcher.wait(timeout=10)
                            watcher = start()
                            time.sleep(0.5)
                            assert record() and record()["command"] == "sleep 593"
            action.wait(timeout=10)
            assert action.returncode == 0 and closed, "".join(output)
            assert watcher.poll() is None, "watcher exited"
            if mode.startswith(("permanent", "expire")):
                wait(lambda: not alive(shell) and record() is None, "final cleanup: " + mode)
                lookup = subprocess.run(cli + ["api", "call", "session.describe_block",
                    json.dumps({"session_id": session, "block_id": block})], capture_output=True, text=True)
                assert lookup.returncode and any(code in lookup.stderr for code in
                    ("code=not_found)", "code=session_not_found)")), lookup.stdout + lookup.stderr
                if mode.startswith("expire"):
                    assert "UNDO_EXPIRED\n" in output, "".join(output)
                if mode == "expire_block":
                    assert "FINAL_BLOCK_CLOSED\n" in output, "".join(output)
                if mode.endswith("session"):
                    destroyed = True
                    assert "SESSION_DESTROYED\n" in output, "".join(output)
                    if mode == "expire_session":
                        assert "FINAL_BLOCK_CLOSED\n" not in output, "session expiry unexpectedly sent a final block event"
                print("PASS " + mode + ": actual child exit, unavailable block, recovery record removed"
                      + ("; undo expired, final_block_event=" + str("FINAL_BLOCK_CLOSED\n" in output)
                         if mode.startswith("expire") else ""), flush=True)
            else:
                current = api("com.superlogical.terminal.process", session_id=session, block_id=block)
                assert current["child"]["pid"] == shell and current["foreground"]["pid"] == shell
                assert record() and record()["delivery"] == original["delivery"]
                screen = subprocess.check_output(cli + ["capture", "-s", session, "-b", block], text=True)
                assert screen.count("sleep 593") == 1, screen
                print("PASS " + mode + ": intent retained, same idle shell, no duplicate input or execution", flush=True)
        except BaseException:
            log.flush()
            print("".join(output) if action else "action not started", flush=True)
            print((root / "watch.log").read_text(), flush=True)
            raise
        finally:
            if action and action.poll() is None:
                action.terminate()
                action.wait(timeout=10)
            if watcher and watcher.poll() is None:
                watcher.terminate()
                watcher.wait(timeout=10)
            log.close()
            if not destroyed and any(s["session_id"] == session for s in api("session.list").get("sessions", [])):
                api("session.destroy", session_id=session)


methods = subprocess.check_output(cli + ["api", "list", "-q"], text=True).splitlines()
undo = "client.undo_close" in methods
for mode in ["detach_nonlast", "detach_last", "permanent_block", "permanent_window", "permanent_session"]:
    case(mode)
if undo:
    for mode in ["undo_block_nonlast", "undo_block_last", "undo_window", "undo_session"]:
        case(mode)
    with ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(case, ["expire_block", "expire_session"]))
else:
    print("SKIP undo and undo-expiry: this server does not advertise client.undo_close", flush=True)
