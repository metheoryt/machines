---
name: dream
description: Use when the user wants the accumulated memory stores consolidated — organised, generalised, deduplicated, pruned — or when running the nightly memory-consolidation pass. Reads every memory store read-only and files a reviewable decision queue; it NEVER edits a memory store itself. The companion /dream-apply is what writes.
---

# dream — consolidate memory without touching it

Named by analogy: long-term memory is reorganised during sleep, not during the
day. This is the reorganising pass. It runs unattended (Orca Automation,
nightly, on `desktop`) and its whole output is a queue of proposed decisions a
human works through whenever it suits them.

## The invariant that defines this skill

**A `/dream` run writes ONLY under `docs/dream/`.** It never edits a memory
store, never edits a `CLAUDE.md`, never touches `kb-harvest-state.json`, never
commits outside the `machines` repo. If a run believes a store must change, it
says so in the queue with the replacement text ready to paste — and stops.

Why this and not "let it tidy up": an unattended session that edits memory can
silently delete a fact that was the only copy, and nobody would find out until
they needed it. The queue makes every deletion a human's decision, with the
evidence attached. See `personality/values.md` — *a file can be the last copy
of a FACT*.

## Read the stores with the shell, not with Read/Grep

`cat`, `sed -n '<a>,<b>p'`, `awk`, `wc -c`. The gortex `PreToolUse` hook runs
in **deny** posture and blocks `Read`/`Grep`/`Glob` against indexed source; an
unattended `claude -p` run has nobody to negotiate with when it fires. This is
not a style preference — it is what makes the nightly run complete at all.

`dream.sh` is itself indexed source, and the deny hook nudges on shell *writes*
to it. Invoking it does pass: measured 2026-09-11, `claude -p 'run bash
agents/plugin/skills/dream/dream.sh paths'` from `~/machines` returned the
output and exited 0. If that ever changes, the nightly run fails as a **silent
skip**, so re-measure it rather than assuming.

## Step 0 — Preflight

```bash
D=~/machines/agents/plugin/skills/dream/dream.sh
bash "$D" paths

# Baseline for the Step 8 invariant check. A store already dirty now is not a
# violation later; without these two files there is nothing to compare against.
before_repo=$(mktemp); before_home=$(mktemp)
git -C ~/machines status --porcelain -- .claude/memory/project.md > "$before_repo"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --porcelain -- \
  $HOME/.claude/memory $HOME/.claude/host-memory.md > "$before_home"
```

If `~/machines` is not a clean checkout on `main`, still run — but say so in the
report and do not commit; leave the queue as an uncommitted change.

## Step 1 — Scan and measure

```bash
bash "$D" scan                                  # path, bytes, scope, ## count
bash "$D" index <store>                         # line, section bytes, heading
```

`scan` discovers stores by **glob**, so one added later shows up on its own.
The `scope` column is what makes a proposal safe to read:

| scope | meaning | what a change there costs |
|---|---|---|
| `shared` | on dotfiles `origin/main` | **fleet-wide** from the next sync tick — every box, byte-identical |
| `host` | tracked by dotfiles, this branch only | this machine; invisible elsewhere until promoted |
| `repo:<name>` | tracked by its own checkout | that repo, everywhere it is cloned |
| `untracked` | no home at all | **that is itself a finding** — file it |

**Attention is not spread evenly.** As of 2026-09-11 the corpus is ~574 KB over
10 stores and `machines/.claude/memory/project.md` alone is 277 KB — 48% of it.
Two stores hold 70%. Budget the run's reading accordingly; re-derive the split
from `scan` each night rather than trusting this sentence.

## Step 2 — Load the suppression baseline FIRST

```bash
cat ~/machines/docs/dream/queue.md      2>/dev/null   # still-open items
cat ~/machines/docs/dream/ledger.tsv    2>/dev/null   # applied + rejected
```

Every candidate is checked with `dream.sh status <id>` before it is filed. An
item already open, applied **or rejected** is dropped silently. Without the
rejected state a declined proposal returns every night, which is exactly how a
queue stops being read.

**The discriminating check for this whole design:** run `/dream` twice in a row.
The second run must file **zero** new items. If it re-proposes, the identity
derivation is wrong and everything downstream is noise — fix that before
trusting any output.

## Step 3 — Pass 1: within-store (fan out)

One subagent per store, in parallel; the two big stores get one subagent per
~40 KB slice of their section index. Give each agent the store path, its
`index` output, and the byte ranges to read with `sed -n`. Each returns rows:

`{action, target, anchor, why, evidence, bytes_before, bytes_after, replacement}`

What pass 1 looks for, inside one store:

- **stale** → `delete` — superseded by a later bullet in the same file, or contradicted by
  something the run can verify cheaply (a path that no longer exists, a host
  that left the fleet, a flag that was renamed).
- **redundant** → `dedupe` — the same fact stated twice under different headings.
- **generalisable** → `generalise` — N specific incidents that are instances of one rule. The
  proposal keeps the rule and **one** dated instance as evidence, not all N.
- **oversized** → `compress` — a section that has become a narrative. Propose the compressed
  version verbatim.
- **misscoped** → `demote`/`promote` — a fact under a heading, or in a store, it does not belong to.

## Step 4 — Pass 2: across stores

Pass 1 agents cannot see each other, so cross-store duplication — the actual
reason this skill exists — is invisible to them. Pass 2 gets only the **section
indexes of every store plus each pass-1 agent's topic list**, finds overlapping
topics, and then reads only the overlapping sections. This is what keeps 574 KB
inside a context.

The two moves it files:

- **dedupe** — the same fact in two stores. Name which copy survives and why;
  the narrower scope usually wins, and the surviving copy must be the *more
  complete* one, not the more convenient one.
- **demote / promote** — a fact sitting at the wrong scope. Project-specific
  content in `global.md` is the known instance: seven `Pure …` sections were
  still there on 2026-09-11 and belong in `pure/backend-api`.

A move is **two** decisions — write here, delete there — and they must be one
queue item, so applying half of it cannot lose the fact.

## Step 5 — Standing checks (every run, regardless of what pass 1/2 found)

- **`core.md` budget.** It is injected verbatim into every session and Claude
  Code truncates a hook's stdout near 3500 bytes. Over ~2000 bytes → file an
  item; over 3000 → file it as urgent, with the compressed text ready.
- **Unharvested transcripts.**
  ```bash
  jq '.sessions | length' ~/machines/.claude/kb-harvest-state.json
  ls ~/.claude/projects/*/*.jsonl | wc -l
  ```
  A gap means facts are ageing out of transcripts unrecorded. File **one**
  `harvest` item naming the gap and the last refresh commit — and **do not run
  kb-refresh from here.** `fleet-gather.sh` advances its watermark at *gather*
  time, before its own review gate, so a nightly gather whose candidates nobody
  applies marks those sessions harvested and strands them permanently. Harvest
  is an attended action.
- **Untracked store** — anything `scan` reports as `untracked` has no home and
  dies with the machine.
- **A store nobody reads.** If a store has not changed in months and nothing
  references it, say so; it is a candidate for folding into another.

## Step 6 — File the items

Each item is a file, then:

```bash
id=$(bash "$D" id "<target>" "<anchor>" "<action>")
# write the item to $t with '## <id> · <action> · <target>' as its first line
bash "$D" append "$id" "$t"     # prints appended|suppressed
```

**The three id inputs are copied verbatim from the tools, never retyped.** This
is the single point the whole queue rests on: an anchor written `## Pure
logging` one night and `Pure logging` the next is two ids for one finding, and
the item comes back forever.

| input | where it comes from | example |
|---|---|---|
| `target` | `scan` column 1 — the **absolute** path, no `~` | `/home/me/.claude/memory/global.md` |
| `anchor` | `index` column 3 — the heading text, no `##`, no backticks | `Pure logging — Grafana/Loki vs Kibana (updated 2026-08-26)` |
| `action` | one word from the taxonomy below | `dedupe` |

Actions: `dedupe` · `demote` · `promote` · `generalise` · `compress` ·
`delete` · `contradiction` · `harvest` · `untracked`. Do not invent a tenth —
a finding that fits none of these is a `contradiction` for a human to name.

For a **cross-store** item the target/anchor pair is the side being **removed**
or rewritten, so a move filed from either direction lands on the same id.

Item shape — the **replacement text must be verbatim and complete**, because
that is what makes applying mechanical instead of re-doing the thinking:

```markdown
## a1b2c3d4 · dedupe · /home/me/.claude/memory/global.md

- **action:** dedupe
- **scope:** shared → fleet-wide change
- **target:** `/home/me/.claude/memory/global.md`
- **anchor:** `Pure logging — Grafana/Loki vs Kibana (updated 2026-08-26)` (L1283, 4210 B)
- **survives:** `/home/me/pure/backend-api/.claude/memory/project.md` `Logging` (host)
- **why:** both describe the Grafana/Loki-vs-Kibana split; the repo copy is
  longer and carries the retention numbers the global one omits.
- **evidence:** global.md:1283-1364 · backend-api/project.md:412-498
- **carry first:** the one fact global has and the repo copy lacks — <quote it>
- **bytes:** 4210 → 0 in global (−4210); +180 in backend-api
- **replacement:** (none — deletion after the carry above)
- **first seen:** 2026-09-11
```

Rules for an item:
- **`delete` requires evidence of what supersedes it**, or a statement that the
  fact is verifiably no longer true. "Looks old" is not evidence.
- **Never propose deleting the last copy of a fact.** If nothing else records
  it, the action is `demote`/`generalise`, never `delete`.
- One item, one decision. If applying half of it would lose something, it is
  one item, not two.

## Step 7 — Run report

`docs/dream/runs/YYYY-MM-DD.md`, and it is the answer to *"how compact will the
organised knowledge be?"*:

- stores scanned: path, bytes, scope — and the total
- **bytes now → bytes if every open item were applied**, per store and overall
- items filed this run, by action
- items suppressed (already open / applied / rejected) — a count, not a list
- anything the run could not read, and why
- standing checks: core.md size, transcript gap

## Step 8 — Prove the invariant held, then commit

Compare against the Step 0 baseline — a store that was **already** dirty when
the run started is not a violation, and one that is clean in both snapshots is
not proof of anything either. Only a store that changed *during* the run is.

```bash
# repo-side stores (machines' own project.md is one of them, and it lives in
# the same repo as the queue — `add docs/dream` is scoped, the CHECK is not)
git -C ~/machines status --porcelain -- .claude/memory/project.md > "$after_repo"
# dotfiles-side stores: ABSOLUTE pathspecs, or the bare repo matches nothing
git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --porcelain -- \
  $HOME/.claude/memory $HOME/.claude/host-memory.md > "$after_home"

diff "$before_repo" "$after_repo" && diff "$before_home" "$after_home"
```

Both diffs must be empty. If either is not, the run edited a memory store:
**say so as the first line of the report, name the file, commit nothing**, and
leave the change in place for a human to look at — do not "clean up" by
reverting, because the edit may be the only record of what went wrong.

```bash
git -C ~/machines add docs/dream
git -C ~/machines commit -m "dream: <N> items, <date>"
```

The `machines` repo only, and only `docs/dream`. No `git push`, no promote.

## Never

- Edit any memory store, any `CLAUDE.md`, or `kb-harvest-state.json`.
- Run `kb-refresh`, `fleet-gather.sh` or `distill.py`.
- Run `/dotfiles-promote`, or any `git push`.
- Rewrite or reorder an existing queue item — a human may have annotated it.
- File an item without evidence a reader can check without re-running the pass.

## Running it nightly

```bash
cd ~/machines && claude -p '/dream'
```

On `desktop`, via an Orca Automation, so the sessions can be watched. It is
read-only plus one commit to one repo, so a failed run costs nothing and the
next night starts from the same queue.
