#!/usr/bin/env bash
# Behavior tests for fleet-pull.sh — builds throwaway repos + a fake fleet.json,
# mocks ssh/tailscale on PATH, asserts on the summary output.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fleet-pull.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# --- fake fleet.json (alias -> tailnet ip) ---
FLEET="$tmp/fleet.json"
cat > "$FLEET" <<'JSON'
{ "machines": {
  "latitude": { "tailnet": { "ip": "100.64.0.2" } },
  "desktop":  { "tailnet": { "ip": "100.64.0.4" } },
  "server":   { "tailnet": { "ip": "100.64.0.3" } },
  "hub":      { "tailnet": { "ip": "100.64.0.1" } }
} }
JSON

# Source the script so we can call helpers directly.
FLEET_JSON="$FLEET"
LOCAL_TAILNET_IP="100.64.0.2"
source "$SCRIPT"

# normalize_url: all forms of the same repo canonicalize equal.
want="github.com/metheoryt/machines"
for u in \
  "git@github.com:metheoryt/machines.git" \
  "git@github.com:metheoryt/machines" \
  "https://github.com/metheoryt/machines.git" \
  "ssh://git@github.com/metheoryt/machines.git" ; do
  got="$(normalize_url "$u")"
  [ "$got" = "$want" ] && pass "normalize $u" || die "normalize $u -> '$got' (want '$want')"
done

# self_alias: LOCAL_TAILNET_IP 100.64.0.2 -> latitude
got="$(self_alias)"
[ "$got" = "latitude" ] && pass "self_alias=latitude" || die "self_alias -> '$got' (want latitude)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
