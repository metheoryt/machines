#!/usr/bin/env bash
# Mechanics for the /dream skill: discover the memory stores, index them, and
# enforce the decision queue's identity + suppression rules.
#
# The judgement lives in SKILL.md. Everything here is deterministic, so it can
# be tested and so an unattended nightly run cannot re-derive it wrong.
#
# INVARIANT — the whole point of the skill: this script writes ONLY under
# $DREAM_ROOT. It never touches a memory store, a transcript, or kb-refresh's
# watermark. Read paths are read-only by construction (cat/awk/wc).
set -euo pipefail

DREAM_ROOT="${DREAM_ROOT:-$HOME/machines/docs/dream}"
QUEUE="$DREAM_ROOT/queue.md"
LEDGER="$DREAM_ROOT/ledger.tsv"
RUNS="$DREAM_ROOT/runs"

_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# Absolute pathspecs only. A relative pathspec against the bare repo silently
# matches nothing and reads as "identical" / "untracked" — that has produced a
# wrong answer here twice.
_dotfiles() { git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" "$@"; }

usage() {
  cat <<'USAGE'
usage: dream.sh <command> [args]

  paths                      print queue/ledger/runs locations
  scan                       TSV of every memory store: path, bytes, scope, sections
  index <file>               TSV of a store's ## sections: line, bytes, heading
  id <target> <anchor> <action>
                             8-hex stable item id (target+anchor+action)
  status <id>                new | open | decided<TAB>applied|rejected
  append <id> <item-file>    append an item to the queue unless already open/decided
  decide <id> <state> <reason>
                             record applied|rejected in the ledger and cut the
                             item out of the queue (used by /dream-apply)

Env: DREAM_ROOT (default $HOME/machines/docs/dream)
USAGE
}

cmd_paths() {
  printf 'root\t%s\nqueue\t%s\nledger\t%s\nruns\t%s\n' \
    "$DREAM_ROOT" "$QUEUE" "$LEDGER" "$RUNS"
}

# shared = on dotfiles origin/main (a change there is fleet-wide)
# host   = tracked by dotfiles, this branch only
# repo:<name> = tracked by its own checkout
# untracked = has no home at all; that is itself a finding
_scope() {
  local p="$1"
  if _dotfiles ls-files --error-unmatch "$p" >/dev/null 2>&1; then
    local rel="${p#"$HOME"/}"
    if _dotfiles cat-file -e "origin/main:$rel" 2>/dev/null; then echo shared; else echo host; fi
    return
  fi
  local top
  if top="$(git -C "$(dirname "$p")" rev-parse --show-toplevel 2>/dev/null)"; then
    if git -C "$top" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
      echo "repo:$(basename "$top")"; return
    fi
  fi
  echo untracked
}

cmd_scan() {
  local f
  # Discovered by glob, never hardcoded: a store added later must show up on
  # its own. Depth 2 under $HOME covers ~/machines and ~/pure/backend-api.
  for f in \
    "$HOME/.claude/memory/core.md" \
    "$HOME/.claude/memory/global.md" \
    "$HOME/.claude/host-memory.md" \
    "$HOME"/.claude/memory/personality/*.md \
    "$HOME"/*/.claude/memory/project.md \
    "$HOME"/*/*/.claude/memory/project.md
  do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\t%s\n' \
      "$f" "$(wc -c <"$f" | tr -d ' ')" "$(_scope "$f")" \
      "$(grep -c '^## ' "$f" 2>/dev/null || echo 0)"
  done
}

cmd_index() {
  awk '
    /^## / { if (h != "") printf "%d\t%d\t%s\n", ln, bytes, h; h = substr($0, 4); ln = NR; bytes = 0 }
    { bytes += length($0) + 1 }
    END { if (h != "") printf "%d\t%d\t%s\n", ln, bytes, h }
  ' "$1"
}

cmd_id() {
  printf '%s\037%s\037%s' "$1" "$2" "$3" | _sha | cut -c1-8
}

cmd_status() {
  local id="$1" state
  if [ -f "$LEDGER" ]; then
    state="$(awk -F'\t' -v i="$id" '$1 == i { print $2 }' "$LEDGER" | tail -1)"
    if [ -n "$state" ]; then printf 'decided\t%s\n' "$state"; return 0; fi
  fi
  if [ -f "$QUEUE" ] && grep -q "^## $id " "$QUEUE"; then printf 'open\t-\n'; return 0; fi
  printf 'new\t-\n'
}

cmd_append() {
  local id="$1" src="$2" st
  st="$(cmd_status "$id" | cut -f1)"
  if [ "$st" != new ]; then
    printf 'suppressed\t%s\t%s\n' "$id" "$(cmd_status "$id" | tr '\t' ':')"
    return 0
  fi
  head -1 "$src" | grep -q "^## $id " || {
    echo "dream: item file must start with '## $id '" >&2; exit 2; }
  mkdir -p "$DREAM_ROOT"
  if [ ! -f "$QUEUE" ]; then
    cat > "$QUEUE" <<'HDR'
# dream — open decisions

Written by `/dream`, applied by `/dream-apply`. **Append-only from the run's
side**: a run never rewrites or reorders an existing item, so notes added by
hand survive. An item leaves this file only through `dream.sh decide`.
HDR
  fi
  printf '\n' >> "$QUEUE"
  cat "$src" >> "$QUEUE"
  printf 'appended\t%s\n' "$id"
}

cmd_decide() {
  local id="$1" state="$2" reason="${3:-}"
  case "$state" in applied|rejected) ;; *) echo "dream: state must be applied|rejected" >&2; exit 2 ;; esac
  mkdir -p "$DREAM_ROOT"
  printf '%s\t%s\t%s\t%s\n' "$id" "$state" "$(date +%F)" "$reason" >> "$LEDGER"
  if [ -f "$QUEUE" ] && grep -q "^## $id " "$QUEUE"; then
    awk -v i="$id" '
      $0 ~ "^## " i " " { cut = 1; next }
      cut && /^## / { cut = 0 }
      !cut { print }
    ' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  fi
  printf 'decided\t%s\t%s\n' "$id" "$state"
}

case "${1:-}" in
  paths)  shift; cmd_paths "$@" ;;
  scan)   shift; cmd_scan "$@" ;;
  index)  shift; cmd_index "$@" ;;
  id)     shift; cmd_id "$@" ;;
  status) shift; cmd_status "$@" ;;
  append) shift; cmd_append "$@" ;;
  decide) shift; cmd_decide "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "dream: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
