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

osc_main() {
    local VAULT="${VAULT:-/mnt/vault}"
    local VAULT_UUID="${VAULT_UUID:?set VAULT_UUID}"
    local STATE="${OFFSITE_STATE:-/var/lib/offsite}"
    local REPO_DIR="$VAULT/restic/latitude"
    local now ok detail actual pct dev health id raw newest snap_age
    local sweep_ts sweep_bad sweep_rc
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
    dev="$(findmnt -no SOURCE "$VAULT" 2>/dev/null | sed 's/[0-9]*$//')"
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
    fi

    # 4. Newest snapshot. Age only — no restic binary, no password.
    newest="$(find "$REPO_DIR/snapshots" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    snap_age=""
    if [ -n "$newest" ]; then snap_age=$((now - ${newest%.*}))
    else note "no snapshots in $REPO_DIR"; fi

    # 5. Last sweep result, written by offsite-verify.timer. rc is checked
    #    separately from bad: restic-pack-verify.sh's exit codes are 0 clean,
    #    1 a hash mismatch, 2 usage/precondition (not a repo) — and a
    #    precondition failure writes bad=0, so bad>0 alone would read a sweep
    #    that never actually ran as clean.
    sweep_ts=""; sweep_bad=""; sweep_rc=""
    if [ -f "$STATE/verify.json" ]; then
        sweep_ts="$(sed -n 's/.*"ts"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_bad="$(sed -n 's/.*"bad"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        sweep_rc="$(sed -n 's/.*"rc"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$STATE/verify.json" | head -1)"
        [ "${sweep_bad:-0}" -gt 0 ] 2>/dev/null && note "sweep found $sweep_bad bad packs"
        [ -n "$sweep_rc" ] && [ "$sweep_rc" != "0" ] && [ "${sweep_bad:-0}" -eq 0 ] 2>/dev/null &&
            note "sweep exited $sweep_rc (not a hash mismatch — usage/precondition failure)"
        # A sweep that has not run in three weeks is itself a failure — a weekly job
        # that stopped is exactly the silence this whole design is built against.
        [ -n "$sweep_ts" ] && [ $((now - sweep_ts)) -gt 1814400 ] && note "sweep last ran $(( (now - sweep_ts) / 86400 ))d ago"
    else
        note "sweep has never run"
    fi

    mkdir -p "$STATE"
    cat > "$STATE/status.json" <<EOF
{"ts":$now,"ok":$ok,"detail":"$detail","snapshot_age":"${snap_age}","vault_pct":"${pct}","sweep_ts":"${sweep_ts}","sweep_bad":"${sweep_bad}","sweep_rc":"${sweep_rc}"}
EOF
    $ok
}

# Sourceable: the suite sources this file (OFFSITE_SELFCHECK_LIB_ONLY=1) to shim
# findmnt/smartctl/df and drive osc_main with no side effects — the runtime PATH
# hardening and `set -uo pipefail` therefore live in this executed branch, not at
# file top, so sourcing never clobbers the caller's own PATH or pipefail setting.
[ -n "${OFFSITE_SELFCHECK_LIB_ONLY:-}" ] || { set -uo pipefail; export PATH=/usr/sbin:/sbin:/usr/bin:/bin; osc_main "$@"; exit $?; }
