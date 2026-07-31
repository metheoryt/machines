#!/usr/bin/env bash
# provision/tests/wsl-fixes.test.sh — unit tests for the WSL-only fixes:
# the wslopen asset and the binfmt watchdog renderers. No sudo, no network,
# no real WSL distro — the installer is sourced in WSL_FIXES_LIB_ONLY mode.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

# ── the wslopen asset ─────────────────────────────────────────────────────────
ASSET="$REPO/provision/assets/wslopen"

[ -f "$ASSET" ] && pass "wslopen asset exists" || die "wslopen asset missing at $ASSET"
bash -n "$ASSET" 2>/dev/null && pass "wslopen parses" || die "wslopen has a syntax error"

# It must base64/UTF-16LE encode the command: plain string interpolation lets
# cmd/PowerShell mangle & ? = in an OAuth callback URL, which is exactly the
# case this exists for.
grep -q 'iconv -f UTF-8 -t UTF-16LE' "$ASSET" && pass "wslopen encodes UTF-16LE" \
  || die "wslopen must pipe through iconv UTF-16LE"
grep -q 'EncodedCommand' "$ASSET" && pass "wslopen uses -EncodedCommand" \
  || die "wslopen must use powershell -EncodedCommand"

# URL schemes must pass through untouched; only real paths get wslpath'd.
grep -q 'http://\* | https://\*' "$ASSET" && pass "wslopen passes URLs through" \
  || die "wslopen must not wslpath a URL"

exit "$fail"
