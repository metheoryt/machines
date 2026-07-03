#!/usr/bin/env bash
# SessionStart hook — inject the synced global + practices + per-host memory
# stores into the session.
#
# Replaces the `@memory/...` imports that used to sit at the end of AGENTS.md /
# CLAUDE.md. Claude Code resolves `@file` imports, but Codex (and most other
# AGENTS.md readers) do not — so the stores are loaded through this SessionStart
# hook instead, a mechanism both tools share. Fires for EVERY session,
# independent of whether cwd is a git repo; the sibling project-memory-check.sh
# handles the per-repo store.
#
# Config-dir-agnostic: derives the config dir from this script's own invocation
# path, so the same file works whether it's run from ~/.claude/hooks or
# ~/.codex/hooks. Uses the invocation path (BASH_SOURCE), NOT a symlink-resolved
# one, so it points at the config tree rather than the repo it links back to.
set -u

hooks_dir="$(dirname "${BASH_SOURCE[0]}")"
config_dir="$(dirname "$hooks_dir")"

emit() {
  # $1 = file path, $2 = header shown before its contents
  [ -s "$1" ] || return 0                       # skip missing / empty stores
  grep -q '[^[:space:]]' "$1" 2>/dev/null || return 0  # skip whitespace-only
  printf '%s\n\n' "$2"
  cat "$1"
  printf '\n'
}

emit "$config_dir/memory/global.md" \
  "Global memory (synced, git-tracked, loaded every session) — treat as your loaded memory:"
emit "$config_dir/memory/practices.md" \
  "Code practices (synced, git-tracked, loaded every session):"
emit "$config_dir/host-memory.md" \
  "Per-host memory for THIS machine (synced, git-tracked, loaded every session):"
