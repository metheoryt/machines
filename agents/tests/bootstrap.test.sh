#!/usr/bin/env bash
# Behavioral tests for agents/bootstrap.sh, driven by DRY_RUN (mutates nothing).
# DRY_RUN reads the live dirs but writes NOTHING (no mkdir/ln/mv/rm).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
boot="$repo/bootstrap.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Case 1: MACHINES_HOST_ID overrides the OS hostname for the host-memory file.
# A non-personal (fake) profile dir is fine — host linking runs unconditionally.
out1="$(MACHINES_HOST_ID=testhost DRY_RUN=1 CLAUDE_CONFIG_DIR=/tmp/does-not-exist-claude bash "$boot" 2>&1)"
check "MACHINES_HOST_ID picks hosts/testhost.md" \
  'printf "%s" "$out1" | grep -q "hosts/testhost.md"'
# Compute the OS-hostname host id the same way bootstrap's host_id() does, so the
# negative assertion is a real guard: pre-fix, out1 seeds this file; post-fix it must not.
os_hid="$(hostname 2>/dev/null)"; os_hid="${os_hid%%.*}"
os_hid="$(printf '%s' "$os_hid" | tr -c 'A-Za-z0-9_-' '_')"
check "MACHINES_HOST_ID does not fall back to OS hostname" \
  '! printf "%s" "$out1" | grep -qF "hosts/'"$os_hid"'.md"'

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

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
