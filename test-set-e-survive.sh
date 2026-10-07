#!/usr/bin/env bash
# Regression: helpers must not leave set -e armed when returning non-zero.
# Incident 2026-10-07 21:20:34 — EXIT status=2 after YubiKey wait (Foot close).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
fail=0
pass() { printf 'ok  %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }

returns_two() { return 2; }

# --- 1) Bug class (do NOT wrap in `if` — that masks set -e) ---
set +e
(
  set -e
  returns_two
  echo REACHED
) >/tmp/sete-out.txt 2>/tmp/sete-err.txt
st=$?
if ((st == 2)) && ! grep -q REACHED /tmp/sete-out.txt; then
  pass "set -e + helper return 2 aborts with status 2 (Foot-close class)"
else
  bad "expected abort st=2 no REACHED; got st=$st out=$(cat /tmp/sete-out.txt)"
fi

# --- 2) No set -e after config bootstrap ---
bad_sete=0
while IFS= read -r line; do
  n=${line%%:*}
  if ((n > 50)); then
    printf '  stray: %s\n' "$line"
    bad_sete=1
  fi
done < <(rg -n '^\s*set -e\s*$' "$ROOT/cursor-cli-remote" || true)
if ((bad_sete)); then
  bad "stray set -e in interactive section"
else
  pass "no set -e after line 50"
fi

# --- 3) Critical helpers must not arm set -e ---
for fn in draw_wait forge_tcp_ok ssh_forge_tty open_master ensure_tailscale rehome_mux ensure_mux_unit run_session; do
  block=$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\)" {grab=1}
    grab {print}
    grab && /^}/ {exit}
  ' "$ROOT/cursor-cli-remote")
  if printf '%s\n' "$block" | rg -q '^\s*set -e\s*$'; then
    bad "$fn still contains set -e"
  else
    pass "$fn does not arm set -e"
  fi
done

# --- 4) Policy ---
if rg -q 'Interactive launcher: non-zero returns are control flow' "$ROOT/cursor-cli-remote"; then
  pass "global set +e after config"
else
  bad "missing global set +e policy"
fi

# --- 5) Post-yubi path under launcher policy (set +e) survives tcp=2 ---
set +e
trap '' INT QUIT
fake_wait() { return 0; }
fake_tcp() { return 2; }
fake_wait
sleep 0.01 || true
fake_tcp
st=$?
if ((st == 2)); then
  pass "post-yubi with set +e survives tcp st=2"
else
  bad "post-yubi st=$st"
fi

# Same path with set -e wrongly armed (old draw_wait) MUST abort — documenting why policy matters
(
  set -e
  fake_wait
  fake_tcp
  echo REACHED
) >/tmp/sete2-out.txt 2>/dev/null
st=$?
if ((st != 0)) && ! grep -q REACHED /tmp/sete2-out.txt 2>/dev/null; then
  pass "old draw_wait set -e + tcp 2 would abort (why Foot closed)"
else
  bad "expected old path to abort"
fi

# --- 6) Real forge_tcp_ok ---
REMOTE=forge
FORGE_HOST="" FORGE_USER="" FORGE_PORT="22" FORGE_TCP_WHY=""
flog() { :; }
load_ssh_meta() {
  local k v
  FORGE_HOST="" FORGE_USER="" FORGE_PORT="22"
  while read -r k v; do
    case "${k,,}" in
      hostname) FORGE_HOST="$v" ;;
      user) FORGE_USER="$v" ;;
      port) FORGE_PORT="$v" ;;
    esac
  done < <(ssh -G forge 2>/dev/null)
  [[ -n "$FORGE_HOST" ]] || FORGE_HOST=forge
  [[ "$FORGE_PORT" =~ ^[0-9]+$ ]] || FORGE_PORT=22
}
eval "$(sed -n '/^forge_tcp_ok()/,/^}/p' "$ROOT/cursor-cli-remote")"
set +e
forge_tcp_ok
tcp_st=$?
case "$tcp_st" in
  0|1|2) pass "forge_tcp_ok returns $tcp_st (set +e survives)" ;;
  *) bad "forge_tcp_ok unexpected $tcp_st" ;;
esac

# --- 7) forge_tui + bash -n ---
python3 "$ROOT/forge_tui.py" --self-test >/dev/null && pass "forge_tui self-test" || bad "forge_tui"
bash -n "$ROOT/cursor-cli-remote" && pass "bash -n" || bad "bash -n"

# --- 8) Installed bin must match repo ---
if diff -q "$ROOT/cursor-cli-remote" "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/bin/cursor-cli-remote" >/dev/null 2>&1; then
  pass "installed bin matches repo"
else
  # install may not have run yet — warn only if bin exists and differs
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/bin/cursor-cli-remote" ]]; then
    bad "installed bin OUT OF DATE vs repo — run ./install.sh"
  else
    pass "no installed bin yet"
  fi
fi

if ((fail == 0)); then
  printf '\nAll set -e survival checks passed.\n'
  exit 0
fi
printf '\n%d check(s) FAILED\n' "$fail"
exit 1
