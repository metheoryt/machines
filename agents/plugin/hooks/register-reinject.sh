#!/usr/bin/env bash
# UserPromptSubmit hook — re-inject the register rules that drift inside a long
# session.
#
# Why this exists: memory/core.md is injected once, at SessionStart, by
# global-memory-load.sh. That is enough to establish the register and not enough
# to hold it — the block scrolls out of attention, and the reply style regresses
# to the default. This hook fires on EVERY prompt and re-states the headline of
# each rule, so the cue is always in the attended window while the full text
# stays where it was written.
#
# It replaces a `tone-reinject.sh` that personality/tone.md claimed existed and
# never did (verified 2026-08-24: no such file anywhere on disk, no
# UserPromptSubmit hook referencing it). Every register calibration recorded in
# tone.md after 2026-08-04 was dead letter as a result. The lesson is the design
# constraint below: this hook must never fail silently.
#
# Source of truth is core.md itself — there is no second copy to drift. The
# extracted span is delimited by an explicit marker pair rather than a heading,
# because a heading rename disabled the old design with no signal:
#
#   <!-- REGISTER-REINJECT:START -->  ...bullets...  <!-- REGISTER-REINJECT:END -->
#
# Same convention as WORKTREE-MODE:START in agents/docs/git-workflow.md, and
# guarded the same way — tests/register-reinject.test.sh asserts the span is
# extractable and bounded, so `just test` catches a core.md rewrite that drops or
# widens it. At runtime a missing span warns into the model's context instead of
# emitting nothing — see warn() for why that is the only channel that reaches
# anybody.
#
# Budget: one line per bullet, its first physical line only, with a trailing "…"
# where the bullet continues in core.md. ~500 B against a ~3.5 KB cap, on every
# turn. Emitting the whole span (~1.9 KB) is affordable but not the point: the
# full rules are already in context from SessionStart, so what is needed here is
# a cue, not a second copy. The dangling "…" is deliberate — it is a standing
# nudge to keep those first lines self-contained.
#
# Takes the config dir as $1 (e.g. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"), passed
# explicitly by the caller's hooks.json and NOT derived from this script's own
# path — the file is symlinked at different nesting depths for different callers.
#
# Always exits 0. A UserPromptSubmit hook that exits 2 BLOCKS the prompt, so no
# failure in here may ever take that path.
#
# Set REGISTER_REINJECT_LOG=<path> to append one timestamped line per invocation.
# That is how you re-prove per-turn firing rather than assuming it, which is the
# check the original tone-reinject bug needed and nobody ran:
#
#   REGISTER_REINJECT_LOG=/tmp/rr.log claude -p 'hi'
#   REGISTER_REINJECT_LOG=/tmp/rr.log claude --continue -p 'again'
#   wc -l /tmp/rr.log   # 2 = per-turn; 1 = wired at SessionStart by mistake
set -u

if [ -n "${REGISTER_REINJECT_LOG:-}" ]; then
  printf 'fired %s pid=%s\n' "$(date -Is 2>/dev/null || date)" "$$" \
    >>"$REGISTER_REINJECT_LOG" 2>/dev/null || true
fi

config_dir="${1:?config dir required (pass \$\{CLAUDE_CONFIG_DIR:-\$HOME/.claude\} or similar)}"
core="$config_dir/memory/core.md"

# shellcheck source=lib-memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-memory.sh"

# No core store at all is not a misconfiguration — a fresh box or a non-Claude
# profile legitimately has nothing to re-inject. Silence is correct here.
mem_has_content "$core" || exit 0

span="$(sed -n '/<!-- REGISTER-REINJECT:START -->/,/<!-- REGISTER-REINJECT:END -->/p' "$core")"

# The warning's audience is the MODEL, not the terminal. Probed 2026-08-24: a
# UserPromptSubmit hook that exits 0 has its stderr discarded — the user saw
# nothing at all, while stdout went into context. So stdout carries the message
# and asks the reader to relay it; stderr keeps a copy only for whoever runs this
# script by hand.
warn() {
  printf 'register-reinject: %s in %s — the per-turn register reminder is DISABLED until the markers are restored. Tell the user this, in your next reply.\n' \
    "$1" "$core" | tee /dev/stderr
  exit 0
}

[ -n "$span" ] || warn 'REGISTER-REINJECT:START/END markers missing'

# One line per bullet: the bullet's first physical line, plus "…" when it wraps.
# Continuation lines are indented; the marker lines themselves are neither, so
# they fall through to the flush branch and are dropped.
rules="$(printf '%s\n' "$span" | awk '
  function flush() { if (buf != "") { printf "%s%s\n", buf, (cont ? " …" : ""); buf = ""; cont = 0 } }
  /^- /                { flush(); buf = $0; next }
  /^[ \t]+[^ \t]/      { if (buf != "") cont = 1; next }
                       { flush() }
  END                  { flush() }
')"

[ -n "$rules" ] || warn 'REGISTER-REINJECT span contains no bullets'

printf 'Register — how this reply must read (per-turn reminder; full rules in %s under ## Register):\n%s\n' \
  "$core" "$rules"

# Deliberately NOT calling mem_warn_if_over: its threshold (MEM_TOTAL_BUDGET) is
# the SessionStart core+index budget, ~7x this emit, so it could never fire — and
# its advice ("trim core.md or drop an index") is wrong for a per-turn hook. The
# real bound on this output is the 900 B assertion in
# tests/register-reinject.test.sh, which catches the END marker drifting down the
# file and dragging the whole ## Register block into every turn.
