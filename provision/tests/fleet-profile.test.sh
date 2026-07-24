#!/usr/bin/env bash
# Unit tests for provision/lib/fleet.sh profile resolvers. Asserts against the
# REAL repo fleet.json (it is the source of truth this ships with).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/fleet.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

# shellcheck source=/dev/null
source "$LIB"

# fleet_profile: explicit field on hub, default elsewhere.
eq "$(fleet_profile hub)" "hub" "fleet_profile hub == hub"
eq "$(fleet_profile latitude)" "workstation" "fleet_profile latitude defaults to workstation"

# fleet_profile_for_host: OS hostname -> profile.
eq "$(fleet_profile_for_host 27608)" "hub" "for_host 27608 == hub"
eq "$(fleet_profile_for_host latitude5520)" "workstation" "for_host latitude5520 == workstation"
eq "$(fleet_profile_for_host no-such-box)" "" "for_host unknown host is empty"

# jq-free path: hub has no jq, so resolution must fall back to python3. Build a
# PATH holding only python3 + dirname (fleet_manifest_path needs dirname) + bash
# (the PATH= prefix below applies to the `bash` lookup itself, so it must resolve).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for b in bash python3 dirname; do ln -s "$(command -v "$b")" "$tmp/bin/$b"; done
nojq="$(PATH="$tmp/bin" bash -c 'source "$1"; fleet_profile_for_host 27608' _ "$LIB")"
eq "$nojq" "hub" "for_host resolves without jq (python3 fallback)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
