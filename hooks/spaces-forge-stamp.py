#!/usr/bin/env python3
"""Cursor hook on the persist host. Writes a stamp; the laptop watcher
talks to Spaces. Does not call omarchy-shell (wrong machine)."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

WORKING_EVENTS = {
    "beforeSubmitPrompt",
    "preToolUse",
    "beforeShellExecution",
    "beforeMCPExecution",
    "subagentStop",
}


def main() -> int:
    raw = sys.stdin.read()
    try:
        data = json.loads(raw or "{}")
    except json.JSONDecodeError:
        data = {}
    event = str(data.get("hook_event_name") or data.get("event_name") or "")
    session = str(
        data.get("conversation_id") or data.get("session_id") or "unknown"
    )
    if event == "beforeSubmitPrompt":
        sys.stdout.write('{"continue":true}\n')
    elif event in ("preToolUse", "beforeShellExecution", "beforeMCPExecution"):
        sys.stdout.write('{"permission":"allow"}\n')
    state = ""
    if event in WORKING_EVENTS:
        state = "working"
    elif event == "stop":
        state = "done"
    elif event == "sessionEnd":
        state = "end"
    if not state:
        return 0
    dest = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "spaces-forge"
    dest.mkdir(parents=True, exist_ok=True)
    line = "%s %d\n" % (state, int(time.time()))
    (dest / session).write_text(line, encoding="utf-8")
    (dest / "latest").write_text("%s %s" % (session, line), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
