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

Copies cursor-cli-remote, forge_tui.py, spaces-forge-watch,
ssh-forge-resume-watch, and forge-mux-load-agent into
~/.config/omarchy/bin, keeps the cursor-forge-persist name as a
symlink, installs a Super+Space desktop entry, enables the
post-resume silent mux reconnect service, hooks ssh-agent
ExecStartPost to reload forge-mux, writes cursor-cli-remote.env
if missing, points KeePassXC at OpenSSH ssh-agent (not gpg),
installs Spaces stamps on the remote, and adopts any live Forge
attach. Does not patch /usr/share/omarchy.
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
install -m 0755 "$ROOT/ssh-forge-resume-watch" "$BIN_OMARCHY/ssh-forge-resume-watch"
install -m 0755 "$ROOT/forge-mux-load-agent" "$BIN_OMARCHY/forge-mux-load-agent"
if [[ -f "$ROOT/forge-mux-install-pubkey" ]]; then
  install -m 0755 "$ROOT/forge-mux-install-pubkey" "$BIN_OMARCHY/forge-mux-install-pubkey"
fi
install -m 0755 "$ROOT/hooks/spaces-forge-stamp.py" "$HOOKS/spaces-forge-stamp.py"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_OMARCHY/cursor-forge-persist"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-cli-remote"
ln -sfn "$BIN_OMARCHY/cursor-cli-remote" "$BIN_LOCAL/cursor-forge-persist"

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR" "$UNIT_DIR/ssh-agent.service.d"
install -m 0644 "$ROOT/ssh-forge-resume-watch.service" "$UNIT_DIR/ssh-forge-resume-watch.service"
install -m 0644 "$ROOT/ssh-agent.service.d/forge-mux.conf" \
  "$UNIT_DIR/ssh-agent.service.d/forge-mux.conf"
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.socket >/dev/null 2>&1 || true
systemctl --user enable --now ssh-forge-resume-watch.service >/dev/null
# Drop-in is picked up on next agent (re)start; do not block here on restart.
if systemctl --user is-active --quiet ssh-agent.service 2>/dev/null; then
  "$BIN_OMARCHY/forge-mux-load-agent" >/dev/null 2>&1 || true
else
  systemctl --user start --no-block ssh-agent.service >/dev/null 2>&1 || true
  sleep 0.3 || true
  "$BIN_OMARCHY/forge-mux-load-agent" >/dev/null 2>&1 || true
fi

MUX_KEY_PATH="${CURSOR_REMOTE_MUX_KEY:-$HOME/.ssh/id_ed25519_forge_mux}"
MUX_PUB_PATH="${MUX_KEY_PATH}.pub"
# Do not create a passphrase-less private key here — private lives in KeePassXC.
# Only remind if setup was never run.
if [[ ! -f "$MUX_PUB_PATH" ]]; then
  printf 'Mux pubkey missing — run once: cursor-cli-remote --setup-mux-key\n'
fi

# OpenSSH ssh-agent for KeePassXC (not gpg-agent — GCR pinentry can kill KeePass).
systemctl --user enable --now ssh-agent.socket >/dev/null 2>&1 || true
SSH_AGENT_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
KP_INI="${XDG_CONFIG_HOME:-$HOME/.config}/keepassxc/keepassxc.ini"
if [[ -f "$KP_INI" ]] || command -v keepassxc >/dev/null 2>&1; then
  mkdir -p "$(dirname "$KP_INI")"
  python3 - "$KP_INI" "$SSH_AGENT_SOCK" <<'PY'
import sys
from pathlib import Path
ini, sock = Path(sys.argv[1]), sys.argv[2]
text = ini.read_text() if ini.is_file() else ""
lines = text.splitlines()
out, i, found = [], 0, False
# KeePassXC → OpenSSH ssh-agent only (never gpg-agent — GCR pinentry can kill KeePass).
keys = {"Enabled": "true", "UseOpenSSH": "true", "AuthSockOverride": sock}
while i < len(lines):
    line = lines[i]
    if line.strip() == "[SSHAgent]":
        found = True
        out.append("[SSHAgent]")
        i += 1
        seen = set()
        while i < len(lines) and not lines[i].startswith("["):
            raw = lines[i]
            if "=" in raw and not raw.strip().startswith("#"):
                k = raw.split("=", 1)[0].strip()
                if k in keys:
                    out.append(f"{k}={keys[k]}")
                    seen.add(k)
                    i += 1
                    continue
            out.append(raw)
            i += 1
        for k, v in keys.items():
            if k not in seen:
                out.append(f"{k}={v}")
        continue
    out.append(line)
    i += 1
if not found:
    if out and out[-1] != "":
        out.append("")
    out.extend(["[SSHAgent]", "Enabled=true", "UseOpenSSH=true", f"AuthSockOverride={sock}"])
ini.write_text("\n".join(out) + "\n")
print(f"KeePassXC SSH Agent → {sock}")
PY
fi

if [[ ! -f "$CONFIG" ]]; then
  cat >"$CONFIG" <<EOF
CURSOR_REMOTE=forge
CURSOR_REMOTE_DIR=$HOME/work
CURSOR_REMOTE_AGENT=$HOME/.local/bin/agent
CURSOR_REMOTE_TITLE="Cursor Forge"
CURSOR_REMOTE_ACCENT="#cba6f7"
CURSOR_REMOTE_MAX_AGE_SECS=$((7 * 24 * 3600))
CURSOR_REMOTE_MUX_PERSIST=20h
# Pubkey path; private key in KeePassXC → ssh-agent (gpg).
CURSOR_REMOTE_MUX_KEY=$HOME/.ssh/id_ed25519_forge_mux
EOF
  printf 'Wrote %s\n' "$CONFIG"
else
  if ! grep -q '^CURSOR_REMOTE_MUX_PERSIST=' "$CONFIG" 2>/dev/null; then
    printf 'CURSOR_REMOTE_MUX_PERSIST=20h\n' >>"$CONFIG"
    printf 'Appended CURSOR_REMOTE_MUX_PERSIST to %s\n' "$CONFIG"
  fi
  if ! grep -q '^CURSOR_REMOTE_MUX_KEY=' "$CONFIG" 2>/dev/null; then
    printf 'CURSOR_REMOTE_MUX_KEY=%s\n' "$HOME/.ssh/id_ed25519_forge_mux" >>"$CONFIG"
    printf 'Appended CURSOR_REMOTE_MUX_KEY to %s\n' "$CONFIG"
  fi
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
"$ROOT/test-set-e-survive.sh"
# Remote SSH steps can hang if mux/Tailscale is mid-repair — bound them.
if ! timeout 45 "$BIN_OMARCHY/spaces-forge-watch" --install-hooks --remote "$REMOTE_NAME" --agent "$AGENT_PATH"; then
  printf 'Spaces hooks on %s: skipped (SSH later, or next attach)\n' "$REMOTE_NAME"
fi
timeout 20 "$BIN_OMARCHY/spaces-forge-watch" --adopt --remote "$REMOTE_NAME" --agent "$AGENT_PATH" \
  || printf 'Spaces adopt on %s: skipped\n' "$REMOTE_NAME"

printf 'Installed %s\n' "$BIN_OMARCHY/cursor-cli-remote"
printf 'TUI: %s\n' "$BIN_OMARCHY/forge_tui.py"
printf 'Watch: %s\n' "$BIN_OMARCHY/spaces-forge-watch"
printf 'Resume: %s (systemd --user ssh-forge-resume-watch)\n' "$BIN_OMARCHY/ssh-forge-resume-watch"
printf 'Mux pubkey: %s (private in KeePassXC)\n' "$MUX_PUB_PATH"
printf 'Log: %s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/cursor-cli-remote.log"
printf 'Desktop: %s/Cursor Forge CLI.desktop\n' "$APPS"
printf 'Mux: OpenSSH agent + forge-mux-load-agent (sleep/lock OK; reboot → unlock KeePass trigger)\n'
printf 'One-time: cursor-cli-remote --setup-mux-key\n'
printf 'KeePass trigger (Unlocked database) → %s/forge-mux-load-agent\n' "$BIN_OMARCHY"
printf 'ssh-agent.service.d/forge-mux.conf reloads the key when the agent restarts.\n'
printf 'Super+Space → Cursor Forge CLI\n'
