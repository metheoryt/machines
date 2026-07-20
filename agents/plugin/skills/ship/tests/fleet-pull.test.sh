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

# --- mock ssh: each alias has its own fake $HOME under $tmp/home/<alias>. ---
# `ssh [-o ..] <alias> true`      -> reachability (fail if alias in UNREACHABLE)
# `ssh <alias> bash -s <target>`  -> run stdin script locally with HOME=that box
UNREACHABLE="$tmp/unreachable"; : > "$UNREACHABLE"
mkdir -p "$tmp/home"
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  if [ "${1:-}" = "true" ]; then
    grep -qx "$alias" "$UNREACHABLE" && return 1 || return 0
  fi
  # $@ is now: bash -s <target> ; run it locally with this box's HOME on stdin.
  HOME="$tmp/home/$alias" bash "${@:2}"
}
export -f mock_ssh 2>/dev/null || true
SSH="mock_ssh"

mkrepo() { # $1 = dir ; makes a repo with origin = machines, one commit
  git init -q "$1"; git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" remote add origin git@github.com:metheoryt/machines.git
}

target="$(normalize_url git@github.com:metheoryt/machines.git)"

# server: clean checkout, behind origin -> OK (a real FF). Build an "origin" the
# checkout can pull from, one commit ahead.
mkdir -p "$tmp/home/server/my"
up="$tmp/upstream.git"; git init -q --bare "$up"
mkrepo "$tmp/home/server/my/machines"
git -C "$tmp/home/server/my/machines" remote set-url origin "$up"
git -C "$tmp/home/server/my/machines" push -q origin main
git -C "$tmp/home/server/my/machines" commit -q --allow-empty -m ahead
git -C "$tmp/home/server/my/machines" push -q origin main
git -C "$tmp/home/server/my/machines" reset -q --hard HEAD~1   # now 1 behind
# The remote probe matches on the ORIGIN url; point target at the bare upstream.
tgt_server="$(normalize_url "$up")"
got="$(run_member server "$tgt_server")"
case "$got" in OK\ *..*) pass "server OK (ff)";; *) die "server -> '$got' (want OK ff)";; esac

# desktop: no matching checkout -> SKIP absent
mkdir -p "$tmp/home/desktop"
got="$(run_member desktop "$target")"
[ "$got" = "SKIP absent" ] && pass "desktop absent" || die "desktop -> '$got' (want SKIP absent)"

# latitude: dirty checkout -> SKIP dirty
mkrepo "$tmp/home/latitude/machines"
echo x > "$tmp/home/latitude/machines/dirty"
tgt_lat="$(normalize_url git@github.com:metheoryt/machines.git)"
got="$(run_member latitude "$tgt_lat")"
[ "$got" = "SKIP dirty" ] && pass "latitude dirty" || die "latitude -> '$got' (want SKIP dirty)"

# hub: unreachable -> SKIP unreachable
echo hub >> "$UNREACHABLE"
got="$(run_member hub "$target")"
[ "$got" = "SKIP unreachable" ] && pass "hub unreachable" || die "hub -> '$got' (want SKIP unreachable)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
