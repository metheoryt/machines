# memory-consolidate — the memory corpus, tidied

`/memory-consolidate` is the reorganising pass over the accumulated Claude
memory stores. It reads every store on this box **and every other box's branch**
out of the dotfiles bare repo, so it runs **once for the fleet**, not once per
machine. It was `/dream` until 2026-09-11.

**Two skills, one queue, and only one of them writes.**

| | what it does | when |
|---|---|---|
| `/memory-consolidate` | reads every memory store, files proposed decisions here | unattended, nightly (Orca Automation on `desktop`) |
| `/memory-consolidate-apply` | reviews the queue with a human and applies what they approve | attended, whenever it suits |

`/memory-consolidate` writes **only** into this directory. It never edits a memory store —
an unattended session that edits memory can delete the last copy of a fact and
nobody finds out until they need it.

## Files

- `queue.md` — open decisions. **Append-only from a run's side**: `/memory-consolidate`
  never rewrites or reorders an existing item, so notes added by hand survive.
  An item leaves this file only through `consolidate.sh decide`.
- `ledger.tsv` — `id · applied|rejected · date · reason`, append-only. This is
  what stops a rejected proposal coming back every night.
- `runs/YYYY-MM-DD.md` — one report per run: what was scanned, the byte totals
  now vs. if every open item were applied, what was filed, what was suppressed.

## Working the queue by hand

```bash
D=~/machines/agents/plugin/skills/memory-consolidate/consolidate.sh
bash "$D" scan                     # every store: path, bytes, scope, sections
bash "$D" status <id>              # new | open | decided
bash "$D" decide <id> rejected "why not"
```

Skills: `agents/plugin/skills/memory-consolidate/` and `agents/plugin/skills/memory-consolidate-apply/`.
