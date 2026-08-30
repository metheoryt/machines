#!/usr/bin/env bash
# provision/tests/windows-core-symlinks.test.sh — guard the repo's one tracked
# symlink, and the Windows provisioning step that makes it survive a checkout.
#
# The contract (AGENTS.md:3-5): the repo-root CLAUDE.md is a SYMLINK to
# AGENTS.md. Agent memory discovery looks for CLAUDE.md; the content lives in
# AGENTS.md; the link is what joins them.
#
# Why a test, and why it also inspects a .ps1 from bash: on 2026-08-03 the
# desktop Windows-native checkout was measured with CLAUDE.md as a 9-byte
# REGULAR FILE containing the literal text "AGENTS.md" — git's rendering of a
# symlink when core.symlinks is false. Every agent session in that clone had
# therefore loaded nine bytes of nothing, silently, because a 9-byte file is not
# an error and `git status` reports the tree CLEAN (the index and worktree agree
# under that mode).
#
# The cause was not the clone. Git for Windows' installer writes
# core.symlinks=false into the SYSTEM config, so every fresh clone on such a box
# reproduces it. provision/windows.ps1 already enables Developer Mode expressly
# so that symlinks work — but Developer Mode only lets `ln -s` succeed; git
# still refuses to check a symlink out until core.symlinks says otherwise. The
# step that closes that half is what assertion 3 pins.
#
# Two failure modes, two halves of this suite:
#   1-2. someone "fixes" the Windows breakage by committing a real file at
#        CLAUDE.md (review item 10b option (b)) — the two files then diverge
#        silently, which is the outcome the symlink shape exists to prevent.
#   3.   the provisioning step is dropped or commented out, and the next fresh
#        Windows clone is inert again.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PS1FILE="$REPO/provision/windows.ps1"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = 0 ]; then pass "$2"; else fail "$2"; fi; }

[ -f "$PS1FILE" ] || { echo "FAIL: $PS1FILE missing" >&2; exit 1; }

# ── 1-2. The tracked shape, read from the INDEX ───────────────────────────────
# git ls-files -s is the authority, not the worktree: on a core.symlinks=false
# checkout the worktree lies (regular file) while the index still says 120000.
# Reading the index means this suite gives the same verdict on every platform,
# including the one box where the bug reproduces.
mode="$(cd "$REPO" && git ls-files -s CLAUDE.md 2>/dev/null | awk '{print $1}')"
[ "$mode" = 120000 ]
check $? "CLAUDE.md is tracked as a symlink (mode 120000, got '${mode:-<untracked>}')"

target="$(cd "$REPO" && git cat-file -p :CLAUDE.md 2>/dev/null)"
[ "$target" = "AGENTS.md" ]
check $? "the tracked symlink points at AGENTS.md (got '${target:-<none>}')"

# ── 3. The Windows provisioning step ──────────────────────────────────────────
# Comments are stripped first: the file DESCRIBES the setting in its step header
# and in this test's rationale, and matching that prose would pass even after
# the live line was deleted. Same false-positive trap fleet-ssh-config-ps.test.sh
# hit on its first run.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }
uncommented "$PS1FILE" | grep -qE "config[^#]*core\.symlinks[^#]*true"
check $? "windows.ps1 sets core.symlinks=true (uncommented)"

# ── 4. The repair must not be able to leave the path DELETED ─────────────────
# The repair deletes the plain file and asks git to write the symlink back. That
# order is forced -- git checkout-index will not overwrite an existing path --
# but it means a failure between the two steps leaves no CLAUDE.md at all, and
# the repair for a silent breakage must not have a louder breakage of its own as
# its failure mode. Every other git call in this file checks $LASTEXITCODE
# (bootstrap.sh, icacls, robocopy); this one is the destructive one, so it is
# the one that must.
body="$(uncommented "$PS1FILE")"
printf '%s' "$body" | grep -A6 'checkout-index' | grep -qE 'LASTEXITCODE|Test-Path'
check $? "windows.ps1 verifies the re-materialisation instead of trusting it"

# ...and the failure branch must STOP, not retry through git. A fallback that
# re-runs a checkout is worse than none: it fires exactly when git could not
# write the symlink, so under the same core.symlinks state it either fails again
# or writes the 9-byte plain file back -- silently restoring the original bug
# while printing a line that reads like a recovery. The whole point of this file
# is that the plain file is INVISIBLE once it exists. So the branch throws, the
# way windows.ps1 already throws when Git Bash is missing.
branch="$(printf '%s' "$body" | grep -A8 'checkout-index')"
printf '%s' "$branch" | grep -q 'throw'
check $? "the failed-repair branch throws"
printf '%s' "$branch" | grep -qE 'git checkout( |$)'
if [ $? -eq 0 ]; then
    fail "the failed-repair branch retries through git checkout, which can restore the plain file"
else
    pass "the failed-repair branch does not retry through git"
fi

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "$FAIL FAILED" >&2; exit 1; fi
