# rex-restore

Brings back what your [Rex](https://www.superlogical.com/rex) panes were running after the Rex server restarts:

- **omp** panes run `omp --resume <session>` on the same chat they had open.
- **Other commands** are typed at the prompt, not run, so you can press Enter or edit them.

Rex already restores sessions, layouts and directories. It doesn't restore programs.

## Install

```sh
git clone <this repo> ~/github.com/iksaku/rex-restore
~/github.com/iksaku/rex-restore/install.sh
```

The installer symlinks this checkout to `~/.config/rex/rex-restore` (it respects `REX_CONFIG` and `XDG_CONFIG_HOME`), adds `require("rex-restore")` to `init.lua`, and reloads the running server. `git pull` followed by `./install.sh` picks up changes. `./install.sh --uninstall` removes it.

Works on macOS and Linux, with any shell. On Linux, run the installer as the account the Rex server runs as: your own account for a personal or login server, or `rex` for the shared server.

## How it works

When the server loads `init.lua`, it starts `watch.lua` with `rex do --all`. A lock file keeps it to one copy per server.

- **Recording:** each time a terminal's foreground program changes, the watcher saves the command and the shell's PID to `~/.local/state/rex-restore/<block>.json`. When the pane has been back at its prompt for 3 seconds, it deletes the file.
- **omp sessions:** omp writes its current session file to `~/.omp/agent/terminal-sessions/<tty>`. The watcher reads it whenever omp retitles the terminal.
- **Restoring:** Rex keeps block IDs across restarts and starts a new shell in every pane. A pane that still has a record but has a different shell PID was interrupted, so the watcher writes the command into it.

The log is at `~/.local/state/rex-restore/watch.log`.

## Limits

- Commands are rebuilt from the process's arguments, not from what you typed. Pipes keep only one part, and redirects, quoting and `FOO=bar` prefixes are lost.
- omp's breadcrumb file is an internal format and could change in an omp update.
- If the watcher dies, nothing restarts it until the next server start or `rex config reload`.
- `rex config check` also runs `init.lua`, so it can start the watcher. The lock stops it from running twice.
