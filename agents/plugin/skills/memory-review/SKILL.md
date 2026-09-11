---
name: memory-review
description: Use when the user wants to work through everything /memory-harvest has filed — the shared-memory proposals from each repo AND the whole-corpus consolidation queue — reviewing each and applying what they approve. This is the only skill that writes to a shared memory store. Always interactive; never run unattended.
---

# memory-review — land what the harvest proposed

`/memory-harvest` writes repo-local facts by itself and **proposes** everything
that would touch a shared memory store. This applies those proposals. It is the
gate, so it is **always attended**: never wire it to an Automation, never run it
inside a `claude -p` batch.

**Two inboxes, one session**, because both write the same stores and both end in
the same `/dotfiles-promote` — splitting them means two sessions racing on
`global.md`:

1. **Shared-memory proposals** — Phase A's Lane 2 rows, one file per repo.
2. **The consolidation queue** — Phase B's items: dedupe, demote, promote,
   contradiction, delete across the whole corpus.

## Step 0 — Load both

```bash
D=~/machines/agents/plugin/skills/lib/consolidate.sh

# inbox 1 — per-repo proposals (same depth-2 glob the harvest discovers with)
ls -1 "$HOME"/*/.claude/harvest/shared-proposal-*.md \
      "$HOME"/*/*/.claude/harvest/shared-proposal-*.md 2>/dev/null

# inbox 2 — the consolidation queue
cat ~/machines/docs/memory-consolidate/queue.md
cat ~/machines/docs/memory-consolidate/ledger.tsv 2>/dev/null

git -C ~/machines status --porcelain
git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --porcelain --untracked-files=no
```

If both are empty, say so and stop — do not go looking for work to do. A **dirty
tracked store** means someone is mid-edit or the 10-minute sync timer is about to
commit: defer rather than mixing your write into theirs.

### Proposals first, queue second

A proposal adds a fact; a queue item merges or deletes one. Land the additions
before deciding what is redundant, or you dedupe against a store that is about
to change. Two refusals apply to a proposal row and are **not** rejections:

- **A row targeting another box's `host-memory.md`.** Per-host files are
  branch-scoped, so that box's copy is readable here but not writable, and its
  own sync timer is committing to that branch live. List these as "carry to
  `<box>`"; they stay open.
- **A row whose source is a work repo but whose content is personal-fleet.**
  Read what it actually says before it lands in a store that reaches every box.
  That is the whole reason Lane 2 is gated.

Keep `core.md` under ~2 KB whatever lands. It is injected verbatim into every
session, and Claude Code truncates a hook's stdout past ~3.5 KB — an overfull
`core.md` is how the entire memory index silently stops loading.

## Step 1 — Present, in scope order

Group items by `scope`, most expensive first: `shared` (fleet-wide) → `repo:` →
`host` → `untracked`. Within a group, deletions before rewrites — a deletion is
what a reader wants to look at hardest.

For each item show: action, target, why, the byte delta, and — for a rewrite —
**the replacement text in full**. One item at a time for anything `shared` or
any `delete`; batching those is how a deletion gets waved through.

**An item carrying `apply on: <box>` is refused here** unless `<box>` is this
machine. Another box's dotfiles branch is being written by its own sync timer
and loaded live in its sessions; a push from here strands its next push as a
conflict. List those items separately at the end as "carry to <box>" — they stay
open, and they are not rejections.

The user approves an item, edits it, or rejects it. **A rejection is a real
outcome that must be recorded** — `consolidate.sh decide <id> rejected "<reason>"` —
or `/memory-harvest` proposes it again tomorrow night.

## Step 2 — Re-verify before writing

The queue can be days old. Before applying an item, re-read the target section
and confirm the quoted lines still say what the item claims. If they moved or
changed, re-derive the item rather than applying it blind; line numbers in the
queue are a starting point, not an address.

For a `dedupe` or `demote`: **write the surviving copy first, verify it landed,
then delete the source.** Never the other way round. If the item names a
"carry first" fact, that carry is what makes the delete safe — do it and read
it back before touching the source.

**An item names one site; the error may live at several.** Before applying a
correction, grep the WHOLE store for the fact being corrected — the serial, the
address, the filename, the claim — and fix or cut every occurrence in the same
edit. A half-applied correction is worse than none: the store still contradicts
itself, and the next reader has no way to tell which half is current. Three
times in one session (2026-09-11, `runs/2026-09-11.md`): `51df5bf5` named 2
sites of a swapped dock pair and there were **3** — the missed one said which
physical box carries immich-2024; `031261e5` named 1 site of a wrong tailnet
table and there were **2**; `2ae4f3c7` said 2 copies of a `gh pr edit` duplicate
and there were **3**, the third carrying two facts the survivor lacked.
**Corollary for a `dedupe`: the item's copy count is a lower bound, never the
count.** And for a `contradiction`, the item's survivor pointer is a claim to
check, not an address — confirm the survivor still exists *and* is still the
fuller copy, especially when an earlier item in the same session moved it.

## Step 2b — A `skill` item is applied with `writing-skills`

An item targeting `memory-harvest/consolidate-phase.md` or `memory-review/SKILL.md` is a change to how
every future run behaves, so it gets the heaviest treatment, not the lightest:

- Invoke `superpowers:writing-skills` to make the edit — that is the tool for
  editing a skill, and it verifies before deployment.
- Re-run `bash agents/plugin/skills/lib/tests/consolidate.test.sh`, and the full
  gate if `consolidate.sh` changed at all.
- Read the item's cited `runs/YYYY-MM-DD.md` before approving. A `skill` item
  must name the run that hit the problem; if it does not, reject it — that is
  the difference between a fix and a drift.

`claude-md-improver` is **not** the tool for the `CLAUDE.md`/`AGENTS.md` items
in this queue. It grades against a generic template and would call a 46 KB
`AGENTS.md` too long without knowing its length is incident history — the exact
"compress a rule" mistake `/memory-harvest` is written to avoid.

## Step 3 — Apply

Edit with the shell (`sed -n` to read, a heredoc or `python3` to rewrite).
`Read`/`Grep` are blocked by the gortex deny hook on indexed source.

## Step 4 — Verify the diff by CONTENT, not by count

Both recipes below are here because the obvious versions produced wrong answers
in this repo:

```bash
# counts — --numstat is the count. A grep is not.
git -C <repo> diff --numstat -- <ABSOLUTE path>

# what was actually deleted
git -C <repo> diff -U0 -- <ABSOLUTE path> | grep '^-' | grep -v '^---' | sed 's/^-//'
```

- **`grep -E '^-[^-]'` is a broken deletion filter.** Every memory store is
  markdown bullets, and `- text` renders as `-- text` in a diff; a deleted blank
  line renders as a bare `-`. That filter reports **zero deletions** on a diff
  that removes a whole section.
- **Relative pathspecs against the dotfiles bare repo match nothing**, silently,
  and read as "identical". Absolute paths, always.

For a deletion, the deleted-line listing must equal the section the item said to
cut — nothing more. Diff it:

```bash
diff <(git -C <repo> diff -U0 -- <abs> | grep '^-' | grep -v '^---' | sed 's/^-//') /tmp/cut-section
```

Anything extra means the edit was wider than the decision. Revert and re-do.

## Step 5 — Record, then commit

```bash
bash "$D" decide <id> applied  "<one line: what landed where>"
bash "$D" decide <id> rejected "<one line: why not>"
```

**Pass the file and a phrase on every `applied`** — those two columns are what
lets `consolidate.sh verify` re-check the decision later:

```bash
bash "$D" decide <id> applied "<what landed where>" \
  /home/me/.claude/memory/global.md "a distinctive phrase from what you wrote"
```

Without them the row is permanently `unverifiable`: recorded as accepted, never
provable as still there. Pick a phrase from the text you actually wrote, not
from the item's prose.

`decide` appends to the ledger and cuts the item out of `queue.md`.

A **proposal file** has no ledger, so move it out of the open set by hand once
every row in it is decided, recording each outcome and — for a rejection — the
reason:

```bash
mkdir -p "$repo/.claude/harvest/decided"
mv "$repo/.claude/harvest/shared-proposal-<date>.md" "$repo/.claude/harvest/decided/"
```

**A rejection must be written down.** Track A will not re-propose it (the
transcript watermark is read-once), but Track B re-derives drift from the git
history every run, so an unrecorded rejection comes back tomorrow night.

Commit **each repo separately** — a dotfiles-tracked store and a repo-tracked
store are different repositories and never share a commit:

```bash
# dotfiles side (core/global/host-memory/personality)
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add <ABSOLUTE paths>
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory: ..."

# repo side (a project.md, plus the queue + ledger themselves)
git -C ~/machines add docs/memory-consolidate .claude/memory/project.md
git -C "$repo" add .claude/harvest   # the decided proposals, per repo
git -C ~/machines commit -m "memory-review: ..."
```

## Step 6 — Promote what is shared

A `shared` store change is not fleet-wide until it reaches dotfiles `main`. Run
`/dotfiles-promote` with **absolute paths** for exactly the stores touched.

Standing instruction from Maxim (2026-09-10): *do not ask about the promote when
it is obvious* — a memory file on `main` lives there by definition. Do it and
name it in the report.

The promote gate is `git -C "$wt" diff --stat origin/main HEAD`: it must list
the promoted paths and nothing else. **An intentional deletion inverts the
gate** — deleted lines are expected there, so check their *content* against the
section you cut using the Step 4 recipe, not their count.

## Step 7 — Report

Per item: applied or rejected, where it landed, the byte delta. Then the corpus
total before and after, and how many items are still open.
