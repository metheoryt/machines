#!/usr/bin/env bash
# Unit tests for provision/dotfiles-sync.sh against a scratch bare "remote" and
# a temp $HOME. Nothing here touches the real ~/.dotfiles or the real remote.
#
# The property under test is not "does it sync" but "can it ever damage $HOME".
# The work-tree is a live home directory, so every case asserts on what is left
# ON DISK, not just on exit status.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dotfiles-sync.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else die "$1: got '$2', want '$3'"; fi; }

# setup: fresh remote + bare clone + machine branch 'air' + branch state file.
# Echoes the temp root. Every test gets its own.
setup() {
  local T
  T="$(mktemp -d)"
  git init -q --bare "$T/remote.git"
  git init -q -b main "$T/seed"
  printf 'original\n' > "$T/seed/.tracked"
  printf '*\n!*/\n!.gitignore\n!.tracked\n' > "$T/seed/.gitignore"
  git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .tracked
  git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$T/seed" push -q "$T/remote.git" main

  mkdir -p "$T/home" "$T/state"
  git clone -q --bare "$T/remote.git" "$T/home/.dotfiles"
  local g=(git --git-dir="$T/home/.dotfiles" --work-tree="$T/home")
  # Mirror what the dotfiles role does: `clone --bare` sets NO
  # remote.origin.fetch, so without this there are no refs/remotes/origin/*
  # and every `origin/main` reference fails to resolve.
  "${g[@]}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  "${g[@]}" fetch -q origin
  "${g[@]}" config status.showUntrackedFiles no
  "${g[@]}" config user.email t@t
  "${g[@]}" config user.name t
  "${g[@]}" checkout -q -b air main
  "${g[@]}" push -q -u origin air
  echo air > "$T/state/branch"
  echo "$T"
}

# tick <root> [extra-env…]: run one sync tick against that root. Echoes exit code.
# `env "$@"` and not a bare `"$@"`: bash recognises assignment prefixes at PARSE
# time, so a quoted expansion that merely looks like VAR=val is treated as the
# command name (exit 127), not as an assignment. env re-reads them at runtime.
tick() {
  local T="$1"; shift
  DOTFILES_GIT_DIR="$T/home/.dotfiles" \
  DOTFILES_WORK_TREE="$T/home" \
  DOTFILES_STATE_DIR="$T/state" \
  HOME="$T/home" \
  env "$@" bash "$SCRIPT" >"$T/out" 2>"$T/err"
  echo $?
}

dfx() { local T="$1"; shift; git --git-dir="$T/home/.dotfiles" --work-tree="$T/home" "$@"; }

# ── 1. Clean tick is a no-op ─────────────────────────────────────────────────
T="$(setup)"
before="$(dfx "$T" rev-parse air)"
rc="$(tick "$T")"
eq "clean tick: exit 0" "$rc" "0"
eq "clean tick: no new commit" "$(dfx "$T" rev-parse air)" "$before"
rm -rf "$T"

# ── 2. Dirty tick defers; the next tick commits the settled change and pushes ─
# COMMIT CADENCE: a tick commits only once the tracked diff has stopped moving.
# See sync_should_commit — one editing burst yields one commit, not one per tick.
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse air)"
rc="$(tick "$T")"
eq "dirty tick: exit 0" "$rc" "0"
eq "dirty tick: defers the first time" "$(dfx "$T" rev-parse air)" "$before"
rc="$(tick "$T")"
eq "settled tick: exit 0" "$rc" "0"
eq "settled tick: committed" "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "settled tick: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
eq "settled tick: work-tree unchanged" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 3. Wrong branch: exit non-zero having committed NOTHING ──────────────────
# Guards against a stray `checkout main` turning the timer into a machine that
# force-feeds host-local content onto the shared branch.
T="$(setup)"
dfx "$T" checkout -q main
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse main)"
rc="$(tick "$T")"
if [ "$rc" != "0" ]; then pass "wrong branch: non-zero exit"; else die "wrong branch: exited 0"; fi
eq "wrong branch: nothing committed" "$(dfx "$T" rev-parse main)" "$before"
eq "wrong branch: work-tree untouched" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 4. No repo / no branch state: silent skip, exit 0 ────────────────────────
T="$(setup)"
rm -rf "$T/home/.dotfiles"
eq "missing repo: exit 0" "$(tick "$T")" "0"
rm -rf "$T"

T="$(setup)"
rm -f "$T/state/branch"
eq "missing branch state: exit 0" "$(tick "$T")" "0"
rm -rf "$T"

# ── 5. origin/main fast-forwards cleanly into the branch ─────────────────────
T="$(setup)"
printf 'shared\n' > "$T/seed/.shared"
printf '*\n!*/\n!.gitignore\n!.tracked\n!.shared\n' > "$T/seed/.gitignore"
git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .shared
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm "add shared"
git -C "$T/seed" push -q "$T/remote.git" main
eq "clean merge: exit 0" "$(tick "$T")" "0"
if [ -f "$T/home/.shared" ]; then
  pass "clean merge: shared file landed in \$HOME"
else
  die "clean merge: .shared missing from \$HOME"
fi
if [ ! -f "$T/state/conflict" ]; then
  pass "clean merge: no conflict marker"
else
  die "clean merge: spurious conflict marker"
fi
rm -rf "$T"

# ── 6. Conflicting origin/main: $HOME byte-identical, marker dropped ─────────
# THE test. If this regresses, a timer tick writes <<<<<<< into a live dotfile.
#
# Tick 1 documents the ONE-TICK STALL that the debounce accepts: the commit is
# deferred, so merge-tree compares the UNCHANGED branch tip against origin/main
# and finds no conflict, and the real merge then refuses because .tracked is
# dirty. Nothing is written and nothing is claimed. Tick 2 commits and the
# conflict is detected properly. Bounding this to one tick is why the gate is a
# debounce and not a 24h timer.
T="$(setup)"
printf 'theirs\n' > "$T/seed/.tracked"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qam "theirs"
git -C "$T/seed" push -q "$T/remote.git" main
printf 'ours\n' > "$T/home/.tracked"

rc="$(tick "$T")"
eq "conflict tick 1: exit 0" "$rc" "0"
eq "conflict tick 1: \$HOME byte-identical" "$(cat "$T/home/.tracked")" "ours"

rc="$(tick "$T")"
eq "conflict: exit 0" "$rc" "0"
eq "conflict: \$HOME byte-identical" "$(cat "$T/home/.tracked")" "ours"
case "$(cat "$T/home/.tracked")" in
  *'<<<<<<<'*) die "conflict: MARKERS WRITTEN TO LIVE \$HOME" ;;
  *) pass "conflict: no markers in \$HOME" ;;
esac
if [ -f "$T/state/conflict" ]; then pass "conflict: marker dropped"; else die "conflict: no marker"; fi
eq "conflict: local work still committed" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 7. Resolving the conflict clears the marker on the next tick ────────────
T="$(setup)"
printf 'theirs\n' > "$T/seed/.tracked"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qam "theirs"
git -C "$T/seed" push -q "$T/remote.git" main
printf 'ours\n' > "$T/home/.tracked"
tick "$T" >/dev/null
tick "$T" >/dev/null
[ -f "$T/state/conflict" ] || die "setup for test 7: expected a marker"
# Resolve by taking origin/main's content, exactly as a human would.
dfx "$T" fetch -q origin main
dfx "$T" merge -q --no-edit -X theirs origin/main >/dev/null 2>&1
eq "resolved: exit 0" "$(tick "$T")" "0"
if [ ! -f "$T/state/conflict" ]; then
  pass "resolved: marker cleared"
else
  die "resolved: marker still present"
fi
rm -rf "$T"


# ── 8. A tick launched from INSIDE the work-tree still sees the whole tree ───
# Regression: git computes a pathspec prefix from the cwd, so `add -u` run from
# a subdirectory of $HOME stages only that subdirectory. On a real box that is
# the common case — `bash ~/machines/provision/dotfiles-sync.sh` — and it made
# the tick a silent no-op that committed none of the actual drift.
T="$(setup)"
mkdir -p "$T/home/sub"
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse air)"
rc="$(cd "$T/home/sub" && tick "$T")"
eq "cwd inside work-tree: exit 0" "$rc" "0"
rc="$(cd "$T/home/sub" && tick "$T")"
eq "cwd inside work-tree: second tick exit 0" "$rc" "0"
if [ "$(dfx "$T" rev-parse air)" != "$before" ]; then
  pass "cwd inside work-tree: drift outside the cwd still committed"
else
  die "cwd inside work-tree: NOTHING COMMITTED — pathspec prefix swallowed it"
fi
rm -rf "$T"

# ── 9. Debounce: state is cleared once the commit lands ──────────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
tick "$T" >/dev/null
if [ -f "$T/state/pending.hash" ]; then
  pass "debounce: pending.hash recorded on the deferring tick"
else
  die "debounce: no pending.hash after a dirty tick"
fi
tick "$T" >/dev/null
if [ ! -f "$T/state/pending.hash" ] && [ ! -f "$T/state/pending.since" ]; then
  pass "debounce: state cleared after the commit"
else
  die "debounce: stale pending state survived the commit"
fi
# A clean tree must also clear it, so a reverted edit does not arm a later commit.
tick "$T" >/dev/null
if [ ! -f "$T/state/pending.hash" ]; then pass "debounce: clean tick leaves no state"; else die "debounce: clean tick left state"; fi
rm -rf "$T"

# ── 10. A diff that keeps moving keeps deferring ─────────────────────────────
T="$(setup)"
before="$(dfx "$T" rev-parse air)"
printf 'one\n' > "$T/home/.tracked"
tick "$T" >/dev/null
printf 'two\n' > "$T/home/.tracked"
tick "$T" >/dev/null
eq "moving diff: still nothing committed" "$(dfx "$T" rev-parse air)" "$before"
tick "$T" >/dev/null
eq "moving diff: commits once settled" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "moving diff: committed the LATEST content" \
   "$(dfx "$T" show air:.tracked)" "two"
rm -rf "$T"

# ── 11. DOTFILES_SYNC_FORCE commits on the first dirty tick ──────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
eq "force: exit 0" "$(tick "$T" DOTFILES_SYNC_FORCE=1)" "0"
eq "force: committed immediately" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "force: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
rm -rf "$T"

# ── 12. FORCE bypasses the debounce ONLY — never the branch guard ─────────────
# The manual-trigger skill sets FORCE. If it could also override sync_guard, a
# /dotfiles-sync run on a stray `checkout main` would force host-local content
# onto the shared branch — worse than the churn the debounce exists to prevent.
T="$(setup)"
dfx "$T" checkout -q main
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse main)"
rc="$(tick "$T" DOTFILES_SYNC_FORCE=1)"
if [ "$rc" != "0" ]; then pass "force+wrong branch: non-zero exit"; else die "force+wrong branch: exited 0"; fi
eq "force+wrong branch: nothing committed" "$(dfx "$T" rev-parse main)" "$before"
eq "force+wrong branch: work-tree untouched" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 13. The max-age valve commits a tree that will not settle ────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
eq "valve: exit 0" "$(tick "$T" DOTFILES_SYNC_MAX_AGE=0)" "0"
eq "valve: committed on the first dirty tick" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 14. Hand-staged content is explicit intent, never debounced ──────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
dfx "$T" add "$T/home/.tracked"
eq "staged: exit 0" "$(tick "$T")" "0"
eq "staged: committed on the first tick" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 15. A deferred commit does not block propagation from origin/main ────────
# The whole point of gating the COMMIT rather than the tick: incoming shared
# content must still land in $HOME on the very tick that defers.
#
# VERIFIED before this plan was written, in both merge shapes: `git merge` refuses
# only on paths the merge itself touches, so an unrelated dirty tracked file
# blocks nothing. Fast-forward (branch has no own commits, which is this case) and
# true merge ('ort', branch ahead — the real-box shape) both landed .shared with
# the dirty file preserved. Contrast case 6, where the dirty path IS the incoming
# path and the merge does refuse.
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
printf 'shared\n' > "$T/seed/.shared"
printf '*\n!*/\n!.gitignore\n!.tracked\n!.shared\n' > "$T/seed/.gitignore"
git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .shared
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm "add shared"
git -C "$T/seed" push -q "$T/remote.git" main
eq "deferred+merge: exit 0" "$(tick "$T")" "0"
if [ -f "$T/home/.shared" ]; then
  pass "deferred+merge: shared file landed despite the deferred commit"
else
  die "deferred+merge: .shared missing — the debounce blocked propagation"
fi
eq "deferred+merge: local edit preserved" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 16. The debounce hash reads the whole tree, not the cwd subtree ──────────
# Regression twin of case 8: git computes a pathspec prefix from the cwd, which
# once made `add -u` a silent no-op. Explicit --git-dir + --work-tree suppresses
# that, but the hash must be proven prefix-safe the same way `add -u` was — the
# real invocation is `bash ~/machines/provision/dotfiles-sync.sh` from anywhere.
T="$(setup)"
mkdir -p "$T/home/sub"
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse air)"
( cd "$T/home/sub" && tick "$T" >/dev/null )
if [ -s "$T/state/pending.hash" ]; then
  pass "subdir hash: drift outside the cwd was seen"
else
  die "subdir hash: EMPTY — the hash saw only the cwd subtree"
fi
( cd "$T/home/sub" && tick "$T" >/dev/null )
if [ "$(dfx "$T" rev-parse air)" != "$before" ]; then
  pass "subdir hash: settled drift outside the cwd committed"
else
  die "subdir hash: nothing committed from a subdirectory"
fi
rm -rf "$T"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
