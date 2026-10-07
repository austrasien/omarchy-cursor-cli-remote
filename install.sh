#!/usr/bin/env bash
# Install cursor-cli-remote into the current user's Omarchy session.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_OMARCHY="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/bin"
BIN_LOCAL="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/cursor-cli-remote.env"
HOOKS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/cursor-cli-remote-hooks"
FOOT_INI="${XDG_CONFIG_HOME:-$HOME/.config}/foot/agent.ini"
APP_ID="org.omarchy.agent.forge"

usage() {
  cat <<'EOF'
Usage: ./install.sh

Copies cursor-cli-remote, forge_tui.py, and spaces-forge-watch into
~/.config/omarchy/bin, keeps the cursor-forge-persist name as a
symlink, installs a Super+Space desktop entry, writes
cursor-cli-remote.env if missing, installs Spaces stamps on the
remote, and adopts any live Forge attach. Does not patch
/usr/share/omarchy.
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

mkdir -p "$BIN_OMARCHY" "$BIN_LOCAL" "$APPS" "$HOOKS" "$(dirname "$CONFIG")"

install -m 0755 "$ROOT/cursor-cli-remote" "$BIN_OMARCHY/cursor-cli-remote"
install -m 0755 "$ROOT/forge_tui.py" "$BIN_OMARCHY/forge_tui.py"
install -m 0755 "$ROOT/spaces-forge-watch" "$BIN_OMARCHY/spaces-forge-watch"
install -m 0755 "$ROOT/hooks/spaces-forge-stamp.py" "$HOOKS/spaces-forge-stamp.py"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_OMARCHY/cursor-forge-persist"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-cli-remote"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-forge-persist"

if [[ ! -f "$CONFIG" ]]; then
  cat >"$CONFIG" <<EOF
CURSOR_REMOTE=forge
CURSOR_REMOTE_DIR=$HOME/work
CURSOR_REMOTE_AGENT=$HOME/.local/bin/agent
CURSOR_REMOTE_TITLE="Cursor Forge"
CURSOR_REMOTE_ACCENT="#cba6f7"
CURSOR_REMOTE_MAX_AGE_SECS=$((7 * 24 * 3600))
CURSOR_REMOTE_MUX_PERSIST=20h
EOF
  printf 'Wrote %s\n' "$CONFIG"
elif ! grep -q '^CURSOR_REMOTE_MUX_PERSIST=' "$CONFIG" 2>/dev/null; then
  printf 'CURSOR_REMOTE_MUX_PERSIST=20h\n' >>"$CONFIG"
  printf 'Appended CURSOR_REMOTE_MUX_PERSIST to %s\n' "$CONFIG"
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
Exec=uwsm-app -- foot ${FOOT_ARGS}--app-id=${APP_ID} -o key-bindings.show-urls-launch=Mod1+u -e ${BIN_OMARCHY}/cursor-cli-remote
Terminal=false
Type=Application
Icon=cursor-forge
StartupWMClass=${APP_ID}
StartupNotify=false
Categories=Development;
Keywords=cursor;cli;agent;forge;persist;ssh;remote;
EOF

if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
fi

REMOTE_NAME="${CURSOR_REMOTE:-forge}"
AGENT_PATH="${CURSOR_REMOTE_AGENT:-$HOME/.local/bin/agent}"
if [[ -f "$CONFIG" ]]; then
  set +e
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG"
  set +a
  set -e
  REMOTE_NAME="${CURSOR_REMOTE:-forge}"
  AGENT_PATH="${CURSOR_REMOTE_AGENT:-$HOME/.local/bin/agent}"
fi

"$BIN_OMARCHY/cursor-cli-remote" --spaces-self-test
if ! "$BIN_OMARCHY/spaces-forge-watch" --install-hooks --remote "$REMOTE_NAME" --agent "$AGENT_PATH"; then
  printf 'Spaces hooks on %s: skipped (SSH later, or next attach)\n' "$REMOTE_NAME"
fi
"$BIN_OMARCHY/spaces-forge-watch" --adopt --remote "$REMOTE_NAME" --agent "$AGENT_PATH"

printf 'Installed %s\n' "$BIN_OMARCHY/cursor-cli-remote"
printf 'TUI: %s\n' "$BIN_OMARCHY/forge_tui.py"
printf 'Watch: %s\n' "$BIN_OMARCHY/spaces-forge-watch"
printf 'Log: %s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/cursor-cli-remote.log"
printf 'Desktop: %s/Cursor Forge CLI.desktop\n' "$APPS"
printf 'Mux: reuse until 04:00 (ControlPersist backup 20h)\n'
printf 'Super+Space → Cursor Forge CLI\n'
