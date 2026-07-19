# Personal git workflow

The one framework for git in the personal fleet-sync repos
(`github.com:metheoryt/*` — machines, vps, …). One model: **`main` is the shared
truth; you push to `main`, no review.** Two modes, picked by where you are.

Work repos (`github.com:thepureapp/*`) are NOT covered by this — they use the
pure-dev PR-for-approval flow.

## Main-checkout mode — on `main` in the canonical clone

- Commit on `main`.
- Ready / small change → commit + push `main`.
- Big or risky work → spawn a worktree and switch to worktree mode.

## Worktree mode — a feature branch in a linked worktree

<!-- WORKTREE-MODE:START -->
You are on a feature branch in a linked worktree. `main` lives in the base
checkout, not here.

- **Commit on the branch, never on `main`.** Do not push `main` from the worktree.
- **Stay current — auto-sync `main` → branch.** When the working tree is clean,
  the branch is behind `main`, and the merge is conflict-free, run `git merge main`
  in the worktree to catch up. On a dirty tree or a conflict, stop and ask. Always
  **merge, never rebase** (these branches are Orca-tracked). Keeping local `main`
  current with `origin` is Orca's job — don't pull `main` or worry about `main`
  vs `origin`.
- **Integrate — offer FF merge-back at checkpoints.** When the work is complete
  and tests pass, *offer* (never automatic) to merge the branch back into `main`.
  It must run in the **base checkout** (git refuses to update `main` from another
  worktree):

      git -C <base-checkout> merge --ff-only <branch>

  First check the base checkout is on `main` and clean; if not, report and defer.
  Because you kept syncing `main` in, this is a fast-forward. If `--ff-only` is
  refused (main diverged independently), stop and ask — do a real merge only with
  explicit OK.
- **Finish.** After a clean merge-back, offer to push `main` and to delete the
  branch. Also offer to remove the worktree (`git worktree remove`) — **unless the
  session is Orca-managed** (`TERM_PROGRAM=Orca`), in which case Orca owns the
  worktree lifecycle: offer branch deletion only, never worktree removal. All
  user-gated.
<!-- WORKTREE-MODE:END -->

---
*Enforcement: `agents/plugin/hooks/worktree-workflow.sh` surfaces the worktree
section above (plus live divergence) at session start in a non-blocklisted linked
worktree. This doc is the single source of truth — the hook and the memory notes
point here, they do not restate the rules.*
