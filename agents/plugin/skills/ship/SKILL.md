---
name: ship
description: "Use when the user wants to ship a change across the personal fleet — commit, fast-forward merge-back into main, push origin, then FF-pull the change on every other fleet member. Fleet-sync personal repos only (machines and siblings); refuses work/Pure repos, which keep the pure-dev PR flow. Invoked as /ship."
---

# /ship — land a change on the whole fleet

Runs in your session so every mutation stays gated by you and the safety
classifier. The local half is done here step-by-step; the fleet half is the
deterministic `fleet-pull.sh` next to this file.

Conventions this flow assumes live in `agents/docs/git-workflow.md` (worktree vs
main-checkout modes) and global memory (fleet SSH shell-dispatch, Windows
HTTPS-push, gh-vs-git auth). Read those if anything below is unclear.

## Guard (stop early if any fail)

1. `git remote get-url origin` — if it matches `thepureapp/`, STOP: work repos
   use the pure-dev PR flow, not /ship.
2. Confirm this is a fleet-sync repo (personal, cloned on multiple boxes). If
   unsure, ask.
3. Detect mode: linked worktree (git-dir != common-dir) → **worktree mode**;
   else **main-checkout mode**.

## Local half (you gate each mutation)

1. **Commit (if dirty).** Show `git status` + a diff summary, propose a commit
   message, get the user's OK, then commit — on the **branch** in worktree mode,
   on **main** in main-checkout mode. Never commit on `main` from a worktree.
2. **Merge-back (worktree mode only).** Verify the base checkout (`dirname` of
   the common git-dir) is on `main` and clean, then:
   `git -C <base> merge --ff-only <branch>`. If it is not a fast-forward, STOP
   and ask — never a real merge without explicit OK.
3. **Push.** `git -C <base> push origin main` (main-checkout: push from cwd). If
   the safety classifier denies it, report and give the user the exact command.

## Fleet half

Run the deterministic pull and show its table verbatim:

    ~/machines/agents/plugin/skills/ship/fleet-pull.sh "$(git remote get-url origin)"

It FF-pulls `main` on every other member, skipping any that are unreachable,
absent, dirty, or diverged. It never runs a destructive op. Report the table;
for any `SKIP(dirty)` / `SKIP(diverged)` row, tell the user that box needs a
manual look.

## Finish (optional)

Offer to delete the branch. Offer `git worktree remove` too — UNLESS the session
is Orca-managed (`TERM_PROGRAM=Orca`), in which case offer branch deletion only
(Orca owns the worktree lifecycle). All user-gated.
