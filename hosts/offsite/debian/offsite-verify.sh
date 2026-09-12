#!/usr/bin/env bash
# offsite-verify.sh — run the weekly keyless integrity sweep and record the
# result for offsite-selfcheck.sh to read.
#
# WHY THIS IS A SCRIPT FILE AND NOT AN INLINE ExecStart. It was a `bash -c`
# blob directly in offsite-verify.service until fix round 1/5 found it
# silently broken: its printf format strings' `%s` is systemd's OWN
# specifier-escape character, and `ExecStart=` is expanded by systemd BEFORE
# bash ever runs. An unescaped `%s` there means "the unit's own shell path",
# so every run wrote literally `{"ts":/bin/bash,"rc":/bin/bash,"bad":/bin/bash}`
# to verify.json regardless of what the sweep actually found — and because
# verify.json then EXISTED, offsite-selfcheck.sh's "sweep has never run"
# branch stopped firing too, so a sweep that had in fact never produced a real
# result read as silently fine. Neighbouring evidence this file's own author
# should have caught: the still-correct `date +%%s` on the line above the
# broken ones only works BECAUSE it doubles the percent sign for systemd —
# the same doubling was owed everywhere else in that ExecStart and wasn't
# paid. A unit file that must be read character by character (counting `%`
# and `$` doublings) to be correct will break again the next time someone
# edits it; a real script removes the specifier hazard at its root rather
# than requiring anyone to keep counting percent signs.
#
# THE WRITE IS ATOMIC — temp file in the same directory, then rename. That is
# the PRODUCER half of the same bug. The consumer (offsite-selfcheck.sh) now
# refuses to read a malformed verify.json as clean, but a consumer-only fix
# would leave this box able to MANUFACTURE the malformed file: a `>` redirect
# on a full disk, or a process killed mid-write, truncates in place and the
# hourly selfcheck then has to interpret a half-written file. rename(2) within
# one filesystem cannot be observed half-done, so the reader only ever sees a
# whole file or the previous whole file.
#
# WHAT IT RECORDS AND WHY EACH FIELD IS THERE. `ts`/`rc`/`bad` were the whole
# record, and that was the root enabler of the coverage bug: one file hashed and
# four hundred thousand files hashed were byte-identical downstream. So:
#   files       how many content-addressed files were actually hashed
#   bytes       how many bytes of them were read
#   unreadable  files that could not be stat'd or hashed at all
#   files_max   the high-water mark of `files`, advanced ONLY by a clean run.
#               The repository is --append-only and nothing ever prunes or
#               forgets there, so the file count is monotonically
#               non-decreasing: a DROP is a real loss of coverage and nothing
#               else. A plain previous-run comparison would not do — a failed
#               run records files=0, and the next run then reads as an increase.
#   missing     which of data/ index/ snapshots/ was absent
#   baseline    ok when config and keys/* were actually judged against
#               baseline.sha, none when they were not judged at all
#
# EXIT: passes through restic-pack-verify.sh's own code, unchanged — 0 clean,
# 1 a hash mismatch, 2 usage/precondition (not a repo), 4 a content-addressed
# directory is missing, 5 a file could not be read. Distinct on purpose; see
# that script's own header and AGENTS.md ("two failures must not share one
# exit status").
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

VAULT=${VAULT:-/mnt/vault}
STATE=${OFFSITE_STATE:-/var/lib/offsite}
RPV=${RESTIC_PACK_VERIFY:-/home/me/machines/hosts/latitude/debian/restic-pack-verify.sh}

out="$("$RPV" "$VAULT/restic/latitude" --baseline "$STATE/baseline.sha")"
rc=$?

# Parse the ONE summary line, field by field. Not a greedy sed over the whole
# output: BAD/UNREADABLE/MISSING lines share the stream and a filename is
# attacker-adjacent text, so anchoring on `^files=` removes every collision
# question rather than reasoning about it.
summary="$(printf '%s\n' "$out" | grep -E '^files=' | tail -1)"
files=""; bad=""; bytes=""; unreadable=""; missing=""; baseline=""
for kv in $summary; do
    case "$kv" in
        files=*)      files="${kv#files=}" ;;
        bad=*)        bad="${kv#bad=}" ;;
        bytes=*)      bytes="${kv#bytes=}" ;;
        unreadable=*) unreadable="${kv#unreadable=}" ;;
        missing=*)    missing="${kv#missing=}" ;;
        baseline=*)   baseline="${kv#baseline=}" ;;
    esac
done

# A field that did not parse becomes JSON null, never 0. "the sweep read zero
# files" and "this box could not tell you how many files the sweep read" are two
# different states and the reader has to be able to separate them.
num() { case "${1:-}" in '' | *[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
# missing= and baseline= come from a fixed vocabulary; pin that rather than
# trust it, so nothing can ever inject a quote into the JSON string body.
word() { printf '%s' "${1:-}" | tr -cd 'a-z,'; }

prev_max="$(sed -n 's/.*"files_max"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' \
    "$STATE/verify.json" 2>/dev/null | head -1)"
case "$prev_max" in '' | *[!0-9]*) prev_max=0 ;; esac
files_max=$prev_max
case "$files" in
    '' | *[!0-9]*) : ;;
    *) [ "$rc" -eq 0 ] && [ "$files" -gt "$prev_max" ] && files_max=$files ;;
esac

mkdir -p "$STATE"
tmp="$STATE/.verify.json.$$"
if printf '{"ts":%s,"rc":%s,"bad":%s,"files":%s,"bytes":%s,"unreadable":%s,"files_max":%s,"missing":"%s","baseline":"%s"}\n' \
        "$(date +%s)" "$rc" "$(num "$bad")" "$(num "$files")" "$(num "$bytes")" \
        "$(num "$unreadable")" "$files_max" "$(word "${missing:-unknown}")" \
        "$(word "${baseline:-unknown}")" > "$tmp"; then
    mv -f "$tmp" "$STATE/verify.json"
else
    rm -f "$tmp"
    echo "could not write $STATE/verify.json" >&2
fi
printf '%s\n' "$out"
exit "$rc"
