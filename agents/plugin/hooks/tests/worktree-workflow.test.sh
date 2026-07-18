#!/usr/bin/env bash
# Behavior tests for worktree-workflow.sh — builds throwaway repos + worktrees,
# runs the hook with a fake session JSON on stdin, asserts on output.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../worktree-workflow.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Runs the hook, capturing stdout in $out, stderr in $err, exit code in $rc.
run_hook() {
  local errfile
  errfile="$(mktemp)"
  out="$(printf '{"cwd":"%s"}' "$1" | bash "$HOOK" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
}

# Asserts exit code 0 and empty stderr for the just-run hook. Sets fail=1 and
# prints a FAIL line (tagged with $1) on violation.
assert_quiet_exit() {
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $1 (expected exit 0, got $rc)"; fail=1
  fi
  if [ -n "$err" ]; then
    echo "FAIL $1 (expected empty stderr, got: $err)"; fail=1
  fi
}

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
run_hook "$tmp/personal-wt"
if printf '%s' "$out" | grep -q "worktree branch : feat" \
   && printf '%s' "$out" | grep -q "WORKTREE-MODE"; then
  echo "PASS case1 fires in personal worktree"
else
  echo "FAIL case1"; printf '%s\n' "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then echo "PASS case1 exits 0"
else echo "FAIL case1 (expected exit 0, got $rc)"; fail=1; fi

# Case 2: base checkout of the same repo -> silent
run_hook "$r1"
if [ -z "$out" ]; then echo "PASS case2 silent in base checkout"
else echo "FAIL case2 (expected empty)"; printf '%s\n' "$out"; fail=1; fi
assert_quiet_exit case2

# Case 3: linked worktree, blocklisted remote -> silent
r3="$tmp/work"; make_repo "$r3" "git@github.com:thepureapp/backend-api.git"
git -C "$r3" branch feat
git -C "$r3" worktree add -q "$tmp/work-wt" feat
run_hook "$tmp/work-wt"
if [ -z "$out" ]; then echo "PASS case3 silent for blocklisted remote"
else echo "FAIL case3 (expected empty)"; printf '%s\n' "$out"; fail=1; fi
assert_quiet_exit case3

# Case 4: plain non-git dir -> silent
mkdir "$tmp/plain"
run_hook "$tmp/plain"
if [ -z "$out" ]; then echo "PASS case4 silent outside git"
else echo "FAIL case4 (expected empty)"; printf '%s\n' "$out"; fail=1; fi
assert_quiet_exit case4

# Case 5 (regression): base checkout reached via a symlinked path -> silent.
# gd (--absolute-git-dir) is a PHYSICAL path; common must be normalized the
# same way (pwd -P) or a symlinked cwd wrongly looks like a linked worktree.
ln -s "$r1" "$tmp/personal-link"
run_hook "$tmp/personal-link"
if [ -z "$out" ]; then echo "PASS case5 silent in base checkout via symlink"
else echo "FAIL case5 (expected empty)"; printf '%s\n' "$out"; fail=1; fi
assert_quiet_exit case5

# Case 6: linked worktree, NO origin remote -> fires (local-only personal
# repo has no blocklisted remote, so the default-on contract must fire).
r6="$tmp/noorigin"; make_repo "$r6" ""
git -C "$r6" branch feat
git -C "$r6" worktree add -q "$tmp/noorigin-wt" feat
run_hook "$tmp/noorigin-wt"
if printf '%s' "$out" | grep -q "worktree branch : feat" \
   && printf '%s' "$out" | grep -q "WORKTREE-MODE"; then
  echo "PASS case6 fires with no origin remote"
else
  echo "FAIL case6"; printf '%s\n' "$out"; fail=1
fi
if [ "$rc" -eq 0 ]; then echo "PASS case6 exits 0"
else echo "FAIL case6 (expected exit 0, got $rc)"; fail=1; fi

# Case 7: base falls back to "main" when refs/remotes/origin/HEAD is unset
# (none of the fresh test repos above set it) -> printed base branch is main.
if printf '%s' "$out" | grep -q "base branch     : main"; then
  echo "PASS case7 base falls back to main"
else
  echo "FAIL case7 (expected base branch fallback to main)"; printf '%s\n' "$out"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
