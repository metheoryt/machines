# Shared memory stores — convergence plan (2026-09-11)

Follow-up to `/dream` run `runs/2026-09-11.md`, queue item **`2f658c5e`**. Written to
survive a context compaction: everything below was measured, not recalled.

## The decision (owner, 2026-09-11)

> "These files should be identical on every host, and host-specific data should be either
> on its own branch, or on its own file. The per-host branches, however, are a good buffer
> to collect data from all machines at once."

So: **`main` is the source of truth for the six shared stores**; a per-host branch is a
collection buffer, never a place shared content lives permanently. **Record this in
`~/.claude/memory/global.md` (or `~/CLAUDE.md`) once the convergence below is done** —
deliberately not written yet, because it would add to the very delta being promoted.

## Two framings in the queue item that were wrong — do not act on them

`2f658c5e` says "three clusters, a human picks which content survives." A later reading
said "purely additive." **Neither.** Measured at section-body level across all six
branches: it is additive accumulation **plus one lagging branch (`air`)**, and air's lag
is what manufactured every apparent conflict. **The whole reconciliation is mechanical —
zero sections need a judgement call.**

## State as measured (2026-09-11)

`origin/main` tip **2026-08-27**; nothing promoted in 15 days. Blob hashes, `ls-tree -r
--full-tree`:

| file | main | air | desktop-wsl | g15 | hub | latitude |
|---|---|---|---|---|---|---|
| core.md | d26f23b6 (3004) | = | **280f315b (3385)** | = | = | = |
| global.md | dd800fdc (99341) | **d231e355 (86373)** | d5f0a8fd (122676) | **7626200b (123859)** | d5f0a8fd | d5f0a8fd |
| habits.md | 825483fb (4781) | = | d4d7e524 (5821) | d4d7e524 | d4d7e524 | d4d7e524 |
| practices.md | c193248a (22141) | **3bedd872 (23148)** | **621d4b12 (31990)** | = | = | = |
| tone.md | 8fc67df2 (9116) | **9c0bd12b (9644)** | **21250390 (10624)** | = | = | = |
| values.md | 93a920d1 (3284) | = | **54233cdc (7034)** | cf5709fd (6068) | cf5709fd | cf5709fd |

`air` is **1 behind `main`, 62 ahead**, and `main` is **not merged** into it
(`merge-base --is-ancestor main origin/air` → false). Every other live branch has `main`
merged.

## Section-body analysis — what is actually contested

22 sections differ in body somewhere. Filtering to sections with **two or more distinct
non-main versions** leaves five, and four of those are air being stale (air has *fewer*
lines than `main`; every other box is byte-identical):

| file · section | verdict |
|---|---|
| `global.md ## Fleet SSH reachability` | main 122, **air 119 (behind)**, all others 134 identical → air merges main |
| `global.md ## Git & bash footguns` | main 93, **air 82 (behind)**, all others 106 identical → air merges main |
| `global.md ## Writing PR bodies / ticket prose at Pure` | main 22, **air 17 (behind)**, all others 25 identical → air merges main |
| `global.md ## ISP-level TLS-SNI filtering in KZ` | absent on main+air; desktop-wsl/hub/latitude 111 identical, **g15 126** → take g15's |
| `practices.md ## Abstraction discipline` | main 23, g15/hub/latitude = main, **air 34**, desktop-wsl 24 |

**The last one is the only true two-branch divergence, and it resolves itself:** air added
a real 11-line rule (a test whose fixtures are all one platform's string shape — the
`"gortex hook"` vs `gortex.exe hook` case that degraded the merge to append-only on half
the fleet for two weeks). desktop-wsl added **one blank line**. **Take air's.**

## What each box is uniquely ahead on

- **desktop-wsl** — `practices.md` +7 sections (review-craft rules from real PRs/tickets:
  PR #742, CFT-4888 ×2, CFT-5051, PR #4384, machines/hosts/g15/staging, g15/Orca),
  `values.md` (7034), `tone.md` (10624), `core.md` (3385), `.claude/CLAUDE.md` (9593).
  **~17.8 KB stranded on one branch.**
- **g15** — `global.md` +1183 over cluster B: `## gh CLI gotchas`,
  `## Piping bulk data out of a container's stdout…`, and +15 lines on the ISP section.
- **air** — `practices.md ## Abstraction discipline` +11 lines, `tone.md` +528.
- **latitude / hub / g15 agree** on `global.md` (+23335 over main), `habits.md` (+1040),
  `values.md` (+2784). **Any one of the three can promote that**; it is the largest piece.

## Order of operations — and the one reason order matters

**Converge first, apply the `/dream` queue second.** The queue proposes deleting 22.9 KB
from `global.md` (the seven Pure demotes) and rewriting `core.md`. Applying those before
the branches converge means re-deriving the same deletions per branch. Get `main` correct
and every box equal, then work the queue from one box at a time.

1. **On `air`:** merge `origin/main` into the air branch. Resolves three of the four
   apparent conflicts outright.
2. **Promote the cluster-B block** (`global.md` +23 KB, `habits.md`, `values.md`) from
   latitude, hub **or** g15 — whichever is convenient; they are byte-identical.
3. **Promote from `desktop-wsl`** — its ~17.8 KB, reviewing whether any of it is really
   desktop-wsl-local and belongs in its `host-memory.md` (33529 B, the fleet's largest)
   instead of on `main`.
4. **Promote from `g15`** — the `global.md` +1183. Eyeball it first: this box's recent
   work was its own Ubuntu reinstall, and a reinstall detail is host memory, not global.
5. **Promote from `air`** — `Abstraction discipline` +11 and `tone.md` +528, after step 1.
6. Let every box's sync timer merge `main`; re-run the check below to confirm convergence.
7. **Then** start `/dream-apply` on the queue, and record the decision at the top of this
   doc into `global.md`.

**Not started.** Step 4 was offered and is awaiting the owner's go — it writes to `main`
and reaches every box on its next sync tick.

## Reproducing the analysis

Nothing above needs to be taken on trust; the section-body comparison is:

```bash
G="git --git-dir=$HOME/.dotfiles --work-tree=$HOME"
for f in .claude/memory/core.md .claude/memory/global.md \
         .claude/memory/personality/{habits,practices,tone,values}.md; do
  base=$(basename "$f" .md)
  for b in main air desktop-wsl g15 hub latitude; do
    r=$b; [ "$b" = main ] || r=origin/$b
    $G show "$r:$f" 2>/dev/null | awk -v d="secs/$base/$b" '
      /^## / { n=$0; gsub(/[^A-Za-z0-9]/,"_",n); f=d"/"substr(n,1,80); system("mkdir -p \""d"\"") }
      f { print > f }'
  done
done
# then: per section, count DISTINCT non-main md5s. 0 = main is current, 1 = mechanical
# (that branch wins), 2+ = needs a human.
```

## Also settled this session

- **`gortex instructions switch core` was run on g15** — `~/.gortex/instructions/active.md`
  exists again (3061 B), so the empty `@`-import on this box is fixed. Queue item
  **`68f42627` stays open but is no longer urgent**: the box is healthy, while the *test*
  in `~/.claude/CLAUDE.md` is still wrong in principle (an empty import cannot distinguish
  "profile not provisioned" from "no gortex"). The replacement text for it is in
  `runs/2026-09-11.md` under *Notes for whoever works the queue*.
