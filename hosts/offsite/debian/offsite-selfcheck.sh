#!/usr/bin/env bash
# offsite-selfcheck.sh — is this box still a working copy of the fleet's data?
#
# Hourly. Cheap: mount by UUID, free space, SMART health, newest snapshot age,
# and the result of the last WEEKLY sweep (offsite-verify.timer, which does the
# expensive part). Writes /var/lib/offsite/status.json.
#
# LATITUDE PULLS THIS FILE; THIS BOX PUSHES NOTHING. The direction matters: the
# whole design is that Almaty can add to this box and never take away, and
# granting it an ssh key INTO Almaty would open exactly the hole --append-only
# closes, in the other direction. On the Almaty end the file's own mtime is this
# box's liveness signal and its contents are the verdict — two conditions on one
# file, which is what keeps "the sweep failed" distinguishable from "the link is
# down".
#
# CHECKING FROM ALMATY IS NOT EQUIVALENT AND THAT IS WHY THIS EXISTS. A check run
# over the link cannot tell "repository is fine" from "link is down", and a
# --read-data check from Almaty would pull tens of gigabytes over a residential
# uplink every time.
#
# Body lives in osc_main so the suite can source this file (OFFSITE_SELFCHECK_LIB_ONLY=1)
# and shim findmnt/smartctl/df as shell functions to exercise both the healthy and
# unhealthy paths without a real disk — same reason restic-pack-verify.sh and
# backup-status.sh keep `set -uo pipefail` and the PATH export out of the
# sourced/library path.

# note() relies on bash's dynamic scoping: it mutates the caller's `ok`/`detail`
# locals rather than declaring its own, exactly as it did when this logic was a
# flat top-level script.
note() { ok=false; detail="${detail:+$detail; }$1"; }

# ── pure helpers (unit-tested by provision/tests/backup-offsite.test.sh) ──────

# osc_is_num <s>: yes|no. An empty or non-numeric scrape is NEVER a zero. This
# exists because `[ "${sweep_bad:-0}" -gt 0 ] 2>/dev/null` read every
# unparseable bad-count as "zero bad packs": the `:-0` default supplied a
# healthy answer the file never gave, and the redirect ate the complaint.
osc_is_num() { case "${1:-}" in '' | *[!0-9]*) echo no ;; *) echo yes ;; esac; }

# osc_smart_dev <mount source>: the whole-disk device to ask smartctl about.
# `sed 's/[0-9]*$//'` alone is right for /dev/sda1 and mangles every namespaced
# device — /dev/nvme0n1p1 became /dev/nvme0n1p, which smartctl cannot open, so
# SMART would have gone unreadable on any box whose vault is an NVMe or an SD
# card. (It now says so out loud rather than passing silently, but saying so
# every hour forever is not a fix.)
osc_smart_dev() {
    local src="${1:-}"
    case "$src" in
        '') return 0 ;;
        *[0-9]p[0-9]*) printf '%s\n' "${src%p[0-9]*}" ;;
        *) printf '%s\n' "$src" | sed 's/[0-9]*$//' ;;
    esac
}

# osc_json_escape <s>: a JSON string body. `detail` is assembled from smartctl
# output, from a mount source and from a device name — none of which this script
# controls — and it is interpolated straight into status.json. One double quote
# in there makes the file unparseable, and an unparseable status file is exactly
# the state latitude's reader must not have to guess about.
osc_json_escape() {
    printf '%s' "${1:-}" |
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
        tr '\n\r\t' '   ' |
        tr -d '\000-\037'
}

osc_main() {
    local VAULT="${VAULT:-/mnt/vault}"
    local VAULT_UUID="${VAULT_UUID:?set VAULT_UUID}"
    local STATE="${OFFSITE_STATE:-/var/lib/offsite}"
    local REPO_DIR="$VAULT/restic/latitude"
    # The datasheet floor is 0 C (WD Red: 0..70; many drives specify 5) and the
    # conservative ceiling 55. These defaults sit INSIDE that range on purpose:
    # a threshold set exactly at the floor only fires once the drive is already
    # out of spec, and the entire argument for choosing an HDD here is that it
    # warns weeks ahead. 5 C leaves that margin; 0 C would not have fired at all
    # at a reading of 0, which is how the suite caught this. Overridable from
    # /etc/default/offsite for a box in a different room.
    local TEMP_MIN_C="${OFFSITE_TEMP_MIN_C:-5}"
    local TEMP_MAX_C="${OFFSITE_TEMP_MAX_C:-55}"
    local now ok detail actual pct dev health id raw newest snap_age temp
    local sweep_ts sweep_bad sweep_rc sweep_files sweep_max sweep_unread
    local sweep_missing sweep_baseline tmpf
    now="$(date +%s)"
    ok=true; detail=""

    # 1. The disk, BY UUID. `findmnt -no SOURCE` only proves something is mounted.
    actual="$(findmnt -no UUID "$VAULT" 2>/dev/null || true)"
    [ "$actual" = "$VAULT_UUID" ] || note "vault not mounted (got '${actual:-nothing}')"

    # 2. Free space. An append-only repo that never prunes must not be allowed to
    #    surprise anyone: fail at 95%.
    pct="$(df --output=pcent "$VAULT" 2>/dev/null | tail -1 | tr -dc '0-9')"
    [ -n "$pct" ] && [ "$pct" -ge 95 ] && note "vault ${pct}% full"

    # 3. SMART. The whole reason this is an HDD: it dies gradually and warns, and
    #    weeks of warning is the difference between a planned trip and a lost copy.
    dev="$(osc_smart_dev "$(findmnt -no SOURCE "$VAULT" 2>/dev/null)")"
    if [ -n "$dev" ]; then
        health="$(smartctl -H "$dev" 2>/dev/null | sed -n 's/.*overall-health.*: *//p')"
        # Empty output — a missing smartctl, a device that refuses the query,
        # a permission error, anything that produces no matching line — must
        # never fall into the same silent branch as an explicit PASSED/OK. A
        # tool that could not be read is its own state, distinct from both
        # healthy and failing: this is the same failure class as fix round
        # 1/5's finding 1, where an unreadable result was silently read as
        # fine instead of flagged.
        case "$health" in
            PASSED | OK) : ;;
            '') note "SMART health unreadable (no output from smartctl)" ;;
            *) note "SMART $health" ;;
        esac
        for id in 5 197 198; do
            raw="$(smartctl -A "$dev" 2>/dev/null | awk -v i="$id" '$1==i { print $10; exit }')"
            [ -n "$raw" ] && [ "${raw%%[^0-9]*}" -gt 0 ] 2>/dev/null && note "SMART attr $id = $raw"
        done

        # Attribute 194 is reported, not just flagged, because this box may end
        # up somewhere with no climate control at all — a veranda swinging
        # -5..+25 C over the year was on the table on 2026-09-12. The drive's
        # operating floor is 0 C (WD Red: 0..70; many drives specify 5), and the
        # danger is not the running box, which heats itself, but a COLD START:
        # "restore on AC power loss" is what the whole unattended design rests
        # on, and it is precisely what makes the box spin a cold-soaked platter
        # by itself, 900 km from anyone. A number on the status page is what
        # turns "the location is probably fine" into something measured.
        temp="$(smartctl -A "$dev" 2>/dev/null | awk '$1==194 { print $10; exit }')"
        temp="${temp%%[^0-9]*}"
        if [ -n "$temp" ]; then
            [ "$temp" -lt "$TEMP_MIN_C" ] 2>/dev/null && note "drive ${temp}C is below the ${TEMP_MIN_C}C operating floor"
            [ "$temp" -gt "$TEMP_MAX_C" ] 2>/dev/null && note "drive ${temp}C is above the ${TEMP_MAX_C}C ceiling"
        fi
    fi

    # 4. Newest snapshot. Age only — no restic binary, no password.
    newest="$(find "$REPO_DIR/snapshots" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    snap_age=""
    if [ -n "$newest" ]; then snap_age=$((now - ${newest%.*}))
    else note "no snapshots in $REPO_DIR"; fi

    # 5. Last sweep result, written by offsite-verify.timer.
    #
    # THREE STATES, NOT TWO. This branch used to be "file absent -> never run"
    # and "file present -> trust the regex scrapes", and that second arm is the
    # same failure class as check 3's SMART branch 25 lines up, stated correctly
    # there and violated here: a tool — or a file — that could not be READ is
    # its own state, distinct from both healthy and failing. Fed the exact
    # %-specifier corruption this branch already fixed once on the emitter side
    # ({"ts":/bin/bash,"rc":/bin/bash,"bad":/bin/bash}) every scrape came back
    # empty and the box reported ok:true, detail:"". A zero-byte verify.json — a
    # truncated write, a full disk, a process killed mid-write — did the same.
    # The emitter-side fix alone left the identical bug recurring invisible.
    #
    # rc is checked separately from bad: restic-pack-verify.sh's exit codes are
    # 0 clean, 1 a hash mismatch, 2 usage/precondition, 4 a content-addressed
    # directory missing, 5 a file unreadable — and a precondition failure writes
    # bad=0, so bad>0 alone would read a sweep that never ran as clean.
    sweep_ts=""; sweep_bad=""; sweep_rc=""; sweep_files=""; sweep_max=""
    sweep_unread=""; sweep_missing=""; sweep_baseline=""
    if [ ! -e "$STATE/verify.json" ]; then
        note "sweep has never run"
    elif [ ! -r "$STATE/verify.json" ] || [ ! -s "$STATE/verify.json" ]; then
        note "sweep state unreadable ($STATE/verify.json is empty or unreadable)"
    else
        sweep_ts="$(sed -n 's/.*"ts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_bad="$(sed -n 's/.*"bad"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_rc="$(sed -n 's/.*"rc"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_files="$(sed -n 's/.*"files"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_max="$(sed -n 's/.*"files_max"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_unread="$(sed -n 's/.*"unreadable"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_missing="$(sed -n 's/.*"missing"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_baseline="$(sed -n 's/.*"baseline"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE/verify.json" | head -1)"
        if [ "$(osc_is_num "$sweep_ts")" = yes ] &&
           [ "$(osc_is_num "$sweep_rc")" = yes ] &&
           [ "$(osc_is_num "$sweep_bad")" = yes ]; then
            [ "$sweep_bad" -gt 0 ] && note "sweep found $sweep_bad bad packs"
            case "$sweep_rc" in
                0) : ;;
                1) [ "$sweep_bad" -gt 0 ] || note "sweep exited 1 (hash mismatch) but recorded bad=0" ;;
                4) note "sweep exited 4: repository directory missing (${sweep_missing:-unknown}) — no coverage at all" ;;
                5) note "sweep exited 5: ${sweep_unread:-some} file(s) could not be read" ;;
                *) note "sweep exited $sweep_rc (not a hash mismatch — usage/precondition failure)" ;;
            esac
            # COVERAGE, not just verdict. A sweep that hashed nothing, or fewer
            # files than it has ever hashed before, is the collapse the rc alone
            # could not see: the repository is --append-only and nothing prunes
            # or forgets there, so the count only ever goes up. A drop is a loss.
            if [ "$(osc_is_num "$sweep_files")" = yes ]; then
                [ "$sweep_rc" = 0 ] && [ "$sweep_files" -eq 0 ] && note "sweep hashed 0 files"
                [ "$(osc_is_num "$sweep_max")" = yes ] && [ "$sweep_files" -lt "$sweep_max" ] &&
                    note "sweep coverage dropped to $sweep_files files (high-water $sweep_max)"
            else
                note "sweep state malformed (files not readable as a number)"
            fi
            [ "$(osc_is_num "$sweep_unread")" = yes ] && [ "$sweep_unread" -gt 0 ] &&
                note "sweep could not read $sweep_unread file(s)"
            # A missing baseline.sha leaves config and keys/* unjudged forever.
            # restic-pack-verify.sh prints a NOTE about it, nothing scraped the
            # NOTE, and verify.json recorded rc:0 bad:0 — so the one thing an
            # operator can forget at install time was the one thing invisible.
            [ "$sweep_baseline" = ok ] ||
                note "config and keys/* not judged (no baseline.sha on this box)"
            # A sweep that has not run in three weeks is itself a failure — a weekly job
            # that stopped is exactly the silence this whole design is built against.
            [ $((now - sweep_ts)) -gt 1814400 ] && note "sweep last ran $(( (now - sweep_ts) / 86400 ))d ago"
        else
            note "sweep state malformed (verify.json: ts/rc/bad are not numbers)"
        fi
    fi

    # Atomic, same as offsite-verify.sh writes verify.json: a `>` redirect that
    # dies mid-write leaves a truncated file, and the only reader of this one is
    # 900 km away. A rename within one filesystem is never observed half-done.
    mkdir -p "$STATE"
    tmpf="$STATE/.status.json.$$"
    if cat > "$tmpf" <<EOF
{"ts":$now,"ok":$ok,"detail":"$(osc_json_escape "$detail")","snapshot_age":"${snap_age}","vault_pct":"${pct}","drive_temp_c":"${temp}","sweep_ts":"${sweep_ts}","sweep_bad":"${sweep_bad}","sweep_rc":"${sweep_rc}","sweep_files":"${sweep_files}","sweep_files_max":"${sweep_max}","sweep_unreadable":"${sweep_unread}","sweep_baseline":"$(osc_json_escape "$sweep_baseline")"}
EOF
    then
        mv -f "$tmpf" "$STATE/status.json"
    else
        rm -f "$tmpf"
        echo "could not write $STATE/status.json" >&2
        ok=false
    fi
    $ok
}

# Sourceable: the suite sources this file (OFFSITE_SELFCHECK_LIB_ONLY=1) to shim
# findmnt/smartctl/df and drive osc_main with no side effects — the runtime PATH
# hardening and `set -uo pipefail` therefore live in this executed branch, not at
# file top, so sourcing never clobbers the caller's own PATH or pipefail setting.
[ -n "${OFFSITE_SELFCHECK_LIB_ONLY:-}" ] || { set -uo pipefail; export PATH=/usr/sbin:/sbin:/usr/bin:/bin; osc_main "$@"; exit $?; }
