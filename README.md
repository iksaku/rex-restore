# rex-restore

> **Retiring rex-restore.** Rex's new [Program Resume Protocol (OSC 7577)](https://www.superlogical.com/rex/docs/build/program-resume) is the reason for retiring this plugin. This repository will be archived shortly after this notice is published. **To remove rex-restore, follow the [uninstall instructions](#uninstall) below**, which cover disabling startup, stopping the watcher, removing shell integrations, and preserving your recovery data and omp conversations. For native resume setup and supported programs, see Rex's [Session Restore](https://www.superlogical.com/rex/docs/features/session-restore) and [Resume Rules](https://www.superlogical.com/rex/docs/customize/resume-rules).

Brings back what your [Rex](https://www.superlogical.com/rex) panes were running after the Rex server restarts:

- **omp** panes run `omp --resume <session>` on the same chat they had open.
- **Other commands** are typed at the prompt, not run, so you can press Enter or edit them.

Rex already restores sessions, layouts and directories. This plugin predates native program resume and uses process inspection instead. Run this plugin on the same machine as the Rex server; recovery and process checks cover that server's local panes, not remote-host blocks. The installation and behavior below describe the existing plugin, not a recommendation to install it for new setups.

## Install

```sh
git clone https://github.com/iksaku/rex-restore.git ~/github.com/iksaku/rex-restore
~/github.com/iksaku/rex-restore/install.sh
```

The installer symlinks this checkout to `~/.config/rex/rex-restore` (it respects `REX_CONFIG` and `XDG_CONFIG_HOME`), adds `require("rex-restore")` to `init.lua`, and reloads the running server. `git pull` followed by `./install.sh` picks up changes. For removal, including the limitations of `./install.sh --uninstall`, follow [Uninstall](#uninstall).

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

## Uninstall

Removing the plugin and deleting saved recovery data are **separate decisions**. The default procedure below keeps recovery data and all real omp conversations. It does not uninstall Rex, stop the Rex server, close panes, or change native resume rules.

### 1. Identify the installation and preserve anything needed

Work on the Rex server's machine, as the account that installed/runs the plugin (possibly `rex` on a shared Linux server). Confirm the server, account and environment rather than using a client's defaults. Repeat for each installation/state directory; one watcher may cover multiple sessions, and the PID file is per state directory, not per pane.

The paths used by this checkout are:

- **Startup config:** `$REX_CONFIG` when nonempty (a **file**, not a directory), otherwise `${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua`.
- **Plugin link:** `rex-restore` beside that config file, normally `~/.config/rex/rex-restore`. The installer creates a symlink to the checkout; a directory or a link to a different project is not safe to delete on that assumption.
- **Plugin state:** `${XDG_STATE_HOME:-$HOME/.local/state}/rex-restore`, even on macOS. Match the watcher's environment and any shell-specific overrides. This is not Rex's own state directory.
- **Manual shell setup:** source lines for `shell-integration.bash`, `.zsh` or `.fish` in interactive startup files and any files they source, including custom `ZDOTDIR`/Fish locations or login-profile additions.
- **omp data (not plugin-owned):** `${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/terminal-sessions/` contains omp's breadcrumbs. The watcher only reads them; their second line points to the real session file, which can be elsewhere. Neither those breadcrumbs nor their targets are uninstall targets.

An environment variable set to an empty string needs special care: Lua treats it as set. With an empty `XDG_STATE_HOME`, the watcher/acknowledgement code uses `/rex-restore`, while the shell launcher and installer fall back to `~/.local/state/rex-restore` for the log/PID cleanup. With an empty `PI_CODING_AGENT_DIR`, the watcher reads `/terminal-sessions/`. Resolve the actual paths before cleanup rather than silently substituting defaults or deleting both locations.

Review the config, link target and startup files before editing. Make private backups of files you change. Recovery JSON contains full command arguments and session paths and may contain secrets; do not paste it into an agent transcript or public issue. If a recovery copy is needed, copy it privately after stopping the watcher and retiring loaded shell hooks in step 3 so it is no longer changing.

### 2. Disable future launches before removing files

In the actual Rex config, remove only the plugin's `require("rex-restore")` call. Check included Lua files for manual variants, such as single quotes, whitespace, `dofile` or a direct `rex do --all /path/to/watch.lua` launcher. Preserve unrelated Lua code, bindings and `resume.*` settings. Remove only verified plugin launch commands from any user-added service, scheduled job or wrapper; this installer creates none of those.

Remove only the source statement for this plugin's shell integration from each affected shell startup file. Keep other hooks, shell configuration, `bash-preexec` itself, and any shared login-profile line that sources `.bashrc`. Do not remove an entire startup file or hook array.

**Do not run `rex config check`, reload config, reinstall, or restart the server while a plugin launch remains:** config evaluation can start the watcher. Removing the require alone does not stop the already detached watcher.

### 3. Stop only the verified watcher and retire loaded shell hooks

Read `watch.pid` in the identified plugin state directory if it exists. It is only a candidate PID: it can be stale or reused. Inspect that process's user, start time and full arguments, for example with `ps -p PID -o user=,pid=,ppid=,lstart=,args=` (replace `PID` with the numeric value). Confirm it is the `rex do --all` process running this installation's `watch.lua`, resolving the config symlink to the checkout as needed. Inspect the process list for additional copies launched from that exact script path; do not assume a missing PID file means no watcher.

Send `TERM` only to each confirmed watcher PID, then verify that the same process identity has exited. Recheck identity immediately before signaling; a PID file or command-name match alone is insufficient. If ownership is ambiguous, leave the process alone and investigate. Do not use `killall rex`, broad `pkill` patterns, signal the server, or kill omp/shell processes. After all confirmed watchers are gone, remove only this installation's stale `watch.pid` (and any verified `watch.pid.tmp`).

Removing a source line does not unload hooks from existing shells. After saving work and exiting any foreground program normally, replace each affected shell with a fresh instance of the same shell, or open a clean shell and retire the old one when safe. Do not replace a shell underneath a running omp session. Avoid blanket `trap - DEBUG`, clearing `PS0`, or deleting hook arrays: Bash may share them with other integrations. The plugin's loaded names are `__rex_restore_preexec`, `__rex_restore_helper`, `__rex_restore_hooked` and, in native Bash mode, `__rex_restore_submitted`; Zsh registers a preexec hook, Fish a `fish_preexec` handler, and Bash uses either `preexec_functions` or a DEBUG trap plus a PS0 prefix. Starting a fresh shell after removing the source statement avoids dismantling shared hooks by hand. Until old shells are retired they can still call `executed.lua` and write acknowledgement files.

### 4. Remove the link and verify removal

Unlink only the verified `rex-restore` symlink beside the Rex config, without a trailing slash; do not recursively delete through it. Keep the checkout until no startup file or live hook needs it. Deleting that checkout later is optional: inspect for local changes and unrelated files first.

The existing `./install.sh --uninstall` is a limited helper, **not** the whole procedure: it removes only an exact standalone `require("rex-restore")` line, unlinks any symlink at the computed plugin path, blindly signals the PID in `watch.pid`, and removes that PID file. It neither reloads Rex nor removes shell setup or saved state. Prefer the inspected manual steps above. If using the helper, first complete the ownership checks, remove custom launch/source statements, stop verified watchers and remove the stale PID file yourself; use the same config/state environment. Do not run it against an unchecked PID or symlink.

Verify all of the following:

- No plugin launch/source references remain in the active config and its included files, shell startup files or custom automation. Unrelated Rex and shell settings are unchanged.
- No process still runs this installation's watcher; the plugin link and its PID file are absent. A fresh interactive shell has no plugin hook/function loaded and emits no missing-source error. Test the shell types you actually configured.
- Only after removing every launch reference, optionally run `rex --autostart=false config check` and, for the explicitly selected running local server, `rex --autostart=false config reload` (add your normal server selector). Inspect errors; do not restart a server merely to verify removal. Recheck that no watcher/PID file appeared. `--autostart=false` prevents starting an absent server, not side effects from remaining Lua launch code.
- Preserved recovery files remain intact and are no longer updated by the plugin after both watchers and old shell hooks are gone. Rex sessions/layouts and omp conversation files are still present. Uninstall does not retract text already typed into a pane or stop an already resumed omp; clear unwanted pending input manually **without executing it**. Test native resume separately on a disposable server before relying on it; do not restart a working server as an uninstall test.

### Optional: intentionally discard plugin recovery data

Keep `${XDG_STATE_HOME:-$HOME/.local/state}/rex-restore` by default. After completing removal, you may explicitly choose to discard its recovery backlog and logs. Inventory it first, including hidden entries, and confirm the resolved directory belongs only to this plugin and is not a symlink to shared data. Expected files are `<block-id>.json`, their `.json.tmp`, `.json.executed` and `.json.executed.tmp` companions, `watch.log`, `watch.pid` and `watch.pid.tmp`. Investigate unexpected entries; do not delete them by name resemblance alone. Delete only approved plugin-owned files, then remove the directory only if empty. This loses saved commands/omp resume pointers and diagnostic history; there is no automatic migration to native Rex resume. Private backup copies, if made, are a separate retention/deletion decision.

Never delete Rex's own state/snapshots or use `rex server stop --discard` for this uninstall. Never delete omp's agent directory, `terminal-sessions`, session files referenced by recovery records, or real conversations. Plugin removal needs none of those deletions.

**For coding agents:** a request to draft or review these instructions is not permission to uninstall. When authorized to remove the plugin, follow the same ownership checks and ordering, preserve recovery data by default, and ask for explicit consent naming the resolved paths and data loss before deleting recovery data, logs or backup copies. Stop for ambiguous process/file ownership rather than widening the match. Report the exact edits/removals, what was preserved, verification results, and any old shells/hooks still requiring attention; do not claim cleanup is complete while they remain. Validate changes to this procedure with disposable fixtures, not a user's live installation.

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
