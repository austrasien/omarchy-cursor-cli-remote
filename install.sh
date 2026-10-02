#!/usr/bin/env bash
# Install cursor-cli-remote into the current user's Omarchy session.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_OMARCHY="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/bin"
BIN_LOCAL="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/cursor-cli-remote.env"
FOOT_INI="${XDG_CONFIG_HOME:-$HOME/.config}/foot/agent.ini"
APP_ID="org.omarchy.agent.forge"

usage() {
  cat <<'EOF'
Usage: ./install.sh

Copies cursor-cli-remote into ~/.config/omarchy/bin, keeps the
cursor-forge-persist name as a symlink, installs a Super+Space
desktop entry, and writes cursor-cli-remote.env if missing.
Does not patch /usr/share/omarchy.
EOF
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    -h | --help) usage ;;
    *) usage ;;
  esac
done

need() {
  command -v "$1" >/dev/null || MISSING+=("$1")
}

MISSING=()
need bash
need python3
need ssh
need gum
if ((${#MISSING[@]})); then
  printf 'Missing commands: %s\n' "${MISSING[*]}" >&2
  exit 1
fi

mkdir -p "$BIN_OMARCHY" "$BIN_LOCAL" "$APPS" "$(dirname "$CONFIG")"

install -m 0755 "$ROOT/cursor-cli-remote" "$BIN_OMARCHY/cursor-cli-remote"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_OMARCHY/cursor-forge-persist"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-cli-remote"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-forge-persist"

if [[ ! -f "$CONFIG" ]]; then
  cat >"$CONFIG" <<EOF
CURSOR_REMOTE=forge
CURSOR_REMOTE_DIR=$HOME/work
CURSOR_REMOTE_AGENT=$HOME/.local/bin/agent
CURSOR_REMOTE_TITLE=Cursor Forge
CURSOR_REMOTE_ACCENT=#cba6f7
CURSOR_REMOTE_MAX_AGE_SECS=$((7 * 24 * 3600))
EOF
  printf 'Wrote %s\n' "$CONFIG"
fi

if [[ ! -f "$FOOT_INI" ]]; then
  FOOT_INI=/dev/null
  FOOT_ARGS=""
else
  FOOT_ARGS="--config=${FOOT_INI} "
fi

cat >"$APPS/Cursor Forge CLI.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Cursor Forge CLI
Comment=Sessions Cursor persistantes via SSH
Exec=foot ${FOOT_ARGS}--app-id=${APP_ID} -o key-bindings.show-urls-launch=Mod1+u -e ${BIN_OMARCHY}/cursor-cli-remote
Terminal=false
Type=Application
Icon=cursor-forge
StartupWMClass=${APP_ID}
StartupNotify=true
Categories=Development;
Keywords=cursor;cli;agent;forge;persist;ssh;remote;
EOF

if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
fi

printf 'Installed %s\n' "$BIN_OMARCHY/cursor-cli-remote"
printf 'Desktop: %s/Cursor Forge CLI.desktop\n' "$APPS"
printf 'Super+Space → Cursor Forge CLI\n'
