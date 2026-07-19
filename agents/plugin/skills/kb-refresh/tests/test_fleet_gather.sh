#!/usr/bin/env bash
# agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../fleet-gather.sh"

# fake HOME with an ssh config that lists two of three fleet aliases
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.ssh"
cat > "$tmp/.ssh/config" <<EOF
Host latitude
  HostName 100.64.0.2
Host server
  HostName 100.64.0.3
EOF

# source the script's functions without running main
export HOME="$tmp"
KB_GATHER_NO_MAIN=1 source "$script"

# ── fixture fleet.json (shared by the pure-function tests) ────────────────────
fixture_json="$tmp/fleet.json"
cat > "$fixture_json" <<'JSON'
{ "machines": {
  "latitude": { "platform": "nixos", "detect": { "hostname": "latitude5520" } },
  "desktop":  { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "g614jv" } },
  "server":   { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "methe-server" } },
  "hub":      { "platform": "debian", "ssh": { "user": "debian", "host": "cyphy.kz" }, "detect": { "hostname": "27608" } }
} }
JSON

if command -v jq >/dev/null 2>&1; then
  # ── fleet_hosts: hub excluded, correct tuples ───────────────────────────────
  fh="$(fleet_hosts "$fixture_json")"
  [ "$(printf '%s\n' "$fh" | wc -l)" = 3 ] || { echo "FAIL: fleet_hosts expected 3 rows, got: $fh"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^latitude\tnixos\tlatitude5520\t$' || { echo "FAIL: fleet_hosts latitude tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^desktop\twindows\tg614jv\tmethe$'  || { echo "FAIL: fleet_hosts desktop tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -qP '^server\twindows\tmethe-server\tmethe$' || { echo "FAIL: fleet_hosts server tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -q 'hub' && { echo "FAIL: fleet_hosts must exclude hub"; exit 1; }
else
  echo "SKIP: fleet_hosts test (jq not installed)"
fi

got="$(detect_hosts | sort | tr '\n' ' ')"
# 'desktop' absent from config -> excluded; 'hub' never included
[ "$got" = "latitude server " ] || { echo "FAIL: got '$got'"; exit 1; }
echo "PASS"
