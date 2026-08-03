#!/usr/bin/env bash
# Unit tests for provision/fleet-selfpull.sh gate helpers. Builds throwaway
# repos with a local "remote" so pulls are real but offline.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet-selfpull.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkrepo() { # <name> <origin-url>  -> prints repo path, main branch, upstream set
  local d="$tmp/$1"; git init -q "$d"
  git -C "$d" checkout -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" remote add origin "$2"
  : > "$d/f"; git -C "$d" add .; git -C "$d" -c commit.gpgsign=false commit -qm c1
  # Fake URL can't be fetched, so hand-create the remote-tracking ref/upstream
  # (mkrepo's contract is "upstream set" — is_fleet_repo requires @{u} to resolve).
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" branch --set-upstream-to=origin/main main >/dev/null 2>&1
  echo "$d"
}

FLEET_SELFPULL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"

personal="$(mkrepo personal git@github.com:metheoryt/machines.git)"
work="$(mkrepo work git@github.com:thepureapp/backend.git)"

# is_fleet_repo: personal origin qualifies, thepureapp is excluded.
is_fleet_repo "$personal" && pass "personal repo qualifies" || die "personal repo qualifies"
is_fleet_repo "$work" && die "thepureapp excluded" || pass "thepureapp excluded"

# A non-repo dir never qualifies.
mkdir "$tmp/plain"
is_fleet_repo "$tmp/plain" && die "plain dir excluded" || pass "plain dir excluded"

# Personal origin but no tracked upstream: must be excluded by the @{u} gate.
noup="$tmp/noup"; git init -q "$noup"; git -C "$noup" checkout -q -b main
git -C "$noup" config user.email t@t; git -C "$noup" config user.name t
git -C "$noup" remote add origin git@github.com:metheoryt/other.git
: > "$noup/f"; git -C "$noup" add .; git -C "$noup" -c commit.gpgsign=false commit -qm c1
is_fleet_repo "$noup" && die "no-upstream excluded" || pass "no-upstream excluded"

# ── selfpull_one: skips are not errors, an unreachable remote IS ───────────────
# The distinction is the whole point: an unreachable remote used to be filed as
# "SKIP diverged" with exit 0, so a dead credential looked exactly like a healthy
# up-to-date fleet.
eqt() { [ "$2" = "$3" ] && pass "$1" || die "$1: expected '$3' got '$2'"; }

# Real local "remote" so a fetch+ff actually succeeds offline.
upstream="$tmp/up.git"; git init -q --bare "$upstream"
live="$tmp/live"; git init -q "$live"; git -C "$live" checkout -q -b main
git -C "$live" config user.email t@t; git -C "$live" config user.name t
git -C "$live" remote add origin "$upstream"
: > "$live/f"; git -C "$live" add .; git -C "$live" -c commit.gpgsign=false commit -qm c1
git -C "$live" push -q -u origin main

# up-to-date: OK, exit 0.
out="$(selfpull_one "$live")"; rc=$?
eqt "up-to-date reports OK" "$out" "OK up-to-date"
eqt "up-to-date exits 0" "$rc" "0"

# a real advance upstream: OK <before>..<after>, exit 0, HEAD moved.
clone2="$tmp/clone2"; git clone -q "$upstream" "$clone2"
git -C "$clone2" config user.email t@t; git -C "$clone2" config user.name t
echo x > "$clone2/g"; git -C "$clone2" add .; git -C "$clone2" -c commit.gpgsign=false commit -qm c2
git -C "$clone2" push -q origin main
before="$(git -C "$live" rev-parse --short HEAD)"
out="$(selfpull_one "$live")"; rc=$?
eqt "advance exits 0" "$rc" "0"
printf '%s\n' "$out" | grep -q "^OK ${before}\.\." \
  && pass "advance reports OK <before>..<after>" || die "advance reports OK range (got '$out')"
[ "$(git -C "$live" rev-parse HEAD)" = "$(git -C "$clone2" rev-parse HEAD)" ] \
  && pass "advance actually fast-forwarded HEAD" || die "HEAD did not move"

# dirty tree: SKIP, exit 0, and NOT pulled (never clobber WIP).
echo dirt > "$live/f"
out="$(selfpull_one "$live")"; rc=$?
eqt "dirty reports SKIP dirty" "$out" "SKIP dirty"
eqt "dirty exits 0 (not an error)" "$rc" "0"
git -C "$live" checkout -q -- f

# not main: SKIP, exit 0.
git -C "$live" checkout -q -b feature
out="$(selfpull_one "$live")"; rc=$?
eqt "non-main reports SKIP not-main" "$out" "SKIP not-main"
eqt "non-main exits 0 (not an error)" "$rc" "0"
git -C "$live" checkout -q main

# unreachable remote: FAIL, exit NON-ZERO. This is the regression guard — the old
# code printed "SKIP diverged" here and exited 0.
git -C "$live" remote set-url origin "$tmp/does-not-exist.git"
out="$(selfpull_one "$live")"; rc=$?
eqt "unreachable remote reports FAIL fetch" "$out" "FAIL fetch"
[ "$rc" -ne 0 ] && pass "unreachable remote exits non-zero" || die "unreachable remote exited 0"

# selfpull_all propagates that failure through the exit status.
FLEET_ROOTS="$tmp"
out="$(selfpull_all)"; rc=$?
[ "$rc" -ne 0 ] && pass "selfpull_all exits non-zero when a repo failed" \
  || die "selfpull_all swallowed the failure"
printf '%s\n' "$out" | grep -q 'FAIL fetch' \
  && pass "selfpull_all reports the failing repo" || die "selfpull_all lost the FAIL token"

# ...and stays clean when every repo merely skips.
git -C "$live" remote set-url origin "$upstream"
echo dirt > "$live/f"
out="$(selfpull_all)"; rc=$?
eqt "selfpull_all exits 0 when repos only skip" "$rc" "0"
git -C "$live" checkout -q -- f

# ── every scheduler must invoke the script THROUGH bash ───────────────────────
# The script is committed mode 644 on purpose: the Windows members clone it onto
# NTFS, where an executable bit does not survive, so no caller may rely on one.
# modules/system/fleet-selfpull.nix originally exec'd it directly and its first
# real run on latitude died with 126 "Permission denied".
mode="$(git -C "$HERE/.." ls-files -s provision/fleet-selfpull.sh 2>/dev/null | cut -d' ' -f1)"
eqt "script stays mode 644 (no exec bit to rely on)" "$mode" "100644"

nixmod="$HERE/../modules/system/fleet-selfpull.nix"
if [ -f "$nixmod" ]; then
  grep -qE '/bin/bash .*fleet-selfpull\.sh' "$nixmod" \
    && pass "nix module invokes the script through bash" \
    || die "nix module must run the script via bash, not exec it (mode 644 = 126)"
fi

# ── a dirty tree must stop being silent once it PERSISTS ─────────────────────
# THE BUG: desktop-wsl sat 28 commits behind for ~35 hours because one untracked
# zero-byte .zed/tasks.json tripped the dirty gate. The journal held 185
# consecutive `SKIP dirty` lines and zero OK, while the timer, the service and
# .machines/last-converge all reported success. A revoked SSH key stayed trusted
# on the box as a direct result.
#
# A skip is still not an error — that contract is deliberate (see the script
# header) and one dirty tick is normal, mid-edit. What is NOT normal is the same
# repo skipping for hours while the fleet moves. So the escalation is on
# PERSISTENCE, not on the skip: it refines the contract rather than reversing it,
# the same way dotfiles-sync commits anyway once a tree has been dirty >2h.
state="$tmp/state"
export FLEET_SELFPULL_STATE="$state"
export FLEET_SELFPULL_DIRTY_LIMIT=3

echo dirt > "$live/f"

st="$(selfpull_one "$live" 2>/dev/null)"; rc=$?
eqt "1st dirty tick is an ordinary skip" "$st" "SKIP dirty"
eqt "1st dirty tick exits 0" "$rc" "0"

st="$(selfpull_one "$live" 2>/dev/null)"; rc=$?
eqt "2nd dirty tick still an ordinary skip (under the limit)" "$st" "SKIP dirty"
eqt "2nd dirty tick exits 0" "$rc" "0"

# The 3rd hits the limit: a distinct token, a non-zero status, and a stderr line
# naming the repo — the journal grep that 185 identical lines never gave anyone.
err="$tmp/stale.err"
st="$(selfpull_one "$live" 2>"$err")"; rc=$?
case "$st" in
  STALE*) pass "3rd dirty tick escalates to a distinct token ($st)" ;;
  *)      die "3rd dirty tick still reported '$st' — the streak is invisible" ;;
esac
[ "$rc" -ne 0 ] \
  && pass "a persistently dirty repo exits non-zero" \
  || die "a persistently dirty repo still exits 0 — the timer stays green forever"
grep -q "$live" "$err" \
  && pass "stderr names the stuck repo" \
  || die "stderr does not name the stuck repo: $(cat "$err")"
grep -qi 'dirty' "$err" \
  && pass "stderr says why it is stuck" \
  || die "stderr does not say why: $(cat "$err")"

# Recovery must reset the streak, or one historical stall poisons the repo's
# status forever and the signal becomes noise to be ignored — which is how the
# original 185 lines came to be unread.
git -C "$live" checkout -q -- f
st="$(selfpull_one "$live" 2>/dev/null)"; rc=$?
case "$st" in
  OK*) pass "a recovered repo pulls normally again ($st)" ;;
  *)   die "a recovered repo did not pull: $st" ;;
esac
eqt "a recovered repo exits 0" "$rc" "0"

echo dirt > "$live/f"
st="$(selfpull_one "$live" 2>/dev/null)"; rc=$?
eqt "the streak reset: dirty after a clean run is an ordinary skip again" "$st" "SKIP dirty"
eqt "and exits 0 again" "$rc" "0"
git -C "$live" checkout -q -- f

# not-main must NEVER escalate, however long it lasts. Working on a feature
# branch is a deliberate, visible choice — `machines` on air is on one right now.
# Escalating it would paint the timer red for the whole life of any branch, which
# is the false-alarm failure that makes people stop reading the signal.
git -C "$live" checkout -q -b feature-branch
for _ in 1 2 3 4 5; do st="$(selfpull_one "$live" 2>/dev/null)"; rc=$?; done
eqt "not-main never escalates, even past the limit" "$st" "SKIP not-main"
eqt "not-main keeps the exit status clean" "$rc" "0"
git -C "$live" checkout -q main

# State must be per-repo: a second stuck repo must not inherit the first's count,
# and must not clear it either.
other="$tmp/other"; git init -q "$other"; git -C "$other" checkout -q -b main
git -C "$other" config user.email t@t; git -C "$other" config user.name t
git -C "$other" remote add origin "$upstream"
: > "$other/g"; git -C "$other" add .; git -C "$other" -c commit.gpgsign=false commit -qm c1
git -C "$other" fetch -q origin main 2>/dev/null
git -C "$other" branch --set-upstream-to=origin/main main >/dev/null 2>&1
echo dirt > "$other/g"
st="$(selfpull_one "$other" 2>/dev/null)"
eqt "a different repo starts its own streak at 1" "$st" "SKIP dirty"

unset FLEET_SELFPULL_STATE FLEET_SELFPULL_DIRTY_LIMIT

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
