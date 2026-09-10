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
  instructions               TSV of every auto-loaded CLAUDE.md/AGENTS.md, same columns
  branches                   TSV of OTHER boxes' memory, read from dotfiles branches:
                             branch, tip date, path, bytes (read-only, never written)
  index <file>               TSV of a store's ## sections: line, bytes, heading
  id <target> <anchor> <action>
                             8-hex stable item id (target+anchor+action)
  status <id>                new | open | decided<TAB>applied|rejected
  append <id> <item-file>    append an item to the queue unless already open/decided
  decide <id> <state> <reason> [file] [phrase]
                             record applied|rejected in the ledger and cut the
                             item out of the queue (used by /dream-apply).
                             file+phrase let `verify` re-check it later.
  verify                     for every applied decision: ok | drifted | missing
                             | unverifiable — did the change actually stay?

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
      "$(awk '/^## /{n++} END{print n+0}' "$f")"
  done
}

# Auto-loaded instruction files. Not memory stores — RULES, and a rule is
# deleted on different evidence than a fact. Separate subcommand rather than a
# column on `scan` so nothing can treat the two as one population.
# CLAUDE.md is a symlink to AGENTS.md in some repos: resolve and dedupe, or the
# same file is reported (and proposed against) twice.
cmd_instructions() {
  local f real
  local -a seen=()
  for f in \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/CLAUDE.md" \
    "$HOME"/*/CLAUDE.md "$HOME"/*/AGENTS.md \
    "$HOME"/*/*/CLAUDE.md "$HOME"/*/*/AGENTS.md
  do
    [ -f "$f" ] || continue
    real="$(readlink -f "$f")"
    case " ${seen[*]-} " in *" $real "*) continue ;; esac
    seen+=("$real")
    printf '%s\t%s\t%s\t%s\n' \
      "$real" "$(wc -c <"$real" | tr -d ' ')" "$(_scope "$real")" \
      "$(awk '/^## /{n++} END{print n+0}' "$real")"
  done
}

# Every other box's memory is READABLE from right here: the dotfiles bare repo
# holds all branches, so `cat-file` reaches latitude's, air's, g15's, hub's and
# both desktop sides' host-memory without touching the network or those boxes.
# It is NOT writable from here — see SKILL.md. Retired boxes still have branches
# (origin/server, origin/g15-wsl), and a retired branch can be the last copy of
# a fact, which is exactly why this lists them instead of filtering them out.
# Columns: branch, tip date, path, bytes.
cmd_branches() {
  local b date
  for b in $(git --git-dir="$HOME/.dotfiles" for-each-ref \
               --format='%(refname:short)' refs/remotes/origin \
             | grep -vx 'origin\|origin/main' | sort); do
    date="$(git --git-dir="$HOME/.dotfiles" log -1 --format=%cs "$b" 2>/dev/null || echo '?')"
    git --git-dir="$HOME/.dotfiles" ls-tree -r -l "$b" 2>/dev/null \
      | awk -v b="$b" -v d="$date" '
          $5 ~ /(^|\/)\.claude\/(host-memory\.md|memory\/.*\.md)$/ ||
          $5 ~ /(^|\/)CLAUDE\.md$/ { printf "%s\t%s\t%s\t%s\n", b, d, $5, $4 }'
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

# ok | drifted | missing | unverifiable, one row per applied decision.
cmd_verify() {
  [ -f "$LEDGER" ] || return 0
  local id state file phrase
  while IFS=$'\t' read -r id state _ _ file phrase; do
    [ "$state" = applied ] || continue
    if [ -z "$file" ] || [ -z "$phrase" ]; then
      printf 'unverifiable\t%s\t-\n' "$id"
    elif [ ! -f "$file" ]; then
      printf 'missing\t%s\t%s\n' "$id" "$file"
    elif grep -qF -- "$phrase" "$file"; then
      printf 'ok\t%s\t%s\n' "$id" "$file"
    else
      printf 'drifted\t%s\t%s\n' "$id" "$file"
    fi
  done < "$LEDGER"
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

# The ledger's last two columns are what makes an applied decision auditable
# later: the file it landed in and a phrase that must still be found there.
# /improve's prior-run cross-check is the idea — "accepted" is not the same as
# "still there", and this repo keeps finding the gap between them.
cmd_decide() {
  local id="$1" state="$2" reason="${3:-}" file="${4:-}" phrase="${5:-}"
  case "$state" in applied|rejected) ;; *) echo "dream: state must be applied|rejected" >&2; exit 2 ;; esac
  mkdir -p "$DREAM_ROOT"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "$(date +%F)" "$reason" "$file" "$phrase" >> "$LEDGER"
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
  instructions) shift; cmd_instructions "$@" ;;
  branches) shift; cmd_branches "$@" ;;
  index)  shift; cmd_index "$@" ;;
  id)     shift; cmd_id "$@" ;;
  status) shift; cmd_status "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  append) shift; cmd_append "$@" ;;
  decide) shift; cmd_decide "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "dream: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
