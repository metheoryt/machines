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
  "${g[@]}" config status.showUntrackedFiles no
  "${g[@]}" config user.email t@t
  "${g[@]}" config user.name t
  "${g[@]}" checkout -q -b air main
  "${g[@]}" push -q -u origin air
  echo air > "$T/state/branch"
  echo "$T"
}

# tick <root> [extra-env…]: run one sync tick against that root. Echoes exit code.
tick() {
  local T="$1"; shift
  DOTFILES_GIT_DIR="$T/home/.dotfiles" \
  DOTFILES_WORK_TREE="$T/home" \
  DOTFILES_STATE_DIR="$T/state" \
  HOME="$T/home" \
  "$@" bash "$SCRIPT" >"$T/out" 2>"$T/err"
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

# ── 2. Dirty tick commits the change and pushes it ───────────────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
rc="$(tick "$T")"
eq "dirty tick: exit 0" "$rc" "0"
eq "dirty tick: committed" "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "dirty tick: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
