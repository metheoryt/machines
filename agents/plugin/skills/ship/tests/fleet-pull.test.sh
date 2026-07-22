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
# `ssh [-o ..] <alias> bash -c true`      -> reachability (fail if alias in UNREACHABLE)
# `ssh <alias> bash -s <target>`          -> run stdin script locally with HOME=that box
# `ssh <alias> <powershell ... -s -- ..>` -> windows work call, same idea
UNREACHABLE="$tmp/unreachable"; : > "$UNREACHABLE"
mkdir -p "$tmp/home"
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  # Reachability probe: remote command CONTAINS `-c true` (both `bash -c true`
  # and the windows PowerShell `... bash.exe" -c true }` fragment contain it).
  # NOTE: detecting via "ends in true" is a trap — the windows probe ends in
  # `}` (the PowerShell if/else close brace), not `true`, so that check would
  # fall through to the work branch and pass vacuously for windows/winbox.
  case "$remote" in
    *"-c true"*)
      # Real ssh drains its stdin; model that so the "ssh in a loop eats the
      # member list" bug is reproducible. Harmless because run_member's probe
      # redirects stdin from /dev/null — if that `</dev/null` is ever removed,
      # this drain consumes main()'s `while read … done < <(jq …)` input and
      # the "all non-self members processed" assertion below goes RED.
      cat >/dev/null 2>&1 || true
      # Model a PowerShell/Windows box: no bare `true`, only bash works.
      case "$remote" in
        *bash.exe*|bash\ *) : ;;                        # bash reached -> ok
        *) [ "$alias" = winbox ] && return 1 ;;          # winbox: no bash -> down
      esac
      grep -qx "$alias" "$UNREACHABLE" && return 1 || return 0
      ;;
  esac
  # Work call: run REMOTE_SCRIPT (on stdin) with this box's HOME. The script's
  # single positional arg (target) is the LAST token of the flattened command
  # for both `bash -s <target>` and Git Bash `-s -- "<target>"`.
  local target; target="$(printf '%s' "$remote" | awk '{gsub(/"/,"",$NF); print $NF}')"
  HOME="$tmp/home/$alias" bash -s "$target"
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
got="$(run_member server linux "$tgt_server")"
case "$got" in OK\ *..*) pass "server OK (ff)";; *) die "server -> '$got' (want OK ff)";; esac

# desktop: no matching checkout -> SKIP absent
mkdir -p "$tmp/home/desktop"
got="$(run_member desktop linux "$absent_target")"
[ "$got" = "SKIP absent" ] && pass "desktop absent" || die "desktop -> '$got' (want SKIP absent)"

# latitude: dirty checkout -> SKIP dirty
mkrepo "$tmp/home/latitude/machines"
echo x > "$tmp/home/latitude/machines/dirty"
tgt_lat="$(normalize_url git@github.com:metheoryt/machines.git)"
got="$(run_member latitude linux "$tgt_lat")"
[ "$got" = "SKIP dirty" ] && pass "latitude dirty" || die "latitude -> '$got' (want SKIP dirty)"

# hub: unreachable -> SKIP unreachable
echo hub >> "$UNREACHABLE"
got="$(run_member hub linux "$target")"
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
got="$(run_member desktop linux "$tgt_div")"
[ "$got" = "SKIP diverged | conv:none" ] && pass "desktop diverged" || die "desktop -> '$got' (want SKIP diverged | conv:none)"

# extra: clean checkout already at the bare upstream's HEAD, no new commits
# either side -> OK up-to-date.
mkdir -p "$tmp/home/extra"
up_uptodate="$tmp/upstream-uptodate.git"; git init -q --bare "$up_uptodate"
mkrepo "$tmp/home/extra/machines"
git -C "$tmp/home/extra/machines" remote set-url origin "$up_uptodate"
git -C "$tmp/home/extra/machines" push -q origin main
tgt_uptodate="$(normalize_url "$up_uptodate")"
got="$(run_member extra linux "$tgt_uptodate")"
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
got="$(run_member winbox windows "$absent_target")"
[ "$got" = "SKIP absent" ] && pass "winbox reachable via bash probe" || die "winbox -> '$got' (want SKIP absent)"

# --- main()'s platform threading: a real "platform":"windows" fleet.json entry
# must flow through main()'s jq @tsv parse into run_member/fd_probe/fd_run, not
# just via a direct run_member call. A separate fixture keeps this isolated
# from the linux-only fixture used by the full-run assertions above. winbox's
# $HOME is already set up (empty -> absent) and the mock's windows probe is
# already wired (see mock_ssh: bash.exe reached -> ok, bare `true` -> down for
# winbox). If main() ever dropped/mis-threaded the platform field (defaulting
# everything to "linux"), the probe would use bare `true`, winbox's special-
# cased failure would fire, and this would read "SKIP unreachable" instead.
FLEET_WIN="$tmp/fleet-win.json"
cat > "$FLEET_WIN" <<JSON
{ "machines": {
  "latitude": { "tailnet": { "ip": "100.64.0.2" } },
  "winbox":   { "tailnet": { "ip": "100.64.0.9" }, "platform": "windows" }
} }
JSON
out_win="$(FLEET_JSON="$FLEET_WIN" LOCAL_TAILNET_IP="100.64.0.2" SSH="mock_ssh" \
           main "git@github.com:metheoryt/machines.git" 2>/dev/null)"
printf '%s' "$out_win" | grep -qE '^winbox[[:space:]]+SKIP absent' \
  && pass "main() threads platform=windows into run_member" \
  || die "main() windows row wrong: $out_win (want winbox ... SKIP absent, not SKIP unreachable)"

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

# canonical-path-first: a checkout at $HOME/machines is found even though the
# roots list would also scan $HOME/*/. Build one at the canonical path only.
mkdir -p "$tmp/home/canon"
up_canon="$tmp/upstream-canon.git"; git init -q --bare "$up_canon"
mkrepo "$tmp/home/canon/machines"
git -C "$tmp/home/canon/machines" remote set-url origin "$up_canon"
git -C "$tmp/home/canon/machines" push -q origin main
tgt_canon="$(normalize_url "$up_canon")"
got="$(run_member canon linux "$tgt_canon")"
[ "$got" = "OK up-to-date | conv:none" ] && pass "canonical \$HOME/machines found" \
  || die "canon -> '$got' (want OK up-to-date)"

# canonical-path PRIORITY: the test above can't tell the canonical-first `if`
# block apart from the fallback scan, because $HOME/machines is ALSO the first
# match the fallback scan would find (root=$HOME's own "$root"/* glob visits
# $HOME's direct children in alphabetical order, and "machines" would be
# reached there regardless). To force a real race we need a competing repo
# that the fallback scan reaches BEFORE $HOME/machines if the canonical-first
# block were absent: a sibling directly under $HOME sorting alphabetically
# ahead of "machines" (verified: "decoy" < "machines" -> checked first in the
# same root=$HOME glob pass). Give the two DIFFERENT, distinguishable status
# tokens (canonical clean+up-to-date; decoy dirty) so a pass here proves the
# canonical clone's token won, not the decoy's.
mkdir -p "$tmp/home/prio"
up_prio="$tmp/upstream-prio.git"; git init -q --bare "$up_prio"
mkrepo "$tmp/home/prio/machines"
git -C "$tmp/home/prio/machines" remote set-url origin "$up_prio"
git -C "$tmp/home/prio/machines" push -q origin main
# competing sibling: same origin, but DIRTY -> distinguishable "SKIP dirty".
mkrepo "$tmp/home/prio/decoy"
git -C "$tmp/home/prio/decoy" remote set-url origin "$up_prio"
git -C "$tmp/home/prio/decoy" push -q origin main
echo x > "$tmp/home/prio/decoy/dirty"
tgt_prio="$(normalize_url "$up_prio")"
got="$(run_member prio linux "$tgt_prio")"
[ "$got" = "OK up-to-date | conv:none" ] \
  && pass "canonical wins over earlier-sorted dirty sibling (decoy)" \
  || die "prio -> '$got' (want OK up-to-date; canonical-first must beat scan order, not '$got')"

# /mnt/c root removed: REMOTE_SCRIPT must not reference /mnt/c any more.
printf '%s' "$REMOTE_SCRIPT" | grep -q '/mnt/c' \
  && die "REMOTE_SCRIPT still references /mnt/c" || pass "no /mnt/c root in REMOTE_SCRIPT"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
