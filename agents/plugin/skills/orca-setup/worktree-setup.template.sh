#!/usr/bin/env bash
# .orca/worktree-setup.sh — repo-specific Orca worktree delegate.
#
# Scaffolded by /orca-setup. The machines dispatcher
# (~/machines/scripts/orca-worktree-setup.sh) runs this from inside a fresh
# worktree AFTER linking the generic gitignored config set. Put this repo's own
# worktree setup here.
#
# INVARIANT: never block Orca. Every path is non-fatal; always exit 0.
# Never use the errexit option.

log() { echo ".orca/worktree-setup: $*" >&2; }

# >>> orca-setup:managed:repo-steps >>>
# Repo-specific steps go here. Examples:
#   - link an extra gitignored file the generic set misses
#   - copy a seed DB / .superpowers ledger the app needs
#   - print a ready-to-run command for the developer
# Keep every step non-fatal (guard with `|| log "WARN: ..."`).
# <<< orca-setup:managed:repo-steps <<<

# >>> orca-setup:managed:gortex-readiness >>>
# Gortex readiness (opt-in via ORCA_GORTEX=1): ensure the daemon is running so
# graph tools work from this worktree and the working agent's own
# `overlay_register {workspace_id: <slug>}` (see cyphy:worktree-agent) doesn't
# hit "cwd not covered". Does NOT register an overlay here — a fresh worktree has
# no uncommitted edits to overlay, and the agent reads its slug from its own
# session orientation.
if [ "${ORCA_GORTEX:-0}" = "1" ] && command -v gortex >/dev/null 2>&1; then
  if gortex daemon status >/dev/null 2>&1; then
    log "gortex daemon already running"
  else
    gortex daemon start --detach >/dev/null 2>&1 \
      && log "started gortex daemon" \
      || log "WARN: could not start gortex daemon"
  fi
fi
# <<< orca-setup:managed:gortex-readiness <<<

exit 0
