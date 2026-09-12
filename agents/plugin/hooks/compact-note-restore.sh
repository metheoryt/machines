#!/usr/bin/env bash
# SessionStart(matcher: compact) hook — hand back what compact-note-save.sh
# froze, and archive the summary that replaced the conversation.
#
# This is the half that reaches the model. A SessionStart hook's stdout is added
# to context; a PreCompact hook's is not. So the pair is: PreCompact writes to
# disk, SessionStart reads it back. Neither half can make the model think before
# compaction — see the save hook's header for why that is not a hook at all.
#
# The matcher is load-bearing. The plugin's other SessionStart hooks run with NO
# matcher and therefore fire on startup, resume, clear, compact and fork alike.
# This one must fire on compact ONLY: injecting a stale note into a fresh
# session would present last week's todo list as current work.
#
# It also archives the post-compact summary next to the note it carried. That
# pairing is the whole point of the experiment — the note and the summary that
# was written without it, side by side, per boundary. Judging "did this help"
# needs the material, and the material expires with the transcript.
#
# Always exits 0. A SessionStart hook that fails must not stop a session
# resuming after a compaction the user asked for.
set -u

state="${COMPACT_NOTE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-compact}"
[ -d "$state" ] || exit 0

input="$(cat 2>/dev/null || true)"
now="$(date -Is 2>/dev/null || date)"
jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null || true; }

session="$(jqr '.session_id // empty')"
transcript="$(jqr '.transcript_path // empty')"
source_="$(jqr '.source // .matcher // empty')"

log="$state/log.tsv"
note=""
how="by-session"

# The session id is expected to survive compaction — the session continues, it
# is not restarted. Expected, not verified: if it ever changes, pairing by id
# silently injects nothing. So fall back to the newest note written in the last
# 10 minutes and RECORD which path was taken, turning an assumption into a
# measurement the log can settle.
if [ -n "$session" ] && [ -f "$state/note-$session.md" ]; then
  note="$state/note-$session.md"
else
  recent="$(find "$state" -maxdepth 1 -name 'note-*.md' -mmin -10 2>/dev/null \
            | sort | tail -n 1)"
  if [ -n "$recent" ]; then note="$recent"; how="by-recency"; fi
fi

# Archive the summary the model wrote, paired with the note. Best-effort: the
# transcript is written asynchronously, so the summary row may not be on disk
# yet when this fires — an empty archive entry means "too early", not "absent".
if [ -n "$transcript" ] && [ -r "$transcript" ] && command -v jq >/dev/null 2>&1; then
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  if command -v tac >/dev/null 2>&1; then rev() { tac "$1"; }
  elif tail -r "$transcript" >/dev/null 2>&1; then rev() { tail -r "$1"; }
  else rev() { cat "$1"; }; fi
  rev "$transcript" | grep -m1 '"isCompactSummary":true' 2>/dev/null \
    | jq -r '.message.content | if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join("\n")) end' \
      2>/dev/null >"$state/archive/$stamp-${session:-unknown}-summary.md" || true
fi

if [ -z "$note" ]; then
  printf '%s\trestore-empty\t%s\t%s\t-\t0\tno note found\n' \
    "$now" "${source_:--}" "${session:--}" >>"$log" 2>/dev/null || true
  exit 0
fi

cat "$note"
printf '\n(The lines above survived the compaction verbatim; everything else in this session reached you as the summary.)\n'

bytes="$(wc -c <"$note" | tr -d ' ')"
printf '%s\trestore\t%s\t%s\t-\t%s\t%s\n' \
  "$now" "${source_:--}" "${session:--}" "$bytes" "$how" >>"$log" 2>/dev/null || true

# Consume it. The note describes one boundary; leaving it in place would let a
# later restore replay it. The archive copy is the durable one.
rm -f "$note" 2>/dev/null || true
exit 0
