#!/usr/bin/env bash
# Unit tests for scripts/converge.sh pure helpers. No privilege, no rebuild:
# sources the script in CONVERGE_LIB_ONLY mode so functions load but converge_main
# never runs. Builds a throwaway git repo to exercise range/gate logic.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/converge.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a throwaway repo that looks like the machines checkout: converge.sh
# derives REPO from its own dir ($0/..), so copy it into <repo>/scripts/.
repo="$tmp/machines"
mkdir -p "$repo/scripts"
cp "$SCRIPT" "$repo/scripts/converge.sh"
git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" checkout -q -b main
: > "$repo/a.txt"; git -C "$repo" add .; git -C "$repo" commit -qm c1
rev1="$(git -C "$repo" rev-parse HEAD)"
echo change > "$repo/mod.nix"; git -C "$repo" add .; git -C "$repo" commit -qm c2
rev2="$(git -C "$repo" rev-parse HEAD)"

# Source the COPY so REPO resolves to the throwaway repo.
CONVERGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$repo/scripts/converge.sh"

# range_low: empty when no converged-rev file yet.
eq "$(range_low)" "" "range_low empty on first run"

# touches_nix: rev1..rev2 added mod.nix -> hit.
touches_nix "$rev1" "$rev2" && pass "touches_nix detects .nix" || die "touches_nix detects .nix"

# touches_nix: empty low (first run) -> treat as changed (hit).
touches_nix "" "$rev2" && pass "touches_nix first-run is hit" || die "touches_nix first-run is hit"

# on_main_primary: true on main in primary checkout.
on_main_primary && pass "on_main_primary true on main" || die "on_main_primary true on main"

# write_status ok: writes both files; converged-rev is the bare SHA.
write_status "$rev2" ok "test-ok"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status ok sets converged-rev"
grep -q '^status=ok$' "$repo/.machines/last-converge" && pass "last-converge status=ok" || die "last-converge status=ok"

# after ok write, range_low returns rev2.
eq "$(range_low)" "$rev2" "range_low reads converged-rev"

# write_status fail: updates last-converge but NOT converged-rev (retry next time).
write_status "$rev2" fail "boom"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status fail leaves converged-rev"
grep -q '^status=fail$' "$repo/.machines/last-converge" && pass "last-converge status=fail" || die "last-converge status=fail"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
