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

# ── the offsite status.json <-> backup-status.sh reader contract (Task 9) ────
# backup-status.sh's `status` kind greps LITERALLY for "ok" then optional
# whitespace, a colon, optional whitespace, then true, and pulls `detail` with
# a specific sed. Pin both directions here so the two scripts cannot drift
# apart silently again.
ok_json="/tmp/bs-test-status-ok.$$.json"
bad_json="/tmp/bs-test-status-bad.$$.json"
printf '{"ts":1,"ok":true,"detail":""}' > "$ok_json"
printf '{"ts":1,"ok":false,"detail":"vault not mounted (got '"'"'nothing'"'"')"}' > "$bad_json"

if grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$ok_json"; then
    pass 'reader ok-grep matches "ok":true'
else
    fail 'reader ok-grep matches "ok":true'
fi
if grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$bad_json"; then
    fail 'reader ok-grep does not match "ok":false'
else
    pass 'reader ok-grep does not match "ok":false'
fi
eq "$(sed -n 's/.*"detail"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$bad_json" | head -1)" \
   "vault not mounted (got 'nothing')" \
   'reader detail-sed extracts the detail string verbatim'
rm -f "$ok_json" "$bad_json"

# ── osc_main (offsite-selfcheck.sh), driven for real (fix round 1/5, finding 4) ─
# The three assertions above pin backup-status.sh's regexes against hand-typed
# JSON — never against a status file the script itself produced. That gap is
# exactly why finding 1 (the %-specifier bug in offsite-verify.service) reached
# review: nothing exercised the real emitter. Source the script and shim
# findmnt/smartctl/df as shell functions — bash resolves an unqualified command
# name to a function before it searches PATH, so these stand in for the real
# tools with no disk and no root required.
export OFFSITE_SELFCHECK_LIB_ONLY=1
# shellcheck source=hosts/offsite/debian/offsite-selfcheck.sh
source "$REPO/hosts/offsite/debian/offsite-selfcheck.sh"

OSC_DIR=/tmp/osc-test.$$
rm -rf "$OSC_DIR"
mkdir -p "$OSC_DIR/vault/restic/latitude/snapshots" "$OSC_DIR/state"
: > "$OSC_DIR/vault/restic/latitude/config"
echo snap > "$OSC_DIR/vault/restic/latitude/snapshots/snap1"

# Healthy: matching UUID, smartctl PASSED, a fresh clean sweep.
findmnt() {
    case "$*" in
        *"-no UUID"*)   echo "FAKE-UUID" ;;
        *"-no SOURCE"*) echo "/dev/fakedisk1" ;;
    esac
}
smartctl() {
    case "$1" in
        -H) echo "SMART overall-health self-assessment test result: PASSED" ;;
        -A) : ;;
    esac
}
df() { echo "10%"; }
printf '{"ts":%s,"rc":0,"bad":0}\n' "$(date +%s)" > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
eq "$rc" 0 'osc_main: a healthy synthetic tree exits 0'
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
has "$out_json" '"ok":true' 'osc_main: a healthy tree writes ok:true'
has "$out_json" '"detail":""' 'osc_main: a healthy tree writes an empty detail'

# Unhealthy: wrong UUID and no sweep state at all.
rm -f "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="WRONG-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
eq "$rc" 1 'osc_main: a mismatched UUID with no sweep state exits 1'
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
has "$out_json" '"ok":false' 'osc_main: a mismatched UUID writes ok:false'
has "$out_json" "vault not mounted" 'osc_main: detail names the vault mismatch'
has "$out_json" 'sweep has never run' 'osc_main: an absent verify.json is flagged'

# SMART unreadable: correct mount, fresh sweep, but smartctl produces no
# output at all for -H (a missing binary, a refused query, or no permission
# all look like this) — finding 3: this must read as its own note, never as
# a silent pass alongside PASSED/OK.
smartctl() { :; }
printf '{"ts":%s,"rc":0,"bad":0}\n' "$(date +%s)" > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
eq "$rc" 1 'osc_main: an unreadable SMART result alone exits 1'
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
has "$out_json" '"ok":false' 'osc_main: an unreadable SMART result writes ok:false'
has "$out_json" 'SMART health unreadable' 'osc_main: empty smartctl output is its own note, never a silent pass'

unset -f findmnt smartctl df
rm -rf "$OSC_DIR"

# Every suite in this repo prints ALL PASS and exits nonzero on failure — that is
# what `just test` reads. Keep this block LAST in the file; later tasks append
# above it.
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "$FAIL FAILED" >&2
exit $((FAIL > 0))
