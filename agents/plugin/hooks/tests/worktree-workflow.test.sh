#!/usr/bin/env bash
# Behavior tests for worktree-workflow.sh — builds throwaway repos + worktrees,
# runs the hook with a fake session JSON on stdin, asserts on output.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../worktree-workflow.sh"
fail=0
tmp="$(mktemp -d)"
trap 'git worktree prune 2>/dev/null; rm -rf "$tmp"' EXIT

run_hook() { printf '{"cwd":"%s"}' "$1" | bash "$HOOK"; }

make_repo() { # $1 = dir, $2 = origin url (may be empty)
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
  [ -n "$2" ] && git -C "$1" remote add origin "$2"
  return 0
}

# Case 1: linked worktree, personal (non-blocklisted) remote -> fires
r1="$tmp/personal"; make_repo "$r1" "git@github.com:metheoryt/machines.git"
git -C "$r1" branch feat
git -C "$r1" worktree add -q "$tmp/personal-wt" feat
out="$(run_hook "$tmp/personal-wt")"
if printf '%s' "$out" | grep -q "worktree branch : feat" \
   && printf '%s' "$out" | grep -q "WORKTREE-MODE"; then
  echo "PASS case1 fires in personal worktree"
else
  echo "FAIL case1"; printf '%s\n' "$out"; fail=1
fi

# Case 2: base checkout of the same repo -> silent
out="$(run_hook "$r1")"
if [ -z "$out" ]; then echo "PASS case2 silent in base checkout"
else echo "FAIL case2 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

# Case 3: linked worktree, blocklisted remote -> silent
r3="$tmp/work"; make_repo "$r3" "git@github.com:thepureapp/backend-api.git"
git -C "$r3" branch feat
git -C "$r3" worktree add -q "$tmp/work-wt" feat
out="$(run_hook "$tmp/work-wt")"
if [ -z "$out" ]; then echo "PASS case3 silent for blocklisted remote"
else echo "FAIL case3 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

# Case 4: plain non-git dir -> silent
mkdir "$tmp/plain"
out="$(run_hook "$tmp/plain")"
if [ -z "$out" ]; then echo "PASS case4 silent outside git"
else echo "FAIL case4 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
