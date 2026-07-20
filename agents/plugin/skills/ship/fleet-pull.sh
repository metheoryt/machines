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

# Script piped to each member. $1 = normalized target url. Prints ONE token.
REMOTE_SCRIPT='set -u
target="$1"
roots="$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly /mnt/c/Users/*/"
norm() {
  local u="$1"
  u="${u%.git}"; u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"; u="${u/://}"
  printf "%s" "$u" | awk -F/ "{ \$1=tolower(\$1) }1" OFS=/
}
found=""
for root in $roots; do
  for d in "$root" "$root"/*; do
    { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || continue
    o="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    if [ "$(norm "$o")" = "$target" ]; then found="$d"; break 2; fi
  done
done
[ -n "$found" ] || { echo "SKIP absent"; exit 0; }
[ -z "$(git -C "$found" status --porcelain 2>/dev/null)" ] || { echo "SKIP dirty"; exit 0; }
before="$(git -C "$found" rev-parse --short HEAD 2>/dev/null)"
if git -C "$found" pull --ff-only origin main >/dev/null 2>&1; then
  after="$(git -C "$found" rev-parse --short HEAD 2>/dev/null)"
  if [ "$before" = "$after" ]; then pull="OK up-to-date"; else pull="OK $before..$after"; fi
else
  pull="SKIP diverged"
fi
conv="none"
cf="$found/.machines/last-converge"
if [ -f "$cf" ]; then
  cs="$(sed -n "s/^status=//p" "$cf")"
  cr="$(sed -n "s/^rev=//p" "$cf")"
  conv="${cs:-?}@$(printf "%s" "$cr" | cut -c1-7)"
fi
echo "$pull | conv:$conv"'

# Reachability probe + remote run for one member. Prints one status token.
run_member() {
  local alias="$1" target="$2"
  # `</dev/null` is load-bearing: without it, ssh drains the caller's stdin,
  # which in main()'s `while read … done < <(jq …)` loop is the member list —
  # so the probe would swallow the remaining members and the loop would stop
  # after the first one. (A shell-function mock does not reproduce this.)
  if ! $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -c true </dev/null 2>/dev/null; then
    printf 'SKIP unreachable\n'; return 0
  fi
  local res
  res="$(printf '%s' "$REMOTE_SCRIPT" | $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -s "$target" 2>/dev/null)"
  printf '%s\n' "${res:-SKIP no-output}"
}

main() {
  local raw="${1:-}"
  [ -n "$raw" ] || { echo "usage: fleet-pull.sh <origin-url>" >&2; return 0; }
  local target self
  target="$(normalize_url "$raw")"
  self="$(self_alias)"
  printf 'Fleet pull of %s  (self: %s)\n' "$target" "${self:-unknown}"
  printf '%-10s %s\n' 'MEMBER' 'RESULT'
  local m
  while read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "$self" ] && continue
    printf '%-10s %s\n' "$m" "$(run_member "$m" "$target")"
  done < <(jq -r '.machines | keys[]' "$FLEET_JSON" 2>/dev/null)
  return 0
}

# Only run main when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
