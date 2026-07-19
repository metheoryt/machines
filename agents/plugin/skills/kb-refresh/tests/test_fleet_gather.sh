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
got="$(detect_hosts | sort | tr '\n' ' ')"
# 'desktop' absent from config -> excluded; 'hub' never included
[ "$got" = "latitude server " ] || { echo "FAIL: got '$got'"; exit 1; }
echo "PASS"
