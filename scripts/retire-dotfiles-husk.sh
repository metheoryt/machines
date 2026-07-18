#!/usr/bin/env bash
# Retire the dead ~/.dotfiles bare-repo husk on THIS machine (per-machine home-state;
# does not propagate by git). Safety: refuses if the husk still tracks files.
# Idempotent. Honors DRY_RUN=1 (reports, mutates nothing). Just deletes — no archive.
set -u
DF="$HOME/.dotfiles"
run() { if [ -n "${DRY_RUN:-}" ]; then echo "  ~ would: $*"; else echo "  + $*"; "$@"; fi; }

# 1. Guard: only retire a genuinely DEAD husk — a valid bare repo with 0 tracked
#    files. FAIL SAFE: if git errors (not a repo / corrupted), REFUSE, never rm.
#    Absent husk => already done.
if [ -d "$DF" ]; then
  if ! tracked="$(git --git-dir="$DF" --work-tree="$HOME" ls-files 2>/dev/null)"; then
    echo "REFUSING: $DF exists but 'git ls-files' failed (not a healthy bare repo). Resolve manually." >&2
    exit 1
  fi
  if [ -n "$tracked" ]; then
    n="$(printf '%s\n' "$tracked" | grep -c .)"
    echo "REFUSING: $DF still tracks $n file(s). Not a dead husk — resolve manually." >&2
    exit 1
  fi
  run rm -rf "$DF"
else
  echo "  = ~/.dotfiles already absent"
fi

# 2. Remove the stale bare-repo ~/CLAUDE.md (the live deployer writes
#    ~/.claude/CLAUDE.md — a different path — so this does not come back).
if [ -e "$HOME/CLAUDE.md" ]; then
  run rm -f "$HOME/CLAUDE.md"
else
  echo "  = ~/CLAUDE.md already absent"
fi

# 3. Drop the `dotfiles` fish alias if present (backup the file first).
fishcfg="$HOME/.config/fish/config.fish"
if [ -f "$fishcfg" ] && grep -q "alias dotfiles" "$fishcfg" 2>/dev/null; then
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  ~ would: remove 'alias dotfiles' line from $fishcfg"
  else
    cp "$fishcfg" "$fishcfg.pre-husk-retire.bak"
    # grep -v exits 1 when it removes EVERY line (alias-only file); the redirect has
    # already written the filtered content, so mv unconditionally (|| true guards the
    # exit-1 case and prevents a stray .tmp being left behind).
    grep -v "alias dotfiles" "$fishcfg" > "$fishcfg.tmp" || true
    mv "$fishcfg.tmp" "$fishcfg"
    echo "  + removed 'alias dotfiles' from $fishcfg (backup: $fishcfg.pre-husk-retire.bak)"
  fi
else
  echo "  = no 'alias dotfiles' in fish config"
fi

echo "Done. Verify: a new agent session no longer loads ~/CLAUDE.md; ~/.claude links intact."
