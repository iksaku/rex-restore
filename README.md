# rex-restore

Brings back what your [Rex](https://www.superlogical.com/rex) panes were running after the Rex server restarts:

- **omp** panes run `omp --resume <session>` on the same chat they had open.
- **Other commands** are typed at the prompt, not run, so you can press Enter or edit them.

Rex already restores sessions, layouts and directories. It doesn't restore programs. Run this plugin on the same machine as the Rex server; recovery and process checks cover that server's local panes, not remote-host blocks.

## Install

```sh
git clone https://github.com/iksaku/rex-restore.git ~/github.com/iksaku/rex-restore
~/github.com/iksaku/rex-restore/install.sh
```

The installer symlinks this checkout to `~/.config/rex/rex-restore` (it respects `REX_CONFIG` and `XDG_CONFIG_HOME`), adds `require("rex-restore")` to `init.lua`, and reloads the running server. `git pull` followed by `./install.sh` picks up changes. `./install.sh --uninstall` removes it.

Requires Rex's `server.status.instance_id` and terminal process/write APIs (tested with API revision 11). On Linux, run the installer as the account the Rex server runs as: your own account for a personal or login server, or `rex` for the shared server.

### Execution acknowledgement

To stop retaining a generic command once you run it, source the matching integration file in your interactive shell startup file. The installer does **not** modify shell configuration:

```bash
# ~/.bashrc (Bash 4.4+, or source after an existing bash-preexec installation)
source ~/.config/rex/rex-restore/shell-integration.bash
```

```zsh
# ~/.zshrc
source ~/.config/rex/rex-restore/shell-integration.zsh
```

```fish
# ~/.config/fish/config.fish
source ~/.config/rex/rex-restore/shell-integration.fish
```

Adjust the path when using a custom Rex config directory. Bash login shells must source `.bashrc` from their login profile. The watcher and the shell must use the same `XDG_STATE_HOME` (or its default). Hooks acknowledge only an exact saved command that you submit; they do not run restored input, change its text, or treat prompt helpers as execution. Bash's native hook uses the first simple command of a submitted line; existing `bash-preexec`, Zsh and Fish hooks receive the whole line. If Bash already has a DEBUG trap, use `bash-preexec` rather than replacing it. Without a working hook, or when an edit/alias/compound command no longer matches the snapshot, the plugin conservatively retains input instead of guessing that it ran. omp does not require shell integration.

## How it works

When the server loads `init.lua`, it starts `watch.lua` with `rex do --all`. The existing PID file permits one watcher per state directory; use separate `XDG_STATE_HOME` directories for multiple local servers.

- **Recording:** startup inventory, process/title events and periodic reconciliation save running activity to `~/.local/state/rex-restore/<block>.json`. Records include session/tab ownership, the server's random run ID, and process start identity, not just PIDs. Direct programs are recorded but never mistaken for idle shells.
- **Input-only recovery:** a fresh recognized shell receives the saved command without Enter. Busy or unavailable panes remain deferred. Successful typing, idle prompts, clearing input, age and retry counts never consume retained intent. The execution hook hands a submitted command back to normal activity tracking; completed activity is cleared after 3 idle seconds.
- **omp recovery:** the watcher reads omp's terminal breadcrumb on startup, process/title changes and retries. It queues `omp --resume <session>` only when the saved session exists. Intent stays persisted until a live omp, its matching session breadcrumb, and a title owned by that process are observed and fresh tracking is saved. Missing session information never falls back to opening a new chat.
- **Checked delivery:** queued byte counts are checked. Explicit rejections retry, and known partial writes continue at a safe UTF-8 boundary. An ambiguous response/crash is retained without blindly replaying into the same shell; a fresh shell can recover it. Queuing omp input does not prove resume, and a failed launch retains its intent for a later restore.
- **Removal:** a final `block_closed` event discards that pane's record. Detach, window closure and undoable session destruction are not final removal: hidden input survives reattachment, undo and watcher reload. A same-run not-found response is reconciled only after the observed local terminal child's process-start identity is proven gone, including PID reuse. This catches missed permanent closes and Snapshot's undo-session expiry, which emits no final block event. Failed/unreadable process checks preserve intent. Disconnect, shutdown and startup absence are not deletion signals; records absent across a new server generation, or without an observed child identity, remain retained because Rex exposes no durable deletion journal.

The log is at `~/.local/state/rex-restore/watch.log`. Snapshots contain full process arguments and session paths and may contain secrets; restore logs do not print command text. There is no TTL or count eviction of recovery records.

## Limits

- Commands are rebuilt from the process's arguments, not from what you typed. Pipes keep only one part, and redirects, quoting and `FOO=bar` prefixes are lost.
- Snapshots containing raw control characters are retained but not typed, because a newline or terminal escape could execute input. Missing ancestry or an unrecognized shell defers delivery rather than injecting into an active program.
- Legacy `typed=true` records with an unchanged shell PID are adopted without duplicate typing on upgrade. They lack generation metadata, so that first migration cannot distinguish PID reuse; newly tracked records can.
- omp's breadcrumb file is an internal format and could change in an omp update.
- If the watcher dies, nothing restarts it until the next server start or `rex config reload`.
- `rex config check` also runs `init.lua`, so it can start the watcher. The lock stops it from running twice.

## Tests

The draft GitHub Actions workflow in `.github/workflows/tests.yml` runs on pull
requests and pushes to `main`. It runs the 23 watcher contract tests against a
simulated Rex API/filesystem/clock, checks all Lua files for Lua 5.1 syntax,
checks the installer and Bash/Zsh/Fish integrations for shell syntax, and runs
ShellCheck on the installer and Bash integration. It also compiles the two
Python live-test scripts for syntax only; it does **not** run them. The job uses
Ubuntu 24.04 with `lua5.1`, `shellcheck`, `zsh` and `fish` installed via apt, plus
the runner's Bash and Python 3. It does not install Rex or omp, execute the
installer, or run `rex config check` (which can start a watcher).

The existing local fast checks require Lua 5.1 and ShellCheck:

```sh
lua5.1 tests/watch_test.lua
luac5.1 -p init.lua watch.lua executed.lua process_identity.lua
sh -n install.sh
bash -n shell-integration.bash
shellcheck install.sh shell-integration.bash
```

CI additionally runs `zsh -n shell-integration.zsh`,
`fish --no-execute shell-integration.fish`, Lua syntax checking on the contract
test itself, and `python3 -m py_compile tests/restart_test.py tests/placement_test.py`.
These static checks do not validate live shell-hook behavior or real Rex
delivery, process identity, undo, or restart behavior. The live suites below
are intentionally excluded from CI pending disposable-server provisioning and
a matching Rex version on PATH; their Python code uses only the standard
library (Python 3.9+).

`tests/restart_test.py` runs the real Rex matrix: startup capture across two sessions/four panes/multiple tabs, three input-only restores, cleared input retention, execution acknowledgements (including a builtin and a short job), scoped removal, and optionally two real omp resumes with renewed tracking. **Use only an isolated disposable server**: the supplied command restarts it three times (five with omp). Its shells must be Bash for the execution-hook portion. It creates and removes its own sessions and temporary watcher state. For the omp cases, put `omp` on the restored shells' PATH and set the test server's `PI_CODING_AGENT_DIR` to an isolated directory:

```sh
python3 tests/restart_test.py --server unix:///tmp/rex-test/server.sock \
  --restart-command 'amp orb service restart rex-test' --omp-dir /tmp/rex-test/omp
```

Omit `--omp-dir` to run only generic-command cases. `--watch /path/to/watch.lua` runs the same scenario against another revision. Ensure the restart command waits for the new server generation to accept API calls; a service manager may return before the socket is ready.

`tests/placement_test.py --server <isolated-server>` exercises local detach/reattach, permanent pane/window/session removal, and—when the server advertises undo—reversible pane/window/session closes and watcher reload while hidden. It also waits for actual undo expiry of a pane and a session (about a minute), requiring the real child to exit and the recovery record to disappear. It seeds saved-input fixtures but uses the real watcher and Rex API throughout. Run it on the server's machine with a matching Rex binary on PATH. Preview skips unsupported undo cases.

Linux/Rex API 11, Preview 23/API 19, Snapshot 2564/API 21 and omp 18.18.2 were exercised. macOS, a real host reboot/power loss, and live model requests were not.
