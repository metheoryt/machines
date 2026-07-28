#!/usr/bin/env bash
# provision/tests/fleet-ssh-config-ps.test.sh — run the PowerShell client-config
# module's own self-test, plus the checks that are possible without PowerShell.
#
# provision/lib/fleet-ssh-config.ps1 renders the fleet block into ~/.ssh/config on
# the Windows-native members. Its logic lives in PowerShell because Git Bash on
# those boxes has no jq, so the jq-based renderer in ssh-wsl.sh cannot be reused.
#
# That leaves it untestable on the mac and Linux members, which is where this
# suite normally runs. Rather than leave it uncovered:
#   • the module carries a `-SelfTest` mode (pure, touches no files) that this
#     script runs whenever a PowerShell is on PATH — real coverage on Windows and
#     anywhere pwsh is installed;
#   • the platform-independent invariants (parity with the bash renderer's
#     contract, no CRLF, no BOM) are asserted here unconditionally, because a
#     divergence between the two renderers is the failure mode that actually bit.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="$REPO/provision/lib/fleet-ssh-config.ps1"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

[ -f "$MODULE" ] || { echo "FAIL: $MODULE missing" >&2; exit 1; }

# ── Platform-independent invariants ───────────────────────────────────────────
grep -q 'Render-FleetSshConfig' "$MODULE"; check $? "module defines Render-FleetSshConfig"
grep -q 'Merge-FleetSshConfig'  "$MODULE"; check $? "module defines Merge-FleetSshConfig"
grep -q 'New-FleetSshBlock'     "$MODULE"; check $? "module defines New-FleetSshBlock"

# The regression this module exists for: User must be unconditional. A guard of
# the `!= "me"` shape is exactly what broke the Windows members, so fail if one
# reappears in either renderer. Comments are stripped first — both files
# deliberately DESCRIBE the old guard, and matching that prose is a false
# positive (it fired on the first run of this test).
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }
! uncommented "$MODULE" | grep -qE "ne[[:space:]]+'me'|-ne[[:space:]]+\"me\""
check $? "module does not gate the User line on a literal 'me' comparison"
! uncommented "$REPO/provision/ssh-wsl.sh" | grep -qE '!=[[:space:]]*"me"'
check $? "the bash renderer does not gate the User line either (contract parity)"

# OpenSSH on Windows treats a BOM as part of the first directive.
! grep -q $'\xEF\xBB\xBF' "$MODULE"; check $? "module has no UTF-8 BOM"
! grep -q $'\r' "$MODULE";           check $? "module has no CRLF line endings"

# Both renderers must emit the same directive set, or a box's behaviour depends on
# which one provisioned it.
for d in 'Host ' '  User ' '  IdentityFile ' '  StrictHostKeyChecking accept-new' 'Host \*\.gg\.ez'; do
  grep -q -- "$d" "$MODULE"; check $? "module emits '$d'"
done

# ── The module's own self-test, when a PowerShell exists ──────────────────────
PS=""
for c in pwsh powershell powershell.exe; do command -v "$c" >/dev/null 2>&1 && { PS="$c"; break; }; done
if [ -z "$PS" ]; then
  printf '  SKIP module -SelfTest (no pwsh/powershell on PATH — runs on the Windows members)\n'
else
  OUT="$("$PS" -NoProfile -File "$MODULE" -SelfTest 2>&1)"; rc=$?
  printf '%s\n' "$OUT" | sed 's/^/    /'
  [ "$rc" = 0 ]; check $? "module -SelfTest exits 0 ($PS)"
  printf '%s' "$OUT" | grep -q 'ALL PASS'; check $? "module -SelfTest reports ALL PASS"
fi

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
