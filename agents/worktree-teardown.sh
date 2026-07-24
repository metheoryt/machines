#!/usr/bin/env bash
# Global worktree DELETE dispatcher (personal fleet; wired into Orca's Delete-worktree hook,
# or run by hand from inside a worktree before removal). Two brackets, reverse order of setup:
#   1. the repo's own local teardown script FIRST (reclaims shared-stack footprint while
#      gortex still covers the worktree; teardown doesn't need gortex).
#   2. gortex untrack this worktree + reconcile: prune any tracked config path gone from disk
#      (catches worktrees removed outside the IDE — `git worktree remove`, `rm -rf`).
# Guarded on `gortex daemon status`; no-op when the daemon is down. Always exits 0.
set -u

CONFIG="${GORTEX_CONFIG:-$HOME/.config/gortex/config.yaml}"

log() { printf '[worktree-teardown] %s\n' "$*" >&2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "not inside a git work tree; nothing to do"; exit 0;
}

wt_root=$(git rev-parse --show-toplevel)

# 1. Repo-local teardown FIRST (first executable candidate wins).
for rel in .orca/worktree-teardown.sh docker/worktree-teardown.sh .worktree/teardown.sh scripts/worktree-teardown.sh; do
  cand="$wt_root/$rel"
  if [ -x "$cand" ]; then
    log "running repo-local teardown: $rel"
    ( cd "$wt_root" && "$cand" ) || log "repo-local teardown exited $? (non-fatal)"
    break
  fi
done

# 2. gortex untrack + reconcile (guarded).
if ! command -v gortex >/dev/null 2>&1; then
  log "gortex not installed; skipping untrack/reconcile"; exit 0
fi
if ! gortex daemon status >/dev/null 2>&1; then
  log "gortex daemon down; skipping untrack/reconcile"; exit 0
fi

if gortex untrack "$wt_root" >/dev/null 2>&1; then
  log "untracked worktree $wt_root"
fi

# Reconcile: prune any tracked path whose directory no longer exists on disk.
if [ -f "$CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"- path:"*) : ;;
      *) continue ;;
    esac
    p=${line#*path:}
    p=$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    [ -n "$p" ] || continue
    if [ ! -d "$p" ]; then
      if gortex untrack "$p" >/dev/null 2>&1; then
        log "reconcile: pruned missing path $p"
      fi
    fi
  done < "$CONFIG"
fi

exit 0
