#!/usr/bin/env bash
# .orca/worktree-setup.sh — repo-specific Orca worktree delegate.
#
# Scaffolded by /orca-setup. The machines dispatcher
# (~/machines/agents/worktree-setup.sh) runs this from inside a fresh worktree
# AFTER it gortex-tracks the worktree (when the daemon is up) and links the generic
# gitignored config set (.env, .claude/settings.local.json). Put this repo's own
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

exit 0
