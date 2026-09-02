#!/usr/bin/env bash
# agents/plugin/hooks/prose-hedge-check.sh — PostToolUse (Edit|Write).
#
# Origin: the CFT-5051 backend tech solution came back from its first review with
# eight substantive corrections. Five were catchable before publishing, and three
# of those sat behind a hedge the author had written himself — "to be verified
# rather than assumed" on a claim one read would have settled, and a caveat
# demoting a fact that actually disqualified the design it was attached to. One
# more was an absolute claim ("the burn primitive does not exist yet") about a
# function that had been in the tree for a year.
#
# So this hook greps a prose deliverable for two phrase classes:
#
#   HEDGE  — the author flagged soft ground instead of standing on it. A reviewer
#            reads the flag as diligence; it is the opposite.
#   CLAIM  — an absolute negative ("X does not exist", "there is no way to"),
#            which is exactly the shape that is cheap to check and expensive to
#            get wrong.
#
# It is deliberately NOT a blocker and NOT a permission prompt: the phrases are
# legitimate often enough that a gate would train the reader to dismiss it. The
# point is that the hit list arrives while the draft is still local and cheap to
# fix, rather than in a review comment a week later.
#
# Why PostToolUse on the local write rather than PreToolUse on the publish call:
# publishing is a separate, later step, so warning at write time is both earlier
# and safer. Gating the publish itself is a deliberate v2 — worth doing only once
# the false-positive rate here is known.
#
# Always exits 0, including on its own errors. Set PROSE_HEDGE_CHECK_OFF=1 to mute.
set -u

[ -n "${PROSE_HEDGE_CHECK_OFF:-}" ] && exit 0
: "${PROSE_HEDGE_STATE_DIR:=${TMPDIR:-/tmp}/prose-hedge-check}"

payload="$(cat)" || exit 0

# Same jq-optional extraction as dotfiles-offer.sh: this runs on every edit, so
# it stays cheap and must not hard-depend on a tool some fleet member lacks.
jget() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null
    else
        printf '%s' "$payload" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    fi
}
file="$(jget '.tool_input.file_path' 'file_path')"
session="$(jget '.session_id' 'session_id')"
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

case "$file" in *.md) : ;; *) exit 0 ;; esac

# Only prose meant for someone else. A note to self is allowed to be tentative —
# that is what a note to self is for.
case "$file" in
    */.git/*|*/node_modules/*|*/memory/*|*CLAUDE.md|*CLAUDE.local.md|*AGENTS.md) exit 0 ;;
esac
base="$(basename "$file")"
case "$file" in
    */docs/*|*/doc/*|*/specs/*|*/spec/*|*/adr/*|*/rfc/*) : ;;
    *)
        case "$base" in
            *spec*|*adr*|*rfc*|*design*|*tech-solution*|*proposal*) : ;;
            *) exit 0 ;;
        esac
        ;;
esac

# Read the file, not the edit fragment: a hedge introduced three edits ago is
# still in the document you are about to hand over.
hedge='to be verified|to be confirmed|to be clarified|to be determined|worth deciding|worth verifying|needs verification|needs confirmation|remains to be|presumably|I assume|we assume|assumed rather than|rather than assumed'
claim='does not exist|doesn.t exist|do not exist|don.t exist|is not possible|is impossible|there is no way|no way to|cannot be done|is unsupported'

hedge_hits="$(grep -nEi "$hedge" "$file" 2>/dev/null | head -8)" || hedge_hits=""
claim_hits="$(grep -nEi "$claim" "$file" 2>/dev/null | head -8)" || claim_hits=""
[ -z "$hedge_hits" ] && [ -z "$claim_hits" ] && exit 0

# One warning per (session, file, set of hits). Editing the same document again
# stays quiet; introducing a NEW hedge speaks up, because the hit set changed.
mkdir -p "$PROSE_HEDGE_STATE_DIR" 2>/dev/null || exit 0
fingerprint="$(printf '%s\n%s\n%s\n' "$file" "$hedge_hits" "$claim_hits")"
if command -v sha1sum >/dev/null 2>&1; then
    key="$(printf '%s' "$fingerprint" | sha1sum | cut -c1-16)"
elif command -v shasum >/dev/null 2>&1; then
    key="$(printf '%s' "$fingerprint" | shasum | cut -c1-16)"
else
    key="$(printf '%s' "$fingerprint" | tr -c 'a-zA-Z0-9' '_' | cut -c1-64)"
fi
seen="$PROSE_HEDGE_STATE_DIR/${session:-nosession}.$key"
[ -e "$seen" ] && exit 0
: > "$seen" 2>/dev/null || exit 0

msg="prose-hedge-check on \`$base\`:"
[ -n "$hedge_hits" ] && msg="$msg\n\nHEDGES — each marks a question the author chose to annotate instead of answer. Resolve it or delete the sentence; do not publish the flag as if it were diligence:\n$hedge_hits"
[ -n "$claim_hits" ] && msg="$msg\n\nABSOLUTE CLAIMS — cheap to check, expensive to get wrong. Confirm each against the code or the vendor's own reference before it ships:\n$claim_hits"
msg="$msg\n\nIf a hit is genuinely correct as written, leave it and say so — this is a prompt to look, not a rule to obey."

# jq builds the JSON when available so newlines and quotes in the grep output
# cannot break the payload; the fallback escapes by hand.
if command -v jq >/dev/null 2>&1; then
    printf '%b' "$msg" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}'
else
    esc="$(printf '%b' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')"
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$esc"
fi
exit 0
