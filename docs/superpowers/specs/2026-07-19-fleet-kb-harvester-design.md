# Fleet KB Harvester + Refresh — Design

**Date:** 2026-07-19
**Branch:** `refresh-kb`
**Status:** design approved, pending spec review → implementation plan

## Problem

Development sessions on this fleet are scattered across ~4 machines (g16 /
desktop, latitude, server, plus the local box). Each machine's Claude Code
transcripts live under `~/.claude/projects/*/` and are **machine-local, never
synced**. Knowledge discovered in a session — architecture decisions down to
"tiny hacks and peculiarities" — only reliably reaches the synced knowledge base
(KB) if the agent in that session wrote it to memory at the time. Anything it
didn't capture is stranded in that machine's transcripts.

Meanwhile the repo itself has moved fast (465 commits in the last 60 days) and
the docs have drifted: the root `CLAUDE.md` was last touched 2026-06-30, while
`.claude/memory/project.md` is current.

We want **ultimate coverage** — vision/architecture through small gotchas —
folded into the existing KB tiers, AND a **repeatable mechanism** so future
scattered sessions get harvested with one command instead of drifting again.

## Goal

1. A **repo-agnostic** KB-refresh capability, invocable in **any repo on any
   machine**, that harvests knowledge from scattered transcripts + reconciles
   docs against code, and merges the result into the correct KB tiers behind a
   mandatory human review gate.
2. Run it once now against `machines` for the big catch-up.

## Non-goals

- Rewriting or "refactoring" docs beyond drift fixes (no unrelated churn).
- Mutating transcripts in any way (they are read-only sources).
- Auto-writing memory without review (writes propagate fleet-wide).
- Replacing the existing per-tier memory system — this *fills* it, doesn't
  redesign it.

## Architecture

Two source tracks converge on one review gate, then write to the KB tiers.

```
TRACK A — Transcripts (tacit hacks)        TRACK B — Code/git (architecture drift)
  gather → distill → map → reduce            code/config diff since last refresh
                    \                        /
                     → candidate facts, tagged by tier →
                            REVIEW GATE (human approves)
                                    ↓
                     write into tier files → stamp provenance → commit
```

### Where it lives (repo-agnostic)

Ships **inside the cyphy plugin** at `agents/plugin/skills/kb-refresh/`. The
plugin is whole-directory symlinked into every profile (`~/.claude`, `~/.codex`,
`~/.claude-pure`) on every machine, so the skill and its bundled scripts are
present and invocable (`/cyphy:kb-refresh`) in **any repo, any session, any
box** with zero per-repo wiring.

Bundled contents:

- `SKILL.md` — drives the workflow: gather → distill → map → reduce → review →
  write → stamp.
- `distill.py` — the mechanical jsonl→digest distiller (no LLM). Portable,
  runs anywhere Python 3 exists (the fleet has `uv` / Python 3.13).
- a gather helper — collects transcript paths for the target repo, locally and
  (when the fleet is detected) over the tailnet.

### Target repo is a runtime parameter

Nothing is hardcoded to `machines`. The skill takes **target repo = the current
repo (cwd)** and derives its transcript slugs from the repo's path(s):
`/home/me/foo` → project slug `-home-me-foo`, plus its worktrees (e.g.
`-home-me-orca-workspaces-foo-*`). Transcript slugs are the cwd path with `/`
replaced by `-`.

## Source read model (mutability-driven)

The two source types are read differently because they change differently:

- **Transcripts = append-only ⇒ read once, incrementally.** They only grow;
  history is never rewritten. Each session's watermark (below) means every turn
  is read **exactly once, ever**. Old lines are never re-read.
- **Git-tracked files = mutable ⇒ re-read each run, scoped to what changed:**
  - **KB tier files** (`global.md`, `host-memory.md`, `project.md`,
    `CLAUDE.md`) — read **in full every run**. Small; they are both the dedup
    baseline ("what's already known") and the write target.
  - **Repo code/config** (Track B target) — read the **git diff since
    `last_refresh.commit` → HEAD**, not the whole tree. On the **first run**
    (no prior commit) do a full pass. The provenance stamp is what makes this
    incremental.

The only thing fully re-scanned each run is the tiny KB files. Transcripts are
incremental-by-watermark; code is incremental-by-git-diff.

## Track A — transcript harvester pipeline

| Stage | Mechanism | Output |
|---|---|---|
| **1. Gather** | Local: glob `~/.claude/projects/<slug>*/ *.jsonl` for the target repo. Fleet (auto-detected): same over `ssh {latitude,desktop,server}`. | list of `(host, session-id, path)` |
| **2. Distill** (mechanical, no LLM; runs in-place on each box — repo/plugin already synced there) | `distill.py`: strips each jsonl to signal — user turns, assistant prose, Bash command lines, edited file paths, commit messages. Drops tool-result noise. Reads only lines beyond the session's watermark. | one ephemeral `.md` digest per session + a manifest `(session→host/date/cwd/new-line-range)` |
| **3. Map** (LLM fan-out, central) | Only the small digests are rsynced back to the invoking box. ~13 subagents, ~15 digests each. | per-batch **candidate facts**: `{tier, topic, fact, source-session, confidence}` |
| **4. Reduce** (LLM, central) | One pass: dedup candidates against each other **and** against the current KB tier files + git log. Cluster survivors by topic. | new-or-now-wrong facts, clustered |

### Fleet-gather is an auto-detected enhancement, not a requirement

Core behavior — mine *this* box's transcripts for the current repo — works in
any repo anywhere. When the skill detects the fleet SSH aliases
(`latitude` / `desktop` / `server`), it *offers* to also gather that same repo's
transcripts from the other boxes (cross-machine drift isn't unique to
`machines`). No fleet detected → local-only, silently.

The distiller runs **in-place** on each box; only the compact digests travel
back. Raw transcripts never leave their machine.

## Track B — code/git reconciliation

Runs in parallel as one focused pass. Reads the **git diff since
`last_refresh.commit`** (full tree on first run) across `modules/`, `hosts/`,
`provision/`, etc., compared against the docs. Emits the same
`{tier, topic, fact, action}` shape → same review gate. Purpose: surface
architecture/vision drift (stale/missing/wrong doc statements), not tacit hacks.

## Review gate (mandatory)

Because writes propagate fleet-wide, **nothing lands unreviewed.** The reduce
stage produces a single **KB-refresh proposal**: rows grouped by tier, each
`add | edit | delete` + target file + source (session-id or commit) +
confidence. The human approves / trims. Only then does the skill write.

## KB tiers (write targets)

- **Universal (always apply, any repo):**
  - `global.md` — cross-project / cross-machine truths & preferences.
  - per-host `host-memory.md` — machine-specific quirks, paths, tooling.
- **Per-repo (resolved relative to the target repo):**
  - that repo's `.claude/memory/project.md` — repo workflow/architecture facts
    (offer to create if absent, matching existing `project-memory-check.sh`).
  - that repo's root `CLAUDE.md` — stable architecture/vision doc.
  - that repo's `docs/` — deep-dives (like the existing
    `agents/docs/claude-code-subagents.md` / `git-workflow.md`) when a fact is
    too large for a bullet.

## State file (git-tracked; triple duty)

Lives in the target repo's `.claude/` (synced if the repo syncs, local
otherwise). It is the **one KB artifact that is itself git-tracked state**, and
it does three jobs:

1. **Read-once watermark.** Maps `session-id → { last_line, hash }`. Re-runs
   read only lines beyond `last_line`; a fully-processed session is skipped; a
   resumed/appended session contributes only its new turns. No turn is ever
   mined twice. Because the file is git-tracked, this holds **fleet-wide** — a
   run from another box won't reprocess an ID already recorded upstream.
2. **Provenance ledger.** Records each refresh's target-repo HEAD SHA +
   timestamp + tiers touched + sessions processed:
   `{ last_refresh: { commit, date, tiers_touched, sessions_processed } }`.
   Gives Track B its precise "commits since last refresh" baseline.
3. Machine-readable index of what has been harvested.

## Provenance stamp

Every refresh stamps the commit it was generated against:

- **Machine-readable** — the `last_refresh` record in the state file (complete).
- **Human-visible** — a single stamp line in the repo's `project.md` (the
  living index), e.g. `<!-- KB refreshed against a1b2c3d on 2026-07-19 -->`.
  Kept in one place to minimize churn, not sprinkled into every touched file.

## Safety properties

- Harvester **never mutates a transcript** — `~/.claude/projects/**` is a
  read-only source. Enforced as an explicit guard in the skill.
- Only **git-tracked KB files** are written (memory tiers, `CLAUDE.md`, repo
  docs, the state file).
- Digests are **ephemeral scratch** (scratchpad dir), never committed.
- No memory write without passing the review gate.
- Track B fixes drift only — no unrelated doc refactoring.

## The catch-up run (now)

After the skill + `distill.py` exist, run once against the full `machines`
corpus: ~200 sessions fleet-wide → distill → ~13-subagent map → reduce → a
single KB-refresh proposal → human approval → write + stamp + commit on
`refresh-kb`. First run has no prior provenance, so Track B does a full-history
pass and the read-once watermark is seeded from empty.

## Open questions

None blocking. Subagent batch sizing (~15 digests) and the exact digest format
are implementation details for the plan.
