# Cursor CLI remote persist for Omarchy

A **Super+Space launcher** that lists Cursor **`agent persist`** sessions on an SSH host (a My Machines worker, not a Cloud VM), then attach / create / stop from a mauve TUI. One Hyprland Foot window per session.

> **⚡ Built for Omarchy:** Foot + gum + python3, user-space only. Does not patch `/usr/share/omarchy`. The window title overlay is a **separate** plugin: [omarchy-agent-title](https://github.com/austrasien/omarchy-agent-title).

```
Super+Space “Cursor Forge CLI”  →  SSH  →  agent persist list / attach / stop
```

---

### ☕ Support the Project
If recovering a persist session instead of spawning an orphan is worth a minute, a tip is always appreciated.

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg?style=for-the-badge&logo=paypal)](https://paypal.me/austraz)

---

### 💬 Feedback & Community
Got a question, found a bug, or have a suggestion? Open an [**issue**](https://github.com/austrasien/omarchy-cursor-cli-remote/issues).

---

## Overview

`agent persist` on every launch creates a **new** tmux session and leaves the old ones behind. This menu talks to the Cursor persist tmux socket on the remote (`/tmp/tmux-$(id -u)/cursor-agent`).

| | Without ❌ | With this launcher ✅ |
| :--- | :--- | :--- |
| **Open again** | New persist session | Attach the one you want |
| **Several jobs** | Orphans on the worker | `0–9` / `A…`, or arrows |
| **Cleanup** | Hunt tmux by hand | Backspace → `agent persist stop`; sessions older than 7 days stop on launch |

Defaults match a host alias `forge`, workdir `$HOME/work`, and `~/.local/bin/agent`. Override with `~/.config/omarchy/cursor-cli-remote.env`.

## Keys

- `0–9` then `A, B, C…` open that session (newest first).
- ↑↓ move. → or Enter opens the highlighted row.
- Backspace stops it immediately (`persist stop`, no confirm). No-op on “Nouvelle session”.
- Between the shortcut and the title: `[YY-MM-DD HH:mm]` from tmux `session_created`.

Foot class: `org.omarchy.agent.forge` so [agent-title](https://github.com/austrasien/omarchy-agent-title) can paint the bar mauve (`#cba6f7`) instead of the Mars orange accent.

## Install (Omarchy)

**Requirements:** `ssh`, `python3`, [gum](https://github.com/charmbracelet/gum), Foot, Cursor CLI `agent` on the **remote**, SSH host alias (ControlMaster recommended). Persist attach needs a TTY (`ssh -tt`).

```sh
git clone https://github.com/austrasien/omarchy-cursor-cli-remote.git
cd omarchy-cursor-cli-remote
./install.sh
```

Then Super+Space → **Cursor Forge CLI**. Optional Hyprland bind: `SHIFT + XF86AudioMedia` (Framework logo) to `gtk-launch "Cursor Forge CLI.desktop"`.

### Config

`~/.config/omarchy/cursor-cli-remote.env` (created on first install if missing):

```sh
CURSOR_REMOTE=forge
CURSOR_REMOTE_DIR="$HOME/work"
CURSOR_REMOTE_AGENT="$HOME/.local/bin/agent"
CURSOR_REMOTE_TITLE="Cursor Forge"
CURSOR_REMOTE_ACCENT="#cba6f7"
CURSOR_REMOTE_MAX_AGE_SECS=$((7 * 24 * 3600))
```

Update:

```sh
cd /path/to/omarchy-cursor-cli-remote
git pull
./install.sh
```
