#!/usr/bin/env bash
# Behavior tests for orca-status.sh — builds a fixture orca-data.json, runs the
# helper for each matrix branch, and asserts the emitted token. Also asserts the
# fixture is byte-identical afterwards (read-only contract).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../orca-status.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

DISPATCH='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'

DATA="$tmp/orca-data.json"
cat > "$DATA" <<'JSON'
{
  "repos": [
    { "path": "/base/machines", "hookSettings": { "scripts": { "setup": "bash \"$HOME/machines/scripts/orca-worktree-setup.sh\"" } } },
    { "path": "/base/reposonly", "hookSettings": { "scripts": { "setup": "bash \"$HOME/machines/scripts/orca-worktree-setup.sh\"" } } }
  ],
  "projectHostSetups": [
    { "projectId": "github:metheoryt/machines", "path": "/base/machines",
      "hookSettings": { "scripts": { "setup": "bash \"$HOME/machines/scripts/orca-worktree-setup.sh\"" } } },
    { "projectId": "github:metheoryt/empty", "path": "/base/empty",
      "hookSettings": { "scripts": { "setup": "" } } },
    { "projectId": "github:metheoryt/foreign", "path": "/base/foreign",
      "hookSettings": { "scripts": { "setup": "bash /some/other-setup.sh" } } }
  ]
}
JSON

# WIRED — all origin URL forms of the same repo canonicalize to the same projectId
for u in \
  "git@github.com:metheoryt/machines.git" \
  "git@github.com:metheoryt/machines" \
  "https://github.com/metheoryt/machines.git" \
  "ssh://git@github.com/metheoryt/machines.git" ; do
  got="$(bash "$SCRIPT" "$DATA" "$u" "$DISPATCH" "/base/machines")"
  [ "$got" = "WIRED" ] && pass "WIRED $u" || die "WIRED $u -> '$got'"
done

# UNWIRED — entry present, setup empty
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/empty.git" "$DISPATCH" "/base/empty")"
[ "$got" = "UNWIRED" ] && pass "UNWIRED" || die "UNWIRED -> '$got'"

# CONFLICT — different non-empty setup, value reported after a tab
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/foreign.git" "$DISPATCH" "/base/foreign")"
[ "$got" = "$(printf 'CONFLICT\tbash /some/other-setup.sh')" ] \
  && pass "CONFLICT" || die "CONFLICT -> '$got'"

# ABSENT — no matching projectId and no matching path
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/nope.git" "$DISPATCH" "/base/nope")"
[ "$got" = "ABSENT" ] && pass "ABSENT" || die "ABSENT -> '$got'"

# Fallback — repo only in .repos[] (by path), not in projectHostSetups -> WIRED
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/reposonly.git" "$DISPATCH" "/base/reposonly")"
[ "$got" = "WIRED" ] && pass "repos-fallback WIRED" || die "repos-fallback -> '$got'"

# Missing data file -> ABSENT, never an error
got="$(bash "$SCRIPT" "$tmp/nofile.json" "git@github.com:metheoryt/machines.git" "$DISPATCH" "/base/machines")"
[ "$got" = "ABSENT" ] && pass "missing-file ABSENT" || die "missing-file -> '$got'"

# READ-ONLY — fixture is byte-identical after all runs
before="$(cksum "$DATA")"
bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/machines.git" "$DISPATCH" "/base/machines" >/dev/null
after="$(cksum "$DATA")"
[ "$before" = "$after" ] && pass "read-only (fixture unchanged)" || die "fixture mutated!"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
