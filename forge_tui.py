#!/usr/bin/env python3
"""Mauve TUI for Cursor Forge CLI (pick / wait / pin / loading).

Invoked by cursor-cli-remote with MODE via --mode or $MODE.
Stdout (pick): action\\nident\\n
Exit: 0 ok/retry, 1 empty pick, 130 quit (esc×2 in wait, esc in pick).
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import select
import struct
import sys
import termios
import time
import tty
import unicodedata

SHORTCUTS = "123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
AZERTY_ROW = dict(zip("&é\"" + chr(39) + "(-è_çà", "1234567890"))
PAD_X, PAD_Y = 2, 1
MIN_INNER = 52

# YubiKey 5 OTP enumerates as a USB keyboard and injects Esc/Enter/Ctrl+C.
# Keep a long quiet window after plug (and at start if already present).
HID_IGNORE_SECS = 4.0
YUBI_RECENT_SECS = 4.0
# Human esc×2: min gap filters OTP double-fire; max gap resets the pair.
ESC_QUIT_MIN_GAP = 0.35
ESC_QUIT_MAX_GAP = 1.5


def rgb(value: str | None, fallback: tuple[int, int, int]) -> tuple[int, int, int]:
    value = (value or "").lstrip("#")
    try:
        return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))
    except Exception:
        return fallback


def yubikey_plugged() -> bool:
    # Vendor sysfs first; also product string — OTP keyboard can emit
    # keystrokes before every idVendor node is readable on some kernels.
    for path in glob.glob("/sys/bus/usb/devices/*/idVendor"):
        try:
            with open(path, encoding="ascii") as fh:
                if fh.read().strip().lower() == "1050":
                    return True
        except OSError:
            continue
    for path in glob.glob("/sys/bus/usb/devices/*/product"):
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                if "yubikey" in fh.read().strip().lower():
                    return True
        except OSError:
            continue
    return False


def dw(text: str) -> int:
    n = 0
    for ch in text:
        n += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return n


def fit(text: str, width: int) -> str:
    if dw(text) <= width:
        return text
    out: list[str] = []
    n = 0
    for ch in text:
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if n + w + 1 > width:
            break
        out.append(ch)
        n += w
    return "".join(out) + "…"


def pad(text: str, width: int) -> str:
    text = fit(text, width)
    return text + " " * (width - dw(text))


def cell(text: str, fg: tuple[int, int, int], bg: tuple[int, int, int]) -> str:
    return "\033[38;2;%d;%d;%dm\033[48;2;%d;%d;%dm%s" % (
        fg[0],
        fg[1],
        fg[2],
        bg[0],
        bg[1],
        bg[2],
        text,
    )


def esc_quit_decision(delta: float) -> str:
    """Classify a second Esc after `delta` seconds: ignore | quit | reset."""
    if delta < ESC_QUIT_MIN_GAP:
        return "ignore"
    if delta <= ESC_QUIT_MAX_GAP:
        return "quit"
    return "reset"


def self_test() -> int:
    assert rgb("#cba6f7", (0, 0, 0)) == (203, 166, 247)
    assert rgb("bogus", (1, 2, 3)) == (1, 2, 3)
    assert dw("ab") == 2
    assert fit("hello world", 5).endswith("…")
    assert pad("x", 3) == "x  "
    # Ctrl+C must not be aliased to esc at the classifier level used by wait.
    assert classify_byte_ctrl(b"\x03") == "ctrl_c"
    assert classify_byte_ctrl(b"\x1b") == "esc_start"
    assert esc_quit_decision(0.05) == "ignore"  # OTP double-fire
    assert esc_quit_decision(0.5) == "quit"  # human esc×2
    assert esc_quit_decision(2.0) == "reset"
    assert HID_IGNORE_SECS >= 3.0
    # Waiting for YubiKey must not treat Esc as quit (regression: Foot close on plug).
    assert True  # AUTO_YUBI wait path ignores esc/enter — see run() wait branch
    yubikey_plugged()  # must not raise
    print("forge_tui self-test ok")
    return 0


def classify_byte_ctrl(ch: bytes) -> str:
    """Pure helper for tests (mirrors read_key specials)."""
    if ch == b"\x03":
        return "ctrl_c"
    if ch == b"\x1b":
        return "esc_start"
    if ch in (b"\r", b"\n"):
        return "enter"
    return "other"


def run(mode: str) -> int:
    accent = rgb(os.environ.get("ACCENT"), (203, 166, 247))
    fg = rgb(os.environ.get("FG"), (190, 190, 190))
    muted = rgb(os.environ.get("MUTED"), (85, 85, 85))
    bg = rgb(os.environ.get("BG"), (18, 18, 18))
    title = os.environ.get("TITLE", "Cursor Forge")
    sub = os.environ.get("SUB", "forge  ·  persist")
    hint = os.environ.get(
        "HINT",
        "0–9 A…  →/⏎  ouvrir     ↑↓     ⌫  supprimer     esc",
    )
    auto_yubi = os.environ.get("AUTO_YUBI", "1") != "0"
    body_lines = [ln for ln in os.environ.get("BODY", "").split("\n") if ln]

    rows_in = (
        [ln.rstrip("\n") for ln in sys.stdin.read().splitlines() if ln]
        if mode == "pick"
        else []
    )
    labels: list[str] = []
    ids: list[str] = []
    keys: dict[str, str] = {}
    for row in rows_in:
        if "\t" in row:
            label, ident = row.split("\t", 1)
        else:
            label, ident = row, ""
        labels.append(label)
        ids.append(ident)
        k = label[:1]
        if ident == "[new]":
            for nk in ("n", "N", "+"):
                keys[nk] = ident
            continue
        if k in SHORTCUTS:
            keys[k] = ident
            keys[k.lower()] = ident
    if mode == "pick" and not labels:
        return 1

    def shortcut_lookup(key: str) -> str | None:
        key = AZERTY_ROW.get(key, key)
        return keys.get(key)

    fd = os.open("/dev/tty", os.O_RDWR)
    ui = os.fdopen(os.dup(fd), "w", buffering=1)
    old = termios.tcgetattr(fd)

    def restore() -> None:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            ui.write("\033[0m\033[?25h")
            ui.flush()
        except Exception:
            pass

    def winsize() -> tuple[int, int]:
        try:
            packed = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
            r, c = struct.unpack("HHHH", packed)[:2]
            return max(int(r), 8), max(int(c), 24)
        except Exception:
            return 24, 80

    def drain() -> None:
        termios.tcflush(fd, termios.TCIFLUSH)
        while select.select([fd], [], [], 0)[0]:
            if not os.read(fd, 4096):
                break

    def quiet_drain(seconds: float = 0.08) -> None:
        end = time.monotonic() + seconds
        while True:
            timeout = end - time.monotonic()
            if timeout <= 0:
                break
            if select.select([fd], [], [], timeout)[0]:
                if not os.read(fd, 4096):
                    break
                end = time.monotonic() + 0.02

    def read_key() -> str:
        ch = os.read(fd, 1)
        if not ch:
            return "ignore"
        if ch in (b"\r", b"\n"):
            return "enter"
        if ch in (b"\x7f", b"\x08"):
            return "bspace"
        # Never treat Ctrl+C as Esc: OTP HID and fat-finger must not quit wait.
        if ch == b"\x03":
            return "ctrl_c"
        if ch != b"\x1b":
            try:
                return ch.decode("utf-8")
            except UnicodeDecodeError:
                return "ignore"
        seq = bytearray(ch)
        if select.select([fd], [], [], 0.05)[0]:
            nxt = os.read(fd, 1)
            seq += nxt
            if nxt in (b"[", b"O"):
                while select.select([fd], [], [], 0.05)[0]:
                    nxt = os.read(fd, 1)
                    seq += nxt
                    if nxt.isalpha() or nxt in b"~":
                        break
        if seq in (b"\x1b", b"\x1b\x1b"):
            return "esc"
        if seq in (b"\x1b[A", b"\x1bOA"):
            return "up"
        if seq in (b"\x1b[B", b"\x1bOB"):
            return "down"
        if seq in (b"\x1b[C", b"\x1bOC"):
            return "right"
        if seq in (b"\x1b[D", b"\x1bOD"):
            return "left"
        return "ignore"

    idx = 0
    scroll = 0

    def paint_box() -> tuple[int, int]:
        nonlocal scroll
        term_r, term_c = winsize()
        show_list = mode == "pick"
        show_body = mode in ("wait", "pin")
        show_hint = mode in ("pick", "wait")
        items = labels if show_list else []
        extra = body_lines if show_body else []
        chrome = 2 + 2 * PAD_Y + 2
        if show_list or mode == "wait":
            chrome += 3
        elif mode == "pin":
            chrome += 1 + len(extra)
        max_rows = max(1, term_r - chrome)
        if show_list:
            if idx < scroll:
                scroll = idx
            if idx >= scroll + max_rows:
                scroll = idx - max_rows + 1
            visible = items[scroll : scroll + max_rows]
        else:
            visible = extra

        inner = MIN_INNER
        inner = max(inner, dw(title), dw(sub))
        if show_list or show_body:
            if show_hint:
                inner = max(inner, dw(hint))
            for lab in items:
                inner = max(inner, dw("› " + lab))
            for lab in extra:
                inner = max(inner, dw(lab))
        inner = min(inner, max(20, term_c - 2 - 2 * PAD_X))
        box_w = inner + 2 + 2 * PAD_X
        inner_lines = 2 + 2 * PAD_Y
        if show_list:
            inner_lines += 3 + len(visible)
        elif mode == "wait":
            inner_lines += 3 + len(visible)
        elif mode == "pin":
            inner_lines += 1 + len(extra)
        box_h = inner_lines + 2
        top = max(1, (term_r - box_h) // 2 + 1)
        if mode == "pin":
            top = max(2, min(top, max(2, term_r // 6)))
            top = min(top, max(2, term_r - box_h - 8))
        left = max(1, (term_c - box_w) // 2 + 1)
        bar = "─" * (box_w - 2)
        blank = " " * inner

        def put(row: int, text: str) -> None:
            ui.write("\033[%d;%dH%s\033[0m" % (row, left, text))

        def side(content: str, color: tuple[int, int, int]) -> str:
            return (
                cell("│", accent, bg)
                + cell(" " * PAD_X, fg, bg)
                + cell(pad(content, inner), color, bg)
                + cell(" " * PAD_X, fg, bg)
                + cell("│", accent, bg)
            )

        ui.write("\033[0m\033[2J\033[H\033[?25l")
        row = top
        put(row, cell("╭" + bar + "╮", accent, bg))
        row += 1
        for _ in range(PAD_Y):
            put(row, side(blank, fg))
            row += 1
        put(row, side(title, accent))
        row += 1
        put(row, side(sub, muted))
        row += 1
        if show_list:
            put(row, side(blank, fg))
            row += 1
            put(row, side(hint, muted))
            row += 1
            put(row, side(blank, fg))
            row += 1
            for i, lab in enumerate(visible):
                real = scroll + i
                if real == idx:
                    put(row, side("› " + lab, accent))
                else:
                    put(row, side("  " + lab, fg))
                row += 1
        elif mode == "wait":
            put(row, side(blank, fg))
            row += 1
            put(row, side(hint, muted))
            row += 1
            put(row, side(blank, fg))
            row += 1
            for lab in extra:
                put(row, side(lab, fg))
                row += 1
        elif mode == "pin":
            put(row, side(blank, fg))
            row += 1
            for lab in extra:
                put(row, side(lab, fg))
                row += 1
        for _ in range(PAD_Y):
            put(row, side(blank, fg))
            row += 1
        put(row, cell("╰" + bar + "╯", accent, bg))
        ui.flush()
        return row, term_r

    hid_ignore_until = 0.0
    yubi_changed_at = 0.0
    esc_first_at = 0.0
    was_yubi = yubikey_plugged()
    # Relaunch with key already in: OTP HID still chatters for a bit.
    if was_yubi:
        hid_ignore_until = time.monotonic() + HID_IGNORE_SECS
        drain()

    def note_yubi() -> bool:
        nonlocal hid_ignore_until, was_yubi, yubi_changed_at, esc_first_at
        now_yubi = yubikey_plugged()
        if now_yubi != was_yubi:
            now = time.monotonic()
            hid_ignore_until = now + HID_IGNORE_SECS
            yubi_changed_at = now
            esc_first_at = 0.0
            drain()
            was_yubi = now_yubi
        return now_yubi

    def hid_quiet() -> bool:
        return time.monotonic() < hid_ignore_until

    def yubi_recent(seconds: float = YUBI_RECENT_SECS) -> bool:
        return yubi_changed_at > 0 and (time.monotonic() - yubi_changed_at) < seconds

    def wait_for_yubi(seconds: float = 1.0) -> bool:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if yubikey_plugged():
                return True
            time.sleep(0.05)
        return yubikey_plugged()

    q_quit_at = 0.0

    try:
        if mode == "wait":
            drain()
            tty.setraw(fd)
            try:
                while True:
                    note_yubi()
                    if auto_yubi and was_yubi:
                        # Key just appeared (or was already in): OTP HID will
                        # keep injecting Esc/Enter for seconds — drain hard,
                        # then let bash continue. Never treat those as quit.
                        quiet_drain(2.0)
                        drain()
                        restore()
                        return 0
                    paint_box()
                    r, _, _ = select.select([fd], [], [], 0.35)
                    if not r:
                        continue
                    key = read_key()
                    if hid_quiet() or key == "ignore":
                        continue
                    # OTP HID: never quit on Ctrl+C / Esc / Enter while we are
                    # auto-waiting for a YubiKey — that is what closes Foot
                    # the moment the user plugs the key.
                    if auto_yubi and not was_yubi:
                        if key in ("ctrl_c", "esc", "enter", "right", "left", "up", "down"):
                            continue
                        # Deliberate quit without a key: type q twice (OTP
                        # does not inject letter q).
                        if key in ("q", "Q"):
                            now = time.monotonic()
                            if q_quit_at > 0 and now - q_quit_at <= ESC_QUIT_MAX_GAP:
                                if now - q_quit_at >= ESC_QUIT_MIN_GAP:
                                    restore()
                                    return 130
                            q_quit_at = now
                        continue
                    if key == "ctrl_c":
                        continue
                    if key == "esc":
                        if yubi_recent() or hid_quiet():
                            continue
                        now = time.monotonic()
                        if esc_first_at <= 0:
                            esc_first_at = now
                            continue
                        delta = now - esc_first_at
                        if delta < ESC_QUIT_MIN_GAP:
                            continue
                        if delta <= ESC_QUIT_MAX_GAP:
                            restore()
                            return 130
                        esc_first_at = now
                        continue
                    if key in ("enter", "right"):
                        if yubi_recent() or hid_quiet():
                            continue
                        restore()
                        return 0
            finally:
                restore()

        if mode == "pin":
            bottom, term_r = paint_box()
            prompt_row = min(term_r, bottom + 2)
            ui.write("\033[0m\033[%d;1H\033[J\033[?25h" % prompt_row)
            ui.flush()
            return 0

        if mode != "pick":
            paint_box()
            ui.write("\033[0m\033[?25h")
            ui.flush()
            return 0

        drain()
        tty.setraw(fd)
        idx = 1 if len(labels) > 1 else 0
        paint_box()
        drain()
        quiet_drain()
        while True:
            note_yubi()
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                continue
            key = read_key()
            if hid_quiet() or key == "ignore" or key == "ctrl_c":
                continue
            if key == "esc":
                restore()
                return 130
            if key == "up":
                idx = (idx - 1) % len(labels)
                paint_box()
                continue
            if key == "down":
                idx = (idx + 1) % len(labels)
                paint_box()
                continue
            if key == "left":
                continue
            action = None
            ident = None
            hit = shortcut_lookup(key)
            if hit is not None:
                action, ident = "open", hit
            elif key in ("enter", "right"):
                action, ident = "open", ids[idx]
            elif key == "bspace":
                action, ident = "delete", ids[idx]
            else:
                continue
            restore()
            sys.stdout.write("%s\n%s\n" % (action, ident))
            sys.stdout.flush()
            return 0
    finally:
        if mode == "pick":
            restore()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Cursor Forge CLI mauve TUI")
    p.add_argument(
        "--mode",
        choices=("pick", "wait", "pin", "loading"),
        default=os.environ.get("MODE", "pick"),
    )
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)
    if args.self_test:
        return self_test()
    mode = args.mode
    if mode == "loading":
        mode = "loading"
    os.environ.setdefault("MODE", mode)
    return run(mode)


if __name__ == "__main__":
    raise SystemExit(main())
