#!/usr/bin/env bash
# provision/tests/latitude-timer-units.test.sh — the mirror timers' failure
# reporting, asserted as text. No root, no systemd, no disks: it reads the two
# .service files and the two scripts they run.
#
# WHY THIS SUITE EXISTS. Both jobs write a backup copy on a timer, so the ONLY
# thing standing between a broken run and nobody noticing is what systemd
# records. Two ways of losing that have already happened here, and this file
# pins both shut:
#
#   1. A FAILED Condition* SKIPS A UNIT, IT DOES NOT FAIL IT — systemd records
#      Result=success. mirror-refresh.service gated on
#      ConditionPathIsMountPoint=/mnt/immich-mirror, so when that disk dropped
#      off the bus at 16:30 on 2026-09-10 the timer reported success for 90
#      minutes while nothing was mirrored. A Condition on a backup DESTINATION
#      converts "the target is gone" into silence. Never again on these units.
#   2. TWO DIFFERENT FAILURES SHARED ONE EXIT STATUS. flock's conflict status
#      defaults to 1, and both scripts used 1 for "the mount is wrong" — so a
#      routine lock collision and a vanished backup disk were the same
#      ExecMainStatus. The convention now is 75 = lock held, 78 = mount is not
#      the expected filesystem, everything else rsync's.
#
# It is text assertions on purpose: the behaviour is systemd's and root's, so
# there is nothing here a non-root test could execute. What it CAN do is stop
# the shapes above from coming back, which is how both got in.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
D="$REPO/hosts/latitude/debian"
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
has()  { printf '%s\n' "$1" | grep -qF -- "$2" && pass "$3" || bad "$3: missing '$2'"; }
hasnt(){ printf '%s\n' "$1" | grep -qF -- "$2" && bad "$3: found '$2'" || pass "$3"; }

UNITS="mirror-refresh archive-mirror"
for u in $UNITS; do
  [ -f "$D/systemd/$u.service" ] || { echo "FAIL unit missing: $u.service"; exit 1; }
  [ -f "$D/$u.sh" ]              || { echo "FAIL script missing: $u.sh"; exit 1; }
done

# ── 1. no Condition* on either mirror unit ───────────────────────────────────
# Deliberately the whole Condition family, not just PathIsMountPoint: every one
# of them resolves to Result=success when it fails, so any of them would
# reintroduce the silent skip.
for u in $UNITS; do
  body="$(cat "$D/systemd/$u.service")"
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*Condition[A-Za-z]+='; then
    bad "$u.service has no Condition* directive (a failed one is Result=success)"
  else
    pass "$u.service has no Condition* directive (a failed one is Result=success)"
  fi
  # The reason has to survive in the file, or the next reader re-adds it.
  has "$body" 'Result=success' "$u.service records WHY a Condition is not used here"
done

# ── 2. the shared lock, and the two statuses that must stay distinct ─────────
LOCK=/var/lock/latitude-mirror.lock
for u in $UNITS; do
  exec_line="$(grep -h '^ExecStart=' "$D/systemd/$u.service")"
  case "$exec_line" in
    *"$LOCK"*)
      has "$exec_line" '-E 75' "$u.service passes flock -E 75 (default conflict status is 1, which collides with a real failure)"
      ;;
    *) bad "$u.service ExecStart no longer takes $LOCK — the -E convention below assumes both jobs share it" ;;
  esac
  # ExecStart must name a script this repo actually ships.
  s="$(printf '%s\n' "$exec_line" | tr ' ' '\n' | grep -E '\.sh$' | head -1)"
  [ -n "$s" ] && [ -f "$s" ] \
    && pass "$u.service ExecStart points at a tracked script" \
    || bad  "$u.service ExecStart points at a tracked script: '$s' not found"
done

for u in $UNITS; do
  body="$(cat "$D/$u.sh")"
  has "$body" 'E_MOUNT=78' "$u.sh exits 78 for a wrong/missing mount, not a bare 1"
  has "$body" 'exit "$E_MOUNT"' "$u.sh actually uses E_MOUNT at the guard (defining it is not using it)"
done

# 75 and 78 must not converge. Read them rather than restating them, so this
# still fails if someone renumbers one side to match the other.
lockcodes="$(grep -h '^ExecStart=' "$D"/systemd/*.service | grep -o -- '-E [0-9]*' | awk '{print $2}' | sort -u)"
mountcodes="$(grep -h '^E_MOUNT=' "$D"/*.sh | cut -d= -f2 | sort -u)"
if [ -n "$lockcodes" ] && [ -n "$mountcodes" ] \
   && [ -z "$(comm -12 <(printf '%s\n' "$lockcodes") <(printf '%s\n' "$mountcodes"))" ]; then
  pass "the lock-conflict and wrong-mount statuses are disjoint ($(echo $lockcodes) vs $(echo $mountcodes))"
else
  bad "the lock-conflict and wrong-mount statuses must stay disjoint (lock='$(echo $lockcodes)' mount='$(echo $mountcodes)')"
fi
# Neither may be 1: rsync uses 1 for a syntax error, so it is not free.
for c in $lockcodes $mountcodes; do
  [ "$c" != 1 ] && pass "status $c is not 1 (rsync already uses 1)" || bad "status 1 is rsync's — pick another"
done

# ── 3. mount identity is by UUID, and the guard is the only one there is ─────
# /mnt/immich-mirror is deliberately NOT in install-docker-ordering.sh's MOUNTS
# (nothing binds it in docker), so its mountpoint is not chattr +i and nothing
# else turns a missing destination into EPERM. `findmnt -no SOURCE` proves only
# that SOMETHING is mounted; every sd letter reshuffles here and one enclosure
# reports a fake serial.
for u in $UNITS; do
  body="$(cat "$D/$u.sh")"
  # Comments are stripped first: both files DISCUSS the `-no SOURCE` test they
  # replaced, and an assertion that cannot tell prose from code would forbid
  # writing down why the change was made.
  code="$(printf '%s\n' "$body" | sed 's/[[:space:]]*#.*$//')"
  has   "$code" 'findmnt -no UUID' "$u.sh checks mount identity by UUID"
  hasnt "$code" 'findmnt -no SOURCE' "$u.sh does not settle for 'something is mounted there'"
  # Unanchored on the right: archive-mirror.sh puts two assignments on one line.
  n=$(printf '%s\n' "$code" | grep -coE '\<[A-Z_]*UUID=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\>')
  [ "$n" -ge 2 ] \
    && pass "$u.sh pins both ends by a well-formed UUID literal ($n found)" \
    || bad  "$u.sh pins both ends by a well-formed UUID literal (found $n, want >= 2)"
done

# mirror-refresh remounts a missing mount but must never umount: docker binds
# /mnt/immich, and unmounting a live bind to repair an identity mismatch is a
# worse failure than refusing to run. archive-mirror's drives carry no binds,
# so it is allowed its umount+mount cycle.
mr="$(cat "$D/mirror-refresh.sh")"
has   "$mr" 'sudo mount'  "mirror-refresh.sh remounts a dropped mount itself (nofail only applies at boot)"
hasnt "$mr" 'sudo umount' "mirror-refresh.sh never umounts — docker binds /mnt/immich"

echo
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
