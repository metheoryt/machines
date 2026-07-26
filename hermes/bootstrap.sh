#!/usr/bin/env bash
# hermes/bootstrap.sh — symlink version-controlled Hermes config from
# <repo>/hermes/ into ~/.hermes/. Mirrors agents/bootstrap.sh pattern.
#
# Usage:
#   bash hermes/bootstrap.sh              # personal ~/.hermes
#   PROFILE=work bash hermes/bootstrap.sh # profile ~/.hermes/profiles/work/
#
# Sources shared link/copy_managed/hash_file/link_entries_into helpers from
# agents/bootstrap.sh (BOOTSTRAP_LIB_ONLY=1) — stays DRY, single implementation.
#
# config.yaml is copy_managed (NOT a symlink): Hermes self-writes it (hermes
# config set …), so a symlink would dirty the tracked repo file. Same rationale
# as agents/settings.json for Claude Code. The srchash stamp prevents churn:
# re-seeds only when the committed baseline changes.
#
# Skills + memory entries are individual symlinks so machine-local additions
# coexist with tracked ones.
set -u

# ── Source shared helpers from agents/bootstrap.sh ────────────────────────────
BOOTSTRAP_LIB_ONLY=1 . "$(dirname "${BASH_SOURCE[0]}")/../agents/bootstrap.sh"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PROFILE="${PROFILE:-}"

if [ -n "$PROFILE" ]; then
  HERMES_HOME="$HOME/.hermes/profiles/$PROFILE"
  mkdir -p "$HERMES_HOME"
fi

# Override the sourced script's CLAUDE_DIR / BAK_ROOT so backup_target() and
# the other helpers compute paths relative to HERMES_HOME, not ~/.claude.
CLAUDE_DIR="$HERMES_HOME"
BAK_ROOT="$HERMES_HOME/.bootstrap-bak"

printf 'Bootstrapping Hermes config\n  repo:  %s\n  live:  %s\n\n' "$SRC_DIR" "$HERMES_HOME"

# ── config.yaml — copy_managed, NOT symlink ───────────────────────────────────
# Hermes writes to config.yaml at runtime (hermes config set …). A symlink would
# route those writes into the tracked repo file and dirty the working tree.
# copy_managed with a srchash stamp re-seeds only when the committed baseline
# changes; local edits between baseline changes survive.
if [ -f "$SRC_DIR/config.yaml" ]; then
  copy_managed "$SRC_DIR/config.yaml" "$HERMES_HOME/config.yaml"
else
  printf '  ! no hermes/config.yaml in repo — skipping\n'
fi

# ── SOUL.md — link if present ─────────────────────────────────────────────────
link "$SRC_DIR/SOUL.md" "$HERMES_HOME/SOUL.md"

# ── Statusline script — link for shell prompt integration ─────────────────────
link "$SRC_DIR/hermes-statusline.sh" "$HERMES_HOME/hermes-statusline.sh"

# ── Skills — individual symlinks per tracked skill dir ────────────────────────
link_entries_into "$SRC_DIR/skills" "$HERMES_HOME/skills"

# ── Memory — individual symlinks per tracked memory entry ─────────────────────
link_entries_into "$SRC_DIR/memories" "$HERMES_HOME/memories"

# ── Cleanup ───────────────────────────────────────────────────────────────────
[ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null

if [ -n "${DRY_RUN:-}" ]; then
  printf '\n(dry-run) would-link=%d  would-back-up=%d  already-linked=%d\n' \
    "$would_link" "$would_backup" "$skipped"
else
  printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
    "$linked" "$skipped" "$backed" "$failed"
fi
[ -d "$BAK_ROOT" ] && printf 'Previous real files saved under %s\n' "$BAK_ROOT"
[ "${failed:-0}" -gt 0 ] && exit 1
