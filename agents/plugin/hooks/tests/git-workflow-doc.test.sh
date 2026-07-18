#!/usr/bin/env bash
# The hook depends on being able to extract a non-empty worktree-mode section
# from the canonical doc. Assert that contract.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/../../../docs/git-workflow.md"

sec="$(sed -n '/<!-- WORKTREE-MODE:START -->/,/<!-- WORKTREE-MODE:END -->/p' "$DOC" 2>/dev/null)"

if [ -n "$sec" ] && printf '%s' "$sec" | grep -q 'merge --ff-only'; then
  echo "PASS worktree-mode section extractable and contains the merge-back command"
  exit 0
else
  echo "FAIL worktree-mode section missing/empty at $DOC"
  exit 1
fi
