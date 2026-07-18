# Personal git workflow framework — one model, two modes

**Date:** 2026-07-18
**Status:** approved (design)

## Problem

There is no single framework for how Claude (and the user) should do git across
the personal fleet. The rules are scattered across **at least five places that
disagree**:

- **`machines` `.claude/memory/project.md`** — "work directly on `main`, push
  whenever ready, branch only for BIG work."
- **The harness default** (every session) — the opposite: "commit/push only when
  asked; if on the default branch, branch first."
- **Orca** — actually spawns per-feature worktree branches, so branching happens
  constantly, contradicting "work directly on main."
- **`~/.dotfiles`** — a *different, now-dead* model: bare repo, `main` +
  per-hostname branches, `--git-dir/--work-tree` invocation.
- **Pure work repos** — a *third* model: protected `main`, land via PR
  (`pure-dev`), never push.

The concrete symptom: in an Orca worktree, Claude reads the unqualified "push to
`main`" note and tries to push to `main` from the worktree.

This spec defines **one** framework for the personal fleet, so every git rule is
a derivation of it rather than a scattered, contradictory note.

## Scope

**Personal fleet-sync repos only** — `machines` now, `vps` and similar normal
repos by opt-in. Explicitly **NOT** the Pure work repos: those keep the
`pure-dev` PR-for-approval convention and are governed separately (the framework
just points to them as out of scope).

This framework **supersedes the old `~/.dotfiles` model.** That bare-`$HOME`
repo is already a dead husk on NixOS (0 tracked files; Home Manager owns the home
config). Its per-*host* branch topology is replaced by this framework's
per-*feature* worktree branches. Physically retiring the husk and unifying
profile/home-state provisioning is a **separate follow-up project** (see Out of
scope) — this spec only replaces the *workflow model*.

## The framework: one model, two modes

Because scope is personal-only, there is exactly **one integration model**
(`main` is the shared truth; you push to `main`, no review) expressed in **two
modes** selected by where you are working:

| Mode | Where | Commit target | Stay current | Integrate |
|---|---|---|---|---|
| **Main-checkout** | canonical clone, on `main` | `main` | (you're on it) | ready/small → push `main`; big/isolated → spawn a worktree |
| **Worktree** | linked worktree, feature branch | the branch | auto-sync `main`→branch (merge) | at checkpoints, offer FF merge-back into `main` (run in base checkout) |

Every mode answers the same three questions: **where commits go, how the branch
stays current, how work reaches `main`.**

### Worktree lifecycle

Worktree mode is a lifecycle, and its front half already exists:

```
create → setup → work → sync → integrate → remove
```

- **create + setup** — Orca spawns the worktree; `scripts/orca-worktree-setup.sh`
  (commits `da49a5b`/`dfca9f4`) links gitignored config + emits the collision-safe
  test command. *Already built.*
- **work** — commit on the feature branch, never on `main`.
- **sync** — auto-merge `main` into the branch when safe (below).
- **integrate** — at checkpoints, offer FF merge-back into `main` (below).
- **remove** — after merge-back, tear the worktree down (`git worktree remove`,
  delete the branch). Offered, not automatic.

The new enforcement (this spec) is the **work → sync → integrate** half.

### Sync rule (main → branch)

Auto-run `git merge main` in the worktree to stay current, **only when safe**:
working tree clean AND branch behind local `main` AND the merge is conflict-free.
On a dirty tree or a conflict → stop and ask.

- **Merge, never rebase** — these are Orca-tracked local branches; rewriting them
  is unsafe.
- Keeping local `main` itself current with `origin` is **left to Orca** — the
  hook neither pulls `main` nor nags about `main` vs `origin`.

### Integrate rule (merge-back to main)

At natural checkpoints (feature complete, tests green), **offer** — never
automatically — to merge the branch back into `main`.

**Mechanic — runs in the base checkout, prefers fast-forward:**

```
git -C <base-checkout> merge --ff-only <branch>
```

- Merge-back **must** run in the base checkout (where `main` lives): git refuses
  to update a branch checked out in another worktree, so `git switch main` /
  `git branch -f main` / `git push . HEAD:main` from inside the worktree all fail.
  `<base-checkout>` is derived from `git rev-parse --git-common-dir` (the parent
  of the shared `.git`), not hardcoded.
- **Guards:** before merging, verify the base checkout is on `main`
  (`git -C <base> symbolic-ref --short HEAD` = `main`) and clean
  (`git -C <base> status --porcelain` empty). If not → report and defer; never
  reach into a dirty/off-main checkout.
- **`--ff-only`:** the sync rule keeps `main` merged into the branch, so `main`
  is an ancestor of the branch tip → merge-back is a **fast-forward**: no merge
  commit, no conflicts, no working-tree churn. This is the **synergy** that keeps
  the mechanic simple: sync makes integrate a fast-forward.
- **Non-FF fallback:** if `--ff-only` is refused (`main` diverged
  independently — rare), stop and ask; do a real merge only with explicit OK.
- After a clean merge-back, **offer** to push `main` (the fleet-sync step) and to
  remove the worktree. Both user-gated.

**Base branch** = the repo's default branch (`main`). Git records no reliable
fork parent, so we default to `main` rather than reconstruct it. (Override
deferred until a repo needs it.)

## Where the framework lives (de-scattering)

One canonical source, referenced everywhere — not restated in five places:

### 1. `agents/docs/git-workflow.md` (new — single source of truth)

The framework prose above (both modes, lifecycle, sync + integrate rules). This
is the ONE authoritative statement. Everything else points at it or surfaces a
section of it — nothing restates it.

### 2. `agents/plugin/hooks/worktree-workflow.sh` (new — SessionStart hook)

Ships in the shared `cyphy` plugin (synced into every profile). It *fires* only
when **both** hold:

1. **cwd is a linked worktree** — `git rev-parse --absolute-git-dir` ≠ realpath
   of `git rev-parse --git-common-dir` (equal in a base checkout, different in a
   linked worktree).
2. **the repo opts in** — a committed marker `.claude/worktree-sync-to-main` at
   the worktree root.

If either is false → exit 0 silently. This is what keeps it fleet-sync-only and
silent in Pure work-repo worktrees (they never carry the marker), even though the
hook is installed in every profile.

When it fires it prints:
- **Live state** — worktree name + branch; base branch (`main`); ahead/behind of
  the branch vs local `main` (`git rev-list --left-right --count main...HEAD`);
  clean/dirty (`git status --porcelain`); base-checkout path.
- **The worktree-mode rules** — by `cat`-ing the worktree section of
  `agents/docs/git-workflow.md` (found via `${CLAUDE_PLUGIN_ROOT}/../docs/…`), so
  the rules live in ONE file and the hook only surfaces them + the live state. It
  runs no git-mutating command itself.

### 3. `.claude/worktree-sync-to-main` (new — opt-in marker in `machines`)

An empty/short committed file at the `machines` repo root; its presence is the
fleet-sync opt-in. Committed on `main`, so it lands in every worktree checkout.
Adding a future fleet-sync repo = commit the same marker there.

### 4. `hooks.json` registration

Add `worktree-workflow.sh` to the existing `SessionStart` array in
`agents/plugin/hooks/hooks.json`, after the current three.

### 5. Reconcile the scattered notes

- **`machines` `project.md`** — replace the "work directly on `main` … straight
  to `main`" bullet with a pointer to the framework doc, scoped to
  **main-checkout mode**. This removes the unqualified push-to-main instruction
  that misfired in worktrees.
- **`agents/memory/global.md`** — one-line pointer to `agents/docs/git-workflow.md`
  as the personal git framework (so it's discoverable without being restated).

## Data flow

- **Session in a marked worktree** → `worktree-workflow.sh` detects linked
  worktree + marker → prints live divergence + the worktree-mode rules → Claude
  commits on the branch, auto-merges `main` in when clean+conflict-free, offers
  FF merge-back (run in the base checkout) at checkpoints, then offers teardown.
- **Session in the base checkout** → hook detects NOT a linked worktree → exits
  silently → main-checkout-mode behavior (framework doc + the scope-fixed
  `project.md` pointer) applies.

## Error handling / safety

- The hook exits 0 on every path; detection/git failure must never block a
  session from starting.
- Auto-sync only on a clean tree + conflict-free merge; otherwise stop and ask.
- Merge-back uses `--ff-only` + on-`main`/clean guards on the base checkout; a
  real (non-FF) merge and the `main` push are always user-gated.
- Rebase is never used for sync.

## Testing / verification

1. **Fires in a worktree** — start a session in this worktree; confirm the hook
   injects branch, base `main`, ahead/behind (currently 25 behind, 0 ahead),
   clean state, and the worktree-mode rules from the doc.
2. **Silent in the base checkout** — start a session in `/home/me/machines`;
   confirm the hook prints nothing (not a linked worktree).
3. **Silent without the marker** — temporarily remove the marker; confirm the
   hook stays silent even in a worktree.
4. **Sync path** — with a clean tree and the branch behind `main`, confirm
   `git merge main` in the worktree is the correct, conflict-free (here
   fast-forward) operation.
5. **Merge-back mechanic** — confirm `git -C <base-checkout> merge --ff-only
   <branch>` succeeds when the branch is a clean descendant, and that the
   in-worktree `git switch main && git merge` is refused (checked-out-elsewhere).
6. **Single-source check** — confirm the hook surfaces the doc's worktree section
   rather than a second copy of the rules.

## Out of scope (→ Project 2: OS-agnostic profile/home-state provisioning)

Deferred to a separate brainstorm/spec:

- Physically retiring the `~/.dotfiles` husk and deleting the stale
  `$HOME/CLAUDE.md` that documents the dead bare-repo model (needs a check of
  what, if anything, non-NixOS machines still get from it).
- Collapsing the duplicated linking logic (`bootstrap.sh` **and** `claude.nix`
  reimplement the same one-hop symlinks) into one OS-agnostic deployer, and
  minimizing per-profile fan-out (shared memory already loads via a hook from one
  canonical path).
- Any change to Orca's worktree lifecycle or its `main`↔`origin` syncing.
- The Pure work-repo PR flow (`pure-dev`) — governed separately.
- A configurable base branch other than `main`.
