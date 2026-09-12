#!/usr/bin/env bash
# PreCompact hook — freeze the session-specific state that compaction flattens,
# so compact-note-restore.sh can hand it back on the other side.
#
# Why this exists: compaction is not truncation. The model writes a summary of
# the conversation and the session continues from that summary plus a preserved
# tail. Nothing is deleted; things are LOST BY OMISSION. Measured on this box
# 2026-09-12 across the whole transcript archive: 51 boundaries, median 200,665
# tokens in and 19,258 out — about 90% of the session restated by one summary.
#
# What it does NOT do, and cannot: give the model a turn before compaction. A
# hook is a shell command, not a reply, so "let Claude write down what matters
# first" is not implementable as a hook at all. This freezes only what a shell
# can read without judgement — the model's own last TodoWrite, the user's own
# last words, and the working tree.
#
# It deliberately carries NO memory content. The plugin's SessionStart block has
# no matcher, so global-memory-load.sh already re-injects core.md and the memory
# index on source=compact. Duplicating that here would spend the restore hook's
# ~3.5 KB budget on something already in context.
#
# All 51 historical compactions were trigger=manual (zero auto). The trigger is
# recorded in the log anyway: the day an auto one appears is the day this hook
# stops being a convenience.
#
# UNVERIFIED, and expected to read '-' in the log: manual/auto is documented as a
# MATCHER value — how the harness selects which hook to run — not necessarily a
# field it passes on stdin. The tests supply it in their own fixture, so they
# prove the plumbing and not the source. The authoritative trigger is on the
# transcript's compactMetadata row, which scripts/compact-boundaries.py reads; a
# dash here is that, not a bug. The keys= column records what really arrived.
#
# Always exits 0 and prints nothing on stdout. PreCompact stdout does not reach
# the model, and a non-zero exit here would interfere with a compaction the user
# asked for.
#
# Set COMPACT_NOTE_STATE=<dir> to relocate the state dir (the tests do).
set -u

state="${COMPACT_NOTE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-compact}"
mkdir -p "$state/archive" 2>/dev/null || exit 0

input="$(cat 2>/dev/null || true)"
now="$(date -Is 2>/dev/null || date)"

jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null || true; }

session="$(jqr '.session_id // empty')"
transcript="$(jqr '.transcript_path // empty')"
trigger="$(jqr '.trigger // .matcher // empty')"
cwd="$(jqr '.cwd // empty')"
[ -n "$cwd" ] || cwd="$PWD"

# The stdin shape for PreCompact is NOT in the published hook reference — only
# the common-field list is, and that list is documented for "every hook". So the
# keys actually received are recorded on every run rather than assumed. If
# transcript_path ever stops arriving, the log says so instead of the note
# quietly degrading to git-state-only.
keys="$(jqr 'keys | join(",")')"

log="$state/log.tsv"
[ -s "$log" ] || printf 'when\tevent\ttrigger\tsession\tcwd\tnote_bytes\tdetail\n' >"$log"

# No session id means no way to pair this note with the restore that follows it.
# Record the event and stop — a note filed under a guessed name is worse than
# none, because restore would inject another session's state.
if [ -z "$session" ]; then
  printf '%s\tsave-skipped\t%s\t-\t%s\t0\tno session_id; keys=%s\n' \
    "$now" "${trigger:--}" "$cwd" "${keys:--}" >>"$log"
  exit 0
fi

note="$state/note-$session.md"
tmp="$note.tmp.$$"

# Newest-line-first view of the transcript. `tac` is coreutils; macOS has
# `tail -r`. Both are absent in some minimal images, hence the plain-cat
# fallback — it makes the "last" extractions pick the FIRST match instead, which
# is wrong but bounded, and better than emitting nothing.
rev_transcript() {
  if command -v tac >/dev/null 2>&1; then tac "$1"
  elif tail -r "$1" >/dev/null 2>&1; then tail -r "$1"
  else cat "$1"; fi
}

{
  printf '## Carried across the compaction (%s)\n\n' "$now"
  printf 'Session %s, %s%s.\n' "$session" "$cwd" \
    "$([ -n "$trigger" ] && printf ', %s compaction' "$trigger")"
  printf 'This is state a shell could read at the moment of compaction — the'
  printf ' summary above it is the model'"'"'s account, this is the raw tail.\n'
} >"$tmp"

if [ -n "$transcript" ] && [ -r "$transcript" ] && command -v jq >/dev/null 2>&1; then
  # 1. The last TodoWrite. The model's own structured statement of what it is
  #    doing, which a prose summary rewrites into narrative.
  todos="$(rev_transcript "$transcript" \
    | grep -m1 '"name":"TodoWrite"' 2>/dev/null \
    | jq -r '[.message.content[]? | select(.type=="tool_use" and .name=="TodoWrite")
              | .input.todos[]?
              | "- [\(.status)] \(.content)"] | join("\n")' 2>/dev/null || true)"
  if [ -n "$todos" ]; then
    printf '\n### Todo list as it stood\n\n%s\n' "$todos" >>"$tmp"
  fi

  # 2. The user's own last words, verbatim. Intent is exactly what a summary
  #    paraphrases, and a paraphrased instruction is an instruction changed.
  #    Meta rows (hook injections, command stubs, tool results) are excluded —
  #    they are not things he said.
  asks="$(rev_transcript "$transcript" \
    | jq -r 'select(.type=="user" and (.isMeta // false | not)
                    and (.isCompactSummary // false | not))
             | .message.content
             | if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join("\n")) end
             | select(. != null and . != "")' 2>/dev/null \
    | grep -v '^<' | head -c 1200 | head -n 24 || true)"
  if [ -n "$asks" ]; then
    printf '\n### Last user turns, verbatim (newest first)\n\n%s\n' "$asks" >>"$tmp"
  fi
fi

# 3. The working tree. Cheap, always available, and the one thing that says
#    whether there is unfinished work on disk right now.
if command -v git >/dev/null 2>&1 && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  dirty="$(git -C "$cwd" status --short 2>/dev/null | head -n 20)"
  printf '\n### Working tree (%s, branch %s)\n\n' "$cwd" "$branch" >>"$tmp"
  if [ -n "$dirty" ]; then printf '%s\n' "$dirty" >>"$tmp"
  else printf '(clean)\n' >>"$tmp"; fi
fi

# The restore hook's stdout is capped at ~3.5 KB by the harness (see
# lib-memory.sh for the measurement). Truncate HERE, where there is a human
# -readable place to say so, rather than letting the harness silently persist
# the overflow to disk and inject a preview.
max="${COMPACT_NOTE_MAX:-2600}"
if [ "$(wc -c <"$tmp" | tr -d ' ')" -gt "$max" ]; then
  head -c "$max" "$tmp" >"$tmp.cut" && printf '\n…(note truncated at %s B)\n' "$max" >>"$tmp.cut"
  mv "$tmp.cut" "$tmp"
fi

mv "$tmp" "$note"
bytes="$(wc -c <"$note" | tr -d ' ')"
cp "$note" "$state/archive/$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)-$session-note.md" 2>/dev/null || true
printf '%s\tsave\t%s\t%s\t%s\t%s\tkeys=%s\n' \
  "$now" "${trigger:--}" "$session" "$cwd" "$bytes" "${keys:--}" >>"$log"
exit 0
