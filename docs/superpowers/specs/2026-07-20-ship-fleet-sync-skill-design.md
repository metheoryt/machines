# `/ship` — fleet-aware git skill — design

*Date: 2026-07-20 · Status: approved design, pending implementation plan*

## Problem

Two recurring pains around git on this fleet:

1. **Re-deriving conventions.** The git rules and footguns are scattered across
   `agents/docs/git-workflow.md`, the `worktree-workflow.sh` hook, and global
   memory (fleet SSH shell-dispatch, Windows HTTPS-push, gh-vs-git auth, Pure
   exclusion). They get re-derived each session instead of loaded as one
   authoritative reference.
2. **Manual multi-step shipping.** Landing a change on the fleet means, by hand:
   commit → (worktree) fast-forward merge-back into `main` → push `origin` →
   then pull on every other fleet member. Done twice by hand this session.

## Solution

One **skill** in the cyphy plugin, invocable as `/ship`. It runs in the main
session (not a subagent) so every mutation stays gated by the user and the
harness safety classifier. It carries a consolidated fleet-aware-git reference
(pain #1) and exposes the end-to-end shipping flow (pain #2).

Explicitly **not** a subagent: git mutations need the main task's context, want
the user in the loop, and cannot escape the safety classifier — a detached
context buys nothing and loses all three.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | **Form:** one cyphy-plugin skill, `/ship`. Not a subagent. |
| 2 | **Architecture:** hybrid — `SKILL.md` runs the gated mutations; a committed, unit-tested `fleet-pull.sh` does the deterministic cross-shell fleet half. |
| 3 | **Local half:** full chain from a dirty tree — guard → commit (propose msg, user confirms) → (worktree) FF merge-back → push `origin main`. |
| 4 | **Fleet-pull:** FF-only, skip-if-unsafe. Unreachable / absent / dirty / diverged each become a `SKIP` row. **Zero destructive ops** — never force, merge, or stash on a remote box. |
| 5 | **Scope:** any fleet-sync repo. Members' checkouts discovered by **normalized `origin` remote-URL match**, not by path convention. Work/Pure repos are refused (they use the pure-dev PR flow). |
| 6 | **Self-detection:** by **tailnet IP**, never OS hostname (logical names `desktop`/`server` map to model-code hostnames `g614jv`/`g513ie` through `fleet.json`; that mapping drifts). |

## Components & file layout

```
agents/plugin/skills/ship/
  SKILL.md                     # orchestration procedure + fleet-git reference
  fleet-pull.sh                # deterministic, non-interactive fleet half
  tests/fleet-pull.test.sh     # mocks ssh/git, covers the decision matrix
```

- **`SKILL.md`** — the ordered procedure the agent follows for a `/ship` run,
  plus a short "fleet-aware git" reference that **links to** the existing
  sources (`git-workflow.md`, the footgun memory) rather than duplicating them.
  Invoking the skill is also the "stop re-deriving conventions" payload.
- **`fleet-pull.sh`** — deterministic and non-interactive. Input: the repo's
  `origin` URL. For each other member it discovers the checkout, checks safety,
  runs `git pull --ff-only origin main`, and emits a summary table. Reusable
  outside Claude (runnable by hand).
- **`tests/fleet-pull.test.sh`** — same mock-the-tools style as
  `worktree-workflow.test.sh`; covers URL normalization and every
  `OK` / `SKIP(unreachable|absent|dirty|diverged)` branch.

## Control flow of a `/ship` run

`SKILL.md` drives; the script does the fleet half.

1. **Guard.** Refuse in a Pure/work repo (pure-dev PR flow). Confirm this is a
   fleet-sync repo. Detect worktree vs main-checkout mode.
2. **Commit** (if dirty). Show the change, propose a commit message, user
   confirms → commit on the **branch** (worktree mode) or **main**
   (main-checkout mode). Never commit on `main` from a worktree.
3. **Merge-back** (worktree mode only). Verify the base checkout is on `main`
   and clean, then `git -C <base> merge --ff-only <branch>`. Not a FF → stop
   and ask (no real merge without explicit OK).
4. **Push.** `git push origin main` from the base checkout. If the safety
   classifier denies it, report and hand the user the exact command to run.
5. **Fleet-pull.** Run `fleet-pull.sh <origin-url>`; print the summary table.
6. **Finish** (optional tail). Offer branch deletion only — honoring the Orca
   rule (`TERM_PROGRAM=Orca` ⇒ never offer worktree removal).

## Discovery & the shell split

- **Members** come from the SSH aliases / `fleet.json` (`latitude`, `desktop`,
  `server`, `hub`), minus self.
- Every remote step runs as `ssh <alias> bash -s < script` — which dispatches
  to WSL bash on the Windows boxes (`desktop`, `server`) and plain bash on
  `latitude`/`hub`, so the fish-vs-PowerShell login-shell split never bites.
- A probe script searches each box's known roots (`~`, `~/my`, `~/pure`,
  `~/cyphy671`, `~/machines`) at shallow depth for a checkout whose **normalized
  `origin` URL** equals the target (canonicalize the `git@host:owner/repo(.git)`
  ↔ `https://host/owner/repo` forms). First match wins; none ⇒ `SKIP(absent)`.

## Self-detection (tailnet IP)

The stable identity on this fleet is the tailnet, not the hostname.

1. Local box's own tailnet IPs: `tailscale ip -4 -6` (or `Self.TailscaleIPs`
   from `tailscale status --json`).
2. Each alias's effective target: `ssh -G <alias>` (reads generated config, no
   connection) → its `hostname`.
3. The alias whose resolved address ∈ the local tailnet IPs **is self** →
   exclude.

Avoid matching on the tailnet **node name** too — it can be an overridden
display name (`homeserver`). IP is the unambiguous key.

**Safety net:** because the fleet-pull is FF-only, a missed self-exclusion is a
harmless `already up to date` no-op on the box just pushed from — the exclusion
is for clean output, not safety.

## Per-member decision matrix (`fleet-pull.sh`)

For each member alias except self:

```
reachable? (ssh -o ConnectTimeout=5 -o BatchMode=yes <alias> true)
  no  -> SKIP(unreachable)
discover checkout by normalized origin URL
  none -> SKIP(absent)
dirty? (git -C <dir> status --porcelain nonempty)
  yes -> SKIP(dirty)
git -C <dir> pull --ff-only origin main
  ok   -> OK (old..new)
  fail -> SKIP(diverged)
```

Emit a human-readable summary table (and a parseable form for the skill).

## Error handling

- One bad box never aborts the run — each failure is a `SKIP` row; the loop
  continues.
- FF-refusal on merge-back, or a denied push, stop the **local** half and ask
  the user; they never touch the fleet.
- Reachability is a 5 s `BatchMode` probe so an offline box fails fast.

## Testing

`tests/fleet-pull.test.sh`, mocking `ssh`/`git`/`tailscale` on `PATH` (as
`worktree-workflow.test.sh` mocks `git`):

- URL normalization: `git@`/`https`/`.git`-suffix variants canonicalize equal.
- Self-exclusion: alias resolving to a local tailnet IP is dropped.
- Decision matrix: each of `OK`, `SKIP(unreachable)`, `SKIP(absent)`,
  `SKIP(dirty)`, `SKIP(diverged)` is produced from the matching mock state.
- Summary format is stable (so the skill can parse it).

## Non-goals

- No destructive remote ops (force/merge/stash on a member) — ever.
- No auto-resolution of a diverged or dirty member — reported for the user to
  fix by hand.
- No work/Pure-repo support — those keep the pure-dev PR flow.
- Not a subagent, and not a general "run any git command on the fleet" tool —
  scoped to the ship flow.

## Where this work lands

Deliberate feature work → committed on the `orca-worktrees` branch (worktree
mode), with a FF merge-back into `main` offered at the end. (Unlike the earlier
memory/doc edits this session, which reached `main` only incidentally because
the `~/.claude` memory symlink resolves into the base checkout.)
