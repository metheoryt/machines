---
name: repo-harvest-apply
description: Use when the user wants to work through the shared-memory proposals that /repo-harvest filed — reviewing each one and applying the approved rows to global.md, personality/* and this box's host-memory.md. This is the only half of the pair that writes to a shared memory store. Always interactive; never run unattended.
---

# repo-harvest-apply — land the shared-memory proposals

`/repo-harvest` writes its repo-local findings by itself and **proposes**
everything aimed at shared fleet memory. This applies those proposals. It is
the gate, so it is **always attended**: never wire it to an Automation, never
run it inside a `claude -p` batch.

Scope is Lane 2 only — `~/.claude/memory/global.md`,
`~/.claude/memory/personality/*`, `~/.claude/host-memory.md`. Lane 1 targets
(`project.md`, `AGENTS.md`, `docs/`) are already committed by the harvest and
are not re-litigated here.

## Step 0 — Load every open proposal

```bash
ls -1 "$HOME"/*/.claude/harvest/shared-proposal-*.md \
      "$HOME"/*/*/.claude/harvest/shared-proposal-*.md 2>/dev/null
```

Same depth-2 glob `/repo-harvest` discovers repos with, so a repo cloned later
shows up on its own. `cat` each one. If none, say so and stop — do not go
looking for work to do.

Then check both write targets are clean before touching them:

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --porcelain --untracked-files=no
```

A dirty tracked store means someone is mid-edit, or the 10-minute sync timer is
about to commit. Defer and say so rather than mixing your write into theirs.

## Step 1 — Present, most expensive first

`global.md` and `personality/*` are **fleet-wide from the next sync tick**;
`host-memory.md` is this box only. Present in that order, one row at a time for
anything that edits or deletes an existing bullet.

For each row show: the fact as it would be written, the target file and
heading, the source session or commit, the confidence, and which repo proposed
it.

Two refusals that are not rejections:

- **A row targeting another box's `host-memory.md`.** Per-host files are
  branch-scoped, so that box's copy is readable from here but not writable, and
  its own sync timer is committing to that branch live. List these separately
  as "carry to `<box>`" — they stay open.
- **A row whose source is a work repo but whose content is personal-fleet.**
  Check what it actually says before it lands in a store that reaches every
  box. This is the whole reason Lane 2 is gated; if the harvest ran over a Pure
  repo, this is where that matters.

The user approves, edits, or rejects each row.

## Step 2 — Re-verify before writing

A proposal can be days old. Re-read the target section and confirm it still
says what the row assumed. Line references in a proposal are a starting point,
not an address.

**A row names one site; the fact may live at several.** Before writing a
correction, search the whole store for the claim being corrected and fix every
occurrence in the same edit. A half-applied correction leaves the store
contradicting itself with no way to tell which half is current — that failure
hit three items in one session on 2026-09-11.

## Step 3 — Apply

Edit with the shell (`sed -n` to read, a heredoc or `python3` to rewrite);
`Read`/`Grep` are blocked by the gortex deny hook on indexed source.

Append under the right existing heading, matching that file's voice and bullet
style. Keep the harvest's provenance tag on the bullet
(`<!-- src: <repo> <sha> | <date> -->`) — it is what lets
`/memory-consolidate` weigh a fact that keeps arriving from several repos.

Keep `core.md` under ~2 KB. It is injected verbatim into every session, and
Claude Code truncates a hook's stdout past ~3.5 KB — an overfull core.md is how
the whole memory index silently stops loading.

## Step 4 — Verify the diff by CONTENT, not by count

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME diff --numstat -- <ABSOLUTE path>
git --git-dir=$HOME/.dotfiles --work-tree=$HOME diff -U0 -- <ABSOLUTE path> \
  | grep '^-' | grep -v '^---' | sed 's/^-//'
```

Both forms are here because the obvious ones give wrong answers in this repo:

- **`grep -E '^-[^-]'` is a broken deletion filter.** Memory stores are
  markdown bullets, so `- text` renders as `-- text` in a diff and a deleted
  blank line renders as a bare `-`. That filter reports zero deletions on a
  diff that removes a whole section.
- **A relative pathspec against the dotfiles bare repo matches nothing**,
  silently, and reads as "identical". Absolute paths, always.

## Step 5 — Record the outcome, then commit

Move each proposal out of the open set so the next run does not re-present it:

```bash
mkdir -p "$repo/.claude/harvest/decided"
# append one line per row — applied|rejected, and for a rejection, why
mv "$repo/.claude/harvest/shared-proposal-<date>.md" \
   "$repo/.claude/harvest/decided/"
```

**A rejection must be written down with its reason.** Track A will not
re-propose it — the transcript watermark is read-once — but Track B re-derives
drift from the git history every run, so an unrecorded rejection comes back.

Commit each repository separately; a dotfiles-tracked store and a repo-tracked
file never share a commit:

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add <ABSOLUTE paths>
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory: <n> facts from <repo> harvest"
git -C "$repo" add .claude/harvest && git -C "$repo" commit -m "harvest: decide <date> proposals"
```

## Step 6 — Promote what is shared

A `global.md` or `personality/*` change is not fleet-wide until it reaches
dotfiles `main`. Run `/dotfiles-promote` with **absolute paths** for exactly
the stores touched.

Standing instruction from Maxim (2026-09-10): *do not ask about the promote
when it is obvious* — a shared memory file on `main` lives there by definition.
Do it and name it in the report. `host-memory.md` is never promoted.

## Step 7 — Report

Per row: applied or rejected, where it landed, the byte delta. Then which
stores were promoted, and what is still open — including anything carried to
another box.
