#!/usr/bin/env bash
# Every editor's per-project directory must be ignored in THIS repo.
#
# THE BUG THIS EXISTS FOR: `.gitignore` covered `.idea/`, `.vscode/` and
# `*.sublime-*` but had no Zed entry. A single zero-byte `.zed/tasks.json` on
# desktop-wsl therefore made the clone permanently dirty, and `fleet-selfpull`'s
# dirty gate skipped it on every tick — 185 consecutive `SKIP dirty` lines and
# zero `OK`, 28 commits behind for ~35 hours, while the timer, the service and
# `.machines/last-converge` all reported success. One of those 28 unpulled
# commits revoked an SSH key that stayed trusted on the box as a result.
#
# So an uncovered editor directory here is not an untidiness issue — it is a
# silent fleet-sync outage with a security tail. Any editor anyone in this fleet
# actually opens the repo in belongs below.
#
# WHY A TEST FOR A CONFIG FILE: this repo has already shipped a silently-broken
# ignore pattern. `agents/.gitignore:9` carries a trailing inline comment, and
# gitignore does NOT strip those, so the pattern is the whole line including the
# comment and matches nothing (review item 9). A pattern that looks right and
# does nothing is exactly the failure `git check-ignore` catches and reading
# cannot. These assertions ask git, not the file.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# Ask git whether a path WOULD be ignored. --no-index matters: check-ignore
# reports nothing for a tracked path, so without it a pattern's absence and a
# path's tracked-ness are indistinguishable.
ignored() { git -C "$REPO" check-ignore --no-index -q "$1"; }

# Guard the guard: an unignorable path must come back NOT ignored, or every
# assertion below would pass vacuously.
if ignored "provision/lib/tiers.sh"; then
    die "check-ignore claims a tracked source file is ignored — this test proves nothing"
else
    pass "check-ignore correctly reports a normal source path as not ignored"
fi

# One entry per editor: the directory itself, and a file inside it — a rule
# written as `.zed` rather than `.zed/` covers one and not always the other.
# Zed is here because it is in use: `.config/zed` is dotfiles-tracked, and its
# stray file is what froze desktop-wsl. Do not pre-add editors nobody opens —
# `.fleet/` in particular would read as this repo's own fleet concept.
for d in .idea .vscode .zed; do
    if ignored "$d/"; then
        pass "$d/ is ignored"
    else
        die "$d/ is NOT ignored — an editor dir here makes the clone permanently dirty and fleet-selfpull skips it forever"
    fi
    if ignored "$d/settings.json"; then
        pass "$d/settings.json is ignored"
    else
        die "$d/settings.json is NOT ignored (the directory rule does not reach files inside it)"
    fi
done

# Sublime is file-shaped, not directory-shaped.
if ignored "machines.sublime-project"; then
    pass "*.sublime-* is ignored"
else
    die "*.sublime-* is NOT ignored"
fi

# The dirty-gate consequence, stated as its own case so a future edit that drops
# a pattern fails with the reason rather than just a name.
if ignored ".zed/tasks.json"; then
    pass ".zed/tasks.json — the exact path that froze desktop-wsl — is ignored"
else
    die ".zed/tasks.json is NOT ignored: this is the literal file that held a fleet member 28 commits behind"
fi

# agents/.gitignore's own patterns, asked of git rather than read. That file's
# header calls everything it lists untrackable — secrets, transcripts, caches —
# so a pattern that parses but matches nothing is the same silent failure as the
# missing `.zed/` above, with a worse tail: this one leaks instead of freezing.
#
# THE BUG THIS CAUGHT (review item 9):
#     settings.local.json   # machine-local per profile — never commit
# gitignore does not strip inline comments, so the pattern was the whole line,
# trailing comment included, and matched no path at all. The single line in that
# file carrying an inline comment was the one its own comment calls secret-bearing
# (gortex hooks plus a work Sentry token).
for p in agents/settings.local.json agents/.credentials.json agents/.env \
         agents/remote-settings.json agents/policy-limits.json; do
    if ignored "$p"; then
        pass "$p is ignored"
    else
        die "$p is NOT ignored — agents/.gitignore names it untrackable and git disagrees"
    fi
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
