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

# NOT `export`, and unset the moment the source is done. These flags tell each
# script "you are being sourced as a library, do not run". Exported, they leak to
# every CHILD PROCESS for the rest of the file — so a later test that runs one of
# these scripts as a subprocess (the rpv_main block below does exactly that)
# would have the child source-only, exit 0, and verify nothing while printing
# PASS. A plain shell variable is visible to the sourced file, which runs in this
# same shell, and invisible to every fork.
RESTIC_PACK_VERIFY_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/restic-pack-verify.sh
source "$REPO/hosts/latitude/debian/restic-pack-verify.sh"
unset RESTIC_PACK_VERIFY_LIB_ONLY

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
BACKUP_STATUS_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/backup-status.sh
source "$REPO/hosts/latitude/debian/backup-status.sh"
unset BACKUP_STATUS_LIB_ONLY

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
OFFSITE_SELFCHECK_LIB_ONLY=1
# shellcheck source=hosts/offsite/debian/offsite-selfcheck.sh
source "$REPO/hosts/offsite/debian/offsite-selfcheck.sh"
unset OFFSITE_SELFCHECK_LIB_ONLY

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
# A COMPLETE verify.json. The three-field form ts/rc/bad is no longer a clean
# sweep and must not be: coverage (`files`), the unreadable count and whether
# `config`/`keys/*` were judged at all are part of the record now, and a record
# missing them cannot tell one file hashed from four hundred thousand.
osc_verify_json() {
    printf '{"ts":%s,"rc":%s,"bad":%s,"files":%s,"bytes":1024,"unreadable":%s,"files_max":%s,"missing":"none","baseline":"%s"}\n' \
        "${1:-$(date +%s)}" "${2:-0}" "${3:-0}" "${4:-100}" "${5:-0}" "${6:-100}" "${7:-ok}"
}
osc_verify_json > "$OSC_DIR/state/verify.json"
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
osc_verify_json > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
eq "$rc" 1 'osc_main: an unreadable SMART result alone exits 1'
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
has "$out_json" '"ok":false' 'osc_main: an unreadable SMART result writes ok:false'
has "$out_json" 'SMART health unreadable' 'osc_main: empty smartctl output is its own note, never a silent pass'

# ── osc_main: verify.json that cannot be TRUSTED (final review, Critical 2) ───
# The branch used to have exactly two arms — file absent ("sweep has never run")
# and file present (trust the regex scrapes) — so anything that scraped EMPTY
# landed in the healthy one. Both cases below produced `ok:true, detail:""`.
# The emitter-side fix for the %-specifier bug did not close this: the identical
# bug recurring, from any cause, would still have rendered healthy. A file that
# could not be READ is its own state, which is the rule this same script already
# states 25 lines earlier for smartctl and then violated here.
smartctl() {
    case "$1" in
        -H) echo "SMART overall-health self-assessment test result: PASSED" ;;
        -A) : ;;
    esac
}
printf '{"ts":/bin/bash,"rc":/bin/bash,"bad":/bin/bash}' > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
eq "$rc" 1 'osc_main: the %-specifier corruption exits 1, never 0'
has "$out_json" '"ok":false' 'osc_main: the %-specifier corruption writes ok:false'
has "$out_json" 'sweep state malformed' 'osc_main: an unparseable verify.json is named as malformed'

: > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
out_json="$(cat "$OSC_DIR/state/status.json" 2>/dev/null)"
eq "$rc" 1 'osc_main: a zero-byte verify.json exits 1'
has "$out_json" 'sweep state unreadable' 'osc_main: a zero-byte verify.json is its own state, not "never run"'

# ── osc_main: coverage, unreadables and the baseline (findings 1 and 6) ───────
# rc:0 bad:0 is not enough to call a sweep clean, and never was.
osc_verify_json "$(date +%s)" 0 0 0 0 0 ok > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
has "$(cat "$OSC_DIR/state/status.json")" 'sweep hashed 0 files' \
  'osc_main: a sweep that hashed nothing is flagged even at rc:0 bad:0'

osc_verify_json "$(date +%s)" 0 0 12 0 400000 ok > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
has "$(cat "$OSC_DIR/state/status.json")" 'sweep coverage dropped to 12 files' \
  'osc_main: a collapse against the high-water mark is flagged'

osc_verify_json "$(date +%s)" 4 0 0 0 400000 none > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
has "$(cat "$OSC_DIR/state/status.json")" 'repository directory missing' \
  'osc_main: rc=4 is named as a missing repository directory'

osc_verify_json "$(date +%s)" 5 0 100 7 100 ok > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
has "$(cat "$OSC_DIR/state/status.json")" 'could not read 7 file' \
  'osc_main: unreadable files reach the status file with their count'

# Finding 6: an operator who never copied baseline.sha left config and keys/*
# unjudged forever, and verify.json said rc:0 bad:0 with no signal anywhere.
osc_verify_json "$(date +%s)" 0 0 100 0 100 none > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
rc=$?
eq "$rc" 1 'osc_main: an unjudged config/keys is not a clean box'
has "$(cat "$OSC_DIR/state/status.json")" 'not judged (no baseline.sha' \
  'osc_main: a missing baseline.sha reaches status.json'

# ── status.json stays PARSEABLE whatever smartctl says (final review, minor) ──
# detail is assembled from smartctl output and interpolated raw; one double
# quote in it used to make the file invalid JSON, and latitude reads this file.
smartctl() { case "$1" in -H) printf 'overall-health: BAD "quoted" and a back\\slash\n' ;; -A) : ;; esac; }
osc_verify_json > "$OSC_DIR/state/verify.json"
VAULT="$OSC_DIR/vault" VAULT_UUID="FAKE-UUID" OFFSITE_STATE="$OSC_DIR/state" osc_main >/dev/null
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OSC_DIR/state/status.json" 2>/dev/null; then
        pass 'osc_main: a detail containing a double quote still writes valid JSON'
    else
        fail "osc_main: a detail containing a double quote still writes valid JSON ($(cat "$OSC_DIR/state/status.json"))"
    fi
else
    pass 'osc_main: JSON validity check skipped (no python3)'
fi
has "$(cat "$OSC_DIR/state/status.json")" '\"quoted\"' 'osc_main: the quotes are escaped, not stripped'

# ── osc_smart_dev (final review, minor) ──────────────────────────────────────
# A bare trailing-digit strip is right for /dev/sda1 and wrong for every
# namespaced device.
eq "$(osc_smart_dev /dev/sda1)"      /dev/sda      'smart dev: a SATA partition strips to its disk'
eq "$(osc_smart_dev /dev/sdb12)"     /dev/sdb      'smart dev: a two-digit partition strips to its disk'
eq "$(osc_smart_dev /dev/nvme0n1p1)" /dev/nvme0n1  'smart dev: nvme keeps its namespace'
eq "$(osc_smart_dev /dev/mmcblk0p2)" /dev/mmcblk0  'smart dev: mmcblk keeps its device number'
eq "$(osc_smart_dev /dev/sdp1)"      /dev/sdp      'smart dev: a disk letter p is not a partition marker'
eq "$(osc_smart_dev '')"             ''            'smart dev: nothing in, nothing out'

# ── osc_is_num ────────────────────────────────────────────────────────────────
eq "$(osc_is_num 0)"         yes 'is_num: zero is a number'
eq "$(osc_is_num 4231)"      yes 'is_num: an integer is a number'
eq "$(osc_is_num '')"        no  'is_num: empty is NOT zero'
eq "$(osc_is_num /bin/bash)" no  'is_num: the %-specifier corruption is NOT zero'
eq "$(osc_is_num -1)"        no  'is_num: a minus sign is not a count'

unset -f findmnt smartctl df osc_verify_json
rm -rf "$OSC_DIR"

# ── rpv_main, driven against real repository trees (final review, finding 5) ──
# The suite exercised only rpv_is_content_addressed and rpv_check_line — both
# pure, both already correct. Criticals 1 and 6 were BOTH in rpv_main, which
# nothing drove, which is the same gap that was raised and fixed for osc_main a
# round earlier. Run the real script as a SUBPROCESS so its exit code is the
# thing under test — which is only possible because the *_LIB_ONLY flags at the
# top of this file are no longer exported.
RPV="$REPO/hosts/latitude/debian/restic-pack-verify.sh"
RPV_DIR=/tmp/rpv-test.$$
mk_repo() {
    local d="$1" f h
    rm -rf "$d"; mkdir -p "$d/data/8a" "$d/index" "$d/snapshots"
    : > "$d/config"
    for f in one two three; do
        echo "$f" > "$d/.stage"
        h="$(sha256sum "$d/.stage" | cut -d' ' -f1)"
        mv "$d/.stage" "$d/data/8a/$h"
    done
    echo idx > "$d/.stage"; h="$(sha256sum "$d/.stage" | cut -d' ' -f1)"; mv "$d/.stage" "$d/index/$h"
    echo snp > "$d/.stage"; h="$(sha256sum "$d/.stage" | cut -d' ' -f1)"; mv "$d/.stage" "$d/snapshots/$h"
}

# Clean.
mk_repo "$RPV_DIR/clean"
out="$(bash "$RPV" "$RPV_DIR/clean")"; rc=$?
eq "$rc" 0 'rpv_main: a clean repository exits 0'
has "$out" 'files=5 bad=0' 'rpv_main: a clean repository reports every content-addressed file'
has "$out" 'missing=none' 'rpv_main: a clean repository reports nothing missing'
has "$out" 'unreadable=0' 'rpv_main: a clean repository reports no unreadable files'
hasnt "$out" 'bytes=0 ' 'rpv_main: bytes is a real count, not a placeholder'

# One tampered pack: its bytes no longer hash to its name.
mk_repo "$RPV_DIR/tamper"
victim="$(find "$RPV_DIR/tamper/data" -type f | sort | head -1)"
printf 'tampered' > "$victim"
out="$(bash "$RPV" "$RPV_DIR/tamper")"; rc=$?
eq "$rc" 1 'rpv_main: a tampered pack exits 1 (hash mismatch), distinct from every other failure'
has "$out" "BAD data/8a/${victim##*/}" 'rpv_main: the tampered pack is named'
has "$out" 'bad=1' 'rpv_main: exactly one bad file is counted'
has "$out" 'files=5' 'rpv_main: a tampered pack is still counted as swept'

# CRITICAL 1. data/ and index/ deleted outright. `find data index snapshots
# -type f 2>/dev/null` walked whatever subset existed and the suppressed stderr
# hid the rest, so this tree printed `files=1 bad=0` and exited 0 — every photo
# byte gone, the box reporting healthy all the way to the board.
mk_repo "$RPV_DIR/gone"
rm -rf "$RPV_DIR/gone/data" "$RPV_DIR/gone/index"
out="$(bash "$RPV" "$RPV_DIR/gone")"; rc=$?
eq "$rc" 4 'rpv_main: a missing data/ exits 4, its own code — not 0 and not a hash mismatch'
has "$out" 'MISSING data,index' 'rpv_main: the missing directories are named'
has "$out" 'files=0' 'rpv_main: a sweep with no coverage reports no coverage'
hasnt "$out" 'files=1 bad=0' 'rpv_main: the old false-clean summary is gone'

# Only snapshots/ missing — still 4, still named.
mk_repo "$RPV_DIR/nosnap"
rm -rf "$RPV_DIR/nosnap/snapshots"
out="$(bash "$RPV" "$RPV_DIR/nosnap")"; rc=$?
eq "$rc" 4 'rpv_main: a missing snapshots/ is the same class of failure'
has "$out" 'missing=snapshots' 'rpv_main: exactly which directory is gone reaches the summary'

# An EMPTY index/ is NOT a failure: a freshly initialised repository has one,
# and a gate that cries wolf there would be turned off.
mk_repo "$RPV_DIR/emptyidx"
rm -f "$RPV_DIR/emptyidx/index"/*
out="$(bash "$RPV" "$RPV_DIR/emptyidx")"; rc=$?
eq "$rc" 0 'rpv_main: an empty index/ is a young repository, not a missing one'

# No config: not a restic repository at all. A `nofail` mount that is absent
# leaves an ordinary empty directory, so this is the mount check too.
mk_repo "$RPV_DIR/noconf"
rm -f "$RPV_DIR/noconf/config"
out="$(bash "$RPV" "$RPV_DIR/noconf" 2>&1)"; rc=$?
eq "$rc" 2 'rpv_main: no config is a precondition failure (2), distinct from a missing data/ (4)'
has "$out" 'not a restic repository' 'rpv_main: the precondition failure says what is wrong'

# A file that cannot be READ is its own state. Counting it BAD would attribute
# corruption to a file nobody read; the old `bytes=$((bytes + $(stat ...)))`
# printed an arithmetic error to stderr and swept on, leaving it counted in
# files= and verified by nothing.
mk_repo "$RPV_DIR/unread"
victim="$(find "$RPV_DIR/unread/data" -type f | sort | head -1)"
chmod 000 "$victim"
if [ -r "$victim" ]; then
    pass 'rpv_main: unreadable-file case skipped (running as root)'
    pass 'rpv_main: unreadable-file case skipped (running as root)'
else
    out="$(bash "$RPV" "$RPV_DIR/unread" 2>/dev/null)"; rc=$?
    eq "$rc" 5 'rpv_main: an unreadable file exits 5, not 0 and not 1'
    has "$out" 'unreadable=1' 'rpv_main: the unreadable file is counted, never as BAD'
fi
chmod 644 "$victim" 2>/dev/null || true

# THE BASELINE (finding 6). Without one, config and keys/* are not judged —
# and that has to be visible in the summary, not only in a NOTE nobody scrapes.
mk_repo "$RPV_DIR/bl"
out="$(bash "$RPV" "$RPV_DIR/bl")"
has "$out" 'baseline=none' 'rpv_main: no --baseline is recorded as baseline=none'
printf '%s config\n' "$(sha256sum "$RPV_DIR/bl/config" | cut -d' ' -f1)" > "$RPV_DIR/bl.sha"
out="$(bash "$RPV" "$RPV_DIR/bl" --baseline "$RPV_DIR/bl.sha")"; rc=$?
eq "$rc" 0 'rpv_main: a matching baseline is clean'
has "$out" 'baseline=ok' 'rpv_main: a judged config/keys is recorded as baseline=ok'
printf 'deadbeef config\n' > "$RPV_DIR/bl.sha"
out="$(bash "$RPV" "$RPV_DIR/bl" --baseline "$RPV_DIR/bl.sha")"; rc=$?
eq "$rc" 1 'rpv_main: a config that drifted from its baseline is a mismatch'
has "$out" 'BAD config (baseline)' 'rpv_main: the baseline mismatch names the file'

# `shift 2` with one argument left is a no-op returning 1 — under no `set -e`
# that was an infinite loop, not a usage error.
out="$(timeout 10 bash "$RPV" "$RPV_DIR/bl" --baseline 2>&1)"; rc=$?
eq "$rc" 2 'rpv_main: --baseline with no value is a usage error, not a hang'

rm -rf "$RPV_DIR"

# ── offsite-verify.sh: the summary line -> verify.json contract ───────────────
# The producer half. It parses the ONE `^files=` summary line field by field,
# writes verify.json ATOMICALLY (a `>` redirect that dies mid-write is what
# manufactures the corrupt file osc_main now has to interpret), and advances the
# files_max high-water mark only on a clean run — a plain previous-run
# comparison cannot see a collapse, because the failed run records files=0 and
# the next run then reads as an increase.
OV="$REPO/hosts/offsite/debian/offsite-verify.sh"
OV_DIR=/tmp/ov-test.$$
rm -rf "$OV_DIR"; mkdir -p "$OV_DIR/state"
mk_repo "$OV_DIR/vault/restic/latitude"
VAULT="$OV_DIR/vault" OFFSITE_STATE="$OV_DIR/state" RESTIC_PACK_VERIFY="$RPV" bash "$OV" >/dev/null
rc=$?
vj="$(cat "$OV_DIR/state/verify.json")"
eq "$rc" 0 'offsite-verify: a clean sweep exits 0'
has "$vj" '"files":5' 'offsite-verify: the file count reaches verify.json'
has "$vj" '"files_max":5' 'offsite-verify: a clean run advances the high-water mark'
has "$vj" '"unreadable":0' 'offsite-verify: the unreadable count reaches verify.json'
has "$vj" '"baseline":"none"' 'offsite-verify: an absent baseline.sha reaches verify.json'
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OV_DIR/state/verify.json" 2>/dev/null; then
        pass 'offsite-verify: verify.json is valid JSON'
    else
        fail "offsite-verify: verify.json is valid JSON ($vj)"
    fi
else
    pass 'offsite-verify: JSON validity check skipped (no python3)'
fi

# Now delete data/ under it. The high-water mark must SURVIVE the failed run, or
# the coverage collapse is invisible the moment anything sweeps successfully again.
rm -rf "$OV_DIR/vault/restic/latitude/data"
VAULT="$OV_DIR/vault" OFFSITE_STATE="$OV_DIR/state" RESTIC_PACK_VERIFY="$RPV" bash "$OV" >/dev/null
rc=$?
vj="$(cat "$OV_DIR/state/verify.json")"
eq "$rc" 4 'offsite-verify: the sweep rc passes through unchanged'
has "$vj" '"rc":4' 'offsite-verify: rc=4 is recorded'
has "$vj" '"files":0' 'offsite-verify: the collapsed coverage is recorded'
has "$vj" '"files_max":5' 'offsite-verify: a FAILED run never ratchets the high-water mark down'
has "$vj" '"missing":"data"' 'offsite-verify: which directory went missing is recorded'
rm -rf "$OV_DIR"
unset -f mk_repo


# ── The verdict and the freshness are INDEPENDENT (final review, finding 3) ──
# The contents check used to be gated on `[ "$state" = ok ]`, so a status file
# 3 h old reporting ok:false rendered `late` -> `warn:offsite late 3h`, while the
# SAME FILE fresh rendered `bad`. The worse input produced the milder alert,
# inside the severity policy this feature exists to implement — and what
# silenced it was the freshness state, the one condition that is never a verdict
# about the data.
eq "$(bs_status_state ok ok)"          ok    'combine: a fresh ok file is ok'
eq "$(bs_status_state ok late)"        late  'combine: an ok verdict carries its freshness through'
eq "$(bs_status_state ok stale)"       stale 'combine: and carries staleness through too'
eq "$(bs_status_state notok ok)"       bad   'combine: a failing verdict is bad'
eq "$(bs_status_state notok late)"     bad   'combine: age can never soften a failing verdict'
eq "$(bs_status_state notok stale)"    bad   'combine: nor can staleness'
eq "$(bs_status_state unreadable ok)"  bad   'combine: an unparseable file is bad, never quietly ok'
eq "$(bs_status_state ok '')"          unknown 'combine: no freshness at all is unknown, not ok'

BS_DIR=/tmp/bs-inv.$$
rm -rf "$BS_DIR"; mkdir -p "$BS_DIR"
printf '{"ts":1,"ok":false,"detail":"sweep found 3 bad packs"}' > "$BS_DIR/status.json"
printf 'status offsite %s/status.json 7200\n' "$BS_DIR" > "$BS_DIR/jobs.conf"
run_bs() { BACKUP_STATUS_JOBS="$BS_DIR/jobs.conf" BACKUP_STATUS_STATE_DIR="$BS_DIR/state" \
    bash "$REPO/hosts/latitude/debian/backup-status.sh" "$@"; }

out="$(run_bs)"
has "$out" 'offsite|0|7200|bad|sweep found 3 bad packs' 'inversion: the file fresh is bad'
touch -d '3 hours ago' "$BS_DIR/status.json"
out="$(run_bs)"
has "$out" '|bad|' 'inversion: the SAME file 3 h old is still bad, not the milder `late`'
has "$out" 'sweep found 3 bad packs (also late)' 'inversion: and the staleness is still reported beside it'
hasnt "$out" '|late|' 'inversion: freshness can no longer mask the verdict'

# An unparseable status file is its own state — the producer half of this is
# offsite-selfcheck.sh's atomic write, but the consumer must not need it.
printf 'not json at all' > "$BS_DIR/status.json"
out="$(run_bs)"
has "$out" '|bad|status file unparseable' 'reader: a status file that is neither true nor false is bad'

# detail reaches --json from a file this box does not write. A double quote or a
# backslash in it used to emit invalid JSON to every consumer.
printf 'badkind a\\"b\\\\c 60\n' > "$BS_DIR/jobs.conf"
out="$(run_bs --json)"
has "$out" '\"' 'json: a double quote in a field is escaped'
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        pass 'json: --json stays valid JSON when a field carries a quote and a backslash'
    else
        fail "json: --json stays valid JSON when a field carries a quote and a backslash ($out)"
    fi
else
    pass 'json: validity check skipped (no python3)'
fi
rm -rf "$BS_DIR"
unset -f run_bs

# Every suite in this repo prints ALL PASS and exits nonzero on failure — that is
# what `just test` reads. Keep this block LAST in the file; later tasks append
# above it.
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "$FAIL FAILED" >&2
exit $((FAIL > 0))
