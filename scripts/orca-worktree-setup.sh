#!/usr/bin/env bash
# Orca worktree-setup dispatcher — synced source of truth in ~/machines.
#
# Orca runs this once when it spawns a new git worktree for a task, with CWD
# inside the fresh worktree. A fresh worktree carries only committed files, so it
# is missing the gitignored local config the app/tests need. This script:
#   1. Symlinks a generic gitignored config set (.env, .claude/settings.local.json)
#      from the main checkout into the worktree — universal, runs for every repo.
#   2. Delegates repo-specific setup to the first delegate found:
#        $repo_root/.orca/worktree-setup.sh                 (repo opts in, committed)
#        $HOME/machines/scripts/orca-worktree.d/<basename>.sh (machines-side registry)
#
# INVARIANT: never block Orca. Every failure path is non-fatal; this script
# always exits 0. Diagnostics go to stderr, loudly. Do NOT `set -e` here.

log() { echo "orca-worktree-setup: $*" >&2; }

# Resolve worktree root + main checkout root from CWD. If we're not inside a git
# work tree there's nothing to do — bail cleanly.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "not inside a git work tree (cwd=$PWD); nothing to do"
  exit 0
fi

wt_root=$(git rev-parse --show-toplevel 2>/dev/null) || wt_root=$PWD

# Main checkout = parent of the common git dir. --git-common-dir may be relative
# in the main worktree, so absolutize it before taking dirname (mirrors
# pure-dev's agent-worktree-setup.sh).
common=$(git rev-parse --git-common-dir 2>/dev/null) || common=""
if [ -n "$common" ]; then
  case "$common" in
    /* | [A-Za-z]:* ) : ;;
    * ) common=$(cd "$wt_root" && cd "$common" && pwd) ;;
  esac
  main_root=$(dirname "$common")
else
  main_root=$wt_root
fi

# 1. Generic: link gitignored local config. Don't clobber anything already
#    present, and treat a stale/dangling symlink as already-linked so re-runs
#    stay idempotent.
for rel in .env .claude/settings.local.json; do
  src="$main_root/$rel"
  dst="$wt_root/$rel"
  if [ -e "$src" ] && [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" \
      && log "linked $rel" \
      || log "WARN: failed to link $rel"
  fi
done

# 2. Delegation: run the first delegate found. Run inline (not exec) so a delegate
#    failure can't abort us before the final exit 0.
main_base=$(basename "$main_root")
for delegate in \
  "$wt_root/.orca/worktree-setup.sh" \
  "$HOME/machines/scripts/orca-worktree.d/$main_base.sh"; do
  if [ -f "$delegate" ]; then
    log "delegating to $delegate"
    bash "$delegate" || log "WARN: delegate $delegate exited nonzero"
    break
  fi
done

exit 0
