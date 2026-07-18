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

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
