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
# the exit status clean.
#
# Testable: `FLEET_SELFPULL_LIB_ONLY=1 source` loads helpers without scanning.
set -u

# Never block on a credential/host prompt (mirrors modules/system/git-autofetch).
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# Scan roots — same shape as fleet-pull.sh's REMOTE_SCRIPT.
FLEET_ROOTS="${FLEET_ROOTS:-$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly}"

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
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || { echo "SKIP not-main"; return 0; }
  [ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ] || { echo "SKIP dirty"; return 0; }

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
