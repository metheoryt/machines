---
name: kb-refresh-unattended
description: Use for a scheduled, unattended knowledge-base harvest of the current repo (Orca Automation, nightly). Runs cyphy:kb-refresh Steps 0-4 only and files a reviewable proposal — it NEVER writes a memory store, because there is no human at the review gate. The attended /cyphy:kb-refresh is what writes.
---

# kb-refresh, unattended

A delta on `cyphy:kb-refresh`, not a replacement. **Read the sibling skill
first** — `cat ../kb-refresh/SKILL.md` relative to this skill's base directory
— and follow its Steps 0-4. Everything below overrides it where they conflict.

Target repo is the **current repo** (cwd). Nothing is passed in.

## The invariant that defines this skill

**An unattended run writes only under `<repo>/.claude/kb-refresh/` and the
watermark in `<repo>/.claude/kb-harvest-state.json`.** It never edits
`~/.claude/memory/*`, `~/.claude/host-memory.md`,
`<repo>/.claude/memory/project.md`, `<repo>/CLAUDE.md`, `<repo>/AGENTS.md` or
`<repo>/docs/*`, and never touches the dotfiles repo.

Step 5 of the parent skill is a hard human gate. There is nobody here to pass
it, and a memory store can be the last copy of a fact (`personality/values.md`).
So this run proposes and stops — same split as `/dream` and `/dream-apply`.

## What makes the failure mode one-way

Step 1 advances the read-once watermarks **at gather time**, and transcripts
expire on their own schedule. A run that gathers and then dies, or gathers with
nobody to approve, leaves watermarks advanced and no facts — permanently. That
is why Step 2 below exists and why the commit at Step 8 is one commit.

## Read with the shell, never Read/Grep/Glob

`cat`, `sed -n '<a>,<b>p'`, `awk`, `wc -c`. The gortex `PreToolUse` hook runs in
**deny** posture and blocks the file tools on indexed source; an unattended
`claude -p` has nobody to negotiate with when it fires. Same clause `/dream`
carries, for the same reason.

## Step 1 — Preflight, before anything else

```bash
repo="$(git rev-parse --show-toplevel)"
# Refuse a worktree. An Orca workspace is a worktree on its own branch and
# carries its OWN .claude/memory/project.md — a second copy of the store this
# harvest is about. Run from the main checkout or not at all.
[ "$(git rev-parse --git-common-dir)" = ".git" ] || { echo "REFUSING: worktree/Orca workspace, not the main checkout"; exit 3; }
```

## Step 2 — Back up the watermark BEFORE the gather

```bash
mkdir -p "$repo/.claude/kb-refresh"
cp "$repo/.claude/kb-harvest-state.json" \
   "$repo/.claude/kb-refresh/state-before.json" 2>/dev/null || true
```

This copy — not `git checkout` — is the recovery path, because most repos
gitignore `.claude/` wholesale and there the parent skill's git-based recovery
silently does nothing.

## Step 3 — Slugs: one match covers the Orca workspaces too

Transcript directories are the cwd path with `/` replaced by `-`, and an Orca
workspace lives at `~/orca/workspaces/<repo-basename>/<workspace-name>/`. So the
repo's basename is a substring of the workspace's slug as well as the main
checkout's, and **a single `--match <basename>` covers both** — including
workspaces that have since been deleted, whose transcripts outlive them
(measured 2026-09-11: `-home-me-orca-workspaces-qaz-code-kazhackstan-2026` was
still present with no workspace directory left).

After the gather, list which slug directories actually matched and name them in
the report. A basename is a substring match, so this is also how a cross-match
with an unrelated repo becomes visible instead of silent.

## Step 4 — Digest hygiene before the fan-out

Split any digest larger than 400K into <=400K parts that each repeat its
`# session:` header, then pack ~15 files per subagent. One oversized digest
blows a subagent's context and the batch returns nothing; attended, a human
catches that.

## Step 5 — Track B baseline

Use `last_scan.commit` from the state file if present, else
`last_refresh.commit`, else a full pass. **Without this, every night re-diffs
the same history and files a duplicate of every drift item.**

## Step 6 — File the proposal instead of Steps 5-6

Write `<repo>/.claude/kb-refresh/proposal-<YYYY-MM-DD>.md`. One row per line:

```
tier | add|edit|delete | the fact, as the exact text to paste | target file | source session-id or commit | confidence
```

**The proposal must stand alone.** Digests are scratch and the transcripts
behind them may be expired before a human reads it, so a row that says "see the
session" is a row that will be lost. Group rows by tier, as the parent skill's
Step 4 does.

## Step 7 — Stamp `last_scan`, not `last_refresh`

Set `last_scan` to `{commit: <HEAD from Step 0>, date: <today>}`,
merge-preserving: read the JSON, set only that key, leave `sessions` (owned by
`distill.py`) and `last_refresh` (owned by the attended write) untouched.
Claiming `last_refresh` here would tell the next run that tiers were written
when nothing was.

## Step 8 — Commit, or say why you could not

```bash
git -C "$repo" check-ignore -q .claude/kb-harvest-state.json && ignored=yes
```

- **Not ignored** — `git add .claude/kb-refresh .claude/kb-harvest-state.json`
  and commit as `kb-refresh: unattended scan <date>`. The proposal and the
  advanced watermark go in **one** commit, never separately: a watermark
  committed without its proposal is the one-way loss above.
- **Ignored** — commit nothing. End the report with the exact `dotfiles add`
  two-step needed to track both files (see `$HOME/CLAUDE.md`, *Adding a tracked
  file*), and say plainly that they are unprotected until someone runs it.

On any failure after the gather: commit nothing, leave `state-before.json` in
place, and name the failed step as the first line of the report.

## Step 9 — Report

`sessions_seen` / `sessions_with_new` / `digests_written`, the slug directories
matched, row counts by tier, the proposal path, and whether it was committed.

## Scheduling

- **One automation per repo, and pin it to ONE box.** `fleet-gather.sh` already
  fans out to the whole fleet, seeding each remote's
  `~/.cache/kb-harvest-state.json`; two boxes running the same repo's automation
  race on that file.
- **Do each repo's first run attended.** With no baseline, Track B reads the
  repo's entire history — the largest run that repo will ever do.
