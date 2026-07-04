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
# Takes the config dir as $1 (e.g. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" or
# "${CODEX_CONFIG_DIR:-$HOME/.codex}"), passed explicitly by the caller's
# hooks.json — NOT derived from this script's own path, because the same file
# is symlinked at different nesting depths for different callers (directly
# under <config_dir>/hooks/ for Codex; under <config_dir>/skills/cyphy/hooks/
# for the Claude Code cyphy plugin).
set -u

config_dir="${1:?config dir required (pass \$\{CLAUDE_CONFIG_DIR:-\$HOME/.claude\} or similar)}"

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
