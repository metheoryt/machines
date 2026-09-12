---
name: memory-harvest
description: Use for the unattended memory pass on this box — one automation per machine, identical text everywhere. Harvests every repo on the box from fleet-wide Claude transcripts and from each repo's git history vs its docs, writes the repo-local facts append-only, and PROPOSES everything aimed at shared fleet memory. On the one box declared memory_publisher it also runs the whole-corpus consolidation. The attended /memory-review applies what it proposes.
---

# memory-harvest — the unattended memory pass for this box

One automation per machine, the same prompt on each. Called `/kb-refresh` until
2026-09-11, and `/repo-harvest` for one day after that.

**Two phases.** Phase A harvests every repo on this box (Steps 0-9 below).
Phase B consolidates the whole memory corpus and runs **only on the box
`fleet.json` names as `"memory_publisher"`** — g15. Its brief is
`consolidate-phase.md` beside this file.

**Run every phase, and every repo, in a subagent.** `machines/.claude/memory/project.md`
alone is 283 KB; reading two stores whole would end the orchestrator's context
before the second repo. The orchestrator dispatches, collects one summary per
subagent, and writes nothing but the report.

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
`/memory-review`, which is attended.

**Lane 1 is append-only for the same reason the gate was dropped.** An
unattended run that rewrites or deletes a bullet can destroy the last copy of a
fact and nobody finds out until they need it (`personality/values.md`). It
appends, and marks a contradiction instead of resolving it:

```markdown
<!-- conflicts-with: "<the quoted stale text>" -->
```

That marker is a work item for `/memory-harvest`, which owns deletion,
merging and generalisation across the whole corpus. Do not pre-curate for it —
a fact withheld is a fact it can never generalise from.

## Invariants (never violate)
- Transcripts under `~/.claude/projects/**` are READ-ONLY, append-only.
- Read-once: never re-distill a line already recorded in the watermark.
- **Never write a Lane 2 target.** Propose it; `/memory-review` writes.
- **Never `git commit -m` without a pathspec, and never `git pull`, in a repo
  you are harvesting.** Both reach past this run into somebody else's work.
- Never delete or rewrite an existing bullet anywhere. Append, and mark the
  conflict.
- Digests are scratch and never live inside a repo.

## Read with the shell, never Read/Grep/Glob

`cat`, `sed -n '<a>,<b>p'`, `awk`, `wc -c`. The gortex `PreToolUse` hook runs in
**deny** posture and blocks the file tools on indexed source; an unattended
`claude -p` has nobody to negotiate with when it fires. Same clause
`/memory-harvest` carries, for the same reason.

## The main checkout is shared — write beside it, land in one commit

Every repo harvested here is somebody's working checkout, and a run lasts
minutes to hours. Two things a long run does to a checkout are invisible to the
agent doing them and loud to everyone else:

- **An in-place append to `project.md` / `CLAUDE.md` leaves that store dirty for
  the whole run.** Another agent reads a half-written file, or sweeps it into
  its own commit.
- **`git commit -m` with no pathspec commits the INDEX, not your files.**
  Anything another agent staged while you worked lands in the harvest commit
  under a `harvest:` message. Measured 2026-09-12: a decoy staged before
  `git commit --only <path>` stays staged and out of the commit; a bare
  `git commit -m` takes it.

So **Lane 1 accumulates in a staging file** beside the Lane 2 proposal —
`"$repo/.claude/harvest/lane1-<YYYY-MM-DD>.md"` — and the real stores are
touched only in Step 8, in one short block ending in a pathspec commit. The
window where a store is dirty is seconds, not the length of the run.

**Every commit in this skill is `git commit --only <paths> -m …`.** A path git
has never seen makes `--only` fail outright (`pathspec … did not match any
file(s) known to git`), so a file created this run — a first `project.md`, a
new `runs/` entry — needs `git add -N <path>` first: intent-to-add, no content
staged, and `--only` then reaches it.

**Never move HEAD in a checkout you do not own.** No `git pull`, no
`git checkout`, no `git merge` while the tree carries someone else's work — a
branch moving under a running agent prints no error at all. See *Pushing* below
for what replaces the pull.

## Step 0 — Pick the repos

**Every repo on this box, discovered by glob, never from a list.** A repo
cloned next month must show up on its own — a hand-listed set is how this repo
once ran 30 of its 40 test suites while printing that all 28 had passed:

```bash
for d in "$HOME"/*/ "$HOME"/*/*/; do
  [ -d "$d/.git" ] || continue      # a dir, not a file: this also skips worktrees
  echo "${d%/}"
done
```

`[ -d .git ]` does two jobs. A git **worktree** — which is what an Orca
workspace is — has a `.git` *file*, so it is skipped, deliberately: a workspace
carries its own `.claude/memory/project.md`, a second copy of the store this
harvest is about. Harvest the main checkout; the workspace's transcripts come in
anyway through the slug (below).

Two narrower rules were considered and rejected, because both fail by
**under**-covering, silently:

- **`repo_groups` from `fleet.json`.** It is the right idea — the manifest
  already declares per-box scope and `provision/repos.sh` maps group to
  directory — but only `g15` actually carries the key today. Everywhere else it
  is absent, so it declares nothing. Use it to *report* (a repo outside every
  declared group is worth a line), not to select.
- **"whatever has a `project.md` in dotfiles".** That is the set of repos which
  already have a knowledge base, so a freshly cloned repo could never get its
  first one — and Step 6 creating a missing `project.md` would never fire.
  `bash agents/plugin/skills/lib/consolidate.sh scan` is that list; use it to
  say which harvested repos already have a store.

Over-covering is cheap: a repo with no new transcripts and no drift yields
nothing and costs one empty pass.

Then dispatch **one subagent per repo**, each running Steps 1-8 for its repo and
returning a summary. For each repo:

- `repo=<path>`; provenance base = `git -C "$repo" rev-parse HEAD`.
- Slug matches: **the repo's basename is enough**. Transcript directories are
  the cwd path with `/` replaced by `-`, and an Orca workspace lives at
  `~/orca/workspaces/<repo-basename>/<workspace-name>/`, so one `--match
  <basename>` covers the main checkout AND every workspace — including
  workspaces already deleted, whose transcripts outlive them (measured
  2026-09-11: `-home-me-orca-workspaces-qaz-code-kazhackstan-2026` was still
  present with no workspace directory left). A basename is a substring match,
  so **name the slug directories that matched in the report** — that is how a
  cross-match with an unrelated repo becomes visible instead of silent.
- State file: `"$repo/.claude/kb-harvest-state.json"` (create with an empty
  `{}` on first run — `distill.py` initializes its own `sessions` key).
  Digests out dir: a scratchpad path, never inside the repo.
- **Before the gather, back up the watermark** — see *Recovery* below:
  ```bash
  mkdir -p "$repo/.claude/harvest"
  cp "$repo/.claude/kb-harvest-state.json" \
     "$repo/.claude/harvest/state-before.json" 2>/dev/null || true
  ```
- **Open the Lane 1 staging file** in the same directory. Nothing is appended to
  a real store before Step 8:
  ```bash
  lane1="$repo/.claude/harvest/lane1-$(date +%F).md"
  : >> "$lane1"
  ```

**Known cost, not yet optimised:** one full fleet gather per repo, so N repos
means N ssh fan-outs. One pass carrying every repo's `--match` would do, because
each digest header already records `# cwd:` and that is enough to partition the
digests by repo afterwards. Do that if the nightly gets too slow; it is a change
to this skill only, not to `distill.py`.

## Step 1 — Gather + distill (mechanical, read-once)
- Run:
  ```
  bash agents/plugin/skills/memory-harvest/fleet-gather.sh \
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

**Staging widens that window on purpose, so it must be reported.** A run that
dies between the gather and Step 8 leaves the facts in
`.claude/harvest/lane1-<date>.md` — not lost, but sitting in a directory most
repos gitignore, which nobody opens unless told to. On an abort: restore
`state-before.json` **and** name the staging file and its row count in the
report. The restored watermark is what lets the next run re-derive those facts;
the staging file is the fallback for when the transcripts have already expired.

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

- `project` / `claude-md` / `docs` → **Lane 1**. Stage it (Step 6), land it
  (Step 8).
- `global` / `personality` / `host:<name>` → **Lane 2**. Propose it.

Two rows that look alike land in different lanes when one is about this repo
and one is about the fleet. When genuinely unsure, Lane 2 — the cost of a
delayed shared fact is one attended session; the cost of a wrong one is every
box.

**A `host:<name>` row for a box you are not sitting on is Lane 2 regardless.**
Per-host files are branch-scoped in the dotfiles bare repo, so another
machine's is readable from here but not writable:
`git --git-dir=$HOME/.dotfiles --work-tree=$HOME show origin/<branch>:.claude/host-memory.md`.

## Step 6 — Lane 1: draft into the staging file

Write every Lane 1 row into `"$lane1"`, **in final form** — the exact bullet
text, the heading it belongs under, and the target file. Not notes to yourself:
Step 8 pastes these, and an agent that has to re-think a row while a store is
dirty is exactly the long window this avoids.

```markdown
## <absolute target file>
### <the ## or ### heading it appends under>
- <the bullet, in that file's voice and bullet style>
  <!-- src: <repo> <short-sha> | <YYYY-MM-DD> -->
```

- Tag every bullet with that provenance comment so `/memory-review` can weigh
  and trace it.
- Do not restructure headings and do not rewrite neighbouring bullets — Lane 1
  is append-only.
- **Never write**: task progress, PR numbers, commit SHAs, "fixed X", "phase N
  done", file counts, suite counts — anything stale within a week. This repo
  has burned itself on written-down counts three times.

Nothing outside `.claude/harvest/` has been touched yet. If the run dies here,
see *Recovery*.

## Step 7 — Lane 2: file the proposal, write nothing

Both staging files live side by side and neither has touched a store yet. This
one is written before Step 8 lands anything.

Write `"$repo/.claude/harvest/shared-proposal-<YYYY-MM-DD>.md"`. One row per
line:

```
tier | add|edit|delete | the fact, as the exact text to paste | target file | source session-id or commit | confidence
```

**The proposal must stand alone.** Digests are scratch and the transcripts
behind them may have expired before anyone reads it, so a row that says "see
the session" is a row that is already lost. Group by tier, as Step 4 does.

The dotfiles repo is not touched by this skill at all — not a write, not a
commit, not a `dotfiles add`.

## Step 8 — Land Lane 1: one block, one commit

This is the **only** step that touches a real store, and it is deliberately the
last one before the report. Run it without pausing for anything else: the
checkout is dirty from the first append until the commit lands.

1. Append each staged block to its target file, verbatim from `"$lane1"`.
   If `$repo/.claude/memory/project.md` does not exist and a row targets it,
   create it (same behaviour as the `project-memory-check.sh` SessionStart
   hook, which offers this in every repo that lacks one) — a created file needs
   the `add -N` below or the commit cannot reach it.
2. Stamp `project.md` with exactly one provenance line, replacing any previous:
   `<!-- KB refreshed against <sha> on <YYYY-MM-DD> -->`
3. Update the state file's `last_refresh` to `{commit: <HEAD from Step 0>,
   date: <today>, tiers_touched: [...], sessions_processed: [...]}`,
   **merge-preserving**: read the JSON, set only that key, leave `sessions`
   (owned by `distill.py`) untouched.
4. Commit the changed Lane 1 files **and the state file, in one commit**. That
   is not tidiness: a watermark committed without the facts it consumed is the
   one-way loss above.

   ```bash
   # intent-to-add ONLY for paths this run created; harmless on existing ones
   git -C "$repo" add -N <files created this run>
   git -C "$repo" commit --only <lane-1 files> .claude/kb-harvest-state.json \
     -m "harvest: <n> facts against <short-sha>"
   ```

   `--only` is load-bearing, not style: it commits those paths from the
   work-tree and ignores the index, so whatever another agent had staged in this
   checkout stays staged and stays out of the harvest commit. Verify it with
   `git -C "$repo" show --stat --oneline HEAD` — the file list must be exactly
   what you passed, and report it.

5. Then delete the staging file — it has served its purpose and a stale
   `lane1-<date>.md` reads on the next run as unlanded work:
   `rm -f "$lane1"`. Keep it (and say so) only if step 4 did not commit.

If `.claude/` is gitignored in that repo, commit nothing there and end the
report with the exact `dotfiles add` two-step needed to track the state file and
the proposal (`$HOME/CLAUDE.md`, *Adding a tracked file*) — saying plainly that
they are unprotected until someone runs it.

Do not push from an unattended run unless the repo is a personal fleet-sync repo
and `/ship` applies; `/ship` refuses work repos (`thepureapp/` origin), which
keep the PR flow.

## Step 9 — Report

Per repo: `sessions_seen` / `sessions_with_new` / `digests_written`, the slug
directories matched, Lane 1 rows written and to which files, Lane 2 rows
proposed and where the proposal was written, the commit sha **and the file list
`git show --stat` printed for it**, whether the fetch ff-merged or fell back to
`--merge-from`, and any `conflicts-with` markers left behind. A commit whose
file list is wider than the paths you passed is the index leak this skill's
`--only` exists to prevent — say so rather than moving on.

Then the box total, and **the pending `/memory-review` runs by name** — that line is the only thing between a
proposed fact and one nobody ever applies.

## Tier reference

| Tier | Lane | Target file | What belongs here |
|---|---|---|---|
| Universal — global | **2** | `~/.claude/memory/global.md` (dotfiles bare repo, shared on `main`) | Cross-project, cross-machine truths and preferences: facts true regardless of which repo or box you're in (e.g. a confirmed user preference, a tool the user always wants used a certain way). |
| Universal — per-host | **2** | `~/.claude/host-memory.md` (dotfiles bare repo, on this machine's branch) | Machine-specific quirks: installed tooling, local paths, hardware peculiarities, anything that's true on that one box and would be wrong if applied elsewhere. Writable for THIS box only. |
| Per-repo — project memory | **1** | `<target-repo>/.claude/memory/project.md` | Repo workflow/architecture facts too specific (or too fresh) for the root doc: how this repo's build/test/deploy actually works day to day, non-obvious repo conventions, in-flight state. Offer to create it if the repo doesn't have one yet. |
| Per-repo — root doc | **1** | `<target-repo>/CLAUDE.md` | Stable architecture/vision: the things that change rarely — module boundaries, host roles, the shape of the system — not day-to-day workflow churn. |
| Per-repo — deep dives | **1** | `<target-repo>/docs/*.md` | Facts too large for a single bullet: a whole subsystem's design, a multi-step process worth its own page (e.g. this repo's `agents/docs/claude-code-subagents.md`, `agents/docs/git-workflow.md`). Link to these from `project.md`/`CLAUDE.md` rather than inlining them. |

## Phase B — consolidate (publisher box only)

```bash
source provision/lib/fleet.sh
[ "$(fleet_memory_publisher)" = "$(fleet_logical_name)" ] || echo "not the publisher — skipping Phase B"
```

Not the publisher → skip it and say so in one line. Publisher → dispatch **one
subagent** with `consolidate-phase.md` beside this file as its brief.

The publisher is **g15**, and the reason is not uptime — latitude, desktop and
g15 are all always on, and air is the only box that sleeps. It is that Phase B
is an *agent session*: it needs Claude Code, a `machines` checkout and the
dotfiles bare repo with every branch fetched, on a box someone actually works
at. latitude is a services host with no development on it. Do not reason from
`tier_gortex_autoupdate` being latitude-only — that is a timer running a shell
script, which is a different requirement that happens to look like this one.

The gate is a **name** at the manifest root (`"memory_publisher": "g15"`),
not a flag on each machine. Two flags can both be true; two names cannot, so
"exactly one publisher" is structural rather than a rule someone has to
remember. Moving the publisher is editing that one value — there is no way to
express adding a second. Pinned by `provision/tests/memory-publisher.test.sh`,
which also fails if the name stops matching a real machine: a typo there means
nobody consolidates, and an empty queue reads exactly like "nothing to do".

## One repo, two boxes

A repo checked out on more than one box needs no owner and does not duplicate:
the watermark lives in that repo's own `.claude/kb-harvest-state.json`, which is
committed and therefore shared by git. Whichever box harvests first records the
sessions it consumed; the second pulls that state and finds nothing new.
Read-once is enforced across the fleet, not per box.

What that does **not** survive is two boxes running before either has pushed —
so **stagger the automations**, a couple of hours apart is enough.

The repos are also not spread the way the machine list suggests: on the desktop
machine every working repo lives inside the `desktop-wsl` distro (Linux, ext4)
and the Windows side holds only `machines`, so the automation there belongs in
the distro.

## Pushing, when N boxes commit nightly

**Fetch before Phase A; merge only into a checkout nobody else is using.** The
pull was there to pick up other boxes' committed watermarks so read-once holds
fleet-wide — but a `pull` rewrites the work-tree and moves HEAD under whoever
else is in that checkout, with no error printed. Get the same watermark without
touching the checkout:

```bash
git -C "$repo" fetch --quiet || echo "FETCH FAILED — read-once is local-only this run; say so"

# ff-merge ONLY if the tree is clean, i.e. nobody else is mid-edit here
if [ -z "$(git -C "$repo" status --porcelain)" ]; then
  git -C "$repo" merge --ff-only @{u} 2>/dev/null || true
else
  # someone is working here: read the remote watermark instead of moving HEAD
  git -C "$repo" show "@{u}:.claude/kb-harvest-state.json" > "$repo/.claude/harvest/state-remote.json" 2>/dev/null \
    && python3 agents/plugin/skills/memory-harvest/distill.py \
         --state "$repo/.claude/kb-harvest-state.json" \
         --merge-from "$repo/.claude/harvest/state-remote.json"
fi
```

`--merge-from` merges only the `sessions` map, which is the whole of read-once;
the local `last_refresh` is untouched. A repo whose `.claude/` is gitignored has
no remote watermark either way — that is the same local-only case as a failed
fetch, and reporting it is the point.

Pushes still collide by design, since every box harvests the same repos: rebase
onto the remote head and push again, **never force**, and if it still fails
leave the commit local and say so loudly in the report. A stranded local commit
is recoverable; a forced push over another box's harvest is not. **Do not
resolve a rejected push by pulling in a shared checkout** — rebase the one
commit in a scratch worktree, or leave it.
