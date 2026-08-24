#!/usr/bin/env bash
# Shared emitters for the memory SessionStart hooks.
#
# Claude Code caps a SessionStart hook's stdout: past roughly 3.5 KB the harness
# persists the output to disk and injects only a ~2 KB preview, so the rest never
# reaches the model. Measured 2026-08-24 on 2.1.241: a 3,518 B hook passed
# through in full; 22,382 B and 142,254 B were both persisted. The limit is a
# compiled constant (MAX_PERSISTED_OUTPUT_BYTES) with no env override, and it
# applies per hook invocation, not per session.
#
# So a store that fits is emitted verbatim, and one that doesn't is emitted as an
# index — path, size and '##' headings with line numbers — which the agent reads
# on demand. Emitting everything verbatim would not be the better trade anyway:
# the four stores are ~142 KB, about 40k tokens per session, re-paid on every
# subagent dispatch.

MEM_INLINE_MAX="${MEM_INLINE_MAX:-2600}"   # bytes; emit verbatim at or under this
MEM_TOTAL_BUDGET="${MEM_TOTAL_BUDGET:-3300}"

mem_size() { wc -c <"$1" | tr -d ' '; }

mem_human() {
  awk -v b="$1" 'BEGIN{ if (b<1024) printf "%dB", b; else printf "%.0fKB", b/1024 }'
}

# mem_has_content <file> — non-empty and not whitespace-only
mem_has_content() {
  [ -s "$1" ] || return 1
  grep -q '[^[:space:]]' "$1" 2>/dev/null
}

# mem_strip_comments <file> — drop <!-- --> blocks; they are notes to the human
# curating the store, and they are charged against the hook's budget.
mem_strip_comments() {
  sed '/<!--/,/-->/d' "$1"
}

# mem_emit_full <file> <header>
mem_emit_full() {
  mem_has_content "$1" || return 0
  printf '%s\n\n' "$2"
  mem_strip_comments "$1" | sed '/./,$!d'
  printf '\n'
}

# mem_emit_index <file> <label> — path, size, and section map
mem_emit_index() {
  mem_has_content "$1" || return 0
  printf '%s (%s)\n' "$2" "$(mem_human "$(mem_size "$1")")"
  if grep -q '^## ' "$1"; then
    grep -n '^## ' "$1" | sed 's/^\([0-9]*\):## /    L\1  /'
  fi
}

# mem_warn_if_over <emitted-text> <hook-name> — stderr only, never stdout.
# Takes the TEXT, not a length: bash ${#var} counts characters, and these stores
# are largely Cyrillic at 2 bytes per character, so a character count reads ~40%
# under the real byte size the harness caps on.
mem_warn_if_over() {
  local bytes
  bytes="$(printf '%s' "$1" | wc -c | tr -d ' ')"
  [ "$bytes" -le "$MEM_TOTAL_BUDGET" ] && return 0
  set -- "$bytes" "$2"
  printf '%s: emitted %s B, over the %s B budget — Claude Code will persist this and inject only a preview. Trim core.md or drop an index.\n' \
    "$2" "$1" "$MEM_TOTAL_BUDGET" >&2
}
