#!/usr/bin/env bash
# Unit tests for fleet_memory_publisher (provision/lib/fleet.sh) and for the
# shape of the live manifest.
#
# Phase B of memory-harvest consolidates the whole memory corpus and files one
# shared queue, reading every machine's dotfiles branch from a single checkout.
# Two boxes running it file a duplicate of every item. The gate is a NAME at the
# manifest root rather than a per-machine flag precisely so that "exactly one"
# cannot be violated by an edit; these tests pin that.
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
mkdir -p "$T/repo"
fleet_manifest_path() { echo "$T/repo/fleet.json"; }

# 1. A named publisher is returned verbatim.
cat > "$T/repo/fleet.json" <<'JSON'
{"memory_publisher":"latitude","machines":{"latitude":{"platform":"debian","roles":[]},"g15":{"platform":"debian","roles":[]}}}
JSON
eq "named publisher is returned" "$(fleet_memory_publisher)" "latitude"

# 2. Absent key prints NOTHING, so the equality gate every caller writes is
#    false on every box rather than true on one by accident.
cat > "$T/repo/fleet.json" <<'JSON'
{"machines":{"g15":{"platform":"debian","roles":[]}}}
JSON
eq "absent key is empty, not 'null'" "$(fleet_memory_publisher)" ""

# 3. A box that is not the publisher does not match.
cat > "$T/repo/fleet.json" <<'JSON'
{"memory_publisher":"latitude","machines":{"latitude":{"platform":"debian","roles":[]}}}
JSON
if [ "$(fleet_memory_publisher)" = "g15" ]; then die "non-publisher must not match"; else pass "non-publisher does not match"; fi

unset -f fleet_manifest_path
# shellcheck source=provision/lib/fleet.sh
source "$HERE/../lib/fleet.sh"

# 4. The LIVE manifest names a publisher, and it is a real machine. A typo here
#    silently means no box consolidates and nobody finds out — the queue just
#    stays empty, which reads exactly like "nothing to do".
live="$(fleet_memory_publisher)"
if [ -n "$live" ]; then pass "live manifest names a publisher"; else die "live manifest names a publisher"; fi
if jq -e --arg m "$live" '.machines | has($m)' "$(fleet_manifest_path)" >/dev/null; then
  pass "live publisher '$live' is a real machine"
else
  die "live publisher '$live' is not a key under .machines"
fi

# 5. No machine carries a per-machine flag. That shape is what this design
#    replaced; a leftover would let two boxes claim the job.
strays="$(jq -r '[.machines | to_entries[] | select(.value.memory_publisher != null) | .key] | join(",")' "$(fleet_manifest_path)")"
eq "no per-machine memory_publisher flags" "$strays" ""

[ "$fail" = 0 ] && echo "ALL PASS"
exit "$fail"
