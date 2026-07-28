#!/usr/bin/env bash
# Unit tests for fleet_logical_name (provision/lib/fleet.sh).
#
# The branch name the dotfiles repo checks out comes from here, so a wrong
# answer puts a machine's commits on another machine's branch. Two sources,
# in priority order: a self-declared fleet.local.json nickname, then the
# fleet.json lookup by OS hostname.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision/lib/fleet.sh
source "$HERE/../lib/fleet.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else die "$1: got '$2', want '$3'"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# A throwaway repo root carrying only the two manifests the resolver reads.
mkdir -p "$T/repo"
cat > "$T/repo/fleet.json" <<'JSON'
{"machines":{"air":{"platform":"darwin","roles":[],"detect":{"hostname":"air"}}}}
JSON

# 1. fleet.local.json nickname wins — it is the only identity a self-declared
#    WSL host has, and such a host has no fleet.json entry at all.
cat > "$T/repo/fleet.local.json" <<'JSON'
{"self":{"nickname":"wsl-g614jv","fleet":true,"platform":"linux"}}
JSON
eq "fleet.local.json nickname wins" "$(fleet_logical_name "$T/repo")" "wsl-g614jv"

# 2. No fleet.local.json => fall through to the fleet.json hostname lookup.
#    Asserted against fleet_detect's own answer rather than a hardcoded name, so
#    the test proves the FALL-THROUGH happened without depending on what this
#    box is actually called.
rm "$T/repo/fleet.local.json"
eq "falls back to fleet_detect" \
   "$(fleet_logical_name "$T/repo" 2>/dev/null || echo NONE)" \
   "$(fleet_detect 2>/dev/null || echo NONE)"

# 3. A fleet.local.json with no .self.nickname must NOT resolve to the empty
#    string — it must fall through, or the caller would check out branch "".
echo '{"other":1}' > "$T/repo/fleet.local.json"
out="$(fleet_logical_name "$T/repo" 2>/dev/null || true)"
if [ -n "$out" ]; then
  pass "empty nickname falls through"
else
  die "empty nickname returned empty (would check out branch '')"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
