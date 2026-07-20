# `/orca-setup` — one-time per-repo Orca worktree wiring — design

*Date: 2026-07-20 · Status: approved design, pending implementation plan*

## Problem

Orca (StablyAI's multi-agent IDE) spawns each task as a managed git worktree and
runs a per-repo **setup script** on every fresh worktree. That script is the
`machines` dispatcher (`scripts/orca-worktree-setup.sh`), which symlinks
gitignored local config from the base checkout and delegates to a repo-specific
hook. Two gaps make adopting it per repo a manual, error-prone chore:

1. **Knowing what to wire.** The setup command lives in Orca's per-repo settings
   (stored machine-locally in the Orca-owned `orca-data.json`). Pointing a repo
   at the dispatcher means knowing the exact one-liner and that it only sticks
   after the repo has been opened in Orca once — easy to get wrong or forget.
2. **Per-repo custom rules have no on-ramp.** The dispatcher already delegates to
   a committed `$repo/.orca/worktree-setup.sh`, but nothing scaffolds that file
   or its optional gortex wiring — you write it from scratch each time.

## Solution

One **skill** in the cyphy plugin, invocable as `/orca-setup`. Run once per repo,
it (a) scaffolds the repo's committed `.orca/worktree-setup.sh` custom-rules
delegate and (b) **prints** the exact setup-script command for the user to paste
into Orca's per-repo settings themselves.

The skill **never writes `orca-data.json` and never asks the user to close
Orca.** The user does the field-wiring through the Orca UI — a two-second paste —
while the skill does the parts worth automating: the guard, the scaffold, and a
**read-only** check of the current wiring so the printed guidance is accurate
("already wired, nothing to do" vs "paste this"). This trades a fragile,
machine-local, IDE-racing write for a copy-paste the user controls.

Explicitly **not** a subagent: it commits a file and reasons about the repo — it
wants the user in the loop. A detached context buys nothing.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | **Form:** one cyphy-plugin skill, `/orca-setup`. Not a subagent. One-time per-repo. |
| 2 | **Architecture:** `SKILL.md` orchestrates; a committed `worktree-setup.template.sh` is the scaffold; an optional **read-only** `orca-status.sh` reports current wiring. The skill **prints** the setup one-liner for the user to paste; it never writes `orca-data.json`, never closes Orca. |
| 3 | **Field wiring is manual (by the user, in the Orca UI).** The skill prints the exact command + where to paste it, and read-only-reports current state. No config mutation, no bulk propagation. "All repos" = run it once per repo. |
| 4 | **Rules location:** committed `$base/.orca/worktree-setup.sh` (synced across the fleet, travels with the repo — the dispatcher checks it first). |
| 5 | **Gortex block:** readiness prep only — **ensure the daemon is running** (opt-in via `ORCA_GORTEX=1`). NOT creation-time overlay registration — a fresh worktree has zero uncommitted edits, so an overlay would be empty; the working agent registers its own overlay later per `cyphy:worktree-agent`, and reads its workspace slug from its own session orientation. (No `track`/slug-marker step — those CLIs can't be verified without a running daemon, and the daemon-up ensure is the load-bearing part.) |
| 6 | **Identity:** match Orca entries on **normalized origin URL → `projectId`**, never path (path is per-machine/per-worktree). Resolve the base checkout via `git rev-parse --git-common-dir`. Refuse work/Pure repos (origin `thepureapp/*`) — pure-dev flow. |

## Components & file layout

```
agents/plugin/skills/orca-setup/
  SKILL.md                     # orchestration procedure (guard, scaffold, print)
  worktree-setup.template.sh   # the committed .orca/ scaffold
  orca-status.sh               # read-only current-wiring check (never writes)
  tests/orca-setup.test.sh     # mocks orca-data.json + a temp repo
```

- **`SKILL.md`** — the ordered procedure the agent follows. Links to the
  dispatcher and `cyphy:worktree-agent` rather than duplicating them.
- **`worktree-setup.template.sh`** — the scaffold written to
  `$base/.orca/worktree-setup.sh`. Marker-delimited managed blocks so re-runs
  update only what the skill owns.
- **`orca-status.sh`** — deterministic, **read-only**. Input: the
  `orca-data.json` path, the raw `origin` URL (it derives the `projectId`
  itself), the dispatcher one-liner, and the base checkout path (fallback match
  key). Emits one status token (matrix below). Never opens the file for writing;
  safe to run while Orca is open. Reusable by hand.
- **`tests/orca-setup.test.sh`** — same mock-the-tools style as
  `fleet-pull.test.sh` / `worktree-workflow.test.sh`.

## Control flow of an `/orca-setup` run

`SKILL.md` drives; `orca-status.sh` does the read-only inspection.

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
     stub; and an opt-in **gortex readiness** block (decision #5): when
     `ORCA_GORTEX=1` and `gortex` is on `PATH`, ensure the daemon is up
     (`gortex daemon start --detach` if `gortex daemon status` fails) so graph
     tools work from the worktree and the working agent's own
     `overlay_register` (per `cyphy:worktree-agent`) doesn't hit "cwd not
     covered". No overlay is registered here.
   - If the file already exists → don't clobber; update only the managed
     (marker-delimited) blocks and show a diff. Offer to `git add` it.

3. **Print the setup command + report current state** (no writes).
   - Run `orca-status.sh` (read-only) against the local `orca-data.json` for the
     matched `projectId`, then print guidance tailored to the result:
     - **WIRED** → "Already pointed at the dispatcher — nothing to do."
     - **UNWIRED** / **ABSENT** → print the exact one-liner and where to paste it
       in Orca:

       ```
       bash "$HOME/machines/scripts/orca-worktree-setup.sh"
       ```

       Paste into Orca → the repo's settings → **Setup script** field. (If the
       repo isn't listed in Orca yet, open it once so it appears, then paste.)
     - **CONFLICT** → "A different setup script is configured (`<value>`).
       Replace it with the dispatcher one-liner only if you mean to; otherwise
       leave it." — never presumes.
   - No backup, no Orca-closed requirement, no field mutation. The user applies
     it in the UI; it takes effect on the next worktree Orca creates.

## Current-wiring status matrix (`orca-status.sh`, read-only)

For the matched `projectId` entry:

```
entry present?
  no                                   -> ABSENT   (repo not opened in Orca yet)
current setup == dispatcher one-liner? -> WIRED    (nothing to do)
current setup empty?                   -> UNWIRED  (print the one-liner to paste)
current setup is some OTHER command?   -> CONFLICT (report the value; user decides)
```

The tool only reads. `SKILL.md` turns the token into the guidance above.

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
  every box. The read-only status check parses `orca-data.json` directly (the
  store the CLI itself uses). If the CLI is present it may be used to *read* the
  registry (`orca repo list --json`), but the JSON is the source of truth.

## Machine scope

Orca's repo/worktree registry is **per-runtime, i.e. per host** (the WSL runtime
and a Windows runtime keep separate registries). `orca-data.json` is not synced.
The committed `.orca/worktree-setup.sh` (step 2) *does* sync, so the custom rules
travel; the field-wiring (step 3) is per-machine — but since the user applies it
in the UI, "run per box" is just "paste per box." The skill's printed guidance is
identical on every machine.

## Error handling

- The skill **never mutates Orca config** — the worst case is a printed command
  the user doesn't paste. No backup/rollback surface.
- Every ambiguous state (foreign setup, repo not opened) is *reported*, not
  acted on — the user decides.
- The scaffold is non-fatal by construction; a bad delegate can't block Orca.
- `orca-status.sh` opens `orca-data.json` read-only; safe with Orca running.

## Testing

`tests/orca-setup.test.sh`, mocking a fixture `orca-data.json` + a temp git repo
(as `fleet-pull.test.sh` mocks ssh/git):

- **projectId match** — origin variants canonicalize to the same `projectId`.
- **Status: ABSENT** — unknown `projectId` → `ABSENT`.
- **Status: WIRED** — entry already at the dispatcher one-liner → `WIRED`.
- **Status: UNWIRED** — empty setup → `UNWIRED`.
- **Status: CONFLICT** — a pure-dev-style setup → `CONFLICT`, value reported.
- **Read-only** — `orca-data.json` is byte-identical after `orca-status.sh` runs.
- **Scaffold non-fatal** — the generated `.orca/worktree-setup.sh` exits 0 even
  when its steps fail.

## Non-goals

- No writing to `orca-data.json` — the skill prints; the user pastes (decision #3).
- No bulk propagation across Orca's repo DB.
- No creation-time gortex overlay (decision #5) — readiness prep only.
- No work/Pure-repo support — pure-dev PR flow.
- No dependency on the `orca` CLI being installed.
- Not a general Orca-config editor.

## Where this work lands

Deliberate feature work → committed on the `orca-worktrees` branch (worktree
mode), with a FF merge-back into `main` offered at the end, then `/ship` to the
fleet.
