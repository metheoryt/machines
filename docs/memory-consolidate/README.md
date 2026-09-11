# memory-consolidate — the memory corpus, tidied

This directory is the output of **Phase B of `/memory-harvest`** — the
whole-corpus consolidation pass, whose brief is
`agents/plugin/skills/memory-harvest/consolidate-phase.md`. It was the `/dream`
skill until 2026-09-11 and `/memory-consolidate` for a day after that.

It runs **once for the fleet, on one box** — the one `fleet.json` marks
`"memory_publisher": true` (latitude). That box reads every machine's dotfiles
branch out of the bare repo, so no ssh and nothing touched remotely; a second
box running it would file a duplicate of every item, which is why the gate is a
manifest key rather than a copy of the phase.

**Phase B never edits a memory store.** It files decisions here, with the
replacement text ready. `/memory-review` is the attended session that applies
them — the same session that works the per-repo shared-memory proposals Phase A
files, because both write the same stores and both end in one
`/dotfiles-promote`.

## Files

- `queue.md` — open decisions. **Append-only from a run's side**: `/memory-harvest`
  never rewrites or reorders an existing item, so notes added by hand survive.
  An item leaves this file only through `consolidate.sh decide`.
- `ledger.tsv` — `id · applied|rejected · date · reason`, append-only. This is
  what stops a rejected proposal coming back every night.
- `runs/YYYY-MM-DD.md` — one report per run: what was scanned, the byte totals
  now vs. if every open item were applied, what was filed, what was suppressed.

## Working the queue by hand

```bash
D=~/machines/agents/plugin/skills/lib/consolidate.sh
bash "$D" scan                     # every store: path, bytes, scope, sections
bash "$D" status <id>              # new | open | decided
bash "$D" decide <id> rejected "why not"
```

Skills: `agents/plugin/skills/memory-harvest/` and `agents/plugin/skills/memory-review/`.
