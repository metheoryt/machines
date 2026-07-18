#!/usr/bin/env bash
# Tests for scripts/retire-dotfiles-husk.sh against a throwaway fake $HOME.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/scripts/retire-dotfiles-husk.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Fixture: a fake HOME with an EMPTY bare husk + stray ~/CLAUDE.md.
mk_home() {
  local h; h="$(mktemp -d)"
  git init --bare -q "$h/.dotfiles"
  printf 'stale bare-repo doc\n' > "$h/CLAUDE.md"
  printf '%s' "$h"
}

# Case 1: empty husk -> retired (DRY_RUN reports the intended actions).
h="$(mk_home)"
out="$(HOME="$h" DRY_RUN=1 bash "$script" 2>&1)"
check "dry-run reports removing ~/.dotfiles" 'printf "%s" "$out" | grep -q "\.dotfiles"'
check "dry-run reports removing ~/CLAUDE.md"  'printf "%s" "$out" | grep -q "CLAUDE.md"'
rm -rf "$h"

# Case 2: empty husk -> real run removes both, idempotent on re-run.
h="$(mk_home)"
HOME="$h" bash "$script" >/dev/null 2>&1
check "husk removed"        '[ ! -e "$h/.dotfiles" ]'
check "stray CLAUDE.md gone" '[ ! -e "$h/CLAUDE.md" ]'
HOME="$h" bash "$script" >/dev/null 2>&1
check "idempotent re-run exits 0" '[ "$?" -eq 0 ]'
rm -rf "$h"

# Case 3: NON-empty husk -> refuses, leaves everything intact.
h="$(mktemp -d)"
git init --bare -q "$h/.dotfiles"
# Give the bare repo a tracked file via a temp work-tree commit.
wt="$(mktemp -d)"; git --git-dir="$h/.dotfiles" --work-tree="$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
printf 'x\n' > "$wt/tracked.txt"
git --git-dir="$h/.dotfiles" --work-tree="$wt" add tracked.txt >/dev/null 2>&1
git --git-dir="$h/.dotfiles" --work-tree="$wt" -c user.email=t@t -c user.name=t commit -q -m add >/dev/null 2>&1
out="$(HOME="$h" bash "$script" 2>&1)"; rc=$?
check "non-empty husk: refuses (nonzero exit)" '[ "'$rc'" -ne 0 ]'
check "non-empty husk: ~/.dotfiles preserved"  '[ -e "$h/.dotfiles" ]'
rm -rf "$h" "$wt"

# Case 4: NON-repo ~/.dotfiles dir with a file -> guard fails SAFE (refuses, preserves).
# This is the regression guard for the fail-open Critical.
h="$(mktemp -d)"
mkdir -p "$h/.dotfiles"; printf 'precious\n' > "$h/.dotfiles/keep.txt"
out="$(HOME="$h" bash "$script" 2>&1)"; rc=$?
check "non-repo husk: refuses (nonzero exit)" '[ "'$rc'" -ne 0 ]'
check "non-repo husk: ~/.dotfiles preserved"  '[ -e "$h/.dotfiles/keep.txt" ]'
rm -rf "$h"

# Case 5: fish alias among other lines -> alias removed, other lines kept, backup made, no stray .tmp.
h="$(mktemp -d)"; git init --bare -q "$h/.dotfiles"
mkdir -p "$h/.config/fish"
printf 'set -x FOO bar\nalias dotfiles "git --git-dir=x"\nfunction fish_prompt\nend\n' > "$h/.config/fish/config.fish"
HOME="$h" bash "$script" >/dev/null 2>&1
check "fish alias line removed"     '! grep -q "alias dotfiles" "$h/.config/fish/config.fish"'
check "fish other lines preserved"  'grep -q "set -x FOO bar" "$h/.config/fish/config.fish" && grep -q "function fish_prompt" "$h/.config/fish/config.fish"'
check "fish config backup created"  '[ -f "$h/.config/fish/config.fish.pre-husk-retire.bak" ]'
check "no stray .tmp (multi-line)"  '[ ! -e "$h/.config/fish/config.fish.tmp" ]'
rm -rf "$h"

# Case 6: fish alias is the ONLY line -> removed cleanly (grep -v exits 1), no stray .tmp, exit 0.
# Regression guard for the false-success Important.
h="$(mktemp -d)"; git init --bare -q "$h/.dotfiles"
mkdir -p "$h/.config/fish"
printf 'alias dotfiles "git --git-dir=x"\n' > "$h/.config/fish/config.fish"
HOME="$h" bash "$script" >/dev/null 2>&1; rc=$?
check "alias-only fish: exits 0"        '[ "'$rc'" -eq 0 ]'
check "alias-only fish: alias gone"     '! grep -q "alias dotfiles" "$h/.config/fish/config.fish"'
check "alias-only fish: no stray .tmp"  '[ ! -e "$h/.config/fish/config.fish.tmp" ]'
rm -rf "$h"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
