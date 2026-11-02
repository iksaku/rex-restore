#!/bin/sh
# Links this checkout into Rex's config directory and loads it from init.lua.
# Usage: ./install.sh [--uninstall]
set -eu

repo=$(cd "$(dirname "$0")" && pwd)
if [ -n "${REX_CONFIG:-}" ]; then
  config=$REX_CONFIG
else
  config="${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua"
fi
link="$(dirname "$config")/rex-restore"
line='require("rex-restore")'
state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-restore"

stop_watcher() {
  if [ -s "$state/watch.pid" ]; then
    kill "$(cat "$state/watch.pid")" 2>/dev/null || true
    rm -f "$state/watch.pid"
  fi
}

reload() {
  if rex --autostart=false config reload >/dev/null 2>&1; then
    echo "Reloaded the running Rex server."
  else
    echo "No running Rex server; it will load on next start."
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$config" ]; then
    grep -vxF "$line" "$config" >"$config.tmp" || true
    mv "$config.tmp" "$config"
  fi
  [ -L "$link" ] && rm "$link"
  stop_watcher
  echo "Removed rex-restore from $config."
  exit 0
fi

mkdir -p "$(dirname "$config")"
if [ -e "$link" ] && [ ! -L "$link" ]; then
  echo "$link exists and isn't a symlink; move it away first." >&2
  exit 1
fi
ln -sfn "$repo" "$link"
touch "$config"
grep -qxF "$line" "$config" || printf '%s\n' "$line" >>"$config"
# Restart the watcher so it runs this checkout's code.
stop_watcher
echo "Installed: $link -> $repo"
reload
