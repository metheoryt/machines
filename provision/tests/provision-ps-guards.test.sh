#!/usr/bin/env bash
# provision/tests/provision-ps-guards.test.sh — the Windows front door's two
# "provisioned nothing, reported success" guards, added 2026-09-02.
#
# provision.sh has had both since 2026-08-01; provision.ps1 had NEITHER, and the
# gap was recorded in AGENTS.md and roadmap P3 rather than closed:
#
#   1. UNKNOWN MACHINE. Get-FleetPlatform on a non-member returns $null,
#      Get-FleetRoles returns $null, `foreach` over $null iterates ZERO times,
#      and the script exits 0 — printed no roles, provisioned nothing, green.
#   2. UNDECLARED ROLE. A role with no $RoleExecutors entry printed
#      "not yet implemented (skipped)" and left $rc at 0.
#
# Both now fail loudly. This suite asserts the EXIT CODES, because the exit code
# is the whole point: a message nobody reads is what the old behaviour already
# had.
#
# Two layers, so this is not dead weight on a box with no PowerShell:
#   • source-level invariants, asserted unconditionally — they are what stops the
#     guards being deleted or hollowed out by an edit made on a Mac;
#   • the real front door, run end to end, wherever a PowerShell exists.
#
# WHAT THIS COSTS, stated because it is a new property of `just test`: the
# exit-code half runs the REAL front door, so `agents`/`dotfiles`/`repos` execute
# their dry-run PREVIEWS against the live Windows profile (/c/Users/methe/.claude)
# on every gate run. Every prompt is answered `n`, so nothing is applied and the
# -Apply arm touches no more than the dry-run arm does. But roles.test.sh proves
# "a dry run writes nothing" for the posix executors with a shim tripwire, and
# there is no equivalent here -- this rests on the executors' own dry-run
# contract, not on a measurement. Worth closing if a PowerShell shim ever becomes
# cheap; not worth dropping the coverage over, since a source-grep-only suite is
# what let both guards stay missing for a month.
#
# -ExecutionPolicy Bypass is mandatory on every invocation. Without it the
# default policy refuses an unsigned .ps1 with a SecurityError before the script
# is parsed, and every assertion below fails for a reason that has nothing to do
# with what it tests — the exact failure that kept fleet-ssh-config-ps.test.sh
# red for a month.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
FRONT="$REPO/provision/provision.ps1"
MOD="$REPO/provision/lib/Fleet.psm1"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

[ -f "$FRONT" ] || { echo "FAIL: $FRONT missing"; exit 1; }

# ── Source-level invariants (every platform) ─────────────────────────────────

grep -q 'function Test-FleetMachine' "$MOD" \
  && pass "Fleet.psm1 defines Test-FleetMachine" \
  || die "Fleet.psm1 defines Test-FleetMachine"

# EXPORTING IT IS A SEPARATE ACT FROM DEFINING IT. Export-ModuleMember lists the
# names on a backtick-continued line; a function left off that list does not
# exist to provision.ps1, and the guard silently never runs.
grep -A2 'Export-ModuleMember' "$MOD" | grep -q 'Test-FleetMachine' \
  && pass "Test-FleetMachine is exported" \
  || die "Test-FleetMachine is NOT exported — the guard would never run"

grep -q 'PlannedRoles' "$FRONT" \
  && pass "provision.ps1 declares -PlannedRoles" \
  || die "provision.ps1 declares -PlannedRoles"

# The declaration must cover today's stubs, or the guard turns every Windows
# member's --apply red the day it lands.
grep -qE "PlannedRoles = @\('base', *'ssh-server'\)" "$FRONT" \
  && pass "-PlannedRoles defaults to base + ssh-server" \
  || die "-PlannedRoles default changed — does it still cover every unimplemented role?"

# THE OLD MESSAGE MUST BE GONE. It is the string the whole failure was named by,
# and leaving it behind is how a doc keeps describing a hole that is closed (or,
# worse, how the hole gets restored under a message that reads as intentional).
# Comments are stripped first: the file deliberately DESCRIBES the arm it used to
# have, and matching that prose is a false positive — it fired on the first run.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }
uncommented "$FRONT" | grep -q 'not yet implemented (skipped)' \
  && die "provision.ps1 still prints 'not yet implemented (skipped)' — the silent-green arm is back" \
  || pass "the silent 'not yet implemented (skipped)' arm is gone"

# Write-Error is a trap here: $ErrorActionPreference is 'Stop', so it THROWS and
# the process exits 1 before reaching `exit 2`. A guard that reports the wrong
# exit code is a guard that cannot be scripted against.
grep -qE '^\s*Write-Error' "$FRONT" \
  && die "provision.ps1 uses Write-Error — under 'Stop' it throws before `exit`, losing the code" \
  || pass "provision.ps1 does not use Write-Error for its guards"

# ── The front door itself, wherever a PowerShell exists ──────────────────────
# pwsh/pwsh.exe first: on a WSL box only the .exe spellings are on PATH, and PS7
# is what the Windows members run.
PS=""
for c in pwsh pwsh.exe powershell powershell.exe; do
  command -v "$c" >/dev/null 2>&1 && { PS="$c"; break; }
done
if [ -z "$PS" ]; then
  echo "SKIP (no PowerShell on PATH — the exit-code assertions run on the Windows members)"
  [ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
fi

run() { timeout 180 "$PS" -NoProfile -ExecutionPolicy Bypass -File "$FRONT" "$@" 2>&1; }

# 1. Unknown machine -> exit 2, names it, lists the real ones. Parity with
#    provision.sh, exit code included, so one wrapper can treat both the same.
out="$(run -Machine no-such-box)"; rc=$?
eq "$rc" "2" "unknown machine exits 2"
printf '%s\n' "$out" | grep -q 'unknown machine: no-such-box' \
  && pass "unknown machine is named" || die "unknown machine is named"
printf '%s\n' "$out" | grep -q 'known machines:.*latitude' \
  && pass "the known machines are listed" || die "the known machines are listed"
# The bug in one assertion: it must not get as far as printing a role plan.
printf '%s\n' "$out" | grep -q '> Roles:' \
  && die "unknown machine still reached the role loop — the old zero-iteration path" \
  || pass "unknown machine never reaches the role loop"

# 2. A DECLARED stub reports itself as declared and does not fail the run.
#    desktop carries base + ssh-server, both unimplemented, plus three roles that
#    do have executors — so one run exercises both sides of the branch.
out="$(run -Machine desktop)"; rc=$?
eq "$rc" "0" "a dry run with declared stubs exits 0"
printf '%s\n' "$out" | grep -q "base - plan: no executor yet (declared)" \
  && pass "'base' reports as declared, not as a failure" \
  || die "'base' reports as declared, not as a failure"

# 3. THE NEGATIVE ARM, which is the guard. -PlannedRoles @() declares nothing, so
#    base and ssh-server become undeclared-and-executor-less and -Apply must fail.
#    This is why -PlannedRoles is a parameter: on Windows `$env:X = ''` REMOVES
#    the variable, so the posix suite's MACHINES_PLANNED_ROLES="" lever — set but
#    empty — cannot be expressed in the environment at all.
#    Every prompt is answered `n`, so the implemented roles are skipped and the
#    exit code can only have come from the fallback arm.
out="$(printf 'n\nn\nn\nn\nn\nn\nn\n' | timeout 180 "$PS" -NoProfile -ExecutionPolicy Bypass \
        -Command "& '$FRONT' -Machine desktop -Apply -PlannedRoles @(); exit \$LASTEXITCODE" 2>&1)"; rc=$?
eq "$rc" "1" "an undeclared, executor-less role fails -Apply"
printf '%s\n' "$out" | grep -q "x base - no executor, and not declared" \
  && pass "the undeclared role's missing executor is named" \
  || die "the undeclared role's missing executor is named"
# And it must not have taken the roles that DO work down with it.
printf '%s\n' "$out" | grep -q 'agents skipped' \
  && pass "the implemented roles still ran their preview" \
  || die "the implemented roles still ran their preview"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
