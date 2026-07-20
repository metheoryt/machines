#!/usr/bin/env bash
# provision/fleet-selfpull.sh — Trigger B (eventual). For each personal
# fleet-sync repo under the scan roots, if safe, `git pull --ff-only origin main`.
# The pull fires the repo's own post-merge hook (only machines has converge.sh),
# so this script NEVER converges — it only keeps checkouts fresh. Excludes work
# repos (thepureapp/). Mirrors modules/system/git-autofetch (scan) +
# self-update.nix (gates). Always exits 0.
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

# selfpull_one <dir>: gate (main, clean, ff) then pull. Prints one status token.
selfpull_one() {
  local d="$1" before after
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || { echo "SKIP not-main"; return 0; }
  [ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ] || { echo "SKIP dirty"; return 0; }
  before="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
  if git -C "$d" pull --ff-only origin main >/dev/null 2>&1; then
    after="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
    [ "$before" = "$after" ] && echo "OK up-to-date" || echo "OK $before..$after"
  else
    echo "SKIP diverged"
  fi
}

selfpull_all() {
  local root d
  for root in $FLEET_ROOTS; do
    [ -d "$root" ] || continue
    for d in "$root" "$root"/*; do
      is_fleet_repo "$d" || continue
      printf '%s\t%s\n' "$d" "$(selfpull_one "$d")"
    done
  done
}

[ -n "${FLEET_SELFPULL_LIB_ONLY:-}" ] || selfpull_all
