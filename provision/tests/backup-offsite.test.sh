#!/usr/bin/env bash
# provision/tests/backup-offsite.test.sh — the offsite site's pure helpers.
#
# No disks, no network: every judgement here is a function of its arguments, so
# the severity policy and the content-addressing rule are testable on any box.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }

export RESTIC_PACK_VERIFY_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/restic-pack-verify.sh
source "$REPO/hosts/latitude/debian/restic-pack-verify.sh"

# ── rpv_is_content_addressed ──────────────────────────────────────────────────
# The whole keyless design rests on this split. data/, index/ and snapshots/ are
# named by the SHA-256 of their own stored bytes; config and keys/* are not, and
# hashing them against their names would report every healthy repo as corrupt.
eq "$(rpv_is_content_addressed data/8a/8a1f4cce)" yes 'data/ is content-addressed'
eq "$(rpv_is_content_addressed index/ab12)"       yes 'index/ is content-addressed'
eq "$(rpv_is_content_addressed snapshots/cd34)"   yes 'snapshots/ is content-addressed'
eq "$(rpv_is_content_addressed config)"           no  'config is NOT content-addressed'
eq "$(rpv_is_content_addressed keys/ef56)"        no  'keys/ is NOT content-addressed'
eq "$(rpv_is_content_addressed locks/aa)"         no  'locks/ is NOT content-addressed'

# ── rpv_check_line ────────────────────────────────────────────────────────────
# The name is the hash, so a match is silence and a mismatch names the file. The
# comparison is on the BASENAME: data files sit one directory deep under a
# two-hex-char prefix, and comparing the whole relative path would never match.
eq "$(rpv_check_line data/8a/8a1f4ccec0325b33 8a1f4ccec0325b33)" '' \
  'a pack whose name equals its hash is silent'
has "$(rpv_check_line data/8a/8a1f4ccec0325b33 deadbeefdeadbeef)" 'BAD data/8a/8a1f4ccec0325b33' \
  'a pack whose bytes changed is named'

# ── bs_age_state ──────────────────────────────────────────────────────────────
# The severity policy is keyed on each job's DECLARED expected period, not on
# observed periodicity. That is what keeps Debian's nine housekeeping timers off
# the page and catches the four that matter — and it is the only rule that
# makes "late" mean anything for a job that runs weekly.
export BACKUP_STATUS_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/backup-status.sh
source "$REPO/hosts/latitude/debian/backup-status.sh"

eq "$(bs_age_state 3600 86400)"   ok    'fresh: an hour into a daily job is ok'
eq "$(bs_age_state 86399 86400)"  ok    'fresh: one second inside the period is still ok'
eq "$(bs_age_state 90000 86400)"  late  'late: one missed daily run is late'
eq "$(bs_age_state 172801 86400)" stale 'stale: two missed daily runs is stale'
eq "$(bs_age_state 600000 604800)" ok   'period is per-job: a week-old weekly job is ok'
eq "$(bs_age_state '' 86400)"     unknown 'no age at all is unknown, not ok'
eq "$(bs_age_state abc 86400)"    unknown 'a non-numeric age is unknown, not ok'

# ── absent status file (controller ruling) ───────────────────────────────────
# The offsite status file is delivered by a later task; on every box today it is
# absent. That must never read as bad or as an error — it is simply not here yet.
rm -rf /tmp/bs-test-jobs.$$ /tmp/bs-test-state.$$
mkdir -p /tmp/bs-test-jobs.$$
printf 'status offsite /tmp/bs-test-jobs.%s/does-not-exist.json 7200\n' "$$" > /tmp/bs-test-jobs.$$/jobs.conf
out="$(BACKUP_STATUS_LIB_ONLY= BACKUP_STATUS_JOBS=/tmp/bs-test-jobs.$$/jobs.conf BACKUP_STATUS_STATE_DIR=/tmp/bs-test-state.$$ bash "$REPO/hosts/latitude/debian/backup-status.sh")"
rc=$?
eq "$rc" 0 'an absent status file exits 0, never an error'
has "$out" 'offsite||7200|unknown|' 'an absent status file yields an unknown row, never bad'
hasnt "$out" '|bad|' 'an absent status file is never reported as bad'
rm -rf /tmp/bs-test-jobs.$$ /tmp/bs-test-state.$$

# Every suite in this repo prints ALL PASS and exits nonzero on failure — that is
# what `just test` reads. Keep this block LAST in the file; later tasks append
# above it.
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "$FAIL FAILED" >&2
exit $((FAIL > 0))
