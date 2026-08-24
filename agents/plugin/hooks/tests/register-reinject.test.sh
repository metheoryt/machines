#!/usr/bin/env bash
# Tests for the register-reinject UserPromptSubmit hook.
#
# The hook it replaces never existed: personality/tone.md documented a
# tone-reinject.sh that was never on disk and never wired, so three weeks of
# register calibration silently never reached a session. Two of the cases below
# exist only to make that failure mode loud — an extraction that finds nothing
# must WARN, never emit nothing quietly, and it must never exit 2 (which would
# block the prompt in Claude Code).
#
# The live-store case is the one that catches the original bug for real: it
# asserts the marker pair is still extractable from the actual ~/.claude core
# store, so a core.md rewrite that drops or renames the markers fails `just test`
# instead of failing in silence.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../register-reinject.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Build a config dir with a core.md we control, reading the store from stdin.
# Called at statement level, never inside $(...) — a here-document body cannot
# cross a command-substitution boundary.
mkcfg() {
  mkdir -p "$T/$1/memory"
  cat > "$T/$1/memory/core.md"
}

# --- 1. happy path: bullets in the span become one line each ---
mkcfg happy <<'MD'
# Memory core

<!--
A stripped human note.
-->

## Register

<!-- REGISTER-REINJECT:START -->
- **Answer first.** Line 1 is what he acts on
  a continuation that must not be emitted
- **Second rule.** No continuation here
<!-- REGISTER-REINJECT:END -->
- **Outside the span.** Must not be emitted
MD
cfg="$T/happy"
out="$(bash "$HOOK" "$cfg" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then
  die "happy path exited $rc, want 0"
elif ! printf '%s' "$out" | grep -q '^- \*\*Answer first\.\*\* Line 1 is what he acts on …$'; then
  die "happy path: wrapped bullet not emitted as first line + ellipsis"
elif ! printf '%s' "$out" | grep -q '^- \*\*Second rule\.\*\* No continuation here$'; then
  die "happy path: unwrapped bullet should carry no ellipsis"
elif printf '%s' "$out" | grep -q 'continuation that must not'; then
  die "happy path: emitted a continuation line"
elif printf '%s' "$out" | grep -q 'Outside the span'; then
  die "happy path: emitted a bullet from outside the markers"
elif printf '%s' "$out" | grep -q 'REGISTER-REINJECT'; then
  die "happy path: leaked a marker line into the output"
else
  pass "happy path emits one cue line per marked bullet, nothing else"
fi

# --- 2. markers missing: must be LOUD, on stdout AND stderr, and still exit 0 ---
mkcfg nomarkers <<'MD'
# Memory core

## Register

- **Answer first.** But nobody marked the span.
MD
cfg="$T/nomarkers"
o="$T/o"; e="$T/e"
bash "$HOOK" "$cfg" >"$o" 2>"$e"; rc=$?
if [ "$rc" -ne 0 ]; then
  die "missing markers exited $rc — a UserPromptSubmit hook must never block the prompt"
elif ! grep -q 'markers missing' "$o"; then
  die "missing markers: no warning on stdout (the silent-failure mode this hook exists to prevent)"
elif ! grep -q 'markers missing' "$e"; then
  die "missing markers: no warning on stderr"
else
  pass "missing markers warn on stdout and stderr, exit 0"
fi

# --- 3. span present but empty of bullets: also loud ---
mkcfg nobullets <<'MD'
## Register
<!-- REGISTER-REINJECT:START -->
<!-- REGISTER-REINJECT:END -->
MD
cfg="$T/nobullets"
bash "$HOOK" "$cfg" >"$o" 2>"$e"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'no bullets' "$o" && grep -q 'no bullets' "$e"; then
  pass "empty span warns on stdout and stderr, exit 0"
else
  die "empty span: want a loud warning and exit 0, got rc=$rc out='$(cat "$o")'"
fi

# --- 4. no core store at all: silent, exit 0 (fresh box / non-Claude profile) ---
mkdir -p "$T/bare/memory"
bash "$HOOK" "$T/bare" >"$o" 2>"$e"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$o" ] && [ ! -s "$e" ]; then
  pass "absent core.md is silent, not an error"
else
  die "absent core.md: want silence and exit 0, got rc=$rc out='$(cat "$o")' err='$(cat "$e")'"
fi

# --- 5. config dir is taken from \$1, never derived from the script's path ---
if bash "$HOOK" >/dev/null 2>&1; then
  die "hook accepted a missing config-dir argument"
else
  pass "hook requires the config dir as \$1"
fi

# --- 6. the LIVE store: if it has markers, the emit must stay bounded ---
# core.md is a dotfiles file on `main` and this repo is checked out on boxes that
# have not received it yet, so an unmarked live store is NOTED, not failed — a red
# suite on air/hub would give no signal at all (AGENTS.md, roadmap P4). The loud
# guarantee for a dropped marker is the hook's own runtime warning, which goes
# into every turn's context; this case exists for the bound, which nothing else
# checks.
live="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -f "$live/memory/core.md" ]; then
  out="$(bash "$HOOK" "$live" 2>/dev/null)"
  bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  n="$(printf '%s\n' "$out" | grep -c '^- ')"
  if printf '%s' "$out" | grep -q 'markers missing\|no bullets'; then
    pass "NOTE live store $live/memory/core.md carries no REGISTER-REINJECT span yet — per-turn reminder is OFF on this box"
  elif [ "$n" -lt 1 ]; then
    die "live store emitted no cue lines"
  elif [ "$bytes" -gt 900 ]; then
    # Guards against the END marker drifting down the file and dragging the
    # whole ## Register block into a per-turn emit.
    die "live emit is $bytes B (> 900) — the marked span has widened"
  else
    pass "live store yields $n cue lines in $bytes B"
  fi
else
  pass "no live core.md on this box — live-store check skipped"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
