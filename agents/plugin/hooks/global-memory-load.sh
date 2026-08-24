#!/usr/bin/env bash
# SessionStart hook — inject the synced global + personality facets + per-host
# memory stores into the session.
#
# Replaces the `@memory/...` imports that used to sit at the end of AGENTS.md /
# CLAUDE.md. Claude Code resolves `@file` imports, but Codex (and most other
# AGENTS.md readers) do not — so the stores are loaded through this SessionStart
# hook instead, a mechanism both tools share. Fires for EVERY session,
# independent of whether cwd is a git repo; the sibling project-memory-check.sh
# handles the per-repo store.
#
# It emits an INDEX, not the stores themselves — see lib-memory.sh for the
# measured reason (the harness truncates a large hook's stdout to a preview, so
# `cat`-ing all 142 KB meant none of it reached the model). memory/core.md is the
# always-loaded slice; everything else is read on demand.
#
# Takes the config dir as $1 (e.g. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" or
# "${CODEX_CONFIG_DIR:-$HOME/.codex}"), passed explicitly by the caller's
# hooks.json — NOT derived from this script's own path, because the same file
# is symlinked at different nesting depths for different callers (directly
# under <config_dir>/hooks/ for Codex; under <config_dir>/skills/cyphy/hooks/
# for the Claude Code cyphy plugin).
#
# Optional $2 selects a slice: all (default) | core | index. Splitting the two
# across separate hook entries buys a second budget, since the cap is per hook
# invocation.
set -u

config_dir="${1:?config dir required (pass \$\{CLAUDE_CONFIG_DIR:-\$HOME/.claude\} or similar)}"
mode="${2:-all}"

# shellcheck source=lib-memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-memory.sh"

emit_core() {
  mem_emit_full "$config_dir/memory/core.md" \
    "Memory core (synced, git-tracked, always loaded) — treat as your loaded memory:"
}

emit_index() {
  local any=""
  mem_has_content "$config_dir/memory/global.md" && any=1
  mem_has_content "$config_dir/host-memory.md" && any=1
  [ -n "$any" ] || return 0

  printf '%s\n' "Memory stores not loaded above — read a section on demand (sed -n '<L>,<next L>p' <path>) when the task touches it:"
  mem_emit_index "$config_dir/memory/global.md" "  $config_dir/memory/global.md — cross-project, every machine"
  mem_emit_index "$config_dir/host-memory.md" "  $config_dir/host-memory.md — THIS machine only"

  shopt -s nullglob
  local facets=("$config_dir"/memory/personality/*.md) f
  if [ ${#facets[@]} -gt 0 ]; then
    printf '  %s\n' "$config_dir/memory/personality/ — behavioral traits, read before writing in my voice"
    for f in "${facets[@]}"; do
      mem_has_content "$f" || continue
      printf '    %s (%s)\n' "$(basename "$f")" "$(mem_human "$(mem_size "$f")")"
    done
  fi
  shopt -u nullglob
  printf '\n'
}

out=""
case "$mode" in
  core)  out="$(emit_core)" ;;
  index) out="$(emit_index)" ;;
  all)   out="$(emit_core; emit_index)" ;;
  *)     printf 'unknown mode: %s (want all|core|index)\n' "$mode" >&2; exit 2 ;;
esac

printf '%s\n' "$out"
mem_warn_if_over "$out" "global-memory-load.sh"
