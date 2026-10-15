#!/usr/bin/env python3
"""Claude Code hook on the persist host. Writes a stamp keyed by the tmux
session the hook runs in; the laptop watcher talks to Spaces. Does not
call omarchy-shell (wrong machine). Must stay silent on stdout."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

STAMP_DIR = Path.home() / ".local/state/spaces-forge/claude"
WORKING_EVENTS = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop"}


def tmux_session() -> str:
    if not os.environ.get("TMUX"):
        return ""
    try:
        out = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{session_name}"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""
    return out.strip()


def main() -> int:
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        data = {}
    event = str(data.get("hook_event_name") or "")
    state = ""
    if event in WORKING_EVENTS:
        state = "working"
    elif event == "Notification":
        if data.get("notification_type") == "permission_prompt":
            state = "waiting"
    elif event == "Stop":
        state = "done"
    elif event == "SessionEnd":
        state = "end"
    if not state:
        return 0
    session = tmux_session()
    if not session or "/" in session:
        return 0
    STAMP_DIR.mkdir(parents=True, exist_ok=True)
    (STAMP_DIR / session).write_text("%s %d\n" % (state, int(time.time())), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
