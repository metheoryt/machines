#!/usr/bin/env bash
# provision/gortex-autoupdate.sh — keep the fleet's PINNED gortex release current.
#
# WHAT IT AUTOMATES, AND WHY THAT AND NOTHING ELSE. gortex is already distributed
# fleet-wide by a mechanism that works: provision/gortex.version pins a release,
# tier_gortex installs exactly that release, and the pin is a reprovision trigger
# in scripts/converge.sh's _touches_driver — so a pushed bump reaches every box
# through fleet-selfpull's ff-pull and the post-merge converge. The ONLY manual
# step in that chain was bumping the pin. This script is that step on a timer,
# and deliberately nothing more: it never installs a binary, never touches
# ~/.local/bin, and never runs `gortex upgrade`. Each box still installs the pin
# through its own tier, so the fleet stays on ONE version and every bump is an
# ordinary reviewable commit.
#
# ONE WRITER, ON PURPOSE. Two boxes bumping in the same window compute the same
# new pin from the same GitHub API and produce two different commits of the same
# change; the second push is rejected non-fast-forward and the loser is left with
# a stranded commit that has to be un-wound by hand. So tier_gortex_autoupdate is
# in the `server` profile list ONLY (latitude) — always-on, and the one box that
# does not run tier_gortex at all, so what it publishes can never be biased by
# what it happens to be running.
#
# THE RISK IT TAKES, NAMED. Auto-adopting a release means a broken upstream
# release reaches every box without a human reading the changelog. Two things
# bound that: the GitHub `releases/latest` endpoint never returns drafts or
# prereleases, and GORTEX_AUTOUPDATE_MIN_AGE (48h) makes the fleet skip a release
# nobody else has shaken out yet. Neither is a substitute for `git revert` of the
# pin commit, which is the actual rollback and is why this writes a commit at all
# rather than mutating a box.
#
# EXIT STATUS: 0 for every normal outcome, INCLUDING no new release, a release
# held back by MIN_AGE, a skipped tick (repo busy / behind / diverged) and a
# failed push — all recur by design and a non-zero would paint the timer
# permanently red. Non-zero means a state that needs a human: a merge or rebase
# left in progress.
#
# Testable: `GORTEX_AUTOUPDATE_LIB_ONLY=1 source` loads the helpers without a tick.
set -u

: "${MACHINES_REPO:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${GORTEX_AUTOUPDATE_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/gortex-autoupdate}"
: "${GORTEX_AUTOUPDATE_BRANCH:=main}"
: "${GORTEX_AUTOUPDATE_SOURCE:=zzet/gortex}"

# MIN_AGE — how long a release must have existed before the fleet adopts it.
# 48h, because the failure this guards is the same-day pull-it-back release, and
# a weekly timer loses nothing by waiting. `just update-gortex` has no such gate
# ON PURPOSE: running it by hand means "I want this one now".
: "${GORTEX_AUTOUPDATE_MIN_AGE:=172800}"

# Never block on a credential or host-key prompt (mirrors dotfiles-sync.sh).
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# The ONE tracked path this script is allowed to commit. Every gate below is
# ultimately about keeping that true.
GORTEX_PIN_PATH="provision/gortex.version"

# g <git-args...>: git against the machines checkout, wherever this script lives.
g() { git -C "$MACHINES_REPO" "$@"; }

# ga_log <msg>: timers have no terminal, so stderr is the journal.
ga_log() { printf 'gortex-autoupdate: %s\n' "$*" >&2; }

# ga_lock: 0 if we hold the lock. Same shape as dotfiles-sync's sync_lock — flock
# where it exists, atomic mkdir on macOS, and a stale dir older than a day is
# swept (this timer fires weekly and its work takes seconds).
ga_lock() {
    mkdir -p "$GORTEX_AUTOUPDATE_STATE_DIR"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$GORTEX_AUTOUPDATE_STATE_DIR/lock" || return 1
        flock -n 9
        return
    fi
    local d="$GORTEX_AUTOUPDATE_STATE_DIR/lock.d"
    if [ -d "$d" ] && [ -z "$(find "$d" -maxdepth 0 -mmin -1440 2>/dev/null)" ]; then
        rmdir "$d" 2>/dev/null || true
    fi
    mkdir "$d" 2>/dev/null || return 1
    # shellcheck disable=SC2064  # expand $d now: the trap must survive unset vars
    trap "rmdir '$d' 2>/dev/null || true" EXIT
    return 0
}

# ga_guard: 0 = proceed, 1 = hard stop (needs a human), 3 = silent skip (this box
# or this checkout is simply not in a state to publish a bump right now).
#
# The pin-file-clean gate is the load-bearing one: scripts/update-gortex.sh
# REWRITES that file, so a hand-edit sitting in the work-tree would be silently
# overwritten and then committed as if the timer had produced it.
ga_guard() {
    local head
    g rev-parse --git-dir >/dev/null 2>&1 || return 3
    [ -f "$MACHINES_REPO/$GORTEX_PIN_PATH" ] || return 3
    [ -f "$MACHINES_REPO/scripts/update-gortex.sh" ] || return 3

    # Primary worktree only. A linked worktree shares the object store, so a bump
    # committed there would land on a branch nobody pushes.
    [ "$(g rev-parse --absolute-git-dir 2>/dev/null)" \
      = "$(g rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] || return 3

    if [ -e "$(g rev-parse --absolute-git-dir)/MERGE_HEAD" ] \
       || [ -d "$(g rev-parse --absolute-git-dir)/rebase-merge" ] \
       || [ -d "$(g rev-parse --absolute-git-dir)/rebase-apply" ]; then
        ga_log 'a merge or rebase is in progress in the machines checkout — bumping nothing'
        return 1
    fi

    head="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$head" = "$GORTEX_AUTOUPDATE_BRANCH" ] || return 3

    # A dirty pin file means a human is mid-bump. Leave it alone.
    g diff --quiet -- "$GORTEX_PIN_PATH" \
      && g diff --cached --quiet -- "$GORTEX_PIN_PATH" \
      || return 3
    return 0
}

# ga_pin: the pin's current value — same parse as tier_gortex and
# update-gortex.sh (first bare semver on a non-comment line).
ga_pin() {
    grep -vE '^[[:space:]]*#' "$MACHINES_REPO/$GORTEX_PIN_PATH" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# ga_release: print "<version-without-v> <published-epoch>" for the newest
# non-prerelease upstream release, or nothing. Non-zero when it can't be
# determined (offline, rate-limited, no jq) — a state, not a fault.
ga_release() {
    local json tag ts epoch
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    json="$(curl -fsSL --max-time 30 \
              "https://api.github.com/repos/${GORTEX_AUTOUPDATE_SOURCE}/releases/latest" 2>/dev/null)" \
      || return 1
    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
    ts="$(printf '%s' "$json" | jq -r '.published_at // empty')"
    [ -n "$tag" ] && [ -n "$ts" ] || return 1
    # GNU date first, BSD/macOS second — the tier is linux-only today but the
    # script is sourced by the test suite on whatever box runs it.
    epoch="$(date -u -d "$ts" +%s 2>/dev/null \
             || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)" || return 1
    [ -n "$epoch" ] || return 1
    printf '%s %s\n' "${tag#v}" "$epoch"
}

# ga_old_enough <published-epoch> [now]: 0 once MIN_AGE has passed.
ga_old_enough() {
    local pub="$1" now="${2:-}"
    [ -n "$now" ] || now="$(date -u +%s)"
    case "$pub" in ''|*[!0-9]*) return 1 ;; esac
    [ "$((now - pub))" -ge "$GORTEX_AUTOUPDATE_MIN_AGE" ]
}

# ga_sync_state: where this checkout sits relative to the remote branch. Prints
# one of: equal | behind | ahead-pin | ahead-other | diverged | unknown.
#
# ahead-pin is the retry path and the reason this is a state machine rather than
# a straight bump-and-push: an offline tick leaves a committed-but-unpushed pin
# bump, and the next tick must PUSH THAT rather than bump on top of it.
# ahead-other means somebody has unpushed work here; pushing it would be this
# timer shipping a human's WIP, so it declines.
ga_sync_state() {
    local branch="$GORTEX_AUTOUPDATE_BRANCH" local_sha remote_sha base changed
    g fetch -q origin "$branch" 2>/dev/null || { printf 'unknown\n'; return 0; }
    local_sha="$(g rev-parse HEAD 2>/dev/null || true)"
    remote_sha="$(g rev-parse FETCH_HEAD 2>/dev/null || true)"
    [ -n "$local_sha" ] && [ -n "$remote_sha" ] || { printf 'unknown\n'; return 0; }
    if [ "$local_sha" = "$remote_sha" ]; then printf 'equal\n'; return 0; fi
    base="$(g merge-base HEAD FETCH_HEAD 2>/dev/null || true)"
    if [ "$base" = "$local_sha" ]; then printf 'behind\n'; return 0; fi
    if [ "$base" = "$remote_sha" ]; then
        changed="$(g diff --name-only FETCH_HEAD..HEAD 2>/dev/null | sort -u | tr '\n' ' ')"
        if [ "$changed" = "$GORTEX_PIN_PATH " ]; then printf 'ahead-pin\n'; else printf 'ahead-other\n'; fi
        return 0
    fi
    printf 'diverged\n'
}

# ga_push: ALWAYS 0. Offline or an expired token is not a malfunction — the
# commit is safe locally and the next tick's ahead-pin path retries it.
ga_push() {
    if g push -q origin "$GORTEX_AUTOUPDATE_BRANCH" 2>/dev/null; then
        ga_log "pushed ${GORTEX_AUTOUPDATE_BRANCH} to origin"
    else
        ga_log 'push failed (offline or auth) — retrying next tick'
    fi
    return 0
}

# ga_commit <old> <new>: commit the pin and NOTHING else. `--only` is what makes
# that a guarantee rather than an intention: it commits the named path even when
# the rest of the tree (or the index) is dirty with somebody else's work.
ga_commit() {
    local old="$1" new="$2"
    g commit -q --only "$GORTEX_PIN_PATH" -F - <<EOF
chore(gortex): pin ${old} -> ${new}

Bumped by provision/gortex-autoupdate.sh on a timer. gortex.version is a
_touches_driver trigger in scripts/converge.sh, so every box installs this
release through tier_gortex on its next ff-pull.

Rollback is a revert of this commit.
EOF
}

# ga_tick: one full pass.
ga_tick() {
    local rc state cur rel new pub
    ga_guard; rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"

    state="$(ga_sync_state)"
    case "$state" in
        ahead-pin)
            ga_log 'an unpushed pin bump is already committed here — pushing that'
            ga_push
            return 0 ;;
        equal) : ;;
        *)
            # behind: fleet-selfpull's ff-pull owns that, and it also fires the
            # converge that applies the pull. Bumping from behind would commit on
            # a stale base and diverge.
            ga_log "checkout is ${state} relative to origin/${GORTEX_AUTOUPDATE_BRANCH} — skipping this tick"
            return 0 ;;
    esac

    rel="$(ga_release)" || { ga_log 'could not reach the GitHub releases API — skipping this tick'; return 0; }
    new="${rel%% *}"; pub="${rel##* }"
    cur="$(ga_pin)"
    if [ -z "$cur" ]; then
        ga_log "could not parse a version from ${GORTEX_PIN_PATH} — skipping"
        return 0
    fi
    if [ "$cur" = "$new" ]; then
        ga_log "pin already at the latest release (${cur})"
        return 0
    fi
    if ! ga_old_enough "$pub"; then
        ga_log "release ${new} is newer than GORTEX_AUTOUPDATE_MIN_AGE (${GORTEX_AUTOUPDATE_MIN_AGE}s) — holding at ${cur}"
        return 0
    fi

    # The bump itself goes through the repo's own writer, so the pin's header and
    # the parse rule have exactly one implementation.
    if ! bash "$MACHINES_REPO/scripts/update-gortex.sh" >/dev/null 2>&1; then
        ga_log 'scripts/update-gortex.sh failed — nothing committed'
        return 0
    fi
    if g diff --quiet -- "$GORTEX_PIN_PATH"; then
        ga_log "update-gortex.sh changed nothing (pin ${cur}) — nothing to commit"
        return 0
    fi
    if ! ga_commit "$cur" "$(ga_pin)"; then
        ga_log 'commit failed — leaving the bump in the work-tree'
        return 0
    fi
    ga_log "pin ${cur} -> $(ga_pin) committed"
    ga_push
    return 0
}

if [ -z "${GORTEX_AUTOUPDATE_LIB_ONLY:-}" ]; then
    ga_lock || exit 0     # another tick holds it; overlapping ticks are a no-op
    ga_tick
fi
