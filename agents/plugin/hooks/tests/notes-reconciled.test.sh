#!/usr/bin/env bash
# The scattered "work directly on main / straight to main" instruction must be
# scoped to main-checkout mode, and the project memory must point at the doc.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"   # repo root (…/machines worktree)
fail=0

pm="$ROOT/.claude/memory/project.md"

grep -q 'git-workflow.md' "$pm" || { echo "FAIL project.md missing doc pointer"; fail=1; }
grep -q 'main-checkout' "$pm" || { echo "FAIL project.md not scoped to main-checkout mode"; fail=1; }

# The GLOBAL half of this check is gone on purpose (2026-07-29). It asserted on
# agents/memory/global.md, which left this repo in the agent-config handover —
# global memory is now a real file at ~/.claude/memory/global.md, tracked on
# dotfiles main. The pointer still lives there; what cannot be reinstated is the
# ASSERTION, because it would make this suite fail wherever dotfiles is not
# checked out at $HOME: a fresh clone, a linked worktree, any CI runner. A
# machines test must not depend on the state of a dotfiles-tracked $HOME path.
# Same reasoning retired the per-host-memory stub loop in
# provision/tests/tiers.test.sh.

[ "$fail" -eq 0 ] && echo "PASS notes reconciled" || true
exit $fail
