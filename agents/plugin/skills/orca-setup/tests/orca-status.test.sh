#!/usr/bin/env bash
# Behavior tests for orca-status.sh — builds a fixture orca-data.json, runs the
# helper for each matrix branch, and asserts the two emitted slot tokens. Also
# asserts the fixture is byte-identical afterwards (read-only contract).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../orca-status.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

SETUP='bash "$HOME/machines/agents/worktree-setup.sh"'
TEARDOWN='bash "$HOME/machines/agents/worktree-teardown.sh"'
LEGACY='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'

# extract the token for a slot ("setup"/"archive") from multi-line status output.
tok() { printf '%s\n' "$1" | awk -v s="$2" -F'\t' '$1==s{ sub(/^[^\t]*\t/,""); print; exit }'; }

DATA="$tmp/orca-data.json"
cat > "$DATA" <<'JSON'
{
  "repos": [
    { "path": "/base/reposonly", "hookSettings": { "scripts": {
      "setup": "bash \"$HOME/machines/agents/worktree-setup.sh\"",
      "archive": "bash \"$HOME/machines/agents/worktree-teardown.sh\"" } } }
  ],
  "projectHostSetups": [
    { "projectId": "github:metheoryt/machines", "path": "/base/machines",
      "hookSettings": { "scripts": {
        "setup": "bash \"$HOME/machines/agents/worktree-setup.sh\"",
        "archive": "bash \"$HOME/machines/agents/worktree-teardown.sh\"" } } },
    { "projectId": "github:metheoryt/legacy", "path": "/base/legacy",
      "hookSettings": { "scripts": {
        "setup": "bash \"$HOME/machines/scripts/orca-worktree-setup.sh\"" } } },
    { "projectId": "github:metheoryt/empty", "path": "/base/empty",
      "hookSettings": { "scripts": { "setup": "", "archive": "" } } }
  ]
}
JSON

# Fully wired (both slots) — and URL forms all canonicalize to the same projectId.
for u in \
  "git@github.com:metheoryt/machines.git" \
  "https://github.com/metheoryt/machines.git" \
  "ssh://git@github.com/metheoryt/machines.git" ; do
  got="$(bash "$SCRIPT" "$DATA" "$u" "$SETUP" "$TEARDOWN" "/base/machines")"
  [ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
    && pass "WIRED both $u" || die "WIRED both $u -> '$got'"
done

# Legacy setup + missing archive -> setup CONFLICT (surfaces old value), archive UNWIRED.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/legacy.git" "$SETUP" "$TEARDOWN" "/base/legacy")"
[ "$(tok "$got" setup)" = "$(printf 'CONFLICT\t%s' "$LEGACY")" ] \
  && pass "legacy setup CONFLICT" || die "legacy setup -> '$(tok "$got" setup)'"
[ "$(tok "$got" archive)" = "UNWIRED" ] \
  && pass "legacy archive UNWIRED" || die "legacy archive -> '$(tok "$got" archive)'"

# Empty both -> UNWIRED both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/empty.git" "$SETUP" "$TEARDOWN" "/base/empty")"
[ "$(tok "$got" setup)" = "UNWIRED" ] && [ "$(tok "$got" archive)" = "UNWIRED" ] \
  && pass "empty UNWIRED both" || die "empty -> '$got'"

# Absent repo -> ABSENT both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/nope.git" "$SETUP" "$TEARDOWN" "/base/nope")"
[ "$(tok "$got" setup)" = "ABSENT" ] && [ "$(tok "$got" archive)" = "ABSENT" ] \
  && pass "absent ABSENT both" || die "absent -> '$got'"

# repos[] fallback (by path, no projectId) -> WIRED both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/reposonly.git" "$SETUP" "$TEARDOWN" "/base/reposonly")"
[ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
  && pass "repos-fallback WIRED both" || die "repos-fallback -> '$got'"

# Missing data file -> ABSENT both, never an error.
got="$(bash "$SCRIPT" "$tmp/nofile.json" "git@github.com:metheoryt/machines.git" "$SETUP" "$TEARDOWN" "/base/machines")"
[ "$(tok "$got" setup)" = "ABSENT" ] && [ "$(tok "$got" archive)" = "ABSENT" ] \
  && pass "missing-file ABSENT both" || die "missing-file -> '$got'"

# READ-ONLY — fixture byte-identical after a run.
before="$(cksum "$DATA")"
bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/machines.git" "$SETUP" "$TEARDOWN" "/base/machines" >/dev/null
after="$(cksum "$DATA")"
[ "$before" = "$after" ] && pass "read-only (fixture unchanged)" || die "fixture mutated!"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
