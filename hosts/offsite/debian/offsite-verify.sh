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
# EXIT: passes through restic-pack-verify.sh's own code, unchanged — 0 clean,
# 1 a hash mismatch, 2 usage/precondition (not a repo). Distinct on purpose;
# see that script's own header and AGENTS.md ("two failures must not share
# one exit status").
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

VAULT=${VAULT:-/mnt/vault}
STATE=${OFFSITE_STATE:-/var/lib/offsite}
RPV=${RESTIC_PACK_VERIFY:-/home/me/machines/hosts/latitude/debian/restic-pack-verify.sh}

out="$("$RPV" "$VAULT/restic/latitude" --baseline "$STATE/baseline.sha")"
rc=$?
bad="$(printf '%s' "$out" | sed -n 's/.*bad=\([0-9]*\).*/\1/p' | tail -1)"

mkdir -p "$STATE"
printf '{"ts":%s,"rc":%s,"bad":%s}\n' "$(date +%s)" "$rc" "${bad:-0}" > "$STATE/verify.json"
printf '%s\n' "$out"
exit "$rc"
