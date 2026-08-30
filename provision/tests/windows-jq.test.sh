#!/usr/bin/env bash
# provision/tests/windows-jq.test.sh — windows.ps1 must provision jq.
#
# THE BUG THIS EXISTS FOR, measured on desktop (g614jv) 2026-08-30:
#
#     ! jq not found — gortex hooks stay inert in .../.claude/settings.local.json
#
# agents/bootstrap.sh's gortex_merge_hooks is the step that copies gortex's hooks
# out of settings.local.json — which Claude Code does NOT read at user scope —
# into settings.json, which it does. That function is written in jq and returns
# early with a warning when jq is missing. windows.ps1 installs git and python
# through winget and never installed jq, so on every Windows box the merge has
# always been a no-op: gortex's hooks were written, warned about once, and never
# ran. Not deny, not nudge, nothing.
#
# That is the same failure shape the merge function itself was written for (a
# step that reports success while doing nothing), one layer down, and it is why
# jq is a PROVISIONING dependency here rather than a nice-to-have: the Linux and
# macOS tiers already install it (tier_apt_min, tier_brew_min), so Windows was
# the only platform where the gortex wiring silently did not work.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
PS1FILE="$REPO/provision/windows.ps1"
BOOTSTRAP="$REPO/agents/bootstrap.sh"
fail=0
pass() { printf '  PASS %s\n' "$1"; }
die()  { printf '  FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

[ -f "$PS1FILE" ]   || { echo "FAIL: $PS1FILE missing" >&2; exit 1; }
[ -f "$BOOTSTRAP" ] || { echo "FAIL: $BOOTSTRAP missing" >&2; exit 1; }

# Comments stripped: the file explains the dependency in prose, and matching the
# prose would pass after the live line was deleted.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }

# 1. The dependency is real — assert it from bootstrap.sh, not from memory, so
#    this suite stops demanding jq if that hard dependency ever goes away.
uncommented "$BOOTSTRAP" | grep -qE 'command -v jq|have jq' \
  && pass "gortex_merge_hooks still hard-depends on jq" \
  || die "bootstrap.sh no longer probes for jq — this suite may be demanding a dependency that is gone"

# 2. windows.ps1 provisions it.
uncommented "$PS1FILE" | grep -qiE 'jq' \
  && pass "windows.ps1 references jq" \
  || die "windows.ps1 never mentions jq — gortex hooks stay inert on every Windows box"

uncommented "$PS1FILE" | grep -qiE 'winget install .*jq|jqlang\.jq' \
  && pass "windows.ps1 installs jq via winget" \
  || die "windows.ps1 mentions jq but does not install it"

# 3. The other two platforms already have it; named here so a future reader sees
#    that Windows was the odd one out rather than jq being a new requirement.
grep -qE '^\s+.*\bjq\b' "$REPO/provision/lib/tiers.sh" \
  && pass "the POSIX tiers install jq (so Windows was the only gap)" \
  || die "tiers.sh no longer installs jq — the premise of this suite has changed"

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES" >&2; exit 1; fi
