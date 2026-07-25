# Per-repo KB cron prompt

Prompt to paste into an Orca-managed cron job for **any** repo. Fully
unattended: it harvests, writes, commits and pushes with no human in the loop.

The only per-repo edit is the `<REPO_PATH>` line at the top. Everything else is
repo-agnostic — `fleet-gather.sh` locates `fleet.json` relative to its own skill
dir (`$SKILL_DIR/../../../../fleet.json`), not relative to the target repo, so
the same text works in `machines`, `skep`, `vasya`, or a repo created next month.

The interactive review gate from the `kb-refresh` skill is dropped, not
replaced: this job writes append-only, and a separate reflection job in
`machines` does the compaction, generalization and pruning. Curation happens
after the fact, on the whole corpus, instead of one candidate at a time.

---

## The prompt (copy everything below the line)

---

Target repo: `<REPO_PATH>`      <!-- e.g. C:\Users\methe\my\skep -->

You are running unattended on a schedule. Refresh this repo's agent-facing
knowledge base, write it, commit it, and push it. Nobody will review your work
before it lands. Write generously: a separate reflection job in `machines`
generalizes, defragments and prunes shared memory afterwards. Your job is to
observe and record, not to curate.

## Step 1 — Preflight

- `cd` to the target repo. Note `git rev-parse HEAD` — the provenance base.
- **Tracked** files must be clean: `git status --short --untracked-files=no`
  must print nothing. **If dirty, stop and report** — never mix your writes into
  in-progress work. Untracked files are deliberately not a blocker: a stray
  scratch file in the repo must not wedge every subsequent run.
- Ensure the gortex daemon is alive: `gortex daemon status`; else
  `gortex daemon start --detach`. If the repo is missing from `gortex repos`:
  `gortex track "<REPO_PATH>" --wait`.
  **Pass NATIVE Windows paths** (`C:\Users\...`) — `gortex track` silently
  rejects MSYS paths (`/c/Users/...`).
- Load the skill: `skill_view(name='kb-refresh')` for the mechanics of Steps 2–4.
  It is wired via `skills.external_dirs` at
  `C:/Users/methe/machines/agents/plugin/skills/kb-refresh/`.

## Step 2 — Track A: harvest Claude transcripts

Run `fleet-gather.sh` per the skill, passing this repo's slugs via `--match`
(repo basename + any `orca/workspaces/<name>` fragments — a worktree checkout
gets its own transcript slug).

State file: `<REPO_PATH>/.claude/kb-harvest-state.json` (git-tracked; create as
`{}` on first run). Digests go to scratch (`$(mktemp -d)/kb-digests`), **never**
inside the repo.

If `digests_written` is 0, say so and skip to Step 3. Otherwise batch digests
(~15 files each), fan out one subagent per batch via `delegate_task`; each
returns rows `{tier, topic, fact, source-session, confidence}`.

## Step 3 — Track B: code/docs drift

Baseline = `last_refresh.commit` in the state file; full pass if absent. Diff
`git log <base>..HEAD` and `git diff <base>..HEAD` against what the docs claim
(`AGENTS.md` / `CLAUDE.md`, `.claude/memory/project.md`, `docs/`). Use gortex
graph queries, not tree greps.

Same row shape plus `action ∈ {add, edit, delete}`. **Drift only** — stale,
missing, or now-wrong statements. No unrelated rewriting or polish.

## Step 4 — Third source: your own experience

Add candidates with `source: "hermes-self"`.

You are a self-learning agent: what you know about how Maxim works lives in your
Hermes memory and skills, on this machine only. It never reaches the fleet or the
other agents unless you write it out here. Do that now.

Targets in the `machines` repo:

- `agents/memory/global.md` § `## User` — who Maxim is, how he works.
  **Currently empty: heading only.**
- `agents/memory/personality/` — `habits.md`, `tone.md`, `values.md`,
  `practices.md`. How he deals with agents; his style and standing corrections.
  Note `practices.md` is coding-guidelines-shaped and says its Deltas are
  opinions, not laws — match each file's existing voice.

Durable facts only. **Never** task progress, PR numbers, commit SHAs, "fixed X",
"phase N done", file counts — anything stale within a week.

## Step 5 — Reduce, then route by lane

First reduce: read the CURRENT tier files in full — they are both the dedup
baseline and the write target. Drop anything already covered verbatim or in
substance. Keep what is genuinely new or what contradicts an existing bullet.
Cluster survivors by topic.

Then classify every survivor. Two lanes.

### Lane 1 — repo-local (permissive)

Targets: `<REPO_PATH>/AGENTS.md` · `CLAUDE.md` · `.claude/memory/project.md`
(create if missing) · `docs/*.md`.

Write these on medium confidence or better. A wrong line here is a one-line fix
in a repo you already touched.

### Lane 2 — shared fleet memory (append-only)

Targets: `machines/agents/memory/**` (`global.md`, `personality/*`,
`projects/*`) and `machines/agents/hosts/*.md`.

Write freely. Compaction, generalization and de-duplication are the reflection
job's work, not yours — do not pre-filter for them. Your job is to get real
observations into shared memory; its job is to turn many observations into few
good ones. A fact you withhold is a fact the reflection job can never generalize
from.

Two rules only:

1. **Additive.** Append; never delete or rewrite a pre-existing bullet. If your
   observation contradicts one, append yours and mark it
   `<!-- conflicts-with: "<quoted stale text>" -->` on the following line. That
   marker is a work item for the reflection job — it decides which survives.
   Resolving contradictions in shared memory is its call, not yours.
2. **Right file.** Universal → `global.md`. Machine-specific →
   `hosts/<host>.md`. Repo-specific → Lane 1, not here. Style/interaction →
   `personality/*`. Append under the right existing heading, matching that
   file's voice and bullet style; don't restructure headings.

Tag each bullet you add with its provenance so the reflection job can weigh and
trace it: `<!-- src: <repo> <short-sha> | <YYYY-MM-DD> -->`. A fact that shows up
from several repos over several runs is exactly the signal that it is real and
worth generalizing — provenance is what makes that visible, which is why
withholding single-sighting facts would destroy the signal rather than protect
it.

Still excluded, for the same reason as everywhere else: task progress, PR
numbers, commit SHAs, "fixed X", "phase N done" — anything stale within a week.
That is not a quality bar, it is the durability rule from Step 4.

If you are unsure whether something belongs in shared memory at all, write it —
biased toward inclusion. The reflection job prunes; a silent omission is
invisible to it.

## Step 6 — Write, stamp, commit, push

Apply the Lane 1 and Lane 2 writes.

**Cross-repo writes.** Lane 2 targets live in `machines`, a different repo from
`<REPO_PATH>` (unless this run's target *is* `machines`). Handle it as a separate
unit of work:
- `machines` must have a clean tree too — check with
  `git -C C:\Users\methe\machines status --short --untracked-files=no` before
  writing; if a tracked file is modified, defer all Lane 2 and say so.
- Pull first (`git -C C:\Users\methe\machines pull --ff-only`) so you append to
  current memory, not a stale copy.
- Commit and push `machines` **separately** from `<REPO_PATH>`, with its own
  message. Never one commit spanning both.

Update `<REPO_PATH>/.claude/kb-harvest-state.json` → `last_refresh` =
`{commit, date, tiers_touched, sessions_processed}`. **Merge-preserving**: read
the JSON, replace only `last_refresh`, leave `sessions` (owned by `distill.py`)
untouched.

Stamp `project.md` with exactly one provenance line, replacing any previous:
`<!-- KB refreshed against <sha> on <YYYY-MM-DD> -->`

Commit the tier files you changed plus the state file — never scratch digests:

    git add <changed tier files> .claude/kb-harvest-state.json
    git commit -m "docs(kb): refresh knowledge base against <short-sha>"

For `machines`, mark provenance in the message so the reflection job can trace
which run introduced a bullet:

    git commit -m "docs(memory): admit N facts from <repo> kb-refresh <short-sha>"

Then push. If the repo is a personal fleet-sync repo, prefer the fleet-aware
path: `skill_view(name='ship')` and follow it, so the change fast-forwards onto
every fleet member. `ship` refuses work/Pure repos (`thepureapp/` origin) — those
keep the PR flow; fall back to plain `git push`.

If push is rejected (someone pushed meanwhile), **do not force**. Rebase onto the
remote head, re-run the repo's test/lint gate if the rebase touched anything
beyond docs, push again. Still failing → leave the commit local and report
loudly.

## Watermark safety (important)

`fleet-gather.sh` advances the transcript watermark at gather time — before any
write. So:

- Reached Step 6 and committed → watermark correctly consumed. Fine.
- Aborted after Step 2 without committing (crash, dirty tree, push failed,
  nothing written) → watermark moved but facts never recorded. The next run
  silently sees "0 digests" and **that harvest is lost forever.**

**On any abort path ending without a commit, restore the state file before
exiting:**

    git checkout -- .claude/kb-harvest-state.json     # if tracked
    rm .claude/kb-harvest-state.json                  # if untracked (first run)

Verify with `git status --short --untracked-files=no` that no tracked file is
left modified.

## Final report

- digests written / sessions with new content
- Lane 1: candidates, written, files touched
- Lane 2: bullets appended, per target file, and any `conflicts-with` markers
  you left for the reflection job
- commits (sha + repo) and push results, including `ship` fleet-pull outcome
- explicit confirmation: no tracked file left modified in either repo, watermark
  consistent with what was committed

---

## Planned follow-up: the reflection job

This job is deliberately **append-only** — it adds observations and never
deletes or rewrites. That is what makes it safe to run unattended across many
repos in parallel, but it means shared memory only accretes. It is half of a
pair, and it is the cheap half on purpose: writing is fast and local, curating
needs the whole corpus in view.

The counterpart is a separate scheduled job in `machines` that does the thinking:

- **generalize** — collapse many concrete observations into one durable
  statement; several repos reporting the same behaviour is the signal that it is
  a real pattern, which is why this job tags every bullet with `src:` provenance
- **defragment** — merge duplicates that arrived from different repos saying the
  same thing in different words, keeping shared memory compact
- **resolve** the `conflicts-with` markers left by this job — deciding which of
  two contradicting bullets survives
- **find drift** — facts contradicted by the current state of the code or fleet,
  which no per-repo job can see because each sees only its own repo
- **prune** stale entries outright

Splitting it this way keeps deletion and generalization authority in one place,
one repo, one schedule — instead of every per-repo job holding a knife to shared
memory, or every per-repo job trying to guess in isolation what is worth keeping.
