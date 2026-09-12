#!/usr/bin/env bash
# Pins the fresh-Windows bootstrap chain by PATH, not by behaviour.
#
# hosts/g16/windows/install.ps1 is the `irm ... | iex` one-liner a freshly
# reinstalled Windows box runs. It cannot be executed here (no PowerShell in the
# fleet's posix toolchain), and it is the kind of file nobody runs until the
# worst possible moment — so the failure it had is exactly the failure to guard
# against: it handed off to `hosts\g16\windows\restore.ps1`, dead twice over (the
# g16 -> desktop rename 2026-07-20 (reverted 2026-09-12), restore.ps1's deletion 2026-07-31), and threw
# unconditionally at step 3 for six weeks with nothing reporting it.
#
# So: assert that every repo-relative path the bootstrap hands off to EXISTS in
# the tree. That is checkable from any box, and it is the whole class of bug.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

boot="$repo/hosts/g16/windows/install.ps1"
check "install.ps1 is present" '[ -f "$boot" ]'

# Every Join-Path target in the script, converted from backslashes and resolved
# against the repo root. `git ls-files` rather than `-e`, so an untracked
# leftover on this box cannot make a broken reference look fine.
# `.git` is excluded on purpose: it is the "already cloned?" probe, not a file
# the bootstrap hands off to, and it exists only after the clone.
targets="$(sed -n "s/.*Join-Path \$Dest '\([^']*\)'.*/\1/p" "$boot" | tr '\\\\' '/' | grep -v '^\.git$')"
check "install.ps1 hands off to at least one repo path" '[ -n "$targets" ]'
while IFS= read -r t; do
  [ -n "$t" ] || continue
  check "install.ps1 -> $t is tracked in this repo" \
    'git -C "$repo" ls-files --error-unmatch "$t" >/dev/null 2>&1'
done <<EOF
$targets
EOF

# The successor is named in the header too; keep the two in step.
check "install.ps1 names provision/windows.ps1 as the handoff" \
  'grep -q "provision.windows.ps1" "$boot"'
check "install.ps1 no longer references the deleted restore.ps1 as a target" \
  '! sed -n "s/.*Join-Path \$Dest .\([^'"'"']*\).*/\1/p" "$boot" | grep -q "restore.ps1"'

# The runbook links the answer file; it lives in install-media/, not beside the
# runbook, and the wrong link sat there for two months.
rb="$repo/hosts/g16/windows/windows-reinstall-runbook.md"
check "the runbook exists" '[ -f "$rb" ]'
check "autounattend.xml is where the runbook says it is" \
  '[ -f "$repo/install-media/autounattend.xml" ]'
check "the runbook does not link autounattend.xml as a sibling" \
  '! grep -q "(\./autounattend\.xml)" "$rb"'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
