# `/orca-setup` — one-time per-repo Orca worktree wiring — design

*Date: 2026-07-20 · Status: approved design, pending implementation plan*

## Problem

Orca (StablyAI's multi-agent IDE) spawns each task as a managed git worktree and
runs a per-repo **setup script** on every fresh worktree. That script is the
`machines` dispatcher (`scripts/orca-worktree-setup.sh`), which symlinks
gitignored local config from the base checkout and delegates to a repo-specific
hook. Two gaps make adopting it per repo a manual, error-prone chore:

1. **Wiring the setup field is hand-work.** The setup command lives in the
   machine-local, Orca-owned `orca-data.json`, mirrored in two places
   (`.repos[]` and `.projectHostSetups[]`), keyed per repo. Pointing a repo at
   the dispatcher means pasting the one-liner into the Orca UI once per repo per
   machine, and it only sticks after the repo has been opened in Orca once.
2. **Per-repo custom rules have no on-ramp.** The dispatcher already delegates to
   a committed `$repo/.orca/worktree-setup.sh`, but nothing scaffolds that file
   or its optional gortex wiring — you write it from scratch each time.

## Solution

One **skill** in the cyphy plugin, invocable as `/orca-setup`. Run once per repo
per machine, it (a) scaffolds the repo's committed `.orca/worktree-setup.sh`
custom-rules delegate and (b) wires that repo's Orca setup field to the shared
dispatcher. Same **hybrid architecture as `/ship`**: `SKILL.md` orchestrates the
gated, user-in-the-loop steps; a committed, unit-tested `wire-orca.sh` does the
deterministic `orca-data.json` mutation.

Explicitly **not** a subagent: it mutates machine-local config and commits a
file — it wants the user in the loop and the harness safety classifier on the
writes. A detached context buys nothing.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | **Form:** one cyphy-plugin skill, `/orca-setup`. Not a subagent. One-time per-repo, per-machine. |
| 2 | **Architecture:** hybrid — `SKILL.md` runs the gated steps; a committed, unit-tested `wire-orca.sh` does the deterministic JSON write; `worktree-setup.template.sh` is the scaffold. |
| 3 | **Propagate scope:** wire-on-scaffold only — one repo per run. "All repos" = run it once in each fleet-sync repo. No bulk loop over Orca's DB. |
| 4 | **Rules location:** committed `$base/.orca/worktree-setup.sh` (synced across the fleet, travels with the repo — the dispatcher checks it first). |
| 5 | **Gortex block:** readiness prep only (daemon up + base repo tracked + base-slug marker), opt-in. NOT creation-time overlay registration — a fresh worktree has zero uncommitted edits, so an overlay would be empty; the working agent registers its own overlay later per `cyphy:worktree-agent`. |
| 6 | **Identity:** match Orca entries on **normalized origin URL → `projectId`**, never path (path is per-machine/per-worktree). Resolve the base checkout via `git rev-parse --git-common-dir`. Refuse work/Pure repos (origin `thepureapp/*`) — pure-dev flow. |
| 7 | **JSON write:** backup-first, Orca-closed, both mirrors, idempotent no-op, never clobber a foreign setup, graceful stop when the repo is unknown to Orca. |

## Components & file layout

```
agents/plugin/skills/orca-setup/
  SKILL.md                     # orchestration procedure (gated steps)
  wire-orca.sh                 # deterministic orca-data.json writer (jq), unit-tested
  worktree-setup.template.sh   # the committed .orca/ scaffold
  tests/wire-orca.test.sh      # mocks orca-data.json + a temp repo, covers the matrix
```

- **`SKILL.md`** — the ordered procedure the agent follows for an `/orca-setup`
  run. Links to the dispatcher and `cyphy:worktree-agent` rather than
  duplicating them.
- **`wire-orca.sh`** — deterministic, non-interactive. Input: the target
  `orca-data.json` path, the normalized `projectId`, and the setup one-liner.
  Emits a single status token per the matrix below. Reusable by hand.
- **`worktree-setup.template.sh`** — the scaffold written to
  `$base/.orca/worktree-setup.sh`. Marker-delimited managed blocks so re-runs
  update only what the skill owns.
- **`tests/wire-orca.test.sh`** — same mock-the-tools style as
  `fleet-pull.test.sh` / `worktree-workflow.test.sh`.

## Control flow of an `/orca-setup` run

`SKILL.md` drives; `wire-orca.sh` does the JSON half.

1. **Resolve identity & guard.**
   - Base checkout = parent of `git rev-parse --git-common-dir` (works from a
     worktree or the main checkout).
   - Project key = normalized `origin` URL (reuse `fleet-pull.sh`'s
     `normalize_url`) → Orca's `projectId` (`github:owner/repo`).
   - **Refuse work/Pure repos** (origin `thepureapp/*`) — they keep the pure-dev
     PR flow. Same guard family as `/ship`.

2. **Scaffold `$base/.orca/worktree-setup.sh`** (committed → synced).
   - Non-fatal template (never `set -e`, always `exit 0`), matching the
     dispatcher's conventions.
   - Sections: a `log()` stderr helper; a clearly-marked **repo-specific steps**
     stub; and an opt-in **gortex readiness** block (decision #5): ensure the
     daemon is up (`gortex daemon start --detach` if `gortex daemon status`
     fails), confirm the base repo is tracked, and drop a marker recording the
     base workspace slug so the working agent's own
     `overlay_register {workspace_id: <slug>}` is a one-liner and never hits
     "cwd not covered".
   - If the file already exists → don't clobber; update only the managed
     (marker-delimited) blocks and show a diff. Offer to `git add` it.

3. **Wire the Orca setup field** (machine-local; `wire-orca.sh`).
   - **Precondition — repo known to Orca:** if no entry matches the `projectId`,
     the repo hasn't been opened in Orca yet → tell the user to open it once,
     stop gracefully (Orca can't be pre-seeded).
   - **Precondition — Orca closed:** the write lands on Orca's *next launch*;
     writing while Orca runs races its own rewrite. If an Orca process is
     running, ask the user to quit it first.
   - Back up `orca-data.json` (timestamped) before writing.
   - Set `scripts.setup` = `bash "$HOME/machines/scripts/orca-worktree-setup.sh"`
     in **both mirrors**: `.repos[]` and `.projectHostSetups[]` for the matched
     entry.
   - **Idempotent:** already the dispatcher → no-op. A *different* non-empty
     setup (e.g. pure-dev) → do **not** clobber; report and ask.
   - Report what changed; note it takes effect on next Orca launch.

## Per-write decision matrix (`wire-orca.sh`)

For the matched `projectId` entry (both mirrors):

```
entry present?
  no        -> ABSENT (repo not opened in Orca; can't pre-seed)
current setup == dispatcher one-liner?
  yes       -> UNCHANGED (idempotent no-op)
current setup empty?
  yes       -> WROTE (both mirrors set)
current setup is some OTHER command?
  yes       -> CONFLICT (foreign setup, e.g. pure-dev; not clobbered — caller asks)
```

`wire-orca.sh` always backs up before any write and never touches an entry other
than the matched `projectId`. The Orca-running check and the user prompts live in
`SKILL.md` (the gated half), not in the deterministic writer.

## Discovery & identity

- **Base checkout:** `git rev-parse --git-common-dir` → parent (mirrors the
  dispatcher). The skill may run from a worktree; the Orca entry is keyed to the
  base.
- **Project key:** normalized `origin` URL. Canonicalize the
  `git@host:owner/repo(.git)` ↔ `https://host/owner/repo` forms with
  `fleet-pull.sh`'s `normalize_url`, then map to Orca's `projectId`
  (`github:owner/repo`). Never match on path — `orca-data.json` keys the base
  path, which differs per machine and per worktree.
- **`orca` CLI:** `~/.local/bin/orca` (regenerated per Orca upgrade by
  `provision/orca-serve.sh`) is **not depended upon** — it isn't present on
  every box and exposes no persistent setup-field setter. The skill reads/edits
  `orca-data.json` directly (the store the CLI itself uses). If the CLI is
  present it may be used to *read* the registry (`orca repo list --json`), but
  the JSON is the source of truth.

## Machine scope

Orca's repo/worktree registry is **per-runtime, i.e. per host** (the WSL runtime
and a Windows runtime keep separate registries). `orca-data.json` is not synced.
So `/orca-setup` is a per-machine action — run it on each box where you want the
repo wired. The committed `.orca/worktree-setup.sh` (step 2) *does* sync, so the
custom rules travel; only the machine-local field-wiring (step 3) repeats.

## Error handling

- Every gate that can't proceed (foreign setup, repo unknown to Orca, Orca
  running) **stops and asks** — it never guesses or clobbers.
- The scaffold is non-fatal by construction; a bad delegate can't block Orca.
- `wire-orca.sh` backs up before writing and mutates only the matched entry.

## Testing

`tests/wire-orca.test.sh`, mocking a fixture `orca-data.json` + a temp git repo
(as `fleet-pull.test.sh` mocks ssh/git):

- **projectId match** — origin variants canonicalize to the same `projectId`.
- **Work-repo refusal** — `thepureapp/*` origin is refused before any write.
- **No-entry graceful stop** — unknown `projectId` → `ABSENT`, no write.
- **Backup created** — a timestamped backup exists before the file is modified.
- **Both mirrors written** — `.repos[]` and `.projectHostSetups[]` both updated.
- **Idempotent no-op** — a second run on an already-wired entry → `UNCHANGED`.
- **Foreign setup not clobbered** — a pure-dev-style setup → `CONFLICT`, value
  untouched.
- **Scaffold non-fatal** — the generated `.orca/worktree-setup.sh` exits 0 even
  when its steps fail.

## Non-goals

- No bulk propagation across Orca's whole repo DB (decision #3).
- No creation-time gortex overlay (decision #5) — readiness prep only.
- No work/Pure-repo support — pure-dev PR flow.
- No dependency on the `orca` CLI being installed.
- Not a general Orca-config editor — scoped to the worktree-setup field.

## Where this work lands

Deliberate feature work → committed on the `orca-worktrees` branch (worktree
mode), with a FF merge-back into `main` offered at the end, then `/ship` to the
fleet.
