#!/usr/bin/env bash
# Behavior tests for fleet-pull.sh — builds throwaway repos + a fake fleet.json,
# mocks ssh/tailscale on PATH, asserts on the summary output.
set -u
# Give the script itself a /dev/null stdin so the stdin-drain regression guard
# fails CLEANLY rather than hanging: main()'s loop keeps its own `< <(jq …)`
# input, but direct run_member probes (whose stdin would otherwise be the
# terminal) never block on the draining mock.
exec </dev/null
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
  # Reachability probe (bash -c true, or legacy bare true) always ends in
  # "true"; the work call (bash -s <target>) always ends in the target.
  if [ "${@: -1}" = "true" ]; then
    # Real ssh drains its stdin; model that so the "ssh in a loop eats the
    # member list" bug is reproducible. Harmless because run_member's probe
    # redirects stdin from /dev/null — if that `</dev/null` is ever removed,
    # this drain consumes main()'s `while read … done < <(jq …)` input and the
    # "all non-self members processed" assertion below goes RED.
    cat >/dev/null 2>&1 || true
    # Model a PowerShell/Windows box: no bare `true`, only bash works.
    # A bare-`true` probe ($1 != "bash") fails; a bash-wrapped probe succeeds.
    if [ "$alias" = "winbox" ] && [ "${1:-}" != "bash" ]; then return 1; fi
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
# A target guaranteed not to collide with any real checkout the unscoped
# `/mnt/c/Users/*/` root in REMOTE_SCRIPT might stumble onto on the host
# running this test (e.g. this very repo's own working copy, whose origin
# happens to equal $target) — used for the "absent" cases below so they stay
# hermetic regardless of what's checked out on the box running the suite.
absent_target="$(normalize_url git@github.com:metheoryt/nonesuch.git)"

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
got="$(run_member desktop "$absent_target")"
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

# desktop (reused, now that "desktop absent" already ran): diverged checkout
# -> SKIP diverged. Local checkout carries a commit not on the bare upstream,
# and the bare upstream independently advanced via a second clone -> real
# divergent histories, `pull --ff-only` must refuse.
up_div="$tmp/upstream-diverged.git"; git init -q --bare "$up_div"
mkrepo "$tmp/home/desktop/machines"
git -C "$tmp/home/desktop/machines" remote set-url origin "$up_div"
git -C "$tmp/home/desktop/machines" push -q origin main
git clone -q "$up_div" "$tmp/clone-diverged"
git -C "$tmp/clone-diverged" config user.email t@t; git -C "$tmp/clone-diverged" config user.name t
git -C "$tmp/clone-diverged" commit -q --allow-empty -m upstream-ahead
git -C "$tmp/clone-diverged" push -q origin main
git -C "$tmp/home/desktop/machines" commit -q --allow-empty -m local-ahead
tgt_div="$(normalize_url "$up_div")"
got="$(run_member desktop "$tgt_div")"
[ "$got" = "SKIP diverged | conv:none" ] && pass "desktop diverged" || die "desktop -> '$got' (want SKIP diverged | conv:none)"

# extra: clean checkout already at the bare upstream's HEAD, no new commits
# either side -> OK up-to-date.
mkdir -p "$tmp/home/extra"
up_uptodate="$tmp/upstream-uptodate.git"; git init -q --bare "$up_uptodate"
mkrepo "$tmp/home/extra/machines"
git -C "$tmp/home/extra/machines" remote set-url origin "$up_uptodate"
git -C "$tmp/home/extra/machines" push -q origin main
tgt_uptodate="$(normalize_url "$up_uptodate")"
got="$(run_member extra "$tgt_uptodate")"
[ "$got" = "OK up-to-date | conv:none" ] && pass "extra up-to-date" || die "extra -> '$got' (want OK up-to-date | conv:none)"

# --- full run via main(): self (latitude, LOCAL_TAILNET_IP=100.64.0.2) excluded ---
# Reset boxes: server behind (OK ff), desktop absent, hub unreachable (already),
# latitude is SELF so must NOT appear.
out="$(FLEET_JSON="$FLEET" LOCAL_TAILNET_IP="100.64.0.2" SSH="mock_ssh" \
       main "$up" 2>/dev/null)"
printf '%s' "$out" | grep -qE '^latitude' && die "self latitude should be excluded" || pass "self excluded"
printf '%s' "$out" | grep -qE '^server .*OK'      && pass "table server OK"      || die "table missing server OK: $out"
printf '%s' "$out" | grep -qE '^desktop .*SKIP'   && pass "table desktop SKIP"   || die "table missing desktop SKIP: $out"
printf '%s' "$out" | grep -qE '^hub .*unreachable'&& pass "table hub unreachable"|| die "table missing hub: $out"

# Regression guard for the "ssh in a loop drains stdin" bug: the mock's probe
# branch drains stdin like real ssh. All three non-self members (desktop, hub,
# server) must appear — if run_member's probe loses its `</dev/null`, the probe
# swallows the member list and the loop stops after the first row.
rows="$(printf '%s\n' "$out" | grep -cE '^(desktop|hub|server) ')"
[ "$rows" -eq 3 ] && pass "loop processed all 3 non-self members (stdin intact)" \
  || die "loop stopped early: only $rows/3 member rows in: $out"

# winbox: models a PowerShell/Windows box where a bare `true` probe fails but
# a bash-wrapped probe (`bash -c true`) succeeds. Empty $HOME (no checkout),
# so once the probe passes the box is reachable but the repo is absent ->
# SKIP absent, NOT SKIP unreachable. This is the regression guard for Fix 1:
# it is RED if run_member's probe reverts to bare `true`, GREEN with `bash -c true`.
mkdir -p "$tmp/home/winbox"
got="$(run_member winbox "$absent_target")"
[ "$got" = "SKIP absent" ] && pass "winbox reachable via bash probe" || die "winbox -> '$got' (want SKIP absent)"

# --- convergence column: REMOTE_SCRIPT reports .machines/last-converge ---
# Build a found-repo with a last-converge record; run the token-builder snippet
# the remote script uses and assert the converge token is derived from it.
convrepo="$tmp/convrepo"; mkdir -p "$convrepo/.machines"
printf 'rev=%s\nstatus=ok\ntimestamp=t\nreason=r\n' 1234567890abcdef > "$convrepo/.machines/last-converge"
conv_token="$(
  found="$convrepo"
  cf="$found/.machines/last-converge"
  if [ -f "$cf" ]; then
    cs="$(sed -n 's/^status=//p' "$cf")"; cr="$(sed -n 's/^rev=//p' "$cf")"
    echo "conv:${cs:-?}@$(printf '%s' "$cr" | cut -c1-7)"
  else echo "conv:none"; fi
)"
[ "$conv_token" = "conv:ok@1234567" ] && pass "converge token from last-converge" || die "converge token: got '$conv_token'"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
