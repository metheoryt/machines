# Worktree-aware git workflow for Claude

**Date:** 2026-07-18
**Status:** approved (design)

## Problem

When Claude works inside an Orca-spawned git worktree
(`~/orca/workspaces/<repo>/<branch>`, a *linked* worktree of `~/machines`), it
still wants to commit and push straight to `main`. The root cause is a memory
note in `machines`' `.claude/memory/project.md`:

> Work directly on `main` and commit + push whenever something is ready … small/
> ready changes go straight to `main`.

That rule is correct in the **main checkout** (`~/machines`, the fleet-sync
model) but wrong in a worktree, where the whole point is an isolated branch.
Claude reads the unqualified note and pushes to `main` from the worktree.

We want, when — and only when — Claude is in a linked worktree of a fleet-sync
repo:

1. Commit to the branch currently checked out, never to `main`.
2. Keep that branch in sync with `main` (bring `main`'s new commits into the
   branch) as work proceeds.
3. At checkpoints, **offer** to merge the branch back into `main`.

## Scope

**Fleet-sync repos only** — `machines` now, and any repo that opts in later
(e.g. `~/.dotfiles`). Explicitly NOT the Pure work repos: those run the
`pure-dev` PR-for-approval convention (never push, queue a PR), where an
"offer to merge back to main" rule would be actively wrong. Scope is enforced by
a per-repo opt-in marker (below), so the globally-installed hook stays silent in
work-repo worktrees even though it ships in every profile.

## Decision

A **single new SessionStart hook** that fires conditionally and injects live
git state + the three rules, **plus** a one-line scope fix to the existing
`project.md` note.

Chosen over a static memory note because the hook (a) auto-detects worktree vs.
main checkout, so the same note can't misfire in `~/machines`, and (b) computes
live divergence (ahead/behind, clean/dirty) — a static note can only print rules.
The `project.md` note is fixed regardless, because that stale sentence is the
reported bug's root cause.

## Components

### 1. `agents/plugin/hooks/worktree-workflow.sh` (new — SessionStart hook)

Ships in the shared `cyphy` plugin hooks, so it syncs into every profile
(`~/.claude`, `~/.claude-pure`, …) via the normal `agents/` symlinking. It
*fires* only when **both** hold:

1. **cwd is a linked worktree** — `git rev-parse --absolute-git-dir` differs
   from the realpath of `git rev-parse --git-common-dir`. (Equal in a main
   checkout, different in a linked worktree.)
2. **the repo opts in** — a committed marker file `.claude/worktree-sync-to-main`
   exists at the worktree root.

If either is false → exit 0 silently. This is what keeps it fleet-sync-only:
Pure work repos never carry the marker.

When it fires, it prints to stdout (SessionStart context injection):

- **Live state:** worktree name + current branch; base branch (`main`);
  ahead/behind counts of the branch vs **local** `main`
  (`git rev-list --left-right --count main...HEAD`); whether the working tree is
  clean (`git status --porcelain`).
- **The three rules** (below), phrased as instructions to Claude.

The hook only reports and instructs; it runs no git-mutating command itself.
Base branch defaults to the repo's default branch (`main`) — git records no
reliable fork parent, so we do not try to reconstruct it. (An override can be
added later if a repo forks worktrees off something other than `main`.)

### 2. The three injected rules

1. **Commit to the current branch, never to `main`.** In a worktree you work on
   the checked-out branch and do not push to `main` from here.

2. **Auto-sync `main` → branch when safe.** When the working tree is clean AND
   the branch is behind local `main` AND the merge is conflict-free, run
   `git merge main` in the worktree automatically to stay current. On a dirty
   tree or a merge conflict, stop and ask the user instead. **Sync method is
   merge** (never rebase — these are Orca-tracked local branches; rewriting them
   is unsafe). Keeping local `main` itself current with `origin` is **left to
   Orca** — the hook neither pulls `main` nor nags about `main` vs `origin`.

3. **Offer merge-back at checkpoints — never automatic.** At natural checkpoints
   (feature complete, tests green), offer to merge the branch back into `main`.
   The merge-back **must run in the main checkout**:
   `git -C /home/me/machines merge <branch>` — git refuses to merge into `main`
   from inside the worktree because `main` is checked out at `~/machines`. After
   a clean merge-back, offer to push `main` (the fleet-sync step). Never run the
   merge-back or the push without the user's go-ahead.

### 3. `hooks.json` registration

Add `worktree-workflow.sh` to the existing `SessionStart` hook array in
`agents/plugin/hooks/hooks.json`, after the current three
(`gortex-onboard-check`, `global-memory-load`, `project-memory-check`).

### 4. `.claude/worktree-sync-to-main` (new — opt-in marker in `machines`)

An empty (or short self-documenting) committed file at the `machines` repo root.
Its presence is the fleet-sync opt-in. Committed on `main` so it lands in every
worktree checkout automatically. Adding a future fleet-sync repo = commit the
same marker there.

### 5. `project.md` note fix (in `machines`)

Scope the existing "work directly on `main` … straight to `main`" bullet to the
**main checkout**, and cross-reference the worktree rules (the hook now injects
them in worktrees). This removes the unqualified push-to-main instruction that
Claude was following from inside worktrees.

## Data flow

Session start in a worktree → `worktree-workflow.sh` runs → detects linked
worktree + marker → computes branch/base/ahead-behind/clean → prints state +
three rules → Claude follows them: commits to the branch, auto-merges `main` in
when clean+conflict-free, offers merge-back (run in `~/machines`) at checkpoints.

Session start in the `~/machines` main checkout → hook detects it is NOT a
linked worktree → exits silently → the (now scope-fixed) `project.md`
"work directly on main" note applies as before.

## Error handling / safety

- Hook exits 0 on every path; a detection or git failure must never block a
  session from starting.
- Auto-sync only on clean tree + conflict-free merge; otherwise stop and ask.
- Merge-back and `main` push are always user-gated.
- Rebase is never used for sync (Orca-tracked branches).

## Testing / verification

1. **Fires in a worktree:** start a session in this worktree; confirm the hook
   injects the branch name, base `main`, ahead/behind (here: 25 behind, 0
   ahead), clean state, and the three rules.
2. **Silent in the main checkout:** start a session in `/home/me/machines`;
   confirm the hook prints nothing (not a linked worktree).
3. **Silent without the marker:** temporarily rename the marker; confirm the
   hook stays silent even in a worktree.
4. **Auto-sync path:** with a clean tree and the branch behind `main`, confirm
   `git merge main` in the worktree is the correct, conflict-free (here
   fast-forward) operation.
5. **Merge-back mechanic:** confirm `git -C /home/me/machines merge <branch>`
   is what succeeds, and that the in-worktree `git switch main && git merge` is
   refused (checked-out-elsewhere).

## Out of scope

- Opting `~/.dotfiles` in (bare-repo, worktrees rare) — add the marker later if
  wanted.
- Any change to Orca's worktree lifecycle or its `main`↔`origin` syncing.
- A configurable base branch other than `main` (add when a repo needs it).
