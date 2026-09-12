#!/usr/bin/env bash
# Behavioral tests for the PreCompact -> SessionStart(compact) carry-over pair:
# compact-note-save.sh writes a note at compaction, compact-note-restore.sh
# injects it on the other side.
#
# Both hooks feed a real synthetic transcript.jsonl and a real git repo through
# real stdin JSON, because every failure this pair can have is a silent one: a
# hook that emits nothing looks exactly like a session with nothing to carry.
# So the assertions are about CONTENT reaching stdout and rows reaching the log,
# never about exit status alone — all four paths exit 0 by design.
#
# The matcher assertion at the end is the one that guards a decision rather than
# code: the plugin's other SessionStart hooks carry no matcher and fire on every
# source. Drop "compact" from this one and a stale note is injected into fresh
# sessions as if it were current work.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/../plugin/hooks" && pwd)"
save="$hooks/compact-note-save.sh"
restore="$hooks/compact-note-restore.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export COMPACT_NOTE_STATE="$work/state"

# --- A repo with an uncommitted change, so the working-tree section has content.
repo="$work/repo"; mkdir -p "$repo"
git -C "$repo" init -q 2>/dev/null
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
echo one > "$repo/a.txt"; git -C "$repo" add a.txt
git -C "$repo" commit -qm init 2>/dev/null
echo two > "$repo/a.txt"

# --- A transcript carrying a TodoWrite, two user turns, and noise that must be
#     excluded: a meta row and a tool_result row are not things the user said.
tr="$work/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"первый вопрос про хуки"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"wire the pair","status":"completed"},{"content":"write the baseline","status":"in_progress"}]}}]}}'
  printf '%s\n' '{"type":"user","isMeta":true,"message":{"content":"HOOK NOISE must not appear"}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"TOOLRESULT must not appear"}]}}'
  printf '%s\n' '{"type":"user","message":{"content":"сравним до и после"}}'
} > "$tr"

stdin_json() {
  jq -nc --arg s "$1" --arg t "$2" --arg c "$3" \
    '{session_id:$s, transcript_path:$t, cwd:$c, trigger:"manual"}'
}

# --- 1. Save builds a note from all three sources.
stdin_json sess-A "$tr" "$repo" | bash "$save"
note="$COMPACT_NOTE_STATE/note-sess-A.md"
check "save writes a note for the session"      '[ -f "$note" ]'
check "note carries the todo list"              'grep -q "wire the pair" "$note"'
check "note marks todo status"                  'grep -q "in_progress" "$note"'
check "note carries the user turns verbatim"    'grep -q "сравним до и после" "$note"'
check "note carries the earlier user turn"      'grep -q "первый вопрос про хуки" "$note"'
check "note excludes meta rows"                 '! grep -q "HOOK NOISE" "$note"'
check "note excludes tool results"              '! grep -q "TOOLRESULT" "$note"'
check "note carries the dirty working tree"     'grep -q "a.txt" "$note"'
check "note names the branch"                   'grep -q "branch" "$note"'
check "save logs the trigger"                   'grep -q "	save	manual	sess-A" "$COMPACT_NOTE_STATE/log.tsv"'
check "save records the stdin keys it got"      'grep -q "keys=" "$COMPACT_NOTE_STATE/log.tsv"'
check "save archives a copy"                    'ls "$COMPACT_NOTE_STATE"/archive/*sess-A-note.md >/dev/null 2>&1'

# --- 2. Restore injects it, once.
out="$(jq -nc --arg s sess-A --arg t "$tr" '{session_id:$s, transcript_path:$t, source:"compact"}' | bash "$restore")"
check "restore prints the note"                 'printf %s "$out" | grep -q "wire the pair"'
check "restore says what survived"              'printf %s "$out" | grep -q "survived the compaction"'
check "restore consumes the note"               '[ ! -f "$note" ]'
check "restore logs how it paired"              'grep -q "	restore	compact	sess-A.*by-session" "$COMPACT_NOTE_STATE/log.tsv"'
out2="$(jq -nc --arg s sess-A '{session_id:$s, source:"compact"}' | bash "$restore")"
check "a consumed note is not replayed"         '[ -z "$out2" ]'

# --- 3. No session_id: record the event, never file a note under a guess.
#     A note paired by guesswork injects ANOTHER session's state, which is worse
#     than injecting nothing.
before="$(ls "$COMPACT_NOTE_STATE" | grep -c '^note-' || true)"
jq -nc --arg t "$tr" '{transcript_path:$t, cwd:"/tmp"}' | bash "$save"
after="$(ls "$COMPACT_NOTE_STATE" | grep -c '^note-' || true)"
check "no session_id writes no note"            '[ "$before" = "$after" ]'
check "no session_id is logged as skipped"      'grep -q "save-skipped" "$COMPACT_NOTE_STATE/log.tsv"'

# --- 4. Recency fallback, and its bound. The session id is EXPECTED to survive
#     compaction; the fallback exists because that is unverified. A note older
#     than the window must never be injected.
stdin_json sess-B "$tr" "$repo" | bash "$save"
out3="$(jq -nc '{session_id:"sess-DIFFERENT", source:"compact"}' | bash "$restore")"
check "falls back to a fresh note by recency"   'printf %s "$out3" | grep -q "wire the pair"'
check "the fallback is logged as such"          'grep -q "by-recency" "$COMPACT_NOTE_STATE/log.tsv"'
stdin_json sess-C "$tr" "$repo" | bash "$save"
touch -d '30 minutes ago' "$COMPACT_NOTE_STATE/note-sess-C.md" 2>/dev/null \
  || touch -A -003000 "$COMPACT_NOTE_STATE/note-sess-C.md" 2>/dev/null
out4="$(jq -nc '{session_id:"sess-OTHER", source:"compact"}' | bash "$restore")"
check "a stale note is never injected"          '[ -z "$out4" ]'
check "the empty restore is logged"             'grep -q "restore-empty" "$COMPACT_NOTE_STATE/log.tsv"'

# --- 5. The note must fit the SessionStart stdout cap (see lib-memory.sh: past
#     ~3.5 KB the harness persists the output and injects a preview instead).
big="$work/big.jsonl"
{ i=0; while [ "$i" -lt 200 ]; do
    printf '{"type":"user","message":{"content":"padding line %s ---------------------------------"}}\n' "$i"
    i=$((i+1))
  done; } > "$big"
stdin_json sess-D "$big" "$repo" | bash "$save"
sz="$(wc -c <"$COMPACT_NOTE_STATE/note-sess-D.md" | tr -d ' ')"
check "note stays under the injection budget"   '[ "$sz" -le 2700 ]'
check "a long session is not truncated by luck" '! grep -q "note truncated" "$COMPACT_NOTE_STATE/note-sess-D.md"'

# The per-section caps above keep a normal note well under budget, so the
# outer truncation is a backstop that a realistic transcript never reaches.
# Exercise it directly rather than leaving it unproven: a backstop nobody has
# ever run is indistinguishable from one that does not work.
COMPACT_NOTE_MAX=400 stdin_json sess-E "$tr" "$repo" | COMPACT_NOTE_MAX=400 bash "$save"
szE="$(wc -c <"$COMPACT_NOTE_STATE/note-sess-E.md" | tr -d ' ')"
check "the backstop caps the note"              '[ "$szE" -le 460 ]'
check "truncation is stated, not silent"        'grep -q "note truncated" "$COMPACT_NOTE_STATE/note-sess-E.md"'

# --- 6. A missing state dir must not make either hook fail a compaction.
rm -rf "$COMPACT_NOTE_STATE"
check "restore is a no-op with no state dir"    'jq -nc "{session_id:\"x\",source:\"compact\"}" | bash "$restore"; [ $? -eq 0 ]'

# --- 7. Wiring. The matcher is the decision; assert it, not just the presence.
hj="$hooks/hooks.json"
check "PreCompact runs the save hook" \
  'jq -e ".hooks.PreCompact[].hooks[].command | select(test(\"compact-note-save\"))" "$hj" >/dev/null'
check "restore is wired with matcher compact" \
  'jq -e ".hooks.SessionStart[] | select(.hooks[].command | test(\"compact-note-restore\")) | select(.matcher == \"compact\")" "$hj" >/dev/null'
check "restore is not wired matcher-less" \
  '! jq -e ".hooks.SessionStart[] | select(.hooks[].command | test(\"compact-note-restore\")) | select(.matcher == null)" "$hj" >/dev/null'

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
