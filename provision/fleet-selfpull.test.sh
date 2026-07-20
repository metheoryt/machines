#!/usr/bin/env bash
# Unit tests for provision/fleet-selfpull.sh gate helpers. Builds throwaway
# repos with a local "remote" so pulls are real but offline.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet-selfpull.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkrepo() { # <name> <origin-url>  -> prints repo path, main branch, upstream set
  local d="$tmp/$1"; git init -q "$d"
  git -C "$d" checkout -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" remote add origin "$2"
  : > "$d/f"; git -C "$d" add .; git -C "$d" -c commit.gpgsign=false commit -qm c1
  # Fake URL can't be fetched, so hand-create the remote-tracking ref/upstream
  # (mkrepo's contract is "upstream set" — is_fleet_repo requires @{u} to resolve).
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" branch --set-upstream-to=origin/main main >/dev/null 2>&1
  echo "$d"
}

FLEET_SELFPULL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"

personal="$(mkrepo personal git@github.com:metheoryt/machines.git)"
work="$(mkrepo work git@github.com:thepureapp/backend.git)"

# is_fleet_repo: personal origin qualifies, thepureapp is excluded.
is_fleet_repo "$personal" && pass "personal repo qualifies" || die "personal repo qualifies"
is_fleet_repo "$work" && die "thepureapp excluded" || pass "thepureapp excluded"

# A non-repo dir never qualifies.
mkdir "$tmp/plain"
is_fleet_repo "$tmp/plain" && die "plain dir excluded" || pass "plain dir excluded"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
