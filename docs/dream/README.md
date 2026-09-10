# dream — memory consolidation

Long-term memory is reorganised during sleep, not during the day. `/dream` is
the reorganising pass over the accumulated Claude memory stores.

**Two skills, one queue, and only one of them writes.**

| | what it does | when |
|---|---|---|
| `/dream` | reads every memory store, files proposed decisions here | unattended, nightly (Orca Automation on `desktop`) |
| `/dream-apply` | reviews the queue with a human and applies what they approve | attended, whenever it suits |

`/dream` writes **only** into this directory. It never edits a memory store —
an unattended session that edits memory can delete the last copy of a fact and
nobody finds out until they need it.

## Files

- `queue.md` — open decisions. **Append-only from a run's side**: `/dream`
  never rewrites or reorders an existing item, so notes added by hand survive.
  An item leaves this file only through `dream.sh decide`.
- `ledger.tsv` — `id · applied|rejected · date · reason`, append-only. This is
  what stops a rejected proposal coming back every night.
- `runs/YYYY-MM-DD.md` — one report per run: what was scanned, the byte totals
  now vs. if every open item were applied, what was filed, what was suppressed.

## Working the queue by hand

```bash
D=~/machines/agents/plugin/skills/dream/dream.sh
bash "$D" scan                     # every store: path, bytes, scope, sections
bash "$D" status <id>              # new | open | decided
bash "$D" decide <id> rejected "why not"
```

Skills: `agents/plugin/skills/dream/` and `agents/plugin/skills/dream-apply/`.
