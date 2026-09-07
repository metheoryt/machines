#!/usr/bin/env bash
# Unit tests for the per-machine repo-group override: fleet_repo_groups (the
# reader) and role_repos (the one consumer). Asserts against the REAL repo
# fleet.json, like fleet-profile.test.sh — the manifest is what ships.
#
# WHY THIS IS TESTED BY COMPOSED ARGV AND NOT BY RUNNING repos.sh.
# provision/repos.sh's dry-run is NOT inert: it switches the active gh account
# and restores it at the end (docs/fleet-mesh-history.md records that gotcha).
# A suite that invoked it would mutate the gh login of whatever box runs the
# gate. So `bash` is shimmed and the assertion is on the argv role_repos hands
# it — which is exactly the thing the override changes.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

# shellcheck source=/dev/null
source "$REPO/provision/lib/fleet.sh"
# shellcheck source=/dev/null
source "$REPO/provision/roles/repos.sh"

# ── 1. the reader ─────────────────────────────────────────────────────────────
# g15 declares `my` only: it is the personal-projects host and the owner does not
# want the work repos (`pure`) or the retired `cyphy671` account on it.
eq "$(fleet_repo_groups g15)" "my" "fleet_repo_groups g15 == my (explicit)"
# air and desktop declare nothing, so they exercise the default path — repos.sh
# keeps its own list. Keep at least one machine with no field here: a manifest
# edit that gave every box an explicit list would leave that branch untested,
# which is the same trap fleet-profile.test.sh guards for `profile`.
eq "$(fleet_repo_groups air)" "" "fleet_repo_groups air is empty (field absent)"
eq "$(fleet_repo_groups desktop)" "" "fleet_repo_groups desktop is empty (field absent)"
# An unknown machine must be empty, not the string "null" — jq -r prints a null
# that way, and `repos.sh null` would match no group row while looking deliberate.
eq "$(fleet_repo_groups no-such-box)" "" "fleet_repo_groups unknown machine is empty"

# ── 2. the consumer's argv ────────────────────────────────────────────────────
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/bash" <<'SHIM'
#!/bin/sh
# Record argv, run nothing. $1 is repos.sh's path; the rest are group names.
shift
printf '%s\n' "$*" >> "$SHIM_LOG"
SHIM
chmod +x "$tmp/bin/bash"

argv_for() {  # argv_for <mode> <machine>
  SHIM_LOG="$tmp/log"; export SHIM_LOG; : > "$SHIM_LOG"
  PATH="$tmp/bin:$PATH" role_repos "$1" debian "$2" >/dev/null 2>&1
  cat "$SHIM_LOG"
}

eq "$(argv_for apply g15)" "my" "role_repos apply g15 passes exactly 'my'"
eq "$(argv_for dry-run g15)" "my" "role_repos dry-run g15 passes exactly 'my'"
# The empty case is the one that would silently clone nothing if it regressed:
# `bash repos.sh ""` matches no group row, so a bare "${groups[@]}" expanding to
# one empty string looks identical to success. Assert NO argument at all.
eq "$(argv_for apply air)" "" "role_repos apply air passes NO group argument"
eq "$(argv_for dry-run air)" "" "role_repos dry-run air passes NO group argument"

# ── 3. sourceable standalone ──────────────────────────────────────────────────
# roles.test.sh sources roles/repos.sh WITHOUT lib/fleet.sh, so role_repos has
# to survive the reader being absent entirely. This pins the OUTCOME that other
# suite depends on, not any one line of the implementation — measured, the
# outcome holds structurally: an undefined `fleet_repo_groups` is a
# "command not found", which `set -u` does not trip.
# The shim goes on the INNER PATH only. Putting it on the PATH that resolves
# `bash -c` itself made this whole block run under the shim, which logs and
# exits — so it asserted nothing and survived the guard being deleted. Found by
# mutation-testing this very case.
out="$(SHIM_LOG="$tmp/log2" bash -c '
  set -u
  source "$1/provision/roles/repos.sh"
  : > "$SHIM_LOG"
  PATH="$2:$PATH" role_repos apply debian g15 >/dev/null 2>&1
  cat "$SHIM_LOG"' _ "$REPO" "$tmp/bin")"
eq "$out" "" "role_repos without lib/fleet.sh sourced falls back to no group args"

# ── 4. the manifest key is spelled the same on both sides ─────────────────────
grep -q 'repo_groups' "$REPO/fleet.json" \
  && pass "fleet.json carries repo_groups" \
  || die "fleet.json carries repo_groups"
grep -q '\.repo_groups' "$REPO/provision/lib/fleet.sh" \
  && pass "the reader queries .repo_groups" \
  || die "the reader queries .repo_groups"

[ "$fail" = 0 ] && echo "ALL PASS" || exit 1
