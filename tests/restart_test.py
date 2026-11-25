"""Real Rex regression matrix. Requires an explicitly disposable server.

The supplied restart command must stop/start that server while preserving its
state directory. The watcher uses a separate, temporary XDG_STATE_HOME. With
--omp-dir, also run a real offline omp session; configure the server's
PI_CODING_AGENT_DIR to that same isolated directory and put omp on its shells'
PATH. No model requests are sent.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--server", required=True)
parser.add_argument("--restart-command", required=True)
parser.add_argument("--omp-dir", type=Path)
parser.add_argument("--watch", type=Path, default=Path(__file__).resolve().parents[1] / "watch.lua")
args = parser.parse_args()


def cli(*argv):
    result = subprocess.run(["rex", "--autostart=false", "-S", args.server, *argv],
                            text=True, capture_output=True, timeout=15)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def api(method, **params):
    return json.loads(cli("api", "call", method, json.dumps(params)))


def wait(fn, label, seconds=25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = fn()
        if result:
            return result
        time.sleep(0.25)
    raise AssertionError("timed out: " + label)


def process(session, block):
    return api("com.superlogical.terminal.process", session_id=session, block_id=block)


def send(session, block, text):
    cli("send", "-s", session, "-b", block, text)


with tempfile.TemporaryDirectory(prefix="rex-restore-regression-") as directory:
    root = Path(directory)
    env = dict(os.environ, XDG_STATE_HOME=directory)
    if args.omp_dir:
        env["PI_CODING_AGENT_DIR"] = str(args.omp_dir.resolve())
    sessions = []
    watcher = None
    log = (root / "watch.log").open("w+")

    def record(block):
        path = root / "rex-restore" / (block.removeprefix("block:") + ".json")
        return json.loads(path.read_text()) if path.exists() else None

    def start_watcher():
        child = subprocess.Popen(["rex", "--autostart=false", "-S", args.server,
                                  "do", "--all", str(args.watch.resolve())],
                                 env=env, stdout=log, stderr=log)
        time.sleep(1.5)
        if child.poll() is not None:
            raise AssertionError("watcher exited; see log below")
        return child

    def restart():
        global watcher
        subprocess.run(shlex.split(args.restart_command), check=True, capture_output=True, timeout=30)
        watcher.wait(timeout=15)
        api("server.status")
        watcher = start_watcher()

    try:
        leaf = {"block": {"flavor": "com.superlogical.terminal.shell"}}
        a = api("session.create", label="restore-regression-a", initial_windows=[{"layout": leaf}])
        s = a["session_id"]
        sessions.append(s)
        b = a["initial_windows"][0]["block_ids"][0]
        split = {"split": {"direction": "horizontal", "before": leaf, "after": leaf}}
        window = api("session.new_window", session_id=s, layout=split)
        b2, b4 = window["block_ids"]
        a2 = api("session.create", label="restore-regression-b", initial_windows=[{"layout": leaf}])
        s2 = a2["session_id"]
        sessions.append(s2)
        b3 = a2["initial_windows"][0]["block_ids"][0]
        cases = [(s, b, "sleep 599"), (s, b2, "sleep 598"),
                 (s2, b3, "sleep 597"), (s, b4, "sleep 596")]
        for session, block, command in cases:
            send(session, block, command + "\r")
        wait(lambda: process(s, b).get("foreground", {}).get("name") == "sleep", "running job")
        watcher = start_watcher()
        for _, block, command in cases:
            wait(lambda: record(block), "startup inventory")
            assert record(block)["command"] == command
        print("PASS startup inventory: two sessions, four panes, multiple tabs", flush=True)

        for cycle in range(1, 4):
            restart()
            for session, block, command in cases:
                wait(lambda: record(block) and record(block).get("delivery", {}).get("complete"), "input delivery")
                assert process(session, block)["foreground"]["name"] in {"bash", "zsh", "fish", "sh"}
                assert command in cli("capture", "-s", session, "-b", block)
                assert record(block)["command"] == command
            send(s, b, "\x15")
            time.sleep(4)
            assert record(b)["command"] == "sleep 599"
            print(f"PASS restart {cycle}: input only, retained after clear", flush=True)

        # Enable the opt-in hook in the fixture only. The command already at
        # the prompt is cleared, not executed, before sourcing integration.
        helper = args.watch.resolve().parent / "shell-integration.bash"
        send(s2, b3, "\x15export XDG_STATE_HOME=" + shlex.quote(directory)
             + " REX_SERVER=" + shlex.quote(args.server)
             + "; source " + shlex.quote(str(helper)) + "\r")
        time.sleep(1)
        assert record(b3)["pending"]
        send(s2, b3, "sleep 597\r")
        wait(lambda: record(b3) and not record(b3).get("pending"), "renewed tracking")
        send(s2, b3, "\x03")
        wait(lambda: record(b3) is None, "completion cleanup")
        print("PASS execution -> renewed tracking -> completion cleanup", flush=True)

        # Seed a fast/builtin recovery record: there is deliberately no job
        # event to observe. The real shell hook must supply execution evidence.
        for command in ("true", "sleep 0.001"):
            path = root / "rex-restore" / (b3.removeprefix("block:") + ".json")
            temporary = path.with_suffix(".seed")
            temporary.write_text(json.dumps({"command": command}))
            temporary.replace(path)
            wait(lambda: record(b3) and record(b3).get("delivery", {}).get("complete"), "fast input delivery")
            send(s2, b3, "\r")
            wait(lambda: record(b3) is None, "short command/builtin acknowledgement")
        print("PASS shell acknowledgements: builtin and short job without process events", flush=True)

        api("block.close", session_id=s, block_id=b)
        wait(lambda: record(b) is None, "pane cleanup")
        assert record(b2) and record(b4)
        api("session.close_window", session_id=s, window_id=window["window_id"])
        wait(lambda: record(b2) is None and record(b4) is None, "tab cleanup")
        print("PASS scoped pane/tab removal", flush=True)

        if args.omp_dir:
            chat = root / "saved-chat.jsonl"
            chat.write_text(json.dumps({"type": "session", "version": 3,
                "id": "019700f1-1a2b-7c3d-8e4f-aabbccddeeff", "timestamp": "2026-11-08T10:00:00.000Z",
                "cwd": directory, "title": "Restore reliability fixture"}) + "\n")
            send(s2, b3, "omp --resume " + shlex.quote(str(chat)) + "\r")
            wait(lambda: record(b3) and record(b3).get("omp_session") == str(chat), "omp capture", 60)
            for cycle in range(1, 3):
                old_job = record(b3)["job_key"]
                restart()
                wait(lambda: record(b3) and record(b3).get("omp_session") == str(chat)
                     and not record(b3).get("pending") and record(b3).get("job_key") != old_job,
                     "omp handover", 60)
                assert process(s2, b3)["foreground"]["name"] == "omp"
                title = api("com.superlogical.terminal.title", session_id=s2, block_id=b3)
                assert title["owner"]["pid"] == record(b3)["job_pid"]
                print(f"PASS omp restart {cycle}: intended session, fresh runtime title, persisted tracking", flush=True)
        else:
            send(s2, b3, "sleep 595\r")
            wait(lambda: record(b3), "second session activity")
        api("session.destroy", session_id=s2)
        sessions.remove(s2)
        wait(lambda: record(b3) is None, "session cleanup")
        print("PASS scoped session removal", flush=True)
    except BaseException:
        log.flush()
        print((root / "watch.log").read_text())
        raise
    finally:
        if watcher and watcher.poll() is None:
            watcher.terminate()
            watcher.wait(timeout=10)
        for session in sessions:
            api("session.destroy", session_id=session)
        log.close()
