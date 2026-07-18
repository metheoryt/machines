#!/usr/bin/env bash
# The scattered "work directly on main / straight to main" instruction must be
# scoped to main-checkout mode, and both memory files must point at the doc.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"   # repo root (…/machines worktree)
fail=0

pm="$ROOT/.claude/memory/project.md"
gm="$ROOT/agents/memory/global.md"

grep -q 'git-workflow.md' "$pm" || { echo "FAIL project.md missing doc pointer"; fail=1; }
grep -q 'main-checkout' "$pm" || { echo "FAIL project.md not scoped to main-checkout mode"; fail=1; }
grep -q 'git-workflow.md' "$gm" || { echo "FAIL global.md missing doc pointer"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS notes reconciled" || true
exit $fail
