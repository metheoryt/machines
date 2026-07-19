---
name: kb-refresh
description: Use when the user wants to refresh a repo's knowledge base (CLAUDE.md, memory tiers, docs) from scattered per-machine Claude transcripts and/or reconcile the docs against the current code. Harvests append-only transcripts read-once, dedups against existing memory, and merges behind a mandatory review gate. Works in any repo; auto-detects the fleet for cross-machine gather.
---

# Refresh a repo's knowledge base

## What this does
Two source tracks → one review gate → tier writes, stamped with the commit
they were generated against. Target repo = the current repo (cwd). Track A
mines scattered Claude Code transcripts (this box, and other fleet boxes when
detected) for tacit facts a session discovered but never wrote to memory.
Track B diffs the repo's own git history against its docs to catch
architecture/vision drift. Both converge on candidate facts of the same shape,
which a human approves before anything is written.

## Invariants (never violate)
- Transcripts under `~/.claude/projects/**` are READ-ONLY, append-only.
- Read-once: never re-distill a line already recorded in the watermark.
- Only git-tracked files are written by the write stage. Digests are scratch.
- Nothing lands in memory without passing the review gate.

## Step 0 — Resolve target & derive slugs
- `repo="$(git rev-parse --show-toplevel)"`; provenance base =
  `git -C "$repo" rev-parse HEAD`.
- Slug matches = the repo's basename + any known worktree path fragments
  (e.g. the repo dir name, and `orca/workspaces/<name>` segments — Claude Code
  transcript directories are the cwd path with `/` replaced by `-`, so a
  worktree checkout gets its own slug distinct from the main checkout's). Pass
  each candidate substring as a separate `--match`.
- State file: `"$repo/.claude/kb-harvest-state.json"` (git-tracked; create
  with an empty `{}` on first run — `distill.py` initializes its own
  `sessions` key). Digests out dir: a scratchpad path (e.g.
  `$(mktemp -d)/kb-digests` or the session's scratchpad directory) — never a
  path inside the repo.

## Step 1 — Gather + distill (mechanical, read-once)
- Run:
  ```
  bash agents/plugin/skills/kb-refresh/fleet-gather.sh \
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
  **in place** against the seeded state, once per projects root for the box's
  platform (Windows: the Windows profile `/mnt/c/Users/<ssh.user>/.claude/projects`
  **and** WSL `~/.claude/projects`; unix: `~/.claude/projects`); pulls the
  remote state back and merges only its `sessions` map via
  `distill.py --merge-from`; then pulls the resulting digests via `tar`
  (excluding `manifest.tsv`). Every remote command is bash-wrapped, so the
  Windows members (whose ssh lands in PowerShell) dispatch correctly to WSL
  bash; raw transcripts never leave their machine. No fleet aliases configured
  → silently local-only.
- `distill.py` reads only lines beyond each session's watermark
  (`last_line`/`id_hash` in the state file), so a session already fully
  harvested contributes nothing on a re-run; a resumed session contributes
  only its new turns.
- Report the summary line it prints (`sessions_seen` / `sessions_with_new` /
  `digests_written`, JSON on stdout). If `digests_written` is 0, say so
  explicitly and skip straight to Track B (Step 3) — there is nothing new for
  Track A to map.

### Recovery / aborted runs
The watermark in the state file is written at gather time (Step 1), long
before the Step 6 commit. If the run aborts after gather — a crash during
map/reduce, or the user rejecting the proposal at the review gate (Step 5) —
the on-disk state already has watermarks advanced, so a naive re-run reports
"0 digests / nothing new" (a silent no-op). To retry a fresh harvest, restore
the state file first: on the first run in a repo it's untracked, so
`rm "$repo/.claude/kb-harvest-state.json"`; on later runs it's git-tracked, so
`git -C "$repo" checkout -- .claude/kb-harvest-state.json` — then re-invoke
Step 1.

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
- Read the CURRENT tier files in full — `agents/memory/global.md`,
  `agents/hosts/<host>.md`, `$repo/.claude/memory/project.md`,
  `$repo/CLAUDE.md`, and any relevant `$repo/docs/*.md` — they are both the
  dedup baseline ("what's already known") and the write target. They're small;
  re-read them whole every run.
- Drop any candidate (from either track) that's already covered verbatim or
  in substance by an existing bullet. Keep candidates that are genuinely new,
  or that contradict/supersede an existing bullet (mark those `edit` or
  `delete` against the stale one).
- Cluster survivors by topic within each tier so the review proposal reads as
  grouped facts, not a flat dump.

## Step 5 — Review gate (MANDATORY)
This step is a hard gate — the skill MUST NOT write anything before it, and
MUST NOT proceed past it without explicit user approval.
- Present ONE proposal to the user: rows grouped by tier, each line showing
  `add|edit|delete` + the fact + target file + source (session-id or
  commit-sha) + confidence.
- The user approves the whole proposal, or trims/edits specific rows.
- Only rows the user approved carry forward to Step 6. If the user rejects the
  whole proposal, stop here — no files are touched, no commit is made.

## Step 6 — Write + stamp + commit
- Apply only the approved rows to their target tier files:
  - universal → `agents/memory/global.md`, `agents/hosts/<host>.md`
  - per-repo → `$repo/.claude/memory/project.md`, `$repo/CLAUDE.md`,
    `$repo/docs/*.md`
  - If `$repo/.claude/memory/project.md` doesn't exist yet and an approved row
    targets it, offer to create it first (matching the behavior of the
    existing `project-memory-check.sh` SessionStart hook, which auto-loads
    `project.md` and offers to start tracking it the same way).
- Update `$repo/.claude/kb-harvest-state.json`'s `last_refresh` key to
  `{commit: <HEAD sha from Step 0>, date: <today>, tiers_touched: [...],
  sessions_processed: [...]}`. This write is merge-preserving — read the
  existing JSON, set/replace only `last_refresh`, and write the file back with
  `sessions` (owned by `distill.py`) untouched.
- Stamp `$repo/.claude/memory/project.md` with a single provenance line, e.g.:
  `<!-- KB refreshed against a1b2c3d on 2026-07-19 -->`
  Keep exactly one such stamp line in the file (replace the previous one if
  present) rather than adding a new line each refresh.
- `git add` the changed tier files + the state file, and commit them (do not
  commit scratch digests — they never lived under version control).

## Tier reference

| Tier | Target file | What belongs here |
|---|---|---|
| Universal — global | `agents/memory/global.md` | Cross-project, cross-machine truths and preferences: facts true regardless of which repo or box you're in (e.g. a confirmed user preference, a tool the user always wants used a certain way). |
| Universal — per-host | `agents/hosts/<host>.md` (symlinked in as `host-memory.md`) | Machine-specific quirks: installed tooling, local paths, hardware peculiarities, anything that's true on that one box and would be wrong if applied elsewhere. |
| Per-repo — project memory | `<target-repo>/.claude/memory/project.md` | Repo workflow/architecture facts too specific (or too fresh) for the root doc: how this repo's build/test/deploy actually works day to day, non-obvious repo conventions, in-flight state. Offer to create it if the repo doesn't have one yet. |
| Per-repo — root doc | `<target-repo>/CLAUDE.md` | Stable architecture/vision: the things that change rarely — module boundaries, host roles, the shape of the system — not day-to-day workflow churn. |
| Per-repo — deep dives | `<target-repo>/docs/*.md` | Facts too large for a single bullet: a whole subsystem's design, a multi-step process worth its own page (e.g. this repo's `agents/docs/claude-code-subagents.md`, `agents/docs/git-workflow.md`). Link to these from `project.md`/`CLAUDE.md` rather than inlining them. |
