# Shared memory stores — convergence plan (2026-09-11)

Follow-up to `/dream` run `runs/2026-09-11.md`, queue item **`2f658c5e`**. Written to
survive a context compaction.

> **CORRECTION (later the same day).** The first version of this doc measured against an
> `origin/main` that had never been fetched in that session. `main` was **not** stale at
> 2026-08-27 — it carried promotes through 2026-09-11, and step 2 below was already done
> before it was written. Every table here is re-measured post-fetch. **If a `dotfiles`
> measurement surprises you, fetch first** — that one omission produced a wrong hash
> table, a wrong "nothing promoted in 15 days", and a plan step that did not exist.

## The decision (owner, 2026-09-11)

> "These files should be identical on every host, and host-specific data should be either
> on its own branch, or on its own file. The per-host branches, however, are a good buffer
> to collect data from all machines at once."

So: **`main` is the source of truth for the six shared stores**; a per-host branch is a
collection buffer, never a place shared content lives permanently. **Record this in
`~/.claude/memory/global.md` once the queue is worked** — deliberately not written yet.

## Two framings in queue item `2f658c5e` that were wrong — do not act on them

`2f658c5e` says "three clusters, a human picks which content survives." A later reading
said "purely additive." **Neither.** The reconciliation was mechanical: additive
accumulation plus one branch (`air`) that had been offline since 2026-09-07.
**Zero sections needed a judgement call about which content survives.**

## What was done (2026-09-11, pushed to `main` as `4fd94fb` / `8ae583e` / `6299689`)

One throwaway worktree off `origin/main`, three provenance commits, one push:

| commit | source | paths | delta |
|---|---|---|---|
| `4fd94fb` | desktop-wsl | `core.md`, `practices.md`, `tone.md`, `values.md`, `.claude/CLAUDE.md` | +201 / -0 |
| `8ae583e` | g15 | `global.md` | +15 / -0 |
| `6299689` | air | `practices.md`, `tone.md`, `global.md` | +22 / -0 |

**Gate: zero deleted lines on every path** (`diff -U0 origin/main HEAD | grep '^-'` empty).
Total +238 lines. `g15` merged `main` back down (`2ec10b9`) and is byte-identical to `main`
on all seven paths.

### The air content was NOT a regression on `main`

Worth recording because the opposite conclusion was reachable and wrong. `air`'s `tone.md`
and `global.md` hold text `main` lacks, and `air` last merged `main` on 2026-08-25 — which
reads like "`main` lost these lines." It did not: `git log -S<phrase> origin/main` finds
**no commit on `main` that ever added or removed them**. Both blocks were authored on
`air` in `ce14d41` (2026-08-17) and never promoted — stranded on a branch for 25 days.
That is the collection-buffer failure mode the owner's decision is about, not a promote
bug. **`air` is still the best audit oracle for `main`'s promote history**: it is the one
branch frozen before the 2026-09-10 wholesale-promote incident the `/dotfiles-promote`
skill documents.

### One judgement call made while merging, and why

`air`'s `global.md` block (a gortex MCP session's project binding, probed 2026-08-17) is
**superseded** by a bullet `main` already carries, probed on 0.63.2 on 2026-08-25 — same
finding, later measurement, better written, and it includes the fix. Promoting air's
version wholesale would have filed the duplicate. **Only the one non-redundant sub-bullet
was taken** — that Orca *does* index a new worktree at creation, so
`gortex://index-health`'s `semantic_enrichment[].repo` is the check before blaming the
index — appended under `main`'s bullet. The rest of air's block was deliberately dropped.

### `practices.md` was the only real merge

Both `desktop-wsl` (+150) and `air` (+11) append at the end of the file, so `git apply -3`
conflicted there. Resolved by keeping both, then verified against an independent oracle
(`desktop-wsl`'s file, concatenated with air's added lines) — byte-identical.

## What is left

- **`air` is offline** (last commit 2026-09-07, `ssh air.gg.ez` times out). It is 9 behind
  / 62 ahead of `main` with `main` not merged in. **This is self-healing**: its sync timer
  merges `origin/main` on boot, and its only post-merge commits touch `practices.md` and
  `.ssh/config`, so the merge is clean by construction — `practices.md` is now
  byte-identical on `main` and `air` because promote copies content.
- **Do NOT push a merge to `origin/air` from another box.** `dotfiles-sync.sh`'s
  `sync_merge` fetches `+refs/heads/main:…` and nothing else, so air would never learn its
  own branch had moved; `sync_push` would be rejected non-fast-forward and report
  "push failed (offline or auth) — retrying next tick" **forever, silently**. Step 1 is an
  at-that-box action or no action at all.
- **`g15`, `hub` and `latitude` converge on their own next sync tick** — no promote needed,
  only the merge their timer already does, and the check below observes it via
  `origin/<branch>`. `g15` is already there.
- **`desktop-wsl` cannot be observed from here**, and it contributed the largest share of
  what was promoted. It refuses SSH on 22 (answers on 2222) and is `dispatch:parent`, so
  its convergence needs a check at that keyboard or through its Windows parent. Do not
  read its absence from the drift list as proof — read it as unobserved.

```bash
G="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
$G fetch --all -q
for f in .claude/memory/core.md .claude/memory/global.md \
         .claude/memory/personality/{habits,practices,tone,values}.md .claude/CLAUDE.md; do
  m=$($G ls-tree -r --full-tree origin/main -- "$f" | awk '{print $3}')
  out=""
  for b in air desktop-wsl g15 hub latitude; do
    h=$($G ls-tree -r --full-tree "origin/$b" -- "$f" | awk '{print $3}')
    [ "$h" = "$m" ] || out="$out $b"
  done
  printf '%-28s %s\n' "$(basename "$f")" "${out:- CONVERGED}"
done
```

**Pathspecs need `-r --full-tree` and a `:(top)` prefix for `diff`.** A relative pathspec
resolves against the shell's cwd, not the work-tree root, so `-- .claude/memory/` run from
`~/machines` asks about `~/machines/.claude/memory/` and prints an **empty diff**. Empty
means "no such path", not "identical", and it looks exactly like the answer you wanted.

## Then — the `/dream` queue

Work the 103-item queue (`queue.md`) with `/dream-apply` **after** the boxes converge, and
record the owner's decision above into `global.md` as part of it.

**Any queue item carrying a verbatim complete replacement for `core.md`, `global.md`,
`practices.md`, `tone.md`, `values.md` or `.claude/CLAUDE.md` was authored against the
pre-convergence file and is now stale.** `core.md` grew 3004 → 3385 B, `practices.md`
+161 lines, `global.md` +19, `.claude/CLAUDE.md` +6 (the "a harness-level instruction wins
for shell reads" paragraph — items `68f42627` and `0a184245` are filed against that file,
and the run report's replacement text for `68f42627` predates it). Re-derive those
replacements at apply time; do not paste them.

### `core.md` is now 3385 B against a ~2 KB budget — check this at the next session start

The budget in `~/.claude/CLAUDE.md` is a mechanism, not tidiness: `global-memory-load.sh`
injects `core.md` verbatim, and Claude Code **persists a hook's stdout past ~3.5 KB and
injects only a preview** — the failure that once turned a 142 KB `cat` into a 2 KB stub.
The hook itself is fine (it emits all 3385 B, verified by grepping its output for
`core.md`'s last line), but 3385 B is inside 200 bytes of the documented cliff and this
session only ever observed the 3004 B version arriving intact. **At the next SessionStart,
confirm the injected core block ends with the `tone.md holds the rest` bullet.** If it is
truncated, every session on every box is loading a stub — shrinking `core.md` is then the
first queue item to work, ahead of everything else.

## Also settled this session

- **`gortex instructions switch core` was run on g15** — `~/.gortex/instructions/active.md`
  exists again (3061 B), so the empty `@`-import on this box is fixed. Queue item
  **`68f42627` stays open but is no longer urgent**: the box is healthy, while the *test*
  in `~/.claude/CLAUDE.md` is still wrong in principle (an empty import cannot distinguish
  "profile not provisioned" from "no gortex"). Its replacement text is in
  `runs/2026-09-11.md` under *Notes for whoever works the queue*.
