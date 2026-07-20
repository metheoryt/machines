#!/usr/bin/env bash
# fleet-pull.sh — FF-only, skip-if-unsafe pull of `main` on every OTHER fleet
# member that has this repo checked out. Zero destructive remote ops. Always
# exits 0 (per-box failures are SKIP rows).
#
# Usage: fleet-pull.sh <origin-url>
# Test overrides: FLEET_JSON, LOCAL_TAILNET_IP, SSH
set -u

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_JSON="${FLEET_JSON:-$SCRIPT_DIR/../../../../fleet.json}"
SSH="${SSH:-ssh}"

# Canonicalize a git remote URL to host/owner/repo (lowercase host, no
# scheme/user/.git) so scp-form and https forms of the same repo compare equal.
normalize_url() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"     # strip any user@
  u="${u/://}"                    # scp-form host:owner -> host/owner (first :)
  u="${u/:/\/}"                   # any leading ssh:// port-less colon safeguard
  printf '%s' "$u" | awk -F/ '{ $1=tolower($1) }1' OFS=/
}

# The box's own tailnet (100.64.0.0/10) address.
local_tailnet_ip() {
  if [ -n "${LOCAL_TAILNET_IP:-}" ]; then printf '%s\n' "$LOCAL_TAILNET_IP"; return; fi
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] && { printf '%s\n' "$ip"; return; }
  ip -4 -o addr show 2>/dev/null \
    | grep -oE '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+' | head -1
}

# The fleet.json member key whose tailnet.ip == this box (empty if none).
self_alias() {
  local ip; ip="$(local_tailnet_ip)"
  [ -n "$ip" ] || return 0
  jq -r --arg ip "$ip" \
    '.machines | to_entries[] | select(.value.tailnet.ip == $ip) | .key' \
    "$FLEET_JSON" 2>/dev/null | head -1
}

# main() is added in Task 3. Only run it when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  :  # main "$@"  (wired in Task 3)
fi
