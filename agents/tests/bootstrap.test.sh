#!/usr/bin/env bash
# Behavioral tests for agents/bootstrap.sh, driven by DRY_RUN (mutates nothing).
# DRY_RUN reads the live dirs but writes NOTHING (no mkdir/ln/mv/rm).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
boot="$repo/bootstrap.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Case 1: per-host memory is dotfiles-owned. bootstrap neither seeds
# agents/hosts/<id>.md nor links anything at ~/.claude/host-memory.md; it only
# retires a stale link there. MACHINES_HOST_ID is no longer consulted.
#
# Both assertions are NEGATIVE, and that is the whole contract for the primary
# profile: bootstrap must produce no output for this path. The positive half —
# that a stale link actually gets retired — is Case 4(a), which tests retire_link
# directly rather than through a bootstrap run whose output depends on whatever
# happens to be at the live path.
# Drive the PRIMARY profile, because that is whose contract this is. A fake
# profile dir would be a secondary profile, where a fan-out link at
# host-memory.md is CORRECT — asserting its absence there tests the opposite of
# the intent. The destination is printed first ("would link: DEST -> SRC"), so
# anchoring on the primary dest also tolerates the legitimate ~/.codex link.
out1="$(MACHINES_HOST_ID=testhost DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "no per-host file is seeded in the repo" \
  '! printf "%s" "$out1" | grep -q "hosts/testhost.md"'
check "nothing is linked at the primary profile's host-memory.md" \
  '! printf "%s" "$out1" | grep -qE "would (link|back up \+ link): '"$HOME"'/\.claude/host-memory\.md"'

# Case 2: the plugin hooks tests/ dir is never linked. The Codex block that links
# plugin/hooks entry-by-entry runs ONLY on the personal profile (IS_PERSONAL=1),
# so drive $HOME/.claude with a THROWAWAY Codex dir (DRY_RUN writes nothing to it).
out2="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "tests dir excluded from hook linking" \
  '! printf "%s" "$out2" | grep -q "hooks/tests"'

# Case 3: copy_managed — the churn-free real-copy handler for settings.json /
# codex hooks.json. Source bootstrap in lib-only mode (defines helpers, runs no
# bootstrap) with CLAUDE_CONFIG_DIR pointed at a throwaway dir so the source-time
# mkdir lands there, not real ~/.claude.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
BOOTSTRAP_LIB_ONLY=1 CLAUDE_CONFIG_DIR="$tmp/claude" . "$boot" >/dev/null 2>&1

src="$tmp/base.json"; dest="$tmp/live.json"
printf 'BASE-V1\n' > "$src"

# (a) first seed: dest is a REAL file with src's content — never a symlink.
copy_managed "$src" "$dest" >/dev/null
check "copy_managed seeds a real file, not a symlink" '[ -f "$dest" ] && [ ! -L "$dest" ]'
check "copy_managed seeds baseline content"           '[ "$(cat "$dest")" = "BASE-V1" ]'

# (b) baseline UNCHANGED → local injection (Orca's block) is preserved (stamp hit).
printf 'BASE-V1\nORCA-INJECTED\n' > "$dest"
copy_managed "$src" "$dest" >/dev/null
check "copy_managed keeps local edits when baseline unchanged" 'grep -q ORCA-INJECTED "$dest"'

# (c) baseline CHANGES → re-seed, clobbering the stale local copy (Orca re-injects on launch).
printf 'BASE-V2\n' > "$src"
copy_managed "$src" "$dest" >/dev/null
check "copy_managed re-seeds when baseline changed" '[ "$(cat "$dest")" = "BASE-V2" ]'

# (d) migration: an existing SYMLINK at dest (the pre-fix state) becomes a real copy.
other="$tmp/other.json"; printf 'OTHER\n' > "$other"
lnk="$tmp/waslink.json"; ln -s "$other" "$lnk"
copy_managed "$src" "$lnk" >/dev/null
check "copy_managed migrates a symlink to a real copy"  '[ -f "$lnk" ] && [ ! -L "$lnk" ]'
check "copy_managed migration writes baseline content"  '[ "$(cat "$lnk")" = "BASE-V2" ]'

# Case 4: retire_link — drops a symlink INTO the repo, never anything else.
# Reuses the lib-only sourcing from Case 3 ($tmp and helpers are already live).
SRC_DIR="$tmp/src"; mkdir -p "$SRC_DIR"
printf 'REPO-CONTENT\n' > "$SRC_DIR/thing.md"

# (a) a symlink into $SRC_DIR is removed.
r_link="$tmp/retire-me.md"; ln -s "$SRC_DIR/thing.md" "$r_link"
retire_link "$r_link" >/dev/null
check "retire_link removes a symlink into the repo" '[ ! -e "$r_link" ] && [ ! -L "$r_link" ]'

# (b) a REAL file is never touched — this is the memory-loss guard.
r_real="$tmp/keep-me.md"; printf 'DOTFILES-OWNED\n' > "$r_real"
retire_link "$r_real" >/dev/null
check "retire_link leaves a real file alone"    '[ -f "$r_real" ]'
check "retire_link preserves real file content" '[ "$(cat "$r_real")" = "DOTFILES-OWNED" ]'

# (c) a symlink pointing OUTSIDE the repo is not ours — leave it.
r_other="$tmp/other-target.md"; printf 'SOMEONE-ELSE\n' > "$r_other"
r_foreign="$tmp/foreign-link.md"; ln -s "$r_other" "$r_foreign"
retire_link "$r_foreign" >/dev/null
check "retire_link leaves a foreign symlink alone" '[ -L "$r_foreign" ]'

# (d) missing path is a silent no-op, not an error. Capture the status in a
# variable: `$?` inside check's eval would read the eval's own predecessor, which
# makes the assertion tautological rather than a test of retire_link.
retire_link "$tmp/does-not-exist.md" >/dev/null; r_rc=$?
check "retire_link is a no-op on a missing path" '[ "$r_rc" -eq 0 ]'

# (e) DRY_RUN removes nothing.
r_dry="$tmp/dry-link.md"; ln -s "$SRC_DIR/thing.md" "$r_dry"
DRY_RUN=1 retire_link "$r_dry" >/dev/null
check "retire_link removes nothing under DRY_RUN" '[ -L "$r_dry" ]'

# (f) link_if_present — links when the source exists, no-ops when it does not.
# The no-op case is the guard against a dangling fan-out link on a box whose
# primary profile has not been converted yet.
p_dest="$tmp/present.md"
link_if_present "$SRC_DIR/thing.md" "$p_dest" >/dev/null
check "link_if_present links an existing source" '[ -L "$p_dest" ]'

a_dest="$tmp/absent.md"
link_if_present "$SRC_DIR/nope.md" "$a_dest" >/dev/null
check "link_if_present creates nothing for a missing source" '[ ! -e "$a_dest" ] && [ ! -L "$a_dest" ]'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
