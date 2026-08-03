#!/usr/bin/env bash
# provision/fleet-selfpull.sh — Trigger B (eventual). For each personal
# fleet-sync repo under the scan roots, if safe, fast-forward it to origin/main.
# The pull fires the repo's own post-merge hook (only machines has converge.sh),
# so this script NEVER converges — it only keeps checkouts fresh. On NixOS there
# is no post-merge hook, but the HEAD movement trips machines-converge.path
# (PathChanged on .git/logs/HEAD), so convergence still fires there.
# Excludes work repos (thepureapp/). Mirrors modules/system/git-autofetch (scan).
#
# EXIT STATUS IS MEANINGFUL: non-zero if any repo hit a real error (unreachable
# remote / bad credential). It used to always exit 0, which made a dead
# credential indistinguishable from "everything current" — the same silent
# failure that let latitude sit 23 commits behind while systemd reported
# success. Deliberate skips (not-main, dirty, diverged) are NOT errors and keep
# the exit status clean — with ONE refinement added 2026-08-03: a repo that skips
# as dirty for FLEET_SELFPULL_DIRTY_LIMIT consecutive ticks reports `STALE dirty`
# and exits non-zero. The skip is still not the error; the streak is. See the
# dirty-streak block below for the incident that motivated it.
#
# NOTE the Windows counterpart provision/fleet-selfpull.ps1 has NOT been given
# this, and has no test coverage at all (review item 20). desktop's clone can
# still freeze silently.
#
# Testable: `FLEET_SELFPULL_LIB_ONLY=1 source` loads helpers without scanning.
set -u

# Never block on a credential/host prompt (mirrors modules/system/git-autofetch).
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# Scan roots — same shape as fleet-pull.sh's REMOTE_SCRIPT.
FLEET_ROOTS="${FLEET_ROOTS:-$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly}"

# ── dirty-streak state ────────────────────────────────────────────────────────
# A single dirty tick is normal (someone is mid-edit) and stays a skip. A repo
# dirty for HOURS while the fleet moves is a fault, and it used to be invisible:
# desktop-wsl sat 28 commits behind for ~35 hours on one untracked zero-byte
# .zed/tasks.json, with 185 consecutive `SKIP dirty` lines in the journal and a
# green unit the whole time. One of the unpulled commits revoked an SSH key.
#
# So this counts CONSECUTIVE dirty ticks per repo and escalates on persistence.
# That refines the "skips are not errors" contract above rather than reversing
# it — the error is the streak, not the skip.
#
# Outside the repo on purpose (XDG state, like dotfiles-sync's): a state file
# inside a checkout would make the tree dirty, which is the condition being
# measured.
FLEET_SELFPULL_STATE="${FLEET_SELFPULL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet-selfpull}"
# 36 ticks ≈ 6h at the 10-minute cadence. Deliberately generous: a false alarm
# teaches people to ignore the signal, which is how 185 lines went unread.
: "${FLEET_SELFPULL_DIRTY_LIMIT:=36}"

# _streak_file <dir> — one state file per repo, name-mangled to a safe basename.
_streak_file() {
  local safe="${1//[^A-Za-z0-9._-]/_}"
  printf '%s/dirty-%s' "$FLEET_SELFPULL_STATE" "$safe"
}

# _streak_bump <dir> — increment and echo this repo's consecutive-dirty count.
# Unwritable state must not break pulling, so a failure degrades to "1" (never
# escalates) rather than aborting the run.
_streak_bump() {
  local f n
  f="$(_streak_file "$1")"
  mkdir -p "$FLEET_SELFPULL_STATE" 2>/dev/null || { echo 1; return 0; }
  n="$(cat "$f" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" > "$f" 2>/dev/null || { echo 1; return 0; }
  echo "$n"
}

# _streak_clear <dir> — a repo that is no longer dirty starts over. Without this
# one historical stall would mark a repo forever and the signal becomes noise.
_streak_clear() { rm -f "$(_streak_file "$1")" 2>/dev/null || :; }

# is_fleet_repo <dir>: git repo, origin not thepureapp/, has a tracked upstream.
is_fleet_repo() {
  local d="$1" o
  { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || return 1
  o="$(git -C "$d" remote get-url origin 2>/dev/null)" || return 1
  case "$o" in *thepureapp/*) return 1 ;; esac
  git -C "$d" rev-parse '@{u}' >/dev/null 2>&1 || return 1
  return 0
}

# selfpull_one <dir>: gate (main, clean), fetch, then fast-forward. Prints one
# status token. Returns non-zero ONLY for a real error, so the caller can tell
# "could not reach the remote" from "nothing to do".
#
# fetch and merge are split deliberately. The old single `git pull --ff-only`
# reported every failure as "SKIP diverged", so an auth failure was filed as a
# branch-topology fact — indistinguishable from a genuine non-ff and invisible in
# the exit status.
selfpull_one() {
  local d="$1" before after
  # not-main deliberately does NOT feed the dirty streak and never escalates:
  # working on a feature branch is a visible choice the user made, and painting
  # the unit red for the life of every branch is the false alarm that teaches
  # people to ignore the signal.
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || { echo "SKIP not-main"; return 0; }

  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    local n; n="$(_streak_bump "$d")"
    if [ "$n" -ge "$FLEET_SELFPULL_DIRTY_LIMIT" ]; then
      printf 'fleet-selfpull: %s dirty for %s consecutive ticks — still not pulling. Clean the tree or ignore the stray path.\n' \
        "$d" "$n" >&2
      echo "STALE dirty ${n}t"
      return 1
    fi
    echo "SKIP dirty"
    return 0
  fi
  _streak_clear "$d"

  # Retry once: git-autofetch fetches the same repos on its own timer, and two
  # concurrent fetches make the loser die with
  #   cannot lock ref 'refs/remotes/origin/main': is at X but expected Y
  # That race is self-correcting (the other fetch updates the ref we want), so it
  # must not be reported as an error.
  if ! git -C "$d" fetch --quiet origin main 2>/dev/null; then
    sleep 5
    if ! git -C "$d" fetch --quiet origin main 2>/dev/null; then
      echo "FAIL fetch"; return 1
    fi
  fi

  before="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
  if git -C "$d" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then
    after="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
    [ "$before" = "$after" ] && echo "OK up-to-date" || echo "OK $before..$after"
    return 0
  fi
  # Local commits or a rewritten upstream — a real state to resolve by hand, but
  # not a malfunction of this script.
  echo "SKIP diverged"
  return 0
}

# selfpull_all: returns non-zero if ANY repo reported a real error.
selfpull_all() {
  local root d st rc=0
  for root in $FLEET_ROOTS; do
    [ -d "$root" ] || continue
    for d in "$root" "$root"/*; do
      is_fleet_repo "$d" || continue
      st="$(selfpull_one "$d")" || rc=1
      printf '%s\t%s\n' "$d" "$st"
    done
  done
  return "$rc"
}

[ -n "${FLEET_SELFPULL_LIB_ONLY:-}" ] || selfpull_all
