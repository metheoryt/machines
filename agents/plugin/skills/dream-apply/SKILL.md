---
name: dream-apply
description: Use when the user wants to work through the /dream decision queue — reviewing proposed memory consolidations and applying the approved ones. This is the only half of the dream pair that writes to a memory store. Always interactive; never run unattended.
---

# dream-apply — work the queue

`/dream` proposes; this applies. It is the gate, so it is **always attended**.
Never wire it to an Automation, never run it inside a `claude -p` batch.

## Step 0 — Load

```bash
D=~/machines/agents/plugin/skills/dream/dream.sh
cat ~/machines/docs/dream/queue.md
cat ~/machines/docs/dream/ledger.tsv 2>/dev/null
git -C ~/machines status --porcelain
```

If the queue is empty, say so and stop — do not go looking for work to do.

## Step 1 — Present, in scope order

Group items by `scope`, most expensive first: `shared` (fleet-wide) → `repo:` →
`host` → `untracked`. Within a group, deletions before rewrites — a deletion is
what a reader wants to look at hardest.

For each item show: action, target, why, the byte delta, and — for a rewrite —
**the replacement text in full**. One item at a time for anything `shared` or
any `delete`; batching those is how a deletion gets waved through.

The user approves an item, edits it, or rejects it. **A rejection is a real
outcome that must be recorded** — `dream.sh decide <id> rejected "<reason>"` —
or `/dream` proposes it again tomorrow night.

## Step 2 — Re-verify before writing

The queue can be days old. Before applying an item, re-read the target section
and confirm the quoted lines still say what the item claims. If they moved or
changed, re-derive the item rather than applying it blind; line numbers in the
queue are a starting point, not an address.

For a `dedupe` or `demote`: **write the surviving copy first, verify it landed,
then delete the source.** Never the other way round. If the item names a
"carry first" fact, that carry is what makes the delete safe — do it and read
it back before touching the source.

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

`decide` appends to the ledger and cuts the item out of `queue.md`.

Commit **each repo separately** — a dotfiles-tracked store and a repo-tracked
store are different repositories and never share a commit:

```bash
# dotfiles side (core/global/host-memory/personality)
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add <ABSOLUTE paths>
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory: ..."

# repo side (a project.md, plus the queue + ledger themselves)
git -C ~/machines add docs/dream .claude/memory/project.md
git -C ~/machines commit -m "dream-apply: ..."
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
