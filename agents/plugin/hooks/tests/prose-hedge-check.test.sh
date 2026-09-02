#!/usr/bin/env bash
# Table-driven tests for the prose-hedge-check PostToolUse hook.
#
# The hook warns when a prose deliverable carries a hedge ("to be verified") or an
# absolute negative claim ("does not exist"). The branches that matter are the
# scope filter (it must stay silent on code and on notes-to-self, or it becomes
# noise nobody reads) and the fingerprint dedup (one warning per hit set, but a
# NEW hedge must speak up again).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../prose-hedge-check.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export PROSE_HEDGE_STATE_DIR="$T/state"
mkdir -p "$T/repo/docs/specs" "$T/repo/src" "$T/repo/.claude/memory"

# run <session> <path>: feed one PostToolUse payload, echo stdout.
run() {
    printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" \
        | bash "$HOOK" 2>/dev/null
}

clean="$T/repo/docs/specs/clean-spec.md"
printf '# Spec\n\nThe base plan resolves through an explicit helper.\n' > "$clean"

hedged="$T/repo/docs/specs/hedged-spec.md"
printf '# Spec\n\nThe constant is the right cohort — to be verified rather than assumed.\n' > "$hedged"

claimy="$T/repo/docs/specs/claim-spec.md"
printf '# Spec\n\nThe burn primitive does not exist yet, so we add one.\n' > "$claimy"

code="$T/repo/src/thing.py"
printf '# to be verified rather than assumed\nx = 1\n' > "$code"

note="$T/repo/.claude/memory/project.md"
printf 'The order id is presumably per line item — to be verified.\n' > "$note"

byname="$T/repo/my-tech-solution.md"
printf 'There is no way to model this.\n' > "$byname"

# 1. A clean deliverable stays silent.
[ -z "$(run s1 "$clean")" ] && pass "clean spec is silent" || die "clean spec is silent"

# 2. A hedge is reported, under the HEDGES heading, with its line number.
out="$(run s1 "$hedged")"
case "$out" in
    *HEDGES*to\ be\ verified*) pass "hedge reported" ;;
    *) die "hedge reported (got: ${out:-<empty>})" ;;
esac
case "$out" in *'3:'*) pass "hedge carries a line number" ;; *) die "hedge carries a line number" ;; esac

# 3. An absolute claim is reported, and under its own heading.
out="$(run s1 "$claimy")"
case "$out" in
    *ABSOLUTE\ CLAIMS*does\ not\ exist*) pass "claim reported" ;;
    *) die "claim reported (got: ${out:-<empty>})" ;;
esac
case "$out" in *HEDGES*) die "claim-only file must not print a HEDGES block" ;; *) pass "claim-only file has no HEDGES block" ;; esac

# 4. Scope: source code with the same phrase is not a deliverable.
[ -z "$(run s1 "$code")" ] && pass "code is out of scope" || die "code is out of scope"

# 5. Scope: a memory file is a note to self and is allowed to be tentative.
[ -z "$(run s1 "$note")" ] && pass "memory file is out of scope" || die "memory file is out of scope"

# 6. Scope by basename, for a deliverable outside any docs/ directory.
out="$(run s1 "$byname")"
case "$out" in *no\ way\ to*) pass "matched by basename" ;; *) die "matched by basename" ;; esac

# 7. Dedup: the same hit set in the same session is silent the second time.
[ -z "$(run s1 "$hedged")" ] && pass "same hit set is deduped" || die "same hit set is deduped"

# 8. ...but a NEW hedge changes the fingerprint and speaks up again.
printf 'And the switch behaviour needs verification.\n' >> "$hedged"
out="$(run s1 "$hedged")"
case "$out" in *needs\ verification*) pass "new hedge re-triggers" ;; *) die "new hedge re-triggers" ;; esac

# 9. A different session gets its own warning for the same file.
out="$(run s2 "$claimy")"
case "$out" in *does\ not\ exist*) pass "dedup is per session" ;; *) die "dedup is per session" ;; esac

# 10. The mute switch wins over everything.
out="$(PROSE_HEDGE_CHECK_OFF=1 run s3 "$hedged")"
[ -z "$out" ] && pass "PROSE_HEDGE_CHECK_OFF mutes" || die "PROSE_HEDGE_CHECK_OFF mutes"

# 11. A missing file is not an error.
[ -z "$(run s4 "$T/repo/docs/specs/gone.md")" ] && pass "missing file is silent" || die "missing file is silent"

# 12. Output is valid JSON when jq is present.
if command -v jq >/dev/null 2>&1; then
    out="$(run s5 "$claimy")"
    printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1 \
        && pass "emits valid JSON" || die "emits valid JSON"
fi

exit "$fail"
