---
name: memory-consolidate
description: Use when the user wants the accumulated memory stores consolidated — organised, generalised, deduplicated, pruned — or when running the nightly memory-consolidation pass. Reads every memory store read-only and files a reviewable decision queue; it NEVER edits a memory store itself. The companion /memory-consolidate-apply is what writes.
---

# memory-consolidate — reorganise memory without touching it

The pass that tidies the memory corpus, fleet-wide. It was called `/dream` until
2026-09-11, by analogy with memory being reorganised during sleep; the name was
swapped for one that says its scope, because the old one gave no hint whether to
run it once or once per box. It is once, for everything. It runs unattended (Orca Automation,
nightly, on `desktop`) and its whole output is a queue of proposed decisions a
human works through whenever it suits them.

## The invariant that defines this skill

**A `/memory-consolidate` run writes ONLY under `docs/memory-consolidate/`.** It never edits a memory
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

`consolidate.sh` is itself indexed source, and the deny hook nudges on shell *writes*
to it. Invoking it does pass: measured 2026-09-11, `claude -p 'run bash
agents/plugin/skills/memory-consolidate/consolidate.sh paths'` from `~/machines` returned the
output and exited 0. If that ever changes, the nightly run fails as a **silent
skip**, so re-measure it rather than assuming.

## Run from the MAIN `~/machines` checkout, never an Orca workspace

Every path here is absolute, so cwd changes nothing about what is read or
written — which is exactly why a worktree is the wrong place to run it. An Orca
workspace is a git worktree on its own branch, and it carries its **own**
`.claude/memory/project.md`: a second copy of the largest store in the corpus
(277 KB, 48% of it). The session's own memory hook would load the worktree's
copy while the run analyses the live one, and the queue's line numbers would
point at neither. Two versions of one store in one session is the confusion
this skill exists to remove.

## Step 0 — Preflight

```bash
D=~/machines/agents/plugin/skills/memory-consolidate/consolidate.sh

# Pull FIRST. The queue is shared across every box that runs /memory-consolidate, and
# suppression is the only thing standing between a second box and a duplicate
# of every item the first one filed tonight. A stale checkout silently defeats
# it: `status` reports `new` for an item that is already open on origin.
git -C ~/machines pull --ff-only || echo 'PULL FAILED — say so in the report and do not push at Step 8'

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

The 10-minute `dotfiles-sync` timer can merge `origin/main` into a store while
this run is reading it. That is harmless to the Step 8 check — a merge commits,
so the work-tree is clean on both sides of it — but a section read early in the
run may be one tick stale. Quote line numbers as a starting point, never as an
address; `/memory-consolidate-apply` re-verifies before it writes.

## Step 1 — Scan and measure

```bash
bash "$D" scan                                  # path, bytes, scope, ## count
bash "$D" index <store>                         # line, section bytes, heading
```

```bash
bash "$D" instructions                          # auto-loaded CLAUDE.md/AGENTS.md
```

Both discover by **glob**, so a store or a repo added later shows up on its own.
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

### Two populations, different rules

`instructions` is a **separate** subcommand, not a column on `scan`, so the two
can never be treated as one pile. Instruction files are auto-loaded into every
session that opens under their path — `~/.claude/CLAUDE.md` and `~/CLAUDE.md`
in *every* session, a repo's `CLAUDE.md`/`AGENTS.md` in that repo's — so their
size is a standing context tax, and that is what puts them in scope here. As of
2026-09-11: ~116 KB over 9 files, `machines/AGENTS.md` alone 46 KB.

They hold **rules, not facts**, and a rule is deleted on different evidence:

- A fact is deleted when something supersedes it. A rule is deleted only when
  it is **verifiably no longer true of the system it describes**, or when it
  never was — the repo has burned itself on both (`machines/AGENTS.md` records
  a bash claim that measurement disproved, and a suite count repeated for weeks
  that reached 30 of 40 suites).
- `contradiction` is the highest-value action here. `machines/AGENTS.md` says
  it out loud: *if you catch this file asserting two incompatible things, the
  contradiction is the bug — do not pick the half that suits the task.* File
  the pair; a human picks.
- **Do not propose compressing a rule into a shorter rule.** The length is
  usually the incident that produced it, and that incident is the reason anyone
  obeys it. `compress` applies to narrative *around* a rule, never to the rule.
- Doc-vs-code drift is **not** this skill's job — that is repo-harvest Track B.
  Here the axis is redundancy, contradiction and bloat *within and between* the
  loaded texts.

## Step 2 — Load the suppression baseline FIRST

```bash
cat ~/machines/docs/memory-consolidate/queue.md      2>/dev/null   # still-open items
cat ~/machines/docs/memory-consolidate/ledger.tsv    2>/dev/null   # applied + rejected
```

Every candidate is checked with `consolidate.sh status <id>` before it is filed.
Also read the ledger for **categories**, not just ids: an action rejected three
or more times with no acceptance is one this queue should stop proposing —
deprioritise it and say so in the report rather than filing a fourth. An
item already open, applied **or rejected** is dropped silently. Without the
rejected state a declined proposal returns every night, which is exactly how a
queue stops being read.

**The discriminating check for this whole design:** run `/memory-consolidate` twice in a row.
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

## Step 3b — Pass 1b: across the FLEET (read-only, from this box)

```bash
bash "$D" branches      # branch, tip date, path, bytes — every other box
```

The dotfiles bare repo holds every machine's branch, so **every box's memory is
readable from right here** — no network, no ssh, nothing touched on those boxes.
Consolidation is fleet-wide by reading, and it costs one command.

What only this pass can see:

- **A fact repeated in three boxes' `host-memory.md` is a `global.md` fact.**
  This is the generalisation nobody else is positioned to make: each box only
  ever sees its own host memory, so a truth about the fleet gets written five
  times and read as five local quirks. Action `promote`.
- **Unpromoted drift on a shared file.** `core.md`, `global.md`, `personality/*`
  are supposed to be byte-identical everywhere. A branch whose copy is *larger*
  than `main`'s holds memory written there that has reached **no other box** —
  measured 2026-09-11, `origin/g15` carried a `global.md` 1183 B bigger than
  main's. A branch *smaller* than main's is just lagging its next sync tick;
  that is not a finding. Compare against `origin/main`, not against each other.
- **A retired box's branch can be the last copy of a fact — so run the check,
  never trust a name.** This is `values.md`'s *a file can be the last copy of a
  FACT* at fleet scale: extract and carry, never archive wholesale and never
  delete blind. The check is blob hashes against `main`, per path:

  ```bash
  dotfiles ls-tree -r origin/<branch>          # run from $HOME — a relative
  dotfiles ls-tree -r origin/main              # pathspec matches nothing here
  dotfiles rev-list --left-right --count origin/main...origin/<branch>
  ```

  A branch whose blobs all match `main`'s and which is 0 ahead carries nothing;
  a branch with commits `main` lacks may carry a last copy. **State the check,
  not the expected result** — this paragraph used to name `origin/server` and
  `origin/g15-wsl` as its two examples, and by 2026-09-11 `origin/server` had
  been deleted and `g15-wsl` was an ancestor of `main` holding zero unique
  content, so a run that trusted the text would have skipped the hashing on a
  false premise. The live example is **`origin/desktop-wsl`**: 135 commits ahead
  of `main`, holding `pure/backend-api/.claude/memory/project.md` at 58333 B,
  tracked on no other branch and not on `main`. A **per-project store is the
  thing a dotfiles branch can hold that `main` does not** — that is the class to
  look for, not any particular branch.
- **Two branches for one physical machine.** `desktop` (Windows-native) and
  `desktop-wsl` are the same box; so were `g15` and `g15-wsl`. Their
  `host-memory.md` files overlap by construction.

### The write boundary — this is where fleet-wide stops

Reading another branch is free. **Writing one is forbidden here**, and not for
neatness: that box's 10-minute sync timer is committing to the same branch, and
the file is loaded live in its sessions. A push from here strands its next push
as a conflict.

So an item about another box is **filed with the box named** and applied there:

```markdown
- **apply on:** g15   ← not this box; /memory-consolidate-apply here must refuse it
```

The two things `/memory-consolidate-apply` on *this* box may touch are unchanged: paths on
this box, and shared files via `/dotfiles-promote`. Fixing unpromoted drift on
`g15` means running the promote **on g15**.

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

- **`core.md` budget — measure the INJECTED bytes, not the file bytes.** The
  loader strips HTML comments, so the two differ (measured 2026-09-11: 3330 B on
  disk, 2608 B injected — a 722 B gap that is pure header comment).

  ```bash
  wc -c ~/.claude/memory/core.md                                    # file bytes
  bash ~/machines/agents/plugin/hooks/global-memory-load.sh \
       ~/.claude core | wc -c                                       # injected
  ```

  **The two numbers answer different questions and must never be compared to
  each other's threshold:**
  - **~3.4 KB is the harness cap** on a hook's stdout — Claude Code persists
    past it and injects only a preview. It applies to the **injected** number.
    Over it, or within ~10% of it, the store is being truncated: urgent.
  - **~2 KB is this repo's style budget** on **file** bytes
    (`~/.claude/CLAUDE.md`, *Keep `core.md` under ~2 KB*). Over it is a
    consolidation item, not an emergency.

  Report both numbers in any item you file. **Never call a file-byte overage
  "urgent" without the injected number beside it** — the 2026-09-11 run read
  `wc -c` = 3004 against the stdout cap, filed it as near-truncation, and the
  hook was emitting 2442 B at the time. Same trap on another box: a branch whose
  `core.md` is 3385 B on disk may be well inside the cap or over it depending on
  how much of that is comments, and only the loader can say.
- **Unharvested transcripts.**
  ```bash
  jq '.sessions | length' ~/machines/.claude/kb-harvest-state.json
  ls ~/.claude/projects/*/*.jsonl | wc -l
  ```
  A gap means facts are ageing out of transcripts unrecorded. File **one**
  `harvest` item naming the gap and the last refresh commit — and **do not run
  repo-harvest from here.** `fleet-gather.sh` advances its watermark at *gather*
  time, before its own review gate, so a nightly gather whose candidates nobody
  applies marks those sessions harvested and strands them permanently. Harvest
  is an attended action.
- **Untracked store** — anything `scan` reports as `untracked` has no home and
  dies with the machine.
- **Did last week's decisions actually stay?**
  ```bash
  bash "$D" verify        # ok | drifted | missing | unverifiable, per applied id
  ```
  Borrowed from `/improve`'s prior-run cross-check, and it earns its place here:
  *accepted* is not *still there*. A `drifted` row means an approved
  consolidation was undone — by a later session, a sync merge, or a human — and
  it is a finding, not an error. File it and cite the original id. `missing`
  means the target file is gone entirely.
- **A rule that keeps getting restated is a rule nobody follows.** If the same
  instruction appears in three stores, or a `## ` section exists only to repeat
  a rule stated elsewhere, the restating is the symptom: prose instructions run
  at roughly 80% compliance, and the fix is **mechanical**, not another
  paragraph. File `action: hook` naming the rule and the event that could
  enforce it (`PreToolUse`, `PostToolUse`, `SessionStart`). Live example: the
  gortex `remember` instruction loads in every session and the store held zero
  entries — three restatements, no hook, no writes.
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
| `target` | `scan`/`instructions` column 1 — the **absolute** path, no `~`. For a `CLAUDE.md` that is a symlink this is the resolved real path (`machines/AGENTS.md`, not `machines/CLAUDE.md`) | `/home/me/.claude/memory/global.md` |
| `anchor` | `index` column 3 — the heading text, no `##`, no backticks. See the anchor table below for findings `index` cannot name | `Pure logging — Grafana/Loki vs Kibana (updated 2026-08-26)` |
| `action` | one word from the taxonomy below | `dedupe` |
| `discriminator` | the finding's **first evidence line range**, `<basename>:<start>-<end>` | `global.md:1283-1364` |

**The id is a four-tuple, and the discriminator is not optional.** Without it,
`(target, anchor, action)` can express only one finding per section per action —
and one section routinely holds several. The 2026-09-11 run hit this on its
largest section: `Fleet network` (39 KB) produced **three** distinct
`contradiction` findings and **three** distinct `delete` findings; `Repo tooling
& scripts` three `delete`s; `Backups` two `contradiction`s. Every one after the
first suppressed as `open` against its own sibling, and the run worked around it
by merging them into one item with numbered `### Part N` sub-decisions — which
breaks *one item, one decision* below and asks a human to accept half an item
the ledger cannot represent. The line range is already in every finding's
`evidence`, and it is stable for as long as the section is unedited, which is
exactly as long as the finding is open.

**Anchors for findings `index` cannot name.** `index` emits `##` rows only, so
these four cases have a fixed convention — use it verbatim, because an anchor
invented fresh each night is a new id each night:

| finding | anchor |
|---|---|
| under a `###` | the **enclosing `##`**, with the `###` quoted in the `why` |
| the whole file | `(whole file)` |
| one branch | `(branch: <name>)` |
| the shared set across the fleet | `(fleet: shared stores vs origin/main)` |

Actions: `dedupe` · `demote` · `promote` · `generalise` · `compress` ·
`delete` · `contradiction` · `harvest` · `untracked` · `skill` · `hook`. Do
not invent a twelfth —
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

## Step 6b — What was awkward tonight (the skill files against ITSELF)

A run ends by proposing changes to **these two skills**, as ordinary queue items
with `action: skill` and target `/home/me/machines/agents/plugin/skills/memory-consolidate/SKILL.md`
(or `memory-consolidate-apply/SKILL.md`).

**It does NOT edit them.** This is the one exception it would be most tempting
to make and the worst one available:

- It inverts the invariant at the worst possible target. A bad edit to
  `global.md` loses one fact. A bad edit to this file changes every future
  run's judgement — **including its judgement about further self-edits** — and
  each night's step looks reasonable while the trajectory nobody reviewed does
  not.
- There is no gate that could catch it. The queue works because a human reads
  the proposal; a self-edit is applied by the same session that wrote it, so it
  has no reader by construction.
- Prose has no failing signal. `consolidate.sh` is tested and a bad change goes red;
  nothing goes red when a paragraph quietly stops being true.

The evidence bar for a `skill` item is **higher** than for a memory item, not
lower: it must name the run that hit the problem (`runs/YYYY-MM-DD.md`) and what
that run did wrong or could not do. A proposal from a feeling rather than an
observed failure is not filed.

Good `skill` items look like: a store the scan missed · a heading format that
produced a duplicate id · a subagent batch that ran out of context · a step
whose output the next step could not use · a rule here that the run could not
follow and worked around.

## Step 7 — Run report

`docs/memory-consolidate/runs/YYYY-MM-DD.md`, and it is the answer to *"how compact will the
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
# the same repo as the queue — `add docs/memory-consolidate` is scoped, the CHECK is not)
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
git -C ~/machines add docs/memory-consolidate
git -C ~/machines commit -m "dream: <N> items, <date>"
```

The `machines` repo only, and only `docs/memory-consolidate`. Never `/dotfiles-promote`,
never a dotfiles commit — this skill has no business writing to `$HOME`.

Then push, but **only if this run's commits are the only thing unpushed**:

```bash
git -C ~/machines log --oneline origin/main..HEAD
```

Every line must start with `dream:`. If anything else is there, an unattended
push would carry someone's half-finished work to `origin` — skip the push, say
so in the report, and leave it for an attended session. Otherwise
`git -C ~/machines push origin HEAD:main`. Unpushed is not "safe": a queue that
only exists on one disk is the thing this repo exists to prevent.

## Never

- Edit any memory store, any `CLAUDE.md`, or `kb-harvest-state.json`.
- Run `repo-harvest`, `fleet-gather.sh` or `distill.py`.
- Run `/dotfiles-promote`, or any `git push`.
- Rewrite or reorder an existing queue item — a human may have annotated it.
- File an item without evidence a reader can check without re-running the pass.

## Where this ends and `/improve` begins

`/improve` (`~/.claude/commands/improve.md`) is a **retrospective on
conversations**: what happened in recent sessions, whether prior recommendations
landed, which config file should change as a result. `/memory-consolidate` is a pass over the
**corpus itself** — offline, fleet-wide, with no session in context.

They must not both propose the same edit, so the boundary is the input:

| | reads | sees |
|---|---|---|
| `/improve` | session transcripts + this conversation | friction, corrections, enforcement gaps |
| `/memory-consolidate` | the stores and instruction files as text, on every branch | redundancy, contradiction, bloat, misscoping |

Do **not** invoke `/improve` from a nightly run: it opens with an
`AskUserQuestion` for scope, so unattended it blocks or guesses; and a nightly
`/memory-consolidate` has no conversation to retrospect on, which is Phase 3 of it.

`/improve config audit` is the one mode that genuinely overlaps (CLAUDE.md bloat
and memory consolidation, project-scoped, no fleet view). Say so in the report
when a run files `CLAUDE.md` items, so the same file does not get two competing
proposals from two skills on the same day.

Three of its mechanisms are borrowed here rather than called: the prior-run
cross-check (`verify`, Step 5), the rule→hook escalation (`action: hook`), and
suppressing categories the ledger shows being rejected repeatedly.

## Running it nightly

```bash
cd ~/machines && claude -p '/memory-consolidate'
```

On `desktop`, via an Orca Automation, so the sessions can be watched. It is
read-only plus one commit to one repo, so a failed run costs nothing and the
next night starts from the same queue.

## Running it on more than one box

The queue is shared — one `docs/memory-consolidate/queue.md` in `machines`, on `main`. Item
ids are content-derived from an **absolute** path, so `/home/me/.claude/memory/
global.md` produces the same id on every box and a second run's duplicate is
suppressed as `open`. That only works if the box pulled first (Step 0).

What a second box adds is **the stores no other box can see**. The fleet-wide
branch pass (Step 3b) reads every machine's `~/.claude` memory out of the
dotfiles bare repo, so the shared and host-local stores need no second run. But
a **per-project** store lives inside its own checkout, not in dotfiles — so a
repo that exists on exactly one machine is invisible everywhere else, forever.
On `g15` that is `~/my/*/.claude/memory/project.md`: measured 2026-09-11, six
stores, ~138 KB, the largest 53 KB. `fleet.json` gives g15 `repo_groups: ["my"]`
and no other box checks those repos out.

So: **one run per box that holds a repo group nobody else does.** Not one per
box.

Stagger the schedules by at least half an hour and let the earlier run push
first — two runs pushing a queue in the same minute is a needless conflict, and
the loser's items are simply lost for the night rather than merged.
