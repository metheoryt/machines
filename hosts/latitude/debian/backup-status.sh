#!/usr/bin/env bash
# backup-status.sh — one row per backup job, for the status board and for agents.
#
# THE ENABLING TRICK, and it is what makes this cheap enough to run every 15
# minutes: a restic repository's newest snapshot age is readable from
# <repo>/snapshots/ FILE MTIMES. No restic binary, no password, no repository
# lock. latitude is the hub, so it can see every pusher's repo — its own,
# g16-wsl's and g15's — from the filesystem.
#
# WHY IT IS A SEPARATE SCRIPT FROM THE BOARD. The board repaints every second and
# this walks four directories; and an agent, a timer or a human at a terminal all
# want the same rows. One implementation of "is the backup fresh", not two that
# drift — the same argument role_backup_hub makes for the hub selfcheck.
#
# SEVERITY IS KEYED ON A DECLARED PERIOD, NOT ON PERIODICITY. Observed
# periodicity would put Debian's nine housekeeping timers on the page and would
# have nothing to say about a weekly job. Each job declares what it promises in
# provision/statusboard/backup-jobs.<hostname>.conf; missing it once is `late`,
# twice is `stale`.
#
# AND SNAPSHOT AGE IS A CLIENT-LIVENESS SIGNAL TOO. A repo goes stale when the
# repo is broken AND when the box that writes to it is merely switched off. The
# hub selfcheck's check 8 has exactly this property and is documented as unusable
# as a sentinel for that reason. It is kept here anyway because for the OFFSITE
# job the confound is the point — an offsite copy that has stopped receiving is a
# problem whichever end caused it — and because the offsite row is corroborated
# by the box's own pushed status (see the `offsite` job below).

STATE_DIR=${BACKUP_STATUS_STATE_DIR:-/var/lib/fleet-backup}
JOBS_CONF=${BACKUP_STATUS_JOBS:-}

# ── pure helpers (unit-tested by provision/tests/backup-offsite.test.sh) ──────

# ok | late | stale | unknown, from an age in seconds and a declared period.
# One missed run is `late` (a warning); two is `stale` (a failure). An age that
# cannot be read is `unknown` — NOT ok, because silence is the failure mode this
# whole script exists to catch.
bs_age_state() {
    local age="${1:-}" period="${2:-}"
    case "$age" in '' | *[!0-9]*) echo unknown; return ;; esac
    case "$period" in '' | *[!0-9]*) echo unknown; return ;; esac
    if [ "$age" -le "$period" ]; then echo ok
    elif [ "$age" -le $((period * 2)) ]; then echo late
    else echo stale; fi
}

# Newest mtime under a directory, epoch seconds. Empty if unreadable or empty —
# an empty snapshots/ dir is a repository that has never received anything, which
# must not read as "age 0, fresh".
bs_newest_mtime() {
    local dir="${1:-}" newest
    [ -d "$dir" ] || return 0
    newest="$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
    [ -n "$newest" ] || return 0
    # LC_NUMERIC=C: find's %T@ always uses a '.' decimal point, but printf's
    # %.0f parses its argument in the locale's own numeric convention. On a
    # non-C locale (this fleet runs ru_RU.UTF-8 on at least one box) that
    # mismatch makes printf reject an otherwise-valid number, so pin it here
    # rather than depend on the caller's environment.
    LC_NUMERIC=C printf '%.0f\n' "$newest"
}

# bs_json_escape <s>: a JSON string body — `\` and `"` escaped, control
# characters and newlines flattened. `detail` reaches --json from a status file
# this box does not write and from jobs.conf, so one double quote in it used to
# emit invalid JSON to every consumer.
#
# DONE IN SHELL, NOT IN awk's gsub, and that is not a style choice: the awk
# replacement string's backslash handling DIFFERS BETWEEN THE TWO awks this
# fleet has. Measured 2026-09-12 on mawk 1.3.4 — `gsub(/\\/, "\\\\", r)`
# leaves both backslashes, while gawk collapses them to one per POSIX. A helper
# whose output depends on which awk `/etc/alternatives/awk` points at is not a
# JSON escaper.
bs_json_escape() {
    printf '%s' "${1:-}" |
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
        tr '\n\r\t' '   ' |
        tr -d '\000-\037'
}

# bs_status_verdict <file>: ok | notok | unreadable — the CONTENTS' verdict,
# read WITHOUT reference to the file's freshness. A file that cannot be parsed
# is its own state: "ok":true absent is not the same thing as "ok":false, and a
# status file that is neither (truncated, half-written, corrupted) must not fall
# into whichever of the two happens to be the quiet one.
bs_status_verdict() {
    local f="${1:-}"
    [ -r "$f" ] || { echo unreadable; return 0; }
    if grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$f"; then echo ok
    elif grep -q '"ok"[[:space:]]*:[[:space:]]*false' "$f"; then echo notok
    else echo unreadable; fi
}

# bs_status_state <verdict> <age-state>: the row's state, from the two
# INDEPENDENT conditions on one status file.
#
# THE BUG THIS REPLACES IS A SEVERITY INVERSION, inside the severity policy this
# feature exists to implement. The contents check used to be gated on
# `[ "$state" = ok ]`, so a status file 3 h old reporting ok:false rendered
# `late` -> `warn:offsite late 3h`, while the SAME FILE fresh rendered `bad`.
# The worse input produced the milder alert, and the freshness state — the one
# thing that is never a verdict about the data — was what silenced it.
#
# So: a verdict that is not `ok` is `bad` at any age, and an `ok` verdict still
# carries its freshness through unchanged. Neither can mask the other.
bs_status_state() {
    case "${1:-}" in
        ok) case "${2:-}" in '') echo unknown ;; *) echo "$2" ;; esac ;;
        *)  echo bad ;;
    esac
}

# ── main ─────────────────────────────────────────────────────────────────────

bs_main() {
    local json=0 now name path period kind mtime age state detail rows=""
    local agest verdict sep jn ja jp js jd
    [ "${1:-}" = "--json" ] && json=1
    now="$(date +%s)"

    if [ -z "$JOBS_CONF" ]; then
        JOBS_CONF="$(dirname "${BASH_SOURCE[0]}")/../../../provision/statusboard/backup-jobs.$(hostname -s).conf"
    fi
    [ -f "$JOBS_CONF" ] || { echo "no jobs conf: $JOBS_CONF" >&2; return 2; }

    while read -r kind name path period; do
        case "$kind" in '' | \#*) continue ;; esac
        detail=""
        case "$kind" in
            repo)
                # A `nofail` mount that is absent leaves an empty directory, so
                # the repo's own config object is the existence test, not the path.
                if [ ! -f "$path/config" ]; then
                    state=bad; age=""; detail="repo missing"
                else
                    mtime="$(bs_newest_mtime "$path/snapshots")"
                    if [ -z "$mtime" ]; then
                        state=bad; age=""; detail="no snapshots"
                    else
                        age=$((now - mtime)); state="$(bs_age_state "$age" "$period")"
                    fi
                fi
                ;;
            status)
                # A status file PULLED from another box. Its own freshness is the
                # liveness signal for that box, and its contents are the verdict —
                # two distinct conditions on one file, so "check failed" stays
                # distinguishable from "link down". An absent or unreadable status
                # file is `unknown`, never an error and never `bad`: the file is
                # delivered by a later task, so on every box today it is simply
                # not there yet, and that must not read as a broken backup.
                if [ ! -r "$path" ]; then
                    state=unknown; age=""; detail="no status file"
                else
                    mtime="$(stat -c %Y "$path" 2>/dev/null)"
                    if [ -z "$mtime" ]; then
                        state=unknown; age=""; detail="no status file"
                    else
                        age=$((now - mtime))
                        agest="$(bs_age_state "$age" "$period")"
                        verdict="$(bs_status_verdict "$path")"
                        state="$(bs_status_state "$verdict" "$agest")"
                        case "$verdict" in
                            ok) detail="" ;;
                            notok)
                                detail="$(sed -n 's/.*"detail"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -1)"
                                [ -n "$detail" ] || detail="reported not ok"
                                ;;
                            *)  detail="status file unparseable" ;;
                        esac
                        # Freshness still has to reach the row once the verdict
                        # has forced it to `bad`, or a copy that is BOTH failing
                        # and no longer being updated reads as merely failing.
                        [ "$state" = bad ] && [ "$agest" != ok ] &&
                            detail="$detail (also $agest)"
                    fi
                fi
                ;;
            *) state=unknown; age=""; detail="unknown kind '$kind'" ;;
        esac
        rows="$rows$name|${age:-}|$period|$state|$detail
"
    done < "$JOBS_CONF"

    mkdir -p "$STATE_DIR"
    printf '%s' "$rows" > "$STATE_DIR/rows"
    if [ "$json" = 1 ]; then
        # One row at a time, in shell. See bs_json_escape's own header for why
        # the escaping is not awk's job.
        printf '[\n'
        sep=""
        while IFS='|' read -r jn ja jp js jd; do
            [ -n "$jn" ] || continue
            case "$jp" in '' | *[!0-9]*) jp=null ;; esac
            printf '%s  {"name":"%s","age":"%s","period":%s,"state":"%s","detail":"%s"}\n' \
                "$sep" "$(bs_json_escape "$jn")" "$(bs_json_escape "$ja")" \
                "$jp" "$(bs_json_escape "$js")" "$(bs_json_escape "$jd")"
            sep=","
        done <<< "$rows"
        printf ']\n'
    else
        printf '%s' "$rows"
    fi
    return 0
}

# Sourceable: the suite sources this file (BACKUP_STATUS_LIB_ONLY=1) to drive the
# pure helpers above with no side effects — the runtime PATH hardening and
# `set -uo pipefail` therefore live in this executed branch, not at file top, so
# sourcing never clobbers the test shell's own PATH or pipefail setting.
[ -n "${BACKUP_STATUS_LIB_ONLY:-}" ] || { set -uo pipefail; export PATH=/usr/sbin:/sbin:/usr/bin:/bin; bs_main "$@"; exit $?; }
