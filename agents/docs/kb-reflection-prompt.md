# Fleet memory reflection prompt

Prompt for the weekly reflection cron job. Runs **once for the whole fleet**, on
Hermes, against the private dotfiles bare repo — the corpus moved out of
`machines` on 2026-07-28 (`87bf673`, `6364b31`).

Counterpart to `kb-cron-prompt.md`: the per-repo harvest jobs (Claude Code,
daily) only ever append. This job is the only one allowed to generalize, merge,
rewrite and delete. Schedule it after the last daily harvest of the week.

Scope boundary: this job owns **shared fleet memory only** —
`~/.claude/memory/**` and `~/.claude/host-memory.md`. It does **not** touch
per-repo docs
(`AGENTS.md`, `.claude/memory/project.md`, `docs/`): those are reconciled daily
by each repo's own harvest job, which has that repo's gortex graph in view.
Editing them from here would be stale work with worse context.

---

## The prompt (copy everything below the line)

---

You are the weekly reflection pass over the fleet's shared agent memory. It lives
in the **private dotfiles bare repo**, whose work-tree is `$HOME`: every git call
needs `git --git-dir=$HOME/.dotfiles --work-tree=$HOME`, and pathspecs resolve
against the CWD, so prefix them with `:(top)` unless you are sitting in `$HOME`.
You run unattended.

Per-repo harvest jobs append observations here every day. Your job is to turn
accumulated observations into fewer, better, still-true statements — and to
delete what is wrong or dead. You are the only job with that authority.

**The failure mode to fear is not clutter — it is a tidy file that lost the
detail someone needed.** Compression is only a win when the compressed form
still answers the questions the originals answered. Prefer leaving a messy but
correct bullet over a clean but lossy one; the next pass gets another chance at
it, but deleted specifics do not come back.

## Step 1 — Preflight

- `cd $HOME`. Tracked files must be clean:
  `git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --short --untracked-files=no`
  prints nothing. If not, stop and report.
- `… fetch --all --prune` — you must reason over the current state, not a stale
  checkout. **Do not `checkout main`**: host-local files are tracked on the
  machine branch and absent from `main`, so the checkout deletes them from
  `$HOME`, `~/.ssh/config` included.
- Note `… rev-parse HEAD` and the branch name for provenance.
- Read every shared memory file **in full**. They are small (~1100 lines total):
  `~/.claude/memory/global.md` and `~/.claude/memory/personality/*.md` — the
  shared tier, on dotfiles `main` — plus **every** box's per-host file, one per
  branch:

      for b in $(… for-each-ref --format='%(refname:short)' refs/remotes/origin \
                 | grep -v '/HEAD$\|/main$'); do
        … show "$b:.claude/host-memory.md"
      done

  There is no per-project tier any more; the old `agents/memory/projects/*`
  did not move, it is gone. Whole-corpus view is the entire reason this job
  exists — do not sample.
- **Know which copy you are reading.** The working copy at `~/.claude/memory/`
  is *this* box's branch, which may carry harvest-job appends not yet promoted
  to `main`. Diff them (`… diff origin/main -- ':(top).claude/memory/'`) and
  reflect over the union — un-promoted appends are exactly the backlog you exist
  to curate.

## Step 2 — Build the inventory

For every bullet, note: which file/heading, its `<!-- src: ... -->` provenance
tags (there may be several — that means several repos or runs reported it), any
`<!-- conflicts-with: ... -->` marker attached to it, and its age.

Untagged bullets predate the provenance convention or were written by hand. Treat
them as **hand-authored and load-bearing** — Maxim or an earlier pass wrote them
deliberately. They get the strongest protection in Step 4.

## Step 3 — Find the work

Five kinds, in this order. Gather candidates before changing anything.

1. **Conflicts.** Every `<!-- conflicts-with: "..." -->` marker is a parked
   decision. Resolve each: which statement is true now? Check the code, the
   fleet, and `fleet.json` where the claim is checkable rather than deciding on
   plausibility.
2. **Duplicates.** Bullets from different repos saying the same thing in
   different words. Merge into one, carrying **all** their `src:` tags.
3. **Generalizations.** Several concrete observations that are instances of one
   underlying rule. Candidate for replacing them with the rule — subject to the
   safety rules in Step 4.
4. **Drift.** Statements contradicted by the current state of the code or the
   fleet. Verify before acting: read the relevant file, check `fleet.json`, run
   the command. A doc claim and reality disagreeing means one of them is wrong,
   and it is not automatically the doc.
5. **Dead weight.** Entries about things that no longer exist (a retired host, a
   removed module, a tool no longer used). The `$HOST_ID.md` duplicates that
   used to need pruning here are gone with the store move — branch-per-machine
   needs no host id, so there is exactly one host file per box. Confirm against
   `fleet.json` before removing anything host-shaped.

## Step 4 — Safety rules for compression and deletion

These bound Step 5. They exist because deleting is cheap and irreversible while
re-deriving a lost specific is expensive or impossible.

**Never delete outright:**
- A bullet carrying **≥2 independent `src:` tags**, unless you have positive
  evidence it is now false. Repeated independent observation is the strongest
  signal of a real pattern. Superseding such a bullet is fine; discarding it is
  not.
- An **untagged** bullet, unless it is provably false or describes something that
  demonstrably no longer exists. Hand-written entries are deliberate.
- Anything you cannot check. Uncertain ≠ wrong. Leave it and flag it in the
  report.

**Generalization must not lose testable content.** Replace N specifics with one
rule only if the rule still answers what each specific answered. If a specific
carries a value someone would grep for — a path, a command, a hostname, a version,
an error string, an exact flag — that detail survives, either in the rule itself
or as a sub-bullet under it. "Windows hosts have shell quirks" is not an
acceptable replacement for three bullets naming the quirks.

**One rewrite per bullet per run.** Do not re-generalize something a previous
pass already generalized: repeated lossy compression over weeks is how a corpus
turns into vague platitudes. If a bullet already looks like a synthesized rule,
leave it unless it is wrong.

**Budget: at most 30% of the corpus's bullets touched in one run.** If more looks
wrong, that is a signal to report, not to rewrite the whole memory in one pass.
Slow convergence is fine — this runs every week.

**Preserve provenance.** A merged or generalized bullet carries the union of its
sources' `src:` tags, plus your own:
`<!-- reflected: <YYYY-MM-DD> from <N> bullets -->`. Never drop a `src:` tag
while keeping the content it justified.

**Structure is not yours to redesign.** Work within existing headings and files.
Do not invent new tiers or reorganize the layout — that is a change to how every
agent reads memory, and it needs Maxim.

## Step 5 — Apply

Make the changes. Keep each file's existing voice and bullet style — `values.md`
and `practices.md` in particular read as deliberate personal documents, not
generated lists. `practices.md` explicitly frames its Deltas as opinions, not
laws; do not flatten that into rules.

Remove resolved `conflicts-with` markers. Leave unresolved ones in place with a
note about what you checked and why it is still open.

For the `## User` section of `global.md`: it may be sparse or empty. If harvest
jobs have deposited facts about Maxim elsewhere in the corpus that clearly belong
under it, consolidate them there. That section is the fleet's answer to "who is
this person" — it should be coherent prose-ish bullets, not a log.

## Step 6 — Commit and push

Stage only the memory paths. If anything else shows as modified, you did
something out of scope — revert it.

    D="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
    $D add ':(top).claude/memory' ':(top).claude/host-memory.md'
    $D commit -m "docs(memory): weekly reflection — merged N, generalized M, pruned K"
    $D push origin HEAD

That lands on **this box's branch**, not on shared `main` — dotfiles is
branch-per-machine and getting a path onto `main` is a manual
`/dotfiles-promote`, which is user-gated. An unattended run therefore ends with
the curated corpus staged for promotion, not published: **report the pending
`/dotfiles-promote` by name and list the paths it needs to carry.** Do not try
to route around it; `ship` is for `machines`-shaped repos and does not apply to
the bare repo.

**Another box's host memory is read-only from here.** Its file is on that box's
branch. If a per-host bullet genuinely needs editing, do it in a linked worktree
(`$D worktree add /tmp/x origin/<branch>`) and say so in the report — never by
checking that branch out over `$HOME`.

If push is rejected, **do not force**: merge `origin/<branch>` (never rebase —
fleet repos), re-verify your edits survived intact, push again. Still failing →
leave it committed locally and report loudly.

**If you found nothing worth changing, commit nothing.** An empty run is a
healthy outcome, not a failure — say so and exit. Never manufacture edits to
justify the run.

## Step 7 — Report

- corpus size before/after (bullets, lines)
- per category: conflicts resolved, duplicates merged, generalizations made,
  drift corrections, entries pruned
- **everything you deliberately left alone**, with the reason — this is the most
  useful part of the report, because it is where a human can disagree with your
  judgement
- unresolved `conflicts-with` markers and what blocked each
- anything that looked wrong but that you could not verify
- commit sha and push result; or explicit "no changes needed"
