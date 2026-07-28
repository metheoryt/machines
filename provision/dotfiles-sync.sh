#!/usr/bin/env bash
# provision/dotfiles-sync.sh — the dotfiles sync timer body.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.1
#
# ~/.dotfiles is a BARE repo whose work-tree is $HOME. Every 10 minutes this
# commits tracked changes to this machine's branch, pushes them, and merges
# origin/main in.
#
# THE GOVERNING SAFETY PROPERTY: the work-tree is a live home directory. A
# conflicted merge would write <<<<<<< markers into ~/.ssh/config, ~/.gitconfig,
# ~/.netrc — breaking ssh and git, possibly including the ability to fix it
# remotely. This script must never leave a conflict on disk and must never start
# a merge it cannot finish. That is what step 5 (merge-tree preflight) buys.
#
# EXIT STATUS: 0 for every normal outcome, INCLUDING a detected conflict and a
# failed push — both are expected states that recur each tick, and a non-zero
# there would just paint the timer permanently red. Non-zero means a hard stop
# that needs a human: HEAD on the wrong branch, or a merge/rebase left in
# progress.
#
# Testable: `DOTFILES_SYNC_LIB_ONLY=1 source` loads helpers without a tick.
set -u

: "${DOTFILES_GIT_DIR:=$HOME/.dotfiles}"
: "${DOTFILES_WORK_TREE:=$HOME}"
: "${DOTFILES_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync}"

# Never block on a credential/host prompt (mirrors fleet-selfpull.sh).
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# df <git-args…>: git bound to the bare-repo / $HOME work-tree pair.
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$DOTFILES_WORK_TREE" "$@"; }

# git_has_mergetree: `merge-tree --write-tree` landed in git 2.38. Below that
# floor there is NO way to detect a conflict without writing markers to disk
# first, so the merge step must be skipped entirely rather than attempted.
git_has_mergetree() {
    local v maj min rest
    v="$(git --version 2>/dev/null | awk '{print $3}')"
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
    case "$maj" in ''|*[!0-9]*) return 1 ;; esac
    case "$min" in ''|*[!0-9]*) return 1 ;; esac
    [ "$maj" -gt 2 ] && return 0
    [ "$maj" -eq 2 ] && [ "$min" -ge 38 ]
}

# sync_lock: 0 if we hold the lock, non-zero if another tick does. macOS ships
# no flock(1), so fall back to an atomic mkdir. A lock dir older than 30 minutes
# is stale by construction (the timer fires every 10 and its work takes seconds),
# so sweep it rather than wedging the timer forever after a kill -9.
sync_lock() {
    mkdir -p "$DOTFILES_STATE_DIR"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$DOTFILES_STATE_DIR/lock" || return 1
        flock -n 9
        return
    fi
    local d="$DOTFILES_STATE_DIR/lock.d"
    if [ -d "$d" ] && [ -z "$(find "$d" -maxdepth 0 -mmin -30 2>/dev/null)" ]; then
        rmdir "$d" 2>/dev/null || true
    fi
    mkdir "$d" 2>/dev/null || return 1
    # shellcheck disable=SC2064  # expand $d now: the trap must survive unset vars
    trap "rmdir '$d' 2>/dev/null || true" EXIT
}

# sync_guard: echo the expected branch. 0 = proceed, 1 = hard stop (loud),
# 3 = silent skip (this box is simply not enrolled yet).
sync_guard() {
    [ -d "$DOTFILES_GIT_DIR" ] || return 3
    local expected head
    expected="$(cat "$DOTFILES_STATE_DIR/branch" 2>/dev/null || true)"
    [ -n "$expected" ] || return 3

    if [ -e "$DOTFILES_GIT_DIR/MERGE_HEAD" ] \
       || [ -d "$DOTFILES_GIT_DIR/rebase-merge" ] \
       || [ -d "$DOTFILES_GIT_DIR/rebase-apply" ]; then
        echo "dotfiles-sync: a merge or rebase is in progress — resolve it by hand" >&2
        return 1
    fi

    head="$(df rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$head" != "$expected" ]; then
        echo "dotfiles-sync: HEAD is '$head', expected '$expected' — committing nothing" >&2
        return 1
    fi
    printf '%s\n' "$expected"
}

# sync_commit <branch>: stage tracked modifications and deletions ONLY.
# `add -u` is deliberate and load-bearing: it can never stage an untracked file,
# so tracking stays an explicit act (the offer-hook surfaces candidates instead).
# Returns 0 whether or not there was anything to commit.
sync_commit() {
    local branch="$1" paths n
    df add -u || return 1
    if df diff --cached --quiet; then return 0; fi
    n="$(df diff --cached --name-only | wc -l | tr -d ' ')"
    paths="$(df diff --cached --name-only | head -5 | tr '\n' ' ')"
    paths="${paths% }"
    [ "$n" -gt 5 ] && paths="$paths … (+$((n - 5)))"
    df commit -q -m "auto($branch): $paths" || return 1
}

# sync_push <branch>: ALWAYS returns 0. Offline, an expired token, a laptop on a
# captive portal — none of those are malfunctions. The commit is already safe
# locally and the next tick retries.
sync_push() {
    if ! df push -q origin "$1" 2>/dev/null; then
        echo "dotfiles-sync: push failed (offline or auth) — retrying next tick" >&2
    fi
    return 0
}

# sync_merge <branch>: fetch origin/main, preflight the merge in the object
# store, and only then touch $HOME. ALWAYS returns 0 — a conflict is a state to
# report, not a malfunction to alarm on.
sync_merge() {
    local branch="$1" marker="$DOTFILES_STATE_DIR/conflict"

    # EXPLICIT REFSPEC, deliberately. `git clone --bare` configures no
    # remote.origin.fetch, so a bare dotfiles repo has NO refs/remotes/origin/*
    # at all and a plain `fetch origin main` lands in FETCH_HEAD only — every
    # later mention of origin/main would then fail to resolve and the merge step
    # would silently no-op forever. The role configures the refspec too; naming
    # it here keeps the timer correct on a repo cloned by hand.
    if ! df fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then
        echo "dotfiles-sync: fetch failed (offline or auth) — retrying next tick" >&2
        return 0
    fi

    # BELOW THE FLOOR: commit and push only. Attempting the merge without a
    # preflight is the one thing this script must never do.
    if ! git_has_mergetree; then
        echo "dotfiles-sync: git $(git --version | awk '{print $3}') lacks 'merge-tree --write-tree' (needs 2.38+) — skipping merge; commit and push still ran" >&2
        return 0
    fi

    # merge-tree --write-tree writes ONLY to the object store. On conflict it
    # exits non-zero having changed nothing on disk. This is the whole reason
    # the design is safe to run unattended against a live $HOME.
    if ! df merge-tree --write-tree "$branch" origin/main >/dev/null 2>&1; then
        mkdir -p "$DOTFILES_STATE_DIR"
        {
            printf 'conflict merging origin/main into %s\n' "$branch"
            printf 'detected: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'resolve by hand, then the next tick clears this file:\n'
            printf '  git --git-dir=%s --work-tree=%s merge origin/main\n' \
                   "$DOTFILES_GIT_DIR" "$DOTFILES_WORK_TREE"
        } > "$marker"
        echo "dotfiles-sync: origin/main conflicts with $branch — \$HOME untouched; see $marker" >&2
        return 0
    fi

    rm -f "$marker"
    # Preflight was clean, so this cannot conflict. It can still refuse if a
    # tracked file changed in the seconds since sync_commit ran — harmless, the
    # next tick commits that change first and then merges.
    df merge -q --no-edit --ff origin/main >/dev/null 2>&1 || true
    return 0
}

# sync_tick: one full pass — spec §5.1 steps 1-6.
sync_tick() {
    local branch rc
    branch="$(sync_guard)"; rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    sync_commit "$branch" || return 1
    sync_push "$branch"
    sync_merge "$branch"
    return 0
}

if [ -z "${DOTFILES_SYNC_LIB_ONLY:-}" ]; then
    sync_lock || exit 0     # another tick holds it; overlapping ticks are a no-op
    sync_tick
fi
