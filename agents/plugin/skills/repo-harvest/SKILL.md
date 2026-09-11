---
name: repo-harvest
description: Use to harvest tacit facts into the knowledge bases of the repos on this box — from scattered Claude transcripts across the fleet, and from each repo's own git history vs its docs. Writes repo-local facts append-only and only PROPOSES changes to shared fleet memory. Safe to run unattended on a schedule; the companion /repo-harvest-apply applies the shared-memory proposals.
---

# repo-harvest — bring new facts into the repos on this box

Called `/kb-refresh` until 2026-09-11. The rename came with two real changes:
it runs over **every repo on this box**, not one, and it **writes repo-local
facts by itself** instead of stopping at a human gate.

## What this does

Two source tracks, then two lanes. Track A mines scattered Claude Code
transcripts (this box, and every other fleet box) for tacit facts a session
discovered but never wrote down. Track B diffs each repo's git history against
its own docs to catch drift. Both produce candidate rows of one shape, which
are then split by **who gets hurt if a row is wrong**:

| lane | targets | what happens |
|---|---|---|
| **1 — repo-local** | `<repo>/.claude/memory/project.md`, `<repo>/CLAUDE.md` / `AGENTS.md`, `<repo>/docs/*.md` | written **append-only**, committed, no human needed |
| **2 — shared fleet memory** | `~/.claude/memory/global.md`, `~/.claude/memory/personality/*`, `~/.claude/host-memory.md` | **proposed only**, never written here |

That split is the whole design, and the reason is blast radius, not caution. A
wrong Lane 1 line is a one-line fix in a repo you already touched. A wrong
Lane 2 line reaches `main` and every box in the fleet — and from a *work* repo
it carries work content into a personal shared store. So Lane 2 waits for
`/repo-harvest-apply`, which is attended.

**Lane 1 is append-only for the same reason the gate was dropped.** An
unattended run that rewrites or deletes a bullet can destroy the last copy of a
fact and nobody finds out until they need it (`personality/values.md`). It
appends, and marks a contradiction instead of resolving it:

```markdown
<!-- conflicts-with: "<the quoted stale text>" -->
```

That marker is a work item for `/memory-consolidate`, which owns deletion,
merging and generalisation across the whole corpus. Do not pre-curate for it —
a fact withheld is a fact it can never generalise from.

## Invariants (never violate)
- Transcripts under `~/.claude/projects/**` are READ-ONLY, append-only.
- Read-once: never re-distill a line already recorded in the watermark.
- **Never write a Lane 2 target.** Propose it; `/repo-harvest-apply` writes.
- Never delete or rewrite an existing bullet anywhere. Append, and mark the
  conflict.
- Digests are scratch and never live inside a repo.

## Read with the shell, never Read/Grep/Glob

`cat`, `sed -n '<a>,<b>p'`, `awk`, `wc -c`. The gortex `PreToolUse` hook runs in
**deny** posture and blocks the file tools on indexed source; an unattended
`claude -p` has nobody to negotiate with when it fires. Same clause
`/memory-consolidate` carries, for the same reason.

## Step 0 — Pick the repos

Default is **every repo on this box**. Discover by glob, never from a list —
a repo cloned next month must show up on its own:

```bash
for d in "$HOME"/*/ "$HOME"/*/*/; do
  [ -d "$d/.git" ] || continue      # a dir, not a file: this also skips worktrees
  echo "${d%/}"
done
```

`[ -d .git ]` is doing two jobs. A git **worktree** — which is what an Orca
workspace is — has a `.git` *file*, so it is skipped, and that is deliberate:
a workspace carries its own `.claude/memory/project.md`, a second copy of the
store this harvest is about. Harvest the main checkout; the workspace's
transcripts are picked up anyway (see slugs below).

Then run Steps 1-6 **once per repo**, and report per repo. If the user named a
repo, or the cwd repo is clearly the target, do that one only.

For each repo:
- `repo=<path>`; provenance base = `git -C "$repo" rev-parse HEAD`.
- Slug matches: **the repo's basename is enough**. Transcript directories are
  the cwd path with `/` replaced by `-`, and an Orca workspace lives at
  `~/orca/workspaces/<repo-basename>/<workspace-name>/`, so one `--match
  <basename>` covers the main checkout AND every workspace — including
  workspaces already deleted, whose transcripts outlive them (measured
  2026-09-11: `-home-me-orca-workspaces-qaz-code-kazhackstan-2026` was still
  present with no workspace directory left). A basename is a substring match,
  so **list the slug directories that matched and name them in the report** —
  that is how a cross-match with an unrelated repo becomes visible instead of
  silent.
- State file: `"$repo/.claude/kb-harvest-state.json"` (create with an empty
  `{}` on first run — `distill.py` initializes its own `sessions` key).
  Digests out dir: a scratchpad path, never inside the repo.
- **Before the gather, back up the watermark** — see *Recovery* below:
  ```bash
  mkdir -p "$repo/.claude/harvest"
  cp "$repo/.claude/kb-harvest-state.json" \
     "$repo/.claude/harvest/state-before.json" 2>/dev/null || true
  ```

**Known cost, not yet optimised:** the loop runs one full fleet gather per
repo, so N repos means N ssh fan-outs. One pass with every repo's `--match` at
once would do, because each digest header already carries `# cwd:` and that is
enough to partition the digests by repo afterwards. Do that if the nightly gets
too slow; it is a change to this skill only, not to `distill.py`.

## Step 1 — Gather + distill (mechanical, read-once)
- Run:
  ```
  bash agents/plugin/skills/repo-harvest/fleet-gather.sh \
    --out <scratch>/kb-digests --state "$repo/.claude/kb-harvest-state.json" \
    --match <slug1> [--match <slug2> ...]
  ```
- `fleet-gather.sh` always distills this box locally first (invoking
  `distill.py --projects-root ~/.claude/projects --out <scratch> --state <state-file>
  --host <this box's fleet detect.hostname>`), then reads `fleet.json` (repo
  root) via `detect_hosts` for the workstation members (hub excluded) that also
  have a `Host` entry in `~/.ssh/config`. For each present, reachable, non-self
  box (self-exclusion by a bash-wrapped `hostname` probe compared to fleet
  identity) it: seeds that box's `~/.cache/kb-harvest-state.json` with the
  authoritative git-tracked watermark and pushes `distill.py` (both via `cat`
  over ssh — no deployed skill needed on the remote); runs `distill.py`
  **in place** against the seeded state at `~/.claude/projects` (on a
  `platform: windows` member this resolves, via Git Bash, to
  `/c/Users/<ssh.user>/.claude/projects` — the Windows-native profile); pulls
  the remote state back and merges only its `sessions` map via
  `distill.py --merge-from`; then pulls the resulting digests via `tar`
  (excluding `manifest.tsv`). Every remote command dispatches through the shared
  helper `../lib/fleet-dispatch.sh` (`fd_run`/`fd_probe`), so a `platform:
  windows` member (whose ssh lands in PowerShell) runs against the
  **Windows-native** clone via Git Bash instead of landing in the WSL
  default-distro bash. Self-declared WSL distros are **separate** fleet hosts:
  for each Windows member, `fd_wsl_hosts` enumerates its distros (`wsl -l -q`)
  and reads each distro's `~/machines/fleet.local.json`. A `fleet:true` distro
  with `dispatch:direct` (at most one per Windows host) is harvested directly
  at `<nickname>.gg.ez` as a plain linux host; every other `fleet:true` distro
  is `dispatch:parent` and IS reached through its Windows parent's dispatch,
  as `wsl.exe -d <distro>` (same seed/distill/pull path either way). Raw
  transcripts never leave their machine. No fleet aliases configured → silently
  local-only.
- `distill.py` reads only lines beyond each session's watermark
  (`last_line`/`id_hash` in the state file), so a session already fully
  harvested contributes nothing on a re-run; a resumed session contributes
  only its new turns.
- Report the summary line it prints (`sessions_seen` / `sessions_with_new` /
  `digests_written`, JSON on stdout). If `digests_written` is 0, say so
  explicitly and skip straight to Track B (Step 3) — there is nothing new for
  Track A to map.

### Recovery / aborted runs — the one-way failure
The watermark is advanced **at gather time**, before anything is written, and
transcripts expire on their own schedule (30 days by default; 90 since
2026-09-10). So a run that gathers and then dies leaves the watermarks moved
and the facts nowhere: the next run reports "0 digests / nothing new" and that
harvest is **gone for good**. The fleet has already lost 2026-07-24 → 08-11
this way.

Restore from `"$repo/.claude/harvest/state-before.json"`, written in Step 0.
Do **not** rely on `git checkout -- .claude/kb-harvest-state.json`: most repos
gitignore `.claude/` wholesale, and there that command silently does nothing.

On any abort path that ends without a commit, put the backup back before
exiting, and say so in the report.

## Step 2 — Track A map (subagent fan-out)
- Batch the digests written to `<scratch>/kb-digests/*.md` into groups of
  ~15 files per batch.
- Dispatch one subagent per batch (general-purpose is fine — this is text
  triage, not code editing). Each subagent reads its batch of digests and
  returns candidate facts as rows:
  `{tier, topic, fact, source-session, confidence}`.
- `tier` ∈ `{global, host:<name>, project, claude-md, docs}`, mapping
  respectively to the "Tier reference" table below: `global` → global.md,
  `host:<name>` → that host's `host-memory.md`, `project` → `project.md`,
  `claude-md` → the repo's root doc, `docs` → a `docs/*.md` deep-dive.
  `source-session` is the digest's
  session id (from its `# session:` header) so a reviewer can trace any fact
  back to the transcript it came from.
- Collect all batches' rows before moving to Step 4 — Track A and Track B
  both feed the same reduce pass.

## Step 3 — Track B (code/git reconciliation)
- Baseline = the state file's `last_refresh.commit`, if present. If the state
  file has no `last_refresh` yet (first run in this repo), do a full pass
  instead of a diff.
- Diff `git -C "$repo" log <base>..HEAD` and `git -C "$repo" diff <base>..HEAD`
  over the repo's code/config (e.g. `modules/`, `hosts/`, `provision/` in this
  repo — the equivalent top-level dirs in any target repo) against what the
  current docs (`CLAUDE.md`, `.claude/memory/project.md`, `docs/`) claim.
- Emit the same row shape as Track A, plus `action ∈ {add, edit, delete}`:
  `{tier, topic, fact, action, source-session: <commit-sha>, confidence}`.
  Purpose is drift only — a doc statement that's stale, missing, or now wrong
  because of a code/config change — never unrelated rewriting or polish.

## Step 4 — Reduce / dedup
- Read the CURRENT tier files in full — `~/.claude/memory/global.md`,
  `~/.claude/host-memory.md`, `$repo/.claude/memory/project.md`,
  `$repo/CLAUDE.md`, and any relevant `$repo/docs/*.md` — they are both the
  dedup baseline ("what's already known") and the write target. They're small;
  re-read them whole every run.
- Drop any candidate (from either track) that's already covered verbatim or
  in substance by an existing bullet. Keep candidates that are genuinely new,
  or that contradict/supersede an existing bullet (mark those `edit` or
  `delete` against the stale one).
- Cluster survivors by topic within each tier so the review proposal reads as
  grouped facts, not a flat dump.

## Step 5 — Route every survivor into a lane

Classify each surviving row by its target file, using the Tier reference below.
There is no approval step in between — the lane *is* the decision.

- `project` / `claude-md` / `docs` → **Lane 1**. Write it.
- `global` / `personality` / `host:<name>` → **Lane 2**. Propose it.

Two rows that look alike land in different lanes when one is about this repo
and one is about the fleet. When genuinely unsure, Lane 2 — the cost of a
delayed shared fact is one attended session; the cost of a wrong one is every
box.

**A `host:<name>` row for a box you are not sitting on is Lane 2 regardless.**
Per-host files are branch-scoped in the dotfiles bare repo, so another
machine's is readable from here but not writable:
`git --git-dir=$HOME/.dotfiles --work-tree=$HOME show origin/<branch>:.claude/host-memory.md`.

## Step 6 — Lane 1: write, stamp, commit

- Append the Lane 1 rows to their targets, under the right existing heading,
  matching that file's voice and bullet style. Do not restructure headings, do
  not rewrite neighbouring bullets.
- Tag each appended bullet with its provenance so `/memory-consolidate` can
  weigh and trace it:
  `<!-- src: <repo> <short-sha> | <YYYY-MM-DD> -->`
- If `$repo/.claude/memory/project.md` does not exist and a row targets it,
  create it (same behaviour as the `project-memory-check.sh` SessionStart
  hook, which offers this in every repo that lacks one).
- **Never write**: task progress, PR numbers, commit SHAs, "fixed X", "phase N
  done", file counts, suite counts — anything stale within a week. This repo
  has burned itself on written-down counts three times.
- Update the state file's `last_refresh` to `{commit: <HEAD from Step 0>,
  date: <today>, tiers_touched: [...], sessions_processed: [...]}`,
  **merge-preserving**: read the JSON, set only that key, leave `sessions`
  (owned by `distill.py`) untouched.
- Stamp `project.md` with exactly one provenance line, replacing any previous:
  `<!-- KB refreshed against <sha> on <YYYY-MM-DD> -->`
- Commit the changed Lane 1 files **and the state file, in one commit**. That
  is not tidiness: a watermark committed without the facts it consumed is the
  one-way loss above.

  ```
  git -C "$repo" add <lane-1 files> .claude/kb-harvest-state.json
  git -C "$repo" commit -m "harvest: <n> facts against <short-sha>"
  ```

  If `.claude/` is gitignored in that repo, commit nothing there and end the
  report with the exact `dotfiles add` two-step needed to track the state file
  and the proposal (`$HOME/CLAUDE.md`, *Adding a tracked file*) — saying
  plainly that they are unprotected until someone runs it.

  Do not push from an unattended run unless the repo is a personal fleet-sync
  repo and `/ship` applies; `/ship` refuses work repos (`thepureapp/` origin),
  which keep the PR flow.

## Step 7 — Lane 2: file the proposal, write nothing

Write `"$repo/.claude/harvest/shared-proposal-<YYYY-MM-DD>.md"`. One row per
line:

```
tier | add|edit|delete | the fact, as the exact text to paste | target file | source session-id or commit | confidence
```

**The proposal must stand alone.** Digests are scratch and the transcripts
behind them may have expired before anyone reads it, so a row that says "see
the session" is a row that is already lost. Group by tier, as Step 4 does.

Then stop. The dotfiles repo is not touched by this skill at all — not a write,
not a commit, not a `dotfiles add`.

## Step 8 — Report

Per repo: `sessions_seen` / `sessions_with_new` / `digests_written`, the slug
directories matched, Lane 1 rows written and to which files, Lane 2 rows
proposed and where the proposal was written, the commit sha, and any
`conflicts-with` markers left behind. Then the box total, and **the pending
`/repo-harvest-apply` runs by name** — that line is the only thing between a
proposed fact and one nobody ever applies.

## Tier reference

| Tier | Lane | Target file | What belongs here |
|---|---|---|---|
| Universal — global | **2** | `~/.claude/memory/global.md` (dotfiles bare repo, shared on `main`) | Cross-project, cross-machine truths and preferences: facts true regardless of which repo or box you're in (e.g. a confirmed user preference, a tool the user always wants used a certain way). |
| Universal — per-host | **2** | `~/.claude/host-memory.md` (dotfiles bare repo, on this machine's branch) | Machine-specific quirks: installed tooling, local paths, hardware peculiarities, anything that's true on that one box and would be wrong if applied elsewhere. Writable for THIS box only. |
| Per-repo — project memory | **1** | `<target-repo>/.claude/memory/project.md` | Repo workflow/architecture facts too specific (or too fresh) for the root doc: how this repo's build/test/deploy actually works day to day, non-obvious repo conventions, in-flight state. Offer to create it if the repo doesn't have one yet. |
| Per-repo — root doc | **1** | `<target-repo>/CLAUDE.md` | Stable architecture/vision: the things that change rarely — module boundaries, host roles, the shape of the system — not day-to-day workflow churn. |
| Per-repo — deep dives | **1** | `<target-repo>/docs/*.md` | Facts too large for a single bullet: a whole subsystem's design, a multi-step process worth its own page (e.g. this repo's `agents/docs/claude-code-subagents.md`, `agents/docs/git-workflow.md`). Link to these from `project.md`/`CLAUDE.md` rather than inlining them. |
