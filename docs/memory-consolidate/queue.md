# memory-consolidate — open decisions

Written by `/memory-harvest`, applied by `/memory-review`. **Append-only from the run's
side**: a run never rewrites or reorders an existing item, so notes added by
hand survive. An item leaves this file only through `consolidate.sh decide`.

## 0c1fdb6a · harvest · /home/me/machines/.claude/memory/project.md

- **action:** harvest
- **scope:** repo:machines
- **apply on:** g15   (the box holding these transcripts)
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `(whole file)` — whole-store finding, no heading
- **why:** every transcript on this box is unharvested. `kb-harvest-state.json`
  lists 129 harvested sessions; `~/.claude/projects/*/*.jsonl` holds 30 session
  files on g15 and `comm -13` puts **30 of 30** outside the harvested set. Facts
  from those sessions are ageing out unrecorded.
- **evidence:** `jq '.sessions|length' .claude/kb-harvest-state.json` → 129 ·
  `ls ~/.claude/projects/*/*.jsonl | wc -l` → 30 · unharvested intersection → 30 ·
  last store-touching commit `644ddac` (2026-09-11)
- **bytes:** n/a (harvest adds, it does not remove)
- **replacement:** (none — the action is an **attended** `/memory-harvest` run on g15)
- **do NOT automate:** `fleet-gather.sh` advances its watermark at gather time,
  before its own review gate, so an unattended gather whose candidates nobody
  applies marks these 30 sessions harvested and strands them permanently.
- **first seen:** 2026-09-11

## 8e41cba2 · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** 6.7 KB of employer-repo operational detail (Loki ds uid, `service_name`
  taxonomy, MCP client ids, his Grafana Viewer role). The repo store has **only 3
  matching lines**, one of which is literally `see global.md, Pure logging` — so
  global is the ONLY copy and this is a demote, not a dedupe.
- **evidence:** global.md:1283-1364 · pure project.md:505-529 (`## Observability — Kibana / logs`) and :592-599 (dangling ref to global)
- **bytes:** 6760 → 0 in global
- **carry first:** verbatim `sed -n '1283,1364p' ~/.claude/memory/global.md` against the
  **unmodified** store, appended to `pure/backend-api/.claude/memory/project.md`, with
  two edits: re-head it `## Logging — Grafana/Loki vs Kibana (updated 2026-08-26)` (the
  `Pure` qualifier is redundant inside the repo's own store), and **delete the clause**
  `Kibana (\`logs.thepure.team\`, ES) is VPN-only and short-retention.` — project.md:505-529
  already documents that in more depth (6-day fuse, basic auth, viewer role,
  `10.99.183.43`) — keeping the `**Grafana is public (no VPN)**…` remainder. Then fix
  project.md:599's `see global.md, Pure logging` to point at the new in-repo heading.
- **replacement:** (none — deletion after the carry)
- **first seen:** 2026-09-11

## 6846453c · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** platform-level facts about the employer's Sentry instance — MCP endpoint +
  Keycloak client, the `execute_sentry_tool` whitelist trap, the 2026-08-11 payload
  floor vs surviving tsdb counts, token scopes that block a Jira link. The repo store
  has only incident triage and at :592 *leans on global* for the phrase "Sentry's
  payload floor", so global is the only copy.
- **evidence:** global.md:1365-1411 · pure project.md:601-639 (incident-only), :515-518, :592
- **bytes:** 3922 → 0 in global
- **carry first:** verbatim `sed -n '1365,1411p'` (unmodified store) appended to project.md
  re-headed `## Sentry — reactive, not monitored (2026-08-24)`, **minus** the final
  sentence of the `One log template = one fingerprint` bullet (`Always run a positive
  control … before believing a zero.`) — project.md:515-518 already has that rule with a
  better control (`"[MOBI]"` → 610k). Re-point project.md:592 at the newly local bullet.
- **replacement:** (none — deletion after the carry)
- **first seen:** 2026-09-11

## 9e243a8c · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** the load-bearing measurement — a configured Apple default per
  (productId, locale) gates the realtime **call**, not just the display, proven on
  cft-2670 by deleting one locale's default — exists **nowhere else** (grep for
  `5886|Configure Default Message|Initiate Performance Test|4000164` on the repo store
  returns 0). project.md:381-427 covers only the code-side locks and the 2026-08-19 probes.
- **evidence:** global.md:1496-1552 · pure project.md:381-427
- **bytes:** 3977 → 0 in global
- **carry first:** verbatim `sed -n '1496,1552p'` (unmodified store), merged **INTO** the
  existing `## Apple retention messages` section of project.md rather than appended as a
  second heading, minus the trailing clause `\`get_realtime_url\` returns \`404 4040021 …\``
  which project.md:418-420 already states.
- **ALSO — a misfiling this exposes:** `### GitHub \`Closes\` needs the keyword per issue
  (2026-08-28)` and `### GitHub review bodies…` at global.md:1531-1552 are **not Apple
  content** — they are generic GitHub facts wrongly nested under this heading. **Promote
  them to their own `##` heading in global.md; do not carry them to the repo.**
- **replacement:** (none — deletion after the carry)
- **first seen:** 2026-09-11

## c18ef4d8 · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** personal facts about named third parties — emails, Slack UIDs, pronouns, and
  one recorded mistake of inventing a surname — sitting in a store that is byte-identical
  on every fleet box **including the VPS**. The tightest-scoped content in the file and
  the row most likely to be handled differently from the rest. Nothing records it
  elsewhere (`grep -ni 'Jam Padilla|Tikhonenko|Katerina|she/her'` on the repo store → 0).
- **evidence:** global.md:1437-1467
- **bytes:** 2544 → 0 in global
- **carry first:** **two writes, and the item is not done until both land.**
  (1) To pure project.md as `## Colleagues (2026-08-18)`: verbatim `sed -n '1437,1460p'` —
  the three roster bullets plus the fourth bullet's first sentence through
  `**author of the Mobi / our_billing code**; reviews his billing PRs.`
  (2) To `~/.claude/memory/personality/tone.md` under a `## Addressing the author of the
  code` heading: verbatim `sed -n '1461,1467p'` — the register lesson, which the section
  itself already marks `Generalize past her` / `Related: [[practices]]` — with `her`/`she`
  generalised to "the colleague who wrote the code".
- **replacement:** (none — deletion after both carries)
- **first seen:** 2026-09-11

## 6c384b09 · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** employer Teleport/kube access facts — his Teleport login `m.romanyuk`,
  `--mfa-mode=otp` because WSL cannot reach WebAuthn, the prod namespaces behind
  `eks-testing`, and the `kubectl auth can-i` lies-through-Teleport trap. The repo store
  has **zero** coverage (`grep -ni 'teleport|tsh |eks-testing|soul-production'` → nothing),
  so global is the sole copy.
- **evidence:** global.md:1252-1282
- **bytes:** 2025 → 0 in global
- **carry first:** verbatim `sed -n '1252,1282p'` (unmodified store), appended to pure
  project.md as `## Infra access — what actually needs the VPN (2026-07-31)`. **Keep the
  first bullet** (`sentry.thepure.team` is public) even though it names Sentry — it is the
  one that stops a future session mis-diagnosing an expired token as "VPN off".
- **replacement:** (none — deletion after the carry)
- **first seen:** 2026-09-11

## d0474135 · demote · /home/me/.claude/memory/global.md

- **action:** demote
- **scope:** shared → repo (employer). **THE WHOLE `Pure …` CLUSTER IS 22.9 KB = 18% of a
  store loaded in EVERY session on EVERY box, including the VPS.**
- **apply on:** **air** or **desktop-wsl** — `~/pure/backend-api` is ABSENT on g15
  (`repo_groups: ["my"]`), so no Pure demote is applicable here.
- **BLOCKER, read before applying any of these:** `pure/backend-api/.claude/memory/project.md`
  is tracked on **`origin/desktop-wsl` only, not on `main`**
  (`cat-file -e main:…` → does not exist). Demoting a fleet-visible fact into it today
  *reduces* availability from every box to one branch. Promote that store to `main`
  first (`/dotfiles-promote`), then apply. This binds hardest on the colleagues roster
  and the prose register.
- **why:** **behavioral, not factual** — it records how he wants prose written (length
  targets, no hard wraps, the 15→4-line Slack digest). His own scoping rule routes that to
  `~/.claude/memory/personality/` ("not a fact but a behavioral trait… outward voice →
  tone.md"), not to a shared knowledge store. One clause is a genuine Pure convention and
  splits off to the repo.
- **evidence:** global.md:1412-1436 · pure project.md has neither half (`grep -ni 'in English|hard line break|bare digest'` → 0)
- **bytes:** 1944 → 0 in global
- **carry first:** **two writes.**
  (1) To `~/.claude/memory/personality/tone.md` under `## Drafting length — PR bodies,
  Jira, Slack`: verbatim `sed -n '1417,1436p'` (the "Short and to the point" bullet through
  the CS-668 digest example ending `Draft at this length first rather than writing long and
  trimming.`). Leave "Maxim"/"he" as-is — tone.md is his own store.
  (2) To pure project.md, one line under its `## Branches & PRs`: verbatim
  `sed -n '1414,1416p'` — `**Everything written into Jira is in English** … Slack stays in
  the language of the thread; Jira does not follow it.`
- **replacement:** (none — deletion after both carries)
- **first seen:** 2026-09-11

## 61aee193 · demote · /home/me/.claude/CLAUDE.md

- **action:** demote · **scope:** shared → repo (employer) + global.md
- **apply on:** **air** or **desktop-wsl** (the boxes with the work checkout) — not g15
- **why:** work-repo Sentry / `pure-connectors` token placement sits in the file loaded in
  EVERY session on EVERY box — **including `hub` and `latitude`, which have no work repos
  at all**. The general mechanism it rests on is already in `global.md` in more detail
  (only `settings.json` is read at the config-dir root; a PROJECT-scope
  `.claude/settings.local.json` is the one place `settings.local.json` is honored), and
  the Pure-specific half belongs beside `## Sentry at Pure`.
- **evidence:** `~/.claude/CLAUDE.md`:73-78 · `global.md`:731-738 (the fuller mechanism) · `global.md`:1365, :1299
- **keeps:** the load-bearing `gortex_merge_hooks` rule at :66-70 and the deny-posture sentence, verbatim
- **bytes:** 585 → 180
- **replacement:**
Consequence now live: the default `--hook-mode deny` posture means `PreToolUse`
blocks `Read`/`Grep`/`Glob` on *indexed* source and redirects to the graph
tools. Anything recorded
- **first seen:** 2026-09-11

## 6c10ae40 · untracked · /home/me/.claude/memory/personality/values.md

- **action:** untracked · **scope:** host (desktop) · **apply on:** **desktop** — not this box
- **why:** **`desktop` is the only fleet box with NO personality facets tracked at all.**
  Its dotfiles branch carries `.claude/CLAUDE.md`, `CLAUDE.md`, `host-memory.md` and — as
  **mode-120000 symlinks into the WSL distro** — `core.md` and `global.md`. There are no
  `personality/*.md` entries of any kind. So a Windows-native session on desktop loads
  neither `tone.md`, `habits.md`, `practices.md` nor `values.md`, and its `core.md` /
  `global.md` resolve only while `desktop-wsl` is running.
- **evidence:** `git --git-dir=$HOME/.dotfiles ls-tree -r --full-tree origin/desktop -- .claude/memory`
  → exactly two entries, both `120000`, blobs `7a04bb57` / `a51b9a9f`, contents
  `//wsl.localhost/desktop-wsl/home/me/.claude/memory/core.md` and `…/global.md`. No
  `personality/` path on that branch. Branch tip **2026-08-29** — 13 days stale.
- **two separate questions for a human:**
  1. Is the UNC-symlink arrangement deliberate (desktop reads the distro's memory) or an
     accident of `core.symlinks`? `machines/AGENTS.md` documents that exact rendering trap
     for `CLAUDE.md`. Here the mode is `120000`, so git stored a real symlink — which
     argues deliberate. But a UNC path resolves only while the distro is up.
  2. Should the four personality facets be tracked on `desktop` at all, or does that box
     deliberately run without them?
- **bytes:** n/a
- **replacement:** (none — this is a question, not an edit)
- **first seen:** 2026-09-11


## 5d2bfaaa · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **action:** skill
- **scope:** repo:machines — the run's own brief + `consolidate.sh`
- **apply on:** g15 (or any box)
- **target:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md`
- **anchor:** `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` (L274; the `verify` bullet is L314-322)
- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` # `skill` # `consolidate-phase.md:314-322`
- **why:** `verify` cannot follow a **rename**, and it reports the failure as
  `drifted` — the same word it uses for "an approved consolidation was undone",
  which the brief calls *a finding, not an error*. Tonight all four non-`ok`
  rows were renames, not drift: the content is intact at the new path. A run
  that trusted the word would have filed four false items against decisions that
  held perfectly.
- **evidence:** `bash consolidate.sh verify` on 2026-09-12 → 87 `ok`, 4
  `drifted`, 0 `missing`, 0 `unverifiable`. The four:
  ```
  drifted  f7082e6e  …/skills/dream/SKILL.md
  drifted  35ce7179  …/skills/dream/SKILL.md
  drifted  e9310fe2  …/skills/dream/SKILL.md
  drifted  06ccc498  …/skills/dream-apply/SKILL.md
  ```
  `dream` was renamed to `memory-harvest` and `dream-apply` to `memory-review`
  on 2026-09-11 (commits `1b38ff8`, `d0bcdda`). Both old paths still exist as
  **660 B / 661 B redirect stubs**, which is why the rows read `drifted` and not
  `missing`. Each phrase was re-checked at the new path with the same test
  `verify` uses (`grep -qF`) and all four were found:
  ```
  f7082e6e  "The id is a four-tuple, and the discriminator is not optional"  -> memory-harvest/consolidate-phase.md
  35ce7179  "State the check,"                                              -> memory-harvest/consolidate-phase.md
  e9310fe2  "measure the INJECTED bytes, not the file bytes"                -> memory-harvest/consolidate-phase.md
  06ccc498  "An item names one site; the error may live at several"         -> memory-review/SKILL.md
  ```
  Cause: `cmd_decide` writes the target path into ledger column 5 at decide
  time (`consolidate.sh:206-216`) and `cmd_verify` greps that frozen path
  (`:153-170`). Nothing re-resolves it.
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md`.
- **bytes:** n/a
- **replacement — add to the `verify` bullet at L322, after "`missing` means the target file is gone entirely.":**
```
  **`drifted` has a false-positive class: a renamed file.** The ledger freezes
  the target path at decide time and `verify` greps that path, so a skill or
  store that moved reports `drifted` (or `missing`) with its content perfectly
  intact — measured 2026-09-12, all four non-`ok` rows were the 2026-09-11
  `dream`→`memory-harvest` / `dream-apply`→`memory-review` rename, and every
  phrase was present at the new path. Before filing a `drifted` row as a
  finding, re-run its own test at the plausible new path:
  `grep -cF -- "<phrase>" <new path>`. If it is found, the row is a rename:
  say so in the report and file nothing.
```
- **also worth doing, same decision:** `consolidate.sh decide` could store the
  path **relative to `$HOME`** instead of absolute, which would not have helped
  here (the rename was below `$HOME`), so the durable fix is the reader's, not
  the writer's — hence a brief change rather than a tool change.
- **first seen:** 2026-09-12

## 2249f890 · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **action:** skill
- **scope:** repo:machines — the run's own brief
- **apply on:** g15 (or any box)
- **target:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md`
- **anchor:** `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` (L274; the transcript-gap bullet is L301-311)
- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` # `skill` # `consolidate-phase.md:301-311`
- **why:** the two-command recipe compares **every project slug on the box**
  against **one repo's** watermark file, so it reports as "unharvested" every
  session that belongs to a *different* repo. It cannot return a small number
  even when every repo on the box is fully harvested, and it overstated the gap
  by 29× tonight. A standing check that cannot return "fine" trains its reader
  to skip it.
- **evidence:** measured 2026-09-12 on g15.
  - The recipe as written: `jq '.sessions|length' machines/.claude/kb-harvest-state.json`
    → **191**; `ls ~/.claude/projects/*/*.jsonl | wc -l` → **44**; the
    `comm -13` the recipe implies → **29 of 44 unharvested**.
  - Per repo, each slug dir against **its own** state file:
    ```
    machines   local=16  gap=1    (1abc7229…, this very session, still open)
    airdrome   local=5   gap=0
    embedthat  local=4   gap=0
    qaz-code   local=5   gap=0
    telegrind  local=5   gap=0
    vps        local=2   gap=0
    ```
    The true local gap is **1 of 44**, and that one is the session doing the
    measuring. The other 28 "unharvested" sessions are other repos' transcripts,
    each already harvested by its own repo's Phase A pass tonight.
  - `.sessions|length` = 191 > 44 because `fleet-gather.sh` merges **other
    boxes'** sessions into the same map. So the two numbers are not even drawn
    from the same population, in either direction.
- **consequence for the open queue:** item **`0c1fdb6a`** (filed 2026-09-11,
  still open) rests entirely on this miscount — it reads "30 of 30 outside the
  harvested set". Its premise is false. **/memory-review: re-measure per repo
  before applying it**; this run may not rewrite an existing item, so it is
  flagged here instead.
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md`.
- **bytes:** n/a
- **replacement — replace L301-311 with:**
```
- **Unharvested transcripts.** Compare **per repo**: a repo's watermark only
  ever covers its own slug dirs, and `.sessions` also carries other boxes'
  sessions merged in by `fleet-gather.sh`, so a box-wide count against one
  state file is meaningless in both directions (measured 2026-09-12: the
  box-wide form said 29 of 44 unharvested; the per-repo form said 1, and that
  one was the running session).
  ```bash
  for r in ~/machines ~/*/ ~/*/*/; do
    [ -d "$r/.git" ] && [ -f "$r/.claude/kb-harvest-state.json" ] || continue
    slug="$(printf '%s' "${r%/}" | tr / -)"
    ls ~/.claude/projects/$slug/*.jsonl 2>/dev/null | xargs -rn1 basename \
      | sed 's/\.jsonl$//' | LC_ALL=C sort > /tmp/l.$$
    jq -r '.sessions|keys[]' "$r/.claude/kb-harvest-state.json" | LC_ALL=C sort > /tmp/h.$$
    printf '%s gap=%s\n' "${r%/}" "$(comm -13 /tmp/h.$$ /tmp/l.$$ | wc -l)"
  done
  ```
  Discount the session that is running the check — its transcript is open and
  cannot be harvested yet, so a gap of 1 on this box's own repo is the floor,
  not a finding. A real gap means facts are ageing out of transcripts
  unrecorded. File **one** `harvest` item naming the repo, the gap and the last
  refresh commit — and **do not run repo-harvest from here.**
  `fleet-gather.sh` advances its watermark at *gather* time, before its own
  review gate, so a nightly gather whose candidates nobody applies marks those
  sessions harvested and strands them permanently. Harvest is an attended
  action.
```
  `LC_ALL=C` is not decoration: this box has a Russian locale and `comm`
  emits "input is not in sorted order" and returns wrong counts without it
  (hit twice in this run).
- **first seen:** 2026-09-12

## a216a4c2 · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 3b — Pass 1b: across the FLEET (read-only, from this box)` # `skill` # `consolidate-phase.md:205-210`
- **action:** skill
- **scope:** repo:machines — the run's own brief
- **apply on:** g15 (or any box)
- **anchor:** `Step 3b — Pass 1b: across the FLEET (read-only, from this box)` (L189; the drift bullet is L205-210)
- **why:** the bullet makes byte size the test — *larger than main* is a
  finding, *smaller than main* "is just lagging its next sync tick; that is not
  a finding." Both halves are measurably wrong, and the false-negative half is
  the dangerous one: a branch can be **smaller** than `main` and still hold
  memory `main` has never seen, because the 2026-09-11 consolidation DELETED
  several hundred lines from the shared stores. Size compares two numbers that
  moved for unrelated reasons.
- **evidence:** measured on this box 2026-09-12 against freshly fetched refs.
  Naive size test vs `origin/main`:
  ```
  origin/desktop-wsl  practices.md  31990 B  vs main 32725 B  -> "smaller, not a finding"
  ```
  Merge-base test on the same file — lines present on the branch and absent from
  the version both sides diverged from:
  ```
  desktop-wsl  merge-base ae03a7d (2026-09-11)
     practices.md  126 NEW lines
     tone.md        21 NEW lines
     values.md      13 NEW lines
     core.md         5 NEW lines
     .claude/CLAUDE.md 5 NEW lines
  air          merge-base 57551c6 (2026-08-24)
     global.md      17 NEW lines
     practices.md   11 NEW lines
     tone.md         7 NEW lines
  g15          merge-base 21abe71 (2026-09-11)
     global.md     166 NEW lines
  ```
  126 lines of unpromoted personality memory sat inside a file the rule tells
  the run to skip. Conversely a naive whole-file `comm` against `main` reports
  332 desktop-wsl lines "main lacks" — mostly text `main` deliberately deleted
  on 2026-09-11, which is how three items were rejected as *already done* last
  run (`6d32518b`, `08ade540`, `6b30ae15`). Only the merge-base form separates
  the two populations.
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md`.
- **bytes:** n/a
- **replacement — replace L205-210 with:**
```
- **Unpromoted drift on a shared file — test by merge-base, never by size.**
  `core.md`, `global.md`, `personality/*` are supposed to be byte-identical
  everywhere. **Do not compare byte counts**: a branch can be SMALLER than
  `main` and still hold memory `main` has never seen, because a consolidation
  pass deletes lines from `main` (measured 2026-09-12: `origin/desktop-wsl`'s
  `practices.md` is 735 B smaller than main's and holds **126** lines written on
  that branch since divergence). And a whole-file `comm` against `main` is just
  as wrong in the other direction — it counts every line `main` deliberately
  deleted, which is how three items were rejected as *already done* in the
  2026-09-11 run. The check that answers the actual question:
  ```bash
  export LC_ALL=C                 # a non-C locale silently breaks comm here
  mb=$(dotfiles merge-base origin/main origin/<branch>)
  for p in .claude/memory/global.md .claude/memory/core.md \
           .claude/memory/personality/*.md .claude/CLAUDE.md CLAUDE.md; do
    dotfiles show "$mb:$p"            2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u > /tmp/mb
    dotfiles show "origin/<branch>:$p" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u > /tmp/br
    printf '%s %s\n' "$p" "$(comm -13 /tmp/mb /tmp/br | wc -l)"
  done
  ```
  A non-zero count is memory written on that branch and reaching no other box.
  File it as `promote`, `apply on:` that branch's box — the write boundary
  below still holds, so it is fixed there, never from here.
```
- **first seen:** 2026-09-12

## b2db3785 · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 1 — Scan and measure` # `skill` # `consolidate-phase.md:96-120`
- **action:** skill
- **scope:** repo:machines — the run's own brief + `consolidate.sh`
- **apply on:** g15 (or any box)
- **anchor:** `Step 1 — Scan and measure` (L96)
- **why:** `scan` and `instructions` count a **git worktree's** checkout of a
  tracked file as a separate store, under a separate `repo:<name>` scope. So one
  file appears three times, at three different sizes, and the run is invited to
  file items against paths whose edits are lost on the next checkout. This is
  the exact hazard the brief already names for Orca workspaces at L47-56 — *"a
  second copy of the largest store in the corpus… Two versions of one store in
  one session is the confusion this skill exists to remove"* — but it is
  enforced only on the run's **cwd**, never on what `scan` reports.
- **evidence:** measured 2026-09-12 on g15.
  ```console
  $ cat /home/me/qaz-baseline/.git
  gitdir: /home/me/my/qaz-code/.git/worktrees/qaz-baseline
  $ cat /home/me/my/qaz-pool/.git
  gitdir: /home/me/my/qaz-code/.git/worktrees/qaz-pool
  $ git -C /home/me/my/qaz-code worktree list
  /home/me/my/qaz-code   a9a1d5a [main]
  /home/me/my/qaz-pool   47933ca [perf/parallel-render]
  /home/me/qaz-baseline  849407c (detached HEAD)
  ```
  `git ls-files --error-unmatch .claude/memory/project.md` succeeds from all
  three, against the one `qaz-code` repo. Yet tonight's `scan` reported:
  ```
  /home/me/my/qaz-code/.claude/memory/project.md      41639  repo:qaz-code
  /home/me/qaz-baseline/.claude/memory/project.md     22383  repo:qaz-baseline
  /home/me/my/qaz-pool/.claude/memory/project.md      23571  repo:qaz-pool
  ```
  and `instructions` the same for the three `CLAUDE.md` (64852 / 59558 / 60019).
  That is **~184 KB of the reported corpus that is two stale checkouts of one
  store family** — about a quarter of tonight's total. Cause: `_scope()` at
  `consolidate.sh:69-75` derives the label from
  `basename $(git rev-parse --show-toplevel)`, and a worktree's toplevel is the
  worktree directory.
  Line-level, the worktree copies hold nothing new — qaz-pool 1 line and
  qaz-baseline 87 lines that the main checkout lacks, all of it older text the
  `main` branch has since edited — so nothing is *lost* tonight. The cost is
  inflated totals and a live invitation to file against the wrong path.
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md` — the qaz
  pass-1 agent was launched against all three files and had to be corrected
  mid-flight once the worktree relationship was measured.
- **bytes:** n/a
- **replacement — two edits, one decision.**
  (1) `consolidate.sh`, in `_scope()`, after the `rev-parse --show-toplevel`
  block, resolve a worktree to its main checkout so one tracked file gets one
  identity:
```bash
  local top
  if top="$(git -C "$(dirname "$p")" rev-parse --show-toplevel 2>/dev/null)"; then
    # A worktree's toplevel is the worktree dir, so the SAME tracked file is
    # reported once per worktree under a different repo name (measured
    # 2026-09-12: qaz-code/project.md counted three times, 87 KB of phantom
    # corpus). Resolve to the main checkout instead.
    local common main
    if common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)"; then
      case "$common" in /*) ;; *) common="$top/$common" ;; esac
      main="$(cd "$common/.." 2>/dev/null && pwd)" || main="$top"
    else main="$top"; fi
    if git -C "$top" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
      if [ "$main" != "$top" ]; then
        echo "worktree:$(basename "$main")"; return
      fi
      echo "repo:$(basename "$main")"; return
    fi
  fi
```
  (2) In this brief's `scope` table at L104-112, add the row:
```
| `worktree:<name>` | a git worktree's checkout of a file tracked by `<name>` | **not a store** — the same file is already counted under `repo:<name>`. Never file an item against this path: an edit here is lost on the next checkout or lands on the worktree's branch. Fold it into the `repo:<name>` item instead, and exclude these bytes from the corpus total. |
```
- **first seen:** 2026-09-12

## 60604a4f · skill · /home/me/machines/agents/plugin/skills/memory-harvest/SKILL.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/SKILL.md` # `Step 0 — Pick the repos` # `skill` # `SKILL.md:108-116`
- **action:** skill
- **scope:** repo:machines — Phase A's brief (the per-repo harvest)
- **apply on:** g15 (or any box)
- **anchor:** `Step 0 — Pick the repos` (L68; the slug-match bullet is L108-116)
- **why:** *"the repo's basename is enough"* is stated as settled and was
  measured false on this box tonight. A basename is a substring match against
  the transcript slug, so a basename that repeats under two parents matches both
  repos' transcripts, and a basename that is a **prefix of its own children's
  paths** matches every child. Phase A had to qualify both by parent directory
  to get a correct gather; the skill gave it no rule for doing so.
- **evidence:** observed in tonight's Phase A run on g15 (11 repos harvested).
  - `~/kazakhstan-law/codes` and `~/split-test/codes` are both basename
    `codes`, so `--match codes` matches the slugs of both:
    ```console
    $ ls -d /home/me/kazakhstan-law/codes /home/me/split-test/codes
    /home/me/kazakhstan-law/codes  /home/me/split-test/codes
    ```
  - `~/kazakhstan-law` is itself a repo (`.git` directory present) whose name is
    a substring of every one of its nested children's slugs, so `--match
    kazakhstan-law` sweeps in every child repo's transcripts.
  The skill already half-knows this — L114-116 say *"A basename is a substring
  match, so name the slug directories that matched in the report — that is how a
  cross-match with an unrelated repo becomes visible instead of silent."* That
  makes the collision **visible after the fact**; it does not stop the gather
  from advancing a watermark over another repo's sessions, which is the
  irreversible half (`### Recovery / aborted runs`, L176-189).
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md` (Phase A, same box, same night).
- **bytes:** n/a
- **replacement — replace the first sentence of L108 and add the qualification rule:**
```
- Slug matches: **start from the repo's basename, then check it is unambiguous.**
  Transcript directories are the cwd path with `/` replaced by `-`, and an Orca
  workspace lives at `~/orca/workspaces/<repo-basename>/<workspace-name>/`, so
  one `--match <basename>` covers the main checkout AND every workspace —
  including workspaces already deleted, whose transcripts outlive them (measured
  2026-09-11: `-home-me-orca-workspaces-qaz-code-kazhackstan-2026` was still
  present with no workspace directory left).
  **But a basename is a substring match and it is not always unique.** Measured
  2026-09-12 on g15: `~/kazakhstan-law/codes` and `~/split-test/codes` share the
  basename `codes`, and `~/kazakhstan-law` is itself a repo whose name is a
  substring of every nested child's slug. Before gathering, test it:
  ```bash
  ls -d ~/.claude/projects/*"$(basename "$repo")"* 2>/dev/null
  ```
  If that lists a slug belonging to a different repo, **do not use the
  basename** — match on the `$HOME`-relative path with `/` replaced by `-`
  instead (`--match my-qaz-code`, `--match kazakhstan-law-codes`), which is
  unique by construction, and add a second `--match` for the workspace form
  (`--match orca-workspaces-<basename>`) so workspaces are still covered.
  Either way, **name the slug directories that matched in the report** — a
  cross-match must be visible, not silent, and an unnoticed one advances a
  watermark over another repo's sessions, which `### Recovery` cannot undo.
```
- **first seen:** 2026-09-12

## ae9ea0da · skill · /home/me/machines/agents/plugin/skills/memory-harvest/SKILL.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/SKILL.md` # `Step 0 — Pick the repos` # `skill` # `SKILL.md:117-125`
- **action:** skill
- **scope:** repo:machines — Phase A's brief (the per-repo harvest)
- **apply on:** g15 (or any box)
- **anchor:** `Step 0 — Pick the repos` (L68; the watermark backup is L120-125, the create-empty is L117-118)
- **why:** the recovery backup is taken **after** the "create with an empty `{}`
  on first run" instruction, so in a repo with no prior state the file copied to
  `.claude/harvest/state-before.json` is the literal string `{}`. Restoring from
  it would set the watermark to empty — which, for a repo that *does* have a
  state file by the time recovery is needed, **wipes the watermark instead of
  restoring it**: the exact opposite of what `### Recovery / aborted runs` (L176-189)
  promises. Two Phase A subagents hit this independently tonight.
- **evidence:** the ordering is plain in the file — `sed -n '117,125p' SKILL.md`:
  ```
  - State file: `"$repo/.claude/kb-harvest-state.json"` (create with an empty
    `{}` on first run — `distill.py` initializes its own `sessions` key).
    Digests out dir: a scratchpad path, never inside the repo.
  - **Before the gather, back up the watermark** — see *Recovery* below:
    ```bash
    mkdir -p "$repo/.claude/harvest"
    cp "$repo/.claude/kb-harvest-state.json" \
       "$repo/.claude/harvest/state-before.json" 2>/dev/null || true
    ```
  ```
  The create step precedes the `cp`, and the `cp` has no guard distinguishing
  "no prior state" from "prior state to protect". Six repos on this box gained
  their first `project.md` today and several their first state file, so the
  first-run branch was live, not hypothetical. The stakes are set by the skill
  itself at L177-183: a gather that dies leaves the watermarks moved and the
  facts nowhere, *"and that harvest is **gone for good**. The fleet has already
  lost 2026-07-24 → 08-11 this way."*
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md` (Phase A, same box, same night — two subagents, independently).
- **bytes:** n/a
- **replacement — reorder, and make the first-run case explicit. Replace L117-125 with:**
```
- State file: `"$repo/.claude/kb-harvest-state.json"`. Digests out dir: a
  scratchpad path, never inside the repo.
- **Back up the watermark BEFORE creating anything** — see *Recovery* below.
  The order matters: taking the backup after the first-run create copies the
  literal `{}`, and restoring *that* wipes a watermark rather than restoring it
  (hit by two subagents on 2026-09-12). Back up only a file that already exists,
  and record that there was none when there was none:
  ```bash
  mkdir -p "$repo/.claude/harvest"
  if [ -s "$repo/.claude/kb-harvest-state.json" ]; then
    cp "$repo/.claude/kb-harvest-state.json" \
       "$repo/.claude/harvest/state-before.json"
  else
    rm -f "$repo/.claude/harvest/state-before.json"   # no watermark to protect
    printf '{}' > "$repo/.claude/kb-harvest-state.json"   # first run
  fi
  ```
  `distill.py` initializes its own `sessions` key, so `{}` is a valid start.
  **Absence of `state-before.json` means "there was no watermark", not "the
  backup failed"** — recovery for such a repo is to delete the state file, not
  to restore one.
```
  and in `### Recovery / aborted runs` at L184, replace *"Restore from
  `"$repo/.claude/harvest/state-before.json"`, written in Step 0."* with:
```
Restore from `"$repo/.claude/harvest/state-before.json"`, written in Step 0 —
**but only if it exists.** Step 0 writes it only when there was a watermark to
protect, so a missing backup means this repo had none and recovery is
`rm -f "$repo/.claude/kb-harvest-state.json"`. Never restore a backup whose
whole content is `{}`: that is not a watermark, and writing it over a real one
strands every session it had recorded.
```
- **first seen:** 2026-09-12

## 5fb4bf31 · promote · /home/me/.claude/memory/personality/practices.md

- **id-inputs:** `/home/me/.claude/memory/personality/practices.md` # `(branch: desktop-wsl)` # `promote` # `practices.md:branch-vs-mergebase-ae03a7d`
- **action:** promote
- **scope:** shared — three fleet-wide stores
- **apply on:** **desktop-wsl** — NOT this box. `/memory-review` on g15 must refuse it.
  A push to another box's branch strands that box's next sync as a conflict
  (*The write boundary*, consolidate-phase.md:237-252).
- **target:** `/home/me/.claude/memory/personality/practices.md`
- **anchor:** `(branch: desktop-wsl)`
- **why:** `origin/desktop-wsl` holds **170 lines across five shared stores that
  `main` has never had** — the largest unpromoted block in the fleet, and it is
  *personality* memory, the class that is supposed to be byte-identical
  everywhere. It is invisible to every other box: none of it is on `main`, and
  `desktop-wsl`'s branch is the only copy.
- **evidence:** measured 2026-09-12 after `dotfiles fetch --all --prune`.
  merge-base `origin/main...origin/desktop-wsl` = `ae03a7d` (2026-09-11);
  lines present on the branch and absent from the merge-base version:
  ```
  .claude/memory/personality/practices.md   126
  .claude/memory/personality/tone.md         21
  .claude/memory/personality/values.md       13
  .claude/memory/core.md                      5
  .claude/CLAUDE.md                           5
  ```
  **Size would have hidden all of it**: `practices.md` on that branch is 31990 B
  against main's 32725 — *smaller*, which the brief's current Step 3b rule
  (L205-210) calls "just lagging… not a finding". See the companion `skill` item
  filed this run against that rule.
  Seven whole `##` sections are among the new lines, e.g.
  `## A guard asserted only on its refusal is not tested (measured 2026-09-07, machines/hosts/g15/staging)`,
  `## Review findings — the observations hold, the remedies don't (measured 2026-08-28, backend-chats PR #742)`,
  `## Never re-expand text a human edited down (2026-09-03, PR #4384)` (values.md),
  `## Review findings I draft — how he cut them (measured 2026-08-27, PR #4360)` (tone.md).
- **carry first / caution:** several of these sections cite employer PRs and
  tickets by number (`PR #4384`, `CFT-4888`, `CFT-5051`). They are *behavioral*
  rules, which is why they are in `personality/` — but promoting puts the ticket
  ids on **every** box including `hub` (the public VPS). That is the same
  judgement the six open `Pure …` demote items turn on; decide it once, the same
  way, for both. Generalising the citation to a date (`measured 2026-09-02, a
  review`) preserves the rule and drops the identifier.
- **bytes:** up to +6 KB across five shared paths on `main`
- **replacement:** (none — `/dotfiles-promote` **on desktop-wsl**, the five paths
  above. Nothing to apply on g15.)
- **first seen:** 2026-09-12

## a82195c2 · promote · /home/me/.claude/memory/global.md

- **id-inputs:** `/home/me/.claude/memory/global.md` # `(branch: air)` # `promote` # `global.md:branch-vs-mergebase-57551c6`
- **action:** promote
- **scope:** shared — three fleet-wide stores
- **apply on:** **air** — NOT this box. `/memory-review` on g15 must refuse it.
- **target:** `/home/me/.claude/memory/global.md`
- **anchor:** `(branch: air)`
- **why:** `origin/air` holds **35 lines across three shared stores that `main`
  has never had**, written on air since it diverged on 2026-08-24. Air's branch
  tip is 2026-09-07 and the box is frequently asleep (unreachable again
  2026-09-11), so this has had three weeks to reach the rest of the fleet and
  has not. Every other shared path on that branch is *smaller* than main's —
  i.e. air is also lagging — which is exactly the state in which a naive sync
  merge can lose the 35 lines silently.
- **evidence:** measured 2026-09-12 after `dotfiles fetch --all --prune`.
  merge-base `origin/main...origin/air` = `57551c6` (2026-08-24);
  lines present on the branch and absent from the merge-base version:
  ```
  .claude/memory/global.md                  17
  .claude/memory/personality/practices.md   11
  .claude/memory/personality/tone.md         7
  ```
  `rev-list --left-right --count origin/main...origin/air` = `17  62`.
  The `global.md` block is one coherent, high-value finding that exists nowhere
  else in the corpus — a gortex MCP session's project is pinned by the client's
  cwd and an in-process subagent inherits it and cannot switch (probed
  2026-08-17), so any agent reviewing code in a different checkout than the
  caller's is graph-blind **silently**, and the fix is to launch it as its own
  session with cwd inside that worktree. Two bullets in `## Gortex` and the
  worktree-indexing rule consolidated on 2026-09-11 both assume the reader knows
  this and neither states it.
- **carry first / caution:** the evidence line names an employer worktree
  (`backend-api-pure-review-4336`). Same judgement as the desktop-wsl promote
  and the six open `Pure …` demotes: generalise the identifier or accept it
  fleet-wide, but decide it once for all three.
- **precondition:** air must be awake. `rev-list` shows it 62 commits ahead of
  `main` and 17 behind, so run `/dotfiles-sync` there first — promoting from a
  stale checkout is how the 2026-09-11 run produced three items that had to be
  rejected as *already done*.
- **bytes:** ~+2 KB across three shared paths on `main`
- **replacement:** (none — `/dotfiles-promote` **on air**, the three paths above.)
- **first seen:** 2026-09-12

## 45e6a3cb · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `compress` # `project.md:193-250`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15 (any box with the checkout)
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191, 40066 B — the largest section in the corpus)
- **why:** 58 lines of live-sounding operational guidance about a Windows install
  that no longer exists — the `C:` review gate, ~410 GB unreviewed, the
  Docker-volume inventory, and in bold *"Reach it as `methe@server.gg.ez` — NAME
  THE USER"*. That disk was wiped 2026-09-07. The block already opens with its
  own SUPERSEDED banner, which is exactly the shape that stops being read while
  the stale addressing underneath stays quotable.
- **evidence:** `project.md:193-250`. Superseded twice in this same file:
  `project.md:2428` (`## g15 phase 1 done`) and `project.md:2449` (`## g15 phase
  4`). Live: `ls hosts/server` → *No such file or directory*; `ls -R hosts/g15` →
  `hosts/g15/ubuntu: README.md compose.override.yml install-compose-override.sh
  rustdesk-seed.sh`; `cat fleet.json` → g15 is `"platform": "debian"`,
  `100.64.0.10`, **no `ssh` block**, so `ssh.user` defaults to `me`.
- **bytes:** 4339 → 1881
- **replacement:**
```
- **HISTORY — the `server` machine is gone twice over.** It was renamed to `g15`
  and re-enrolled in `fleet.json` 2026-08-27 (see *`g15` (ex-`server`) back in
  the fleet*), and the Windows install this block described was WIPED on
  2026-09-07 when the box was reinstalled as native Ubuntu 26.04 (see *g15 phase
  1 done* and *g15 phase 4*). So the `C:` review gate, the ~410 GB of unreviewed
  profile data, the Docker-volume inventory and every `methe@server.gg.ez`
  address in the old text are dead — reach the box as `me@g15.gg.ez`
  (`ssh.user` defaults to `me`), and `hosts/server/` stays deleted. Five things
  outlive it:
  - **Forgejo was WIPED 2026-08-01, not rehomed** — zero repositories, a
    bare-install `gitea.db`, nothing written since the 2026-05-03 install. Both
    volumes removed. No old data exists to restore; start fresh if git hosting
    is ever wanted again.
  - **`telegrind_pgdata` lives on latitude now** — exported as a raw tar from a
    cleanly-`Exited (0)` container (self-consistent data dir, a stronger
    guarantee than a dump comparison), sha256-identical on three hosts, restored
    and verified there: 987 files, `PG_VERSION` 15. `embedthat_redis_data` and
    `tugtainer_tugtainer_data` are on latitude too.
  - **`CACHEDIR.TAG` is the cheap disposability check.** Tooling that writes it
    is telling you the directory is throwaway; testing for it beat reasoning
    about contents and cleared 14 GB in one command.
  - **The `server` PROFILE outlives the `server` MACHINE** — latitude runs
    `profile: server` and `tiers.test.sh` exercises it as `plan server`. Don't
    "clean up" the profile thinking it is the retired box.
  - A `Permission denied (publickey)` names the user it tried. Reading that
    field first would have saved a wrong "the key is unenrolled" diagnosis that
    was really a username mismatch.
```
- **first seen:** 2026-09-12

## 3b71c80d · dedupe · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `dedupe` # `project.md:278-297`
- **action:** dedupe
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191)
- **survives:** `/home/me/machines/AGENTS.md` `### Two-layer hostname convention` (L724-746) — the auto-loaded file, and the fuller copy (the g15 rename and its reason, hub's VPS special case, the live `Rename-Computer` verification, the WSL third identity)
- **why:** the same convention in two files — but a plain dedupe would destroy
  something. `project.md:278` asserts a **universal** that is false ("Every fleet
  machine's OS hostname differs from its SSH alias by design") and AGENTS.md
  silently omits the exception, so cutting project.md leaves a wrong rule
  standing. The durable part — the probe rule — is in **neither** copy's
  survivor form and must be kept verbatim.
- **evidence:** `project.md:278-297` vs `AGENTS.md:724-746`.
  `cat fleet.json` → `"air": { "platform": "darwin", …, "detect": { "hostname":
  "air" } }` — OS hostname **equals** the SSH alias, so the universal is false.
  `project.md:279` also still writes the pair as `` `g513ie`↔`server` ``, a
  logical name deleted 2026-08-27.
- **bytes:** 1356 → 603
- **replacement — TWO edits, one decision.**
  (1) Replace `project.md:278-297` with:
```
- **"Is this host me?" cannot be decided by comparing `hostname` to an SSH
  alias** — use a runtime probe (`ssh $alias hostname` vs local `hostname`), as
  `memory-harvest` self-exclusion does. Most members' OS hostname differs from
  their alias (`latitude5520`↔`latitude`, `g614jv`↔`desktop`, `g513ie`↔`g15`),
  but **`air` is both**, so the difference is a convention, not an invariant.
  The two-layer convention itself (spec
  `docs/superpowers/specs/2026-07-19-fleet-hostname-normalization-design.md`,
  executed 2026-07-20) is documented in AGENTS.md, *Two-layer hostname
  convention*.
```
  (2) **Companion edit to the survivor**, `AGENTS.md` `### Two-layer hostname
  convention`: add `air` as the named exception, so the surviving copy is
  actually complete. Without (2) the exception exists nowhere and (1) points at
  a file that contradicts it.
- **NOTE:** `/improve config audit` also proposes against `CLAUDE.md`/`AGENTS.md`
  bloat. This run files several `AGENTS.md` items — say so if both are run on the
  same day so the same file does not get two competing proposals.
- **first seen:** 2026-09-12

## 90c837eb · dedupe · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `dedupe` # `project.md:301-314`
- **action:** dedupe
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191)
- **survives:** `/home/me/machines/AGENTS.md` *Fleet networking / tailnet architecture* (L486-518) — the corrected and more complete copy
- **why:** not merely redundant — the project.md copy **dispatches to a machine
  key that no longer exists in the manifest**, and hedges that WSL discovery is
  "not yet live-verified end-to-end" while AGENTS.md describes that discovery as
  live and in use by both callers.
- **evidence:** `project.md:301-314` vs `AGENTS.md:486-518`. `project.md:307-308`
  names the Windows-native dispatch members as `` (`desktop`, `server`) ``;
  `cat fleet.json` has **no `server` key at all**, and `g15` is
  `"platform": "debian"`. `AGENTS.md:501-503` already states the correction:
  *"which means **`desktop` and only `desktop`**. `g15` was a Windows member from
  2026-08-27 until the 2026-09-07 reinstall; its manifest platform is `debian`
  now"*.
- **carry first:** the `/mnt/c` root-removal detail is unique to project.md and
  is kept in the replacement below.
- **bytes:** 1034 → 620
- **replacement:**
```
- **Fleet dispatch is platform-aware** —
  `agents/plugin/skills/lib/fleet-dispatch.sh` (`fd_probe`/`fd_run`/
  `fd_wsl_hosts`), sourced by `/ship`'s `fleet-pull.sh` and memory-harvest's
  `fleet-gather.sh`. The mechanism, the Windows-native dispatch and the WSL
  `dispatch:direct`/`dispatch:parent` split are in AGENTS.md, *Fleet networking
  / tailnet architecture*. The one fact only recorded here: the old `/mnt/c`
  cross-filesystem root was REMOVED — `machines` is located
  canonical-path-first (`$HOME/machines`), root-scan fallback second.
  Half-provision a WSL host with `just provision-wsl <nickname>`.
```
- **first seen:** 2026-09-12

## af15caff · delete · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `delete` # `project.md:547-553`
- **action:** delete
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191)
- **why:** the bullet is a changelog of edits to five files that no longer exist,
  in a repo that has no Nix tree. Its only durable content — the AmneziaVPN
  client is gone from our machines, the VPS hub is untouched and owned by `vps` —
  is stated **twice** elsewhere, once in this same section.
- **evidence:** `project.md:547-553`. Every path it names is deleted:
  `ls modules flake.nix pkgs hosts/g16 hosts/homeserver` → *No such file or
  directory* for all five; `git log --oneline -1 f3d63b2` →
  `feat!: delete the NixOS tree; rehome its two live inputs`.
  Survivors: `project.md:318-320` (the AmneziaWG→Headscale DECISION bullet —
  *"AmneziaWG stays ONLY as the obfuscated VPN for Russia-based relatives… on the
  VPS hub"*) and `AGENTS.md:456-458` (*"The old AmneziaWG mesh was retired from
  the repo 2026-07-17 (AmneziaWG survives only as the VPS's obfuscated VPN for RU
  relatives)"*).
- **bytes:** 547 → 0
- **replacement:** (none — deletion)
- **first seen:** 2026-09-12

## 131173da · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `compress` # `project.md:532-546`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191)
- **why:** fifteen lines reasoning about `pkgs.linuxPackages_latest` in
  `modules/system/base.nix`, a branch name, and "full `latitude5520` toplevel
  builds green" — a build target that cannot exist. One line is transferable and
  still live on g15 (RTX 3050 Ti, NVIDIA DKMS on Ubuntu 26.04), so this is a
  compress, not a delete.
- **evidence:** `project.md:532-546`. `ls modules flake.nix` → *No such file or
  directory*; `git log --oneline -1 f3d63b2` → the NixOS-tree deletion;
  `git tag -l 'nixos*'` → `nixos-final`;
  `ls -la docs/2026-08-01-nixos-harvest.md` → present, 10094 B.
- **bytes:** 1144 → 486
- **replacement:**
```
- **An out-of-tree kernel module only loads under the kernel it was built for.**
  After a kernel-changing upgrade it fails `Module <x> not found in
  .../<old-kernel>` until you REBOOT into the new kernel — still live for g15's
  NVIDIA DKMS. (The rest of this bullet tracked latitude's NixOS kernel pin,
  taken out of force when AmneziaWG's out-of-tree module was retired
  2026-07-17; the tree it named is gone — see `docs/2026-08-01-nixos-harvest.md`
  and tag `nixos-final`.)
```
- **first seen:** 2026-09-12

## 7a8ce25a · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `compress` # `project.md:471-480`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191)
- **survives:** `/home/me/machines/AGENTS.md` *Fleet networking / tailnet architecture* (L460-472) — it holds the per-pair IPs (latitude via 192.168.8.155 in 2 ms, g15 via 192.168.8.170 in 3 ms, hub via public IP in 6 ms)
- **why:** the same 2026-09-07 refutation of "two separate LANs" in both files,
  with AGENTS.md the more complete. But project.md holds the one thing AGENTS.md
  lacks: **why the wrong claim was ever true** ("It rested on latitude sitting on
  a hotspot behind this ISP's CGNAT"). A straight delete drops that mechanism,
  and the mechanism is what stops the claim being re-derived.
- **evidence:** `project.md:471-480` vs `AGENTS.md:460-472`.
- **bytes:** 766 → 553
- **replacement:**
```
- Probe PASSED 2026-07-13 (spec/plan/results under `docs/superpowers/`): SSH +
  RustDesk over the tailnet work, and DERP fallback through our own relay is
  reliable. **Its other finding — "the fleet spans two separate LANs; cross-LAN
  pairs relay via our own DERP, EXPECTED and ACCEPTED" — is DEAD.** It rested
  on latitude sitting on a hotspot behind this ISP's CGNAT; that stopped being
  true and the sentence outlived it. The current measurements and the lesson
  drawn from them are in AGENTS.md, *Fleet networking / tailnet architecture*.
```
- **lowest-confidence of this slice's six** — ship it last; if a reviewer would
  rather keep both copies whole, that is a defensible call.
- **first seen:** 2026-09-12

## b069cc28 · delete · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `delete` # `project.md:971-976`
- **action:** delete
- **scope:** repo:machines — **highest-consequence item in this slice**
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737, 25858 B)
- **why:** the bullet names **both the restic repository and its config at paths
  that no longer exist.** A restore attempt reads it, goes to `/mnt/spare320`,
  and finds nothing. Everything else in this run is tidiness; this one is a
  broken recovery path.
- **evidence:** `project.md:971-976`. Superseded by `project.md:3128`
  (`## Оба restic-репозитория на 8 ТБ…`) and by the config itself:
  `awk '/repository|REPO PLACEMENT|It replaces/' backup/latitude/profiles.yaml` →
  `31: # REPO PLACEMENT: /mnt/wd8, the WD Blue 8 TB, since 2026-09-10.` /
  `35: # It replaces /mnt/spare320 (ST320LT020, 36k power-on hours, 293 G)` /
  `103:   repository: "/mnt/wd8/restic/latitude"`.
  Config location: `git -C /home/me/my/vps ls-files backup` → **empty**;
  `git log --oneline --all | awk '/f70b9cb/'` →
  `f70b9cb backup: the profiles move to \`machines\`, the REST server stays here`;
  `ls machines/backup/latitude/` → `install-tasks.sh  profiles.yaml`.
- **bytes:** 437 → 471 (it grows; a correct pointer costs more than a wrong one)
- **replacement:**
```
  - **restic for the small irreplaceable set** — `/mnt/wd8/restic/latitude`
    (moved off `/mnt/spare320` 2026-09-10; see *Оба restic-репозитория на 8 ТБ*),
    repo `14f4eab544`, covering the nightly pg_dumpall, ServarrConfig,
    xs-keepers and `~/my/vps` (for its seven gitignored `.env` files). 6.5 GiB →
    2.3 G. Backup 04:30 daily, `check --read-data-subset 5%` Sundays 06:00.
    Config `machines/backup/latitude/profiles.yaml`, `schedule-permission:
    system` because pg_dumpall output is root-owned.
```
- **first seen:** 2026-09-12

## 83538d13 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `contradiction` # `project.md:849-854`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737)
- **why:** the Backups section still gives **layout advice derived from a
  property this repo retracted on 2026-09-10**, and the advice is now backwards:
  the archive *copy* lives on dock A and the source on 4-2, the reverse of what
  the text says. Three sites, not one.
- **evidence:** `project.md:849-854` ("dock B (`usb 4-2`) is the worst offender…
  archive *primary* on dock A, *copy* on flakier dock B… `--partial
  --append-verify`"), `project.md:860` ("— the flaky one, and"),
  `project.md:940` ("the flaky dock-A bridge").
  Retracted by `project.md:3078-3086`: *"AGENTS.md и этот файл описывают 4-2 как
  постоянно флаки — это состояние июля-августа, а не свойство дока … С 17.08 не
  повторялся"*. `AGENTS.md:783-785` is **already fixed**: *"**That storm has not
  recurred since 17.08** … so do not read '4-2 is the flaky dock' as a standing
  property"*. Live layout `project.md:3172-3173`: `u4-1:1 HGST
  (/mnt/immich-2024-backup), u4-2:0 wd8, u4-2:1 immich-2024` — the copy is on
  dock A. And `AGENTS.md:578` records *why `--partial-dir` rather than
  `--append-verify`*. L940's "dock-A" is residue of the A/B swap that L860 itself
  says was fixed 2026-09-11.
- **bytes:** 630 (468 + 79 + 83) → 540
- **replacement — THREE edits under one anchor, one decision.**
  (a) Replace `project.md:849-854` with:
```
- **The docks also reset unprompted — check the journal before blaming your own
  command.** Check with
  `sudo journalctl -k --since today | grep -aE "usb [0-9.-]+: (reset|USB disconnect)"`.
  **Two different failures, do not conflate them**: `disconnect` on BOTH docks in
  the same second is mains, `reset` on ONE under load is link/enclosure — the
  measurements are in *Доки роняет розетка, а не USB* (2026-09-10), and neither
  dock is a standing "flaky" one (the 4-2 storm ended 17.08). Long writes into
  either dock get `--partial-dir`, not `--append-verify`.
```
  (b) At L860, strike `— the flaky one, and` so the line reads:
```
  — the one carrying immich-2024. This bullet had A and B
```
  (c) At L940, strike the dock letter (immich-2024 is on 4-2, per L860):
```
  2024 archive across a single dock bridge — do it deliberately. Falling back
```
- **first seen:** 2026-09-12

## 7dc3f946 · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `compress` # `project.md:800-803`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737)
- **why:** the headline is provably false and the clause it rests on is dead.
  "latitude5520 has no dedicated backup today" is contradicted 170 lines below
  and by the live config; "Whatever home-manager declares in this repo is already
  'backed up' by being in git" names a mechanism no box has. The **last** clause
  is still true and may be its only statement, so this is a compress.
- **evidence:** `project.md:800-803`. Falsified by `project.md:971-976` and
  `backup/latitude/profiles.yaml:103` (`repository: "/mnt/wd8/restic/latitude"`),
  plus `ls machines/backup/` → `_retired-homeserver base.yaml desktop-wsl g15
  latitude …`. The home-manager clause: `ls machines/hosts/` → `desktop g15
  latitude`, no Nix tree (`AGENTS.md:271` *The NixOS tree is gone*, `f3d63b2`).
  The surviving clause holds: `profiles.yaml`'s source list is
  `/var/backups/immich-db`, `ServarrConfig`, `xs-keepers`, `~/my/vps` and
  nothing else.
- **bytes:** 307 → 231
- **replacement:**
```
- **latitude's restic covers only the small irreplaceable set** (see *The backup
  topology, rebuilt 2026-08-01*). Outside that scope — browser profiles, ad hoc
  `~/.config`, local documents — nothing on this box is protected.
```
- **first seen:** 2026-09-12

## 2a10559c · delete · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `delete` # `project.md:942-945`
- **action:** delete
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737)
- **why:** two bullets in one section give **two different live symlink locations
  for the same restic password**, and only the later one is current. A recovery
  session reading top-down finds the dead one first.
- **evidence:** `project.md:942-945` says the live path is
  `~/my/vps/backup/homeserver/pass.txt`. Superseded by `project.md:1039-1044`
  (*latitude's password is one file reached through one symlink, deliberately* —
  `~/machines/backup/latitude/pass.txt` symlinks to it). The `vps` path is gone:
  `git -C /home/me/my/vps ls-files backup` → **empty**;
  `git log --oneline --all | awk '/f70b9cb/'` →
  `f70b9cb backup: the profiles move to \`machines\`, the REST server stays here`.
  `backup/latitude/profiles.yaml:51-58` states the same thing the surviving
  bullet does, naming `~/machines/backup/latitude/pass.txt`.
- **nothing is the last copy:** the tracked byte-source
  (`!/g513ie-prod-config/vps/backup/homeserver/pass.txt`) and the
  "don't create a second copy" rule both survive in the L1039 bullet.
- **bytes:** 319 → 0
- **replacement:** (none — deletion)
- **first seen:** 2026-09-12

## dd41f743 · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `compress` # `project.md:901-906`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737)
- **why:** half the bullet describes a drive that is out of the box and a music
  collection that was deleted as proven redundant. The ntfs3 dirty-`$LogFile`
  remount rule inside it has **no other copy anywhere**, so it stays — restated
  as a general rule rather than a `/mnt/xs` fact.
- **evidence:** `project.md:901-906`. The stick is gone — `AGENTS.md:578`
  ("the HGST; it was `/mnt/xs` until that stick left the box 2026-09-09");
  `project.md:3116` (*`/mnt/xs` в `/etc/fstab` закомментирован (диск физически
  снят)*); `project.md:2902-2905` (*Вынули его из парка 2026-09-09*). The music
  claim is dead too — `project.md:2814`: *"**The 89 G music pile on latitude was
  proven redundant and is DELETED (2026-09-08, his go). spare320: 82 G → 170 G
  free.**"*. Uniqueness of the kept rule: `awk '/ntfs3|LogFile/' project.md` →
  only 901, 902, 1153; the same over `AGENTS.md` → **no hits**.
- **NOT touched:** the `exfat xs700` row at L1780 — plausibly a different
  partition on the same Ventoy stick, and not settleable from g15.
- **bytes:** 380 → 233
- **replacement:**
```
- **An ntfs3 filesystem with a dirty `$LogFile` cannot be remounted read-write in
  place** — `ntfs3: Couldn't remount rw because journal is not replayed`, left by
  an unclean Windows shutdown. Needs a full `umount` + `mount -o rw`.
```
- **first seen:** 2026-09-12

## a856256c · delete · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Repo tooling & scripts` # `delete` # `project.md:1424-1427`
- **action:** delete
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Repo tooling & scripts` (L1214, 23041 B)
- **why:** the bullet exists only to warn against conflating two files; **one of
  them was deleted with `hosts/server/` on 2026-08-01**, so the advice cannot be
  acted on.
- **evidence:** `project.md:1424-1427`. `ls machines/hosts/` → `desktop  g15
  latitude`; `ls -d machines/hosts/server` → *No such file or directory*.
  `AGENTS.md:430` confirms: *"(hosts/server/ was deleted with the decommission —
  git history has it.)"* The surviving fact (desktop's is a full `winget export`
  snapshot) is already implied by `AGENTS.md`'s `hosts/desktop/windows/` line,
  which names `winget-packages.json` alongside the runbook.
- **bytes:** 350 → 0
- **replacement:** (none — deletion)
- **first seen:** 2026-09-12

## 2ea760f6 · dedupe · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Repo tooling & scripts` # `dedupe` # `project.md:1419-1421`
- **action:** dedupe
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Repo tooling & scripts` (L1214)
- **survives:** `/home/me/machines/AGENTS.md` *Common Commands* (L185-186) — auto-loaded in every session in this repo, and the rationale sits next to the recipe menu, which is where a reader hits it
- **why:** the rationale sentence is **verbatim identical** in both files.
  `AGENTS.md` is the right home; what it does **not** carry is the
  `update-gortex.sh` survivor clause, so that is kept here with a pointer.
- **evidence:** `project.md:1419-1421` — *"they wrote only into
  `modules/home/*-bin.nix` and nothing else read those files."*
  `AGENTS.md:185-186` — *"update-orca and update-rustdesk are gone — they wrote
  only into / `modules/home/*-bin.nix` and nothing else read those files."*
  Same sentence.
- **bytes:** 349 → 217
- **replacement:**
```
- The `.nix`-era updaters are gone (`orca-bin.nix`, `update-orca.sh`,
  `update-rustdesk.sh`, `just update`/`just upgrade`) — rationale in AGENTS.md
  *Common Commands*. `scripts/update-gortex.sh` is the only survivor: it bumps
  `provision/gortex.version`, the pin `tier_gortex` installs.
```
- **first seen:** 2026-09-12

## fe27f639 · delete · /home/me/machines/AGENTS.md

- **id-inputs:** `/home/me/machines/AGENTS.md` # `Architecture` # `delete` # `AGENTS.md:594-598`
- **action:** delete
- **scope:** repo:machines — an **auto-loaded instruction file**, so this is a standing context error for every session in this repo
- **apply on:** g15
- **target:** `/home/me/machines/AGENTS.md`
- **anchor:** `Architecture` (L271, 31696 B) — the finding is under the `###`-level
  `**`hosts/latitude/debian/`**` block, in the `restic-hub-selfcheck.sh` bullet at L594-598
- **SUPERSEDES `94fc81c8`, filed minutes earlier in this same run under the
  invented anchor `Host configurations`.** That string is a bolded inline label,
  not a `##` heading — `consolidate.sh index AGENTS.md` emits only four rows
  (`Repository Overview` L19, `Common Commands` L146, `Architecture` L271,
  `Hardware Context` L722), and `awk` confirms L594 is enclosed by `## Architecture`.
  This item is the same finding with the correct anchor and therefore the
  reproducible id. **/memory-review: reject `94fc81c8` as a mis-anchored
  duplicate and apply this one.** (An item is never rewritten in place, which is
  why the correction arrives as a second item rather than an edit.)
- **why:** the bullet names the hub's repo directory at a path the profiles moved
  off on 2026-09-10. A reader debugging "healthy repos report MISSING" goes to
  `/mnt/spare320/restic-rest/`, finds nothing, and concludes the checker is
  broken. The **rule** (must run as root; exit 2 for non-root vs 1 for a real
  failure; `role_backup_hub` sudo-wraps it) is correct and kept verbatim — only
  the path is wrong.
- **evidence:** `AGENTS.md:596` → *"the repo dirs under
  `/mnt/spare320/restic-rest/` are `drwx------ root:root`"*.
  `awk '/restic-rest/' backup/latitude/profiles.yaml` →
  `:91`, `:218 repository: "/mnt/wd8/restic-rest/g614jv"`,
  `:240 test -f /mnt/wd8/restic-rest/g614jv/config`,
  `:336 repository: "/mnt/wd8/restic-rest/g513ie"`, `:346`.
  Same 2026-09-10 move the `Backups` `delete` item filed this run corrects in
  `project.md:971-976`; `AGENTS.md` was missed by that fix.
- **bytes:** 5 characters (`spare320` → `wd8`); the consequence is a dead
  recovery path in the file every session loads.
- **replacement — replace `AGENTS.md:596` with:**
```
  under `/mnt/wd8/restic-rest/` are `drwx------ root:root`, so an unprivileged
```
- **first seen:** 2026-09-12

## 03b60232 · contradiction · /home/me/my/vps/.claude/memory/project.md

- **id-inputs:** `/home/me/my/vps/.claude/memory/project.md` # `Services & scheduler` # `contradiction` # `vps-project.md:94`
- **action:** contradiction
- **scope:** cross-store — `repo:vps` vs `repo:machines`
- **apply on:** g15 (both checkouts are here)
- **target:** `/home/me/my/vps/.claude/memory/project.md`
- **anchor:** `Services & scheduler` (L85, 25176 B) — the `What is UP on latitude` bullet is at L94
- **SUPERSEDES `1939af4c`, filed minutes earlier in this same run under the
  invented anchor `Services on latitude`.** That heading does not exist:
  `consolidate.sh index` on this store gives `Services & scheduler` at L85.
  **/memory-review: reject `1939af4c` as a mis-anchored duplicate and apply this
  one.**
- **why:** `vps`' store lists **`restic-server` as "Down on purpose"**, dated
  2026-08-01, while `machines` describes the restic REST hub as live, bound and
  serving — and ships a systemd timer whose whole job is to catch that hub
  serving an empty bind. Both cannot be true. The repo boundary is exactly where
  this drift survives: `machines` owns the backup *profiles*, `vps` owns the REST
  *server container*, so each store records half the system and neither reader
  sees the other half.
- **evidence:** `vps/project.md:94` → *"Down on purpose: navidrome,
  restic-server, forgejo, plus the four below."* (dated 2026-08-01).
  Against `machines`: `backup/latitude/profiles.yaml` defines two REST-served
  repositories (`:218` `/mnt/wd8/restic-rest/g614jv`, `:336`
  `/mnt/wd8/restic-rest/g513ie`) with `test -f …/config` health checks;
  `machines/AGENTS.md:594-598` documents `restic-hub-selfcheck.sh` as one of
  latitude's **three installed system timers**, "the only thing that catches the
  restic REST hub serving an empty bind", sudo-wrapped by `role_backup_hub`.
- **do not resolve by authority — measure on latitude:**
  `docker ps --filter name=restic` and
  `systemctl status restic-hub-selfcheck.timer`. One command settles it.
  The `vps` line is older and the more likely stale, but it is also the only
  statement of *deliberate* intent, so a silent flip would destroy a decision
  record.
- **bytes:** n/a until resolved
- **replacement:** (none — a pair for a human. If the hub is up, strike
  `restic-server` from the "Down on purpose" list **with the date it came back**;
  do not delete the list — it is a decision record.)
- **first seen:** 2026-09-12

## 01ba3c32 · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)` # `compress` # `project.md:2029-2223`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)` (L2029, 12627 B)
- **why:** two thirds of the section is one-time forensics for a route whose
  **both ends are gone** — per-repo branch inventory, `id_cyphy671` removal, the
  184 GB / 25,468,309-chunk restatements, the 14 GB → 737 MB tallies, the
  `172.26.x` portproxy names, "nothing deleted yet" status lines. Every portable
  rule survives verbatim, including two that are live for a box that still
  exists.
- **evidence:** `project.md:2029-2223`. Dead state: `cat fleet.json` → `g15` is
  `platform: debian`, `repo_groups:["my"]`, no WSL; `ls hosts/g15/` → `ubuntu`
  only. **Live state, the opposite error:** AGENTS.md's `tier_docker` still
  assumes Docker Desktop owns the engine on a WSL distro, so *"removing DD
  removes the thing holding desktop-wsl up"* constrains a plan that has **not**
  been executed — that bullet is not history.
- **what is deliberately kept verbatim:** the blob-hash-by-hand recipe
  (`$HOME/CLAUDE.md`'s *Branches* section tells readers to run it before deleting
  a branch — cutting it would orphan a live policy reference); all four
  pre-delete gate commands **with** the reason a worktree is invisible to the
  other three; the `du`-vs-truncated-tar mechanism; `rc=0` + file-count-diff; and
  both halves of the `--ignored` qualifier, which sit in two different paragraphs
  (L2123 and L2160) and are merged here deliberately.
- **bytes:** 12627 → 8808 (−3819, 30%)
- **replacement:** **`docs/memory-consolidate/replacements/01ba3c32.md`** — verbatim,
  replaces L2029-2223 inclusive. It is 8.8 KB, kept as a sibling file rather than
  inline so this queue stays readable; the file is inside
  `docs/memory-consolidate/` and therefore inside this phase's write boundary.
- **EITHER/OR with the `contradiction` item filed this run against
  `project.md:2147-2154`** (the `~/my/vps` do-not-delete order). That range is
  inside this one and the replacement above already folds the correction in.
  **Apply this compress OR that contradiction, never both.**
- **first seen:** 2026-09-12

## 462d1839 · generalise · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet migration 2026-07 (MacBook primary, latitude → server, retire G15)` # `generalise` # `project.md:1684-1710`
- **action:** generalise
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet migration 2026-07 (MacBook primary, latitude → server, retire G15)` (L1552, 11551 B)
- **why:** three dangling `modules/` citations in the auto-pull bullets. The last
  bullet's **rule** — one implementation read from the working tree, so a bad
  commit breaks self-updating on every box at once — is live and load-bearing;
  its **framing** (a `/nix/store` immutability contrast) describes a mechanism no
  box has. Folding the two bullets keeps the tradeoff and drops the three
  unresolvable paths.
- **evidence:** `project.md:1684-1710`. `ls modules` → *No such file or
  directory*; the NixOS tree was deleted 2026-08-01 (`f3d63b2`). Dead paths
  cited: `modules/system/self-update.nix`, `modules/system/fleet-selfpull.nix`,
  `services.fleetSelfpull`. Live: `provision/fleet-selfpull.sh` and
  `provision/fleet-selfpull.test.sh` both exist.
- **bytes:** 1882 → 1614 (−268)
- **replacement — replaces L1684-1710 inclusive:**
```
- **One auto-pull mechanism fleet-wide, read from the working tree** (`9b8d63c`).
  `nix-repo-auto-pull` is gone; every member runs `provision/fleet-selfpull.sh`,
  so latitude keeps `~/my/vps` fresh too, which the old single-repo puller never
  did. Converge is unaffected — `machines-converge.path` watches
  `.git/logs/HEAD`, so it fires for whoever moved HEAD. **The tradeoff that came
  with unifying is live and deliberate:** the old puller was an inline script
  frozen in a `/nix/store` generation, so a bad commit could not brick it; the
  shared script is read from the **working tree**, so a bad commit to
  `fleet-selfpull.sh` breaks self-updating on **every box at once**. Treat
  `provision/fleet-selfpull.test.sh` as load-bearing, not decorative.
- **`fleet-selfpull.sh` had the same silent-failure bug** that
  `nix-repo-auto-pull` did: it **always exited 0**, and reported *every* pull
  failure as `SKIP diverged`, filing an auth failure as a branch-topology fact.
  Now fetch and merge are split so the two are distinguishable, a real error
  exits non-zero, the deliberate skips (`not-main` / `dirty` / `diverged`) stay
  clean, and the fetch retries once. Guard: `provision/fleet-selfpull.test.sh`,
  18 assertions.
- **Two timers fetch the same repos — keep their `OnCalendar` off a shared
  boundary.** `fleet-selfpull` is `*:03/10` (:03/:13/:23) precisely so it never
  lands on `git-autofetch`'s `*:0/10` (:00/:10/:20). Sharing that boundary made
  concurrent fetches collide on `refs/remotes/origin/main` and the loser fail.
  If you ever retune either interval, re-check the offset.
```
- **first seen:** 2026-09-12

## 76f548ac · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `latitude storage layout (settled 2026-08-01)` # `contradiction` # `project.md:1773-1780`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `latitude storage layout (settled 2026-08-01)` (L1765, 3570 B)
- **why:** the section's own opening rule is *always identify a drive by UUID*,
  and **two rows of its table now point a reader at disks that were re-used** —
  the exact failure the section exists to prevent. One of those UUIDs is
  currently a backup destination under a different mountpoint.
- **evidence:** table at `project.md:1773-1780`.
  `hosts/latitude/debian/archive-mirror.sh:71-73` →
  `DST=/mnt/immich-2024-backup/…`, `DST_UUID=fd0b0662-d574-40f5-930d-de8dc0fc5082`
  — the same UUID the table still labels `/mnt/servarr`.
  `install-docker-ordering.sh` → `MOUNTS=(/mnt/immich /mnt/immich-2024
  /mnt/spare320 /mnt/wd8)`; neither `/mnt/servarr` nor `/mnt/xs` appears.
  Corrections already exist at `project.md:3088` (ServarrMedia → `/mnt/wd8`,
  2026-09-10) and in `archive-mirror.sh`'s WHY header.
- **deliberately an INSERTED marker, not a rewritten table:** current UUIDs are
  not verifiable from g15, and the corrections are already recorded twice
  elsewhere — so nothing here is a last copy and nothing is guessed.
- **bytes:** 0 → 860 (insertion)
- **replacement — insert directly after L1780 (the last table row), before the
  existing blank line at L1781:**
```

**Two rows of this table died on 2026-09-09/10 — the table is the 2026-08-01
snapshot, the repo is authoritative.** `/mnt/servarr` (sdb2, HGST 931 G) is no
longer a mount: `ServarrMedia` moved to the 8 TB WD Blue at `/mnt/wd8`, and that
same HGST — UUID `fd0b0662…`, unchanged — came back as `/mnt/immich-2024-backup`
and is now `archive-mirror.sh`'s destination. `/mnt/xs` (the exfat `xs700`
partition on the Kingston XS2000 Ventoy stick) left the box 2026-09-09 and its
`fstab` line is commented out; it was that job's destination for one week only.
Read `hosts/latitude/debian/archive-mirror.sh` (`DST_MNT` / `DST_UUID` + its WHY
header) and `install-docker-ordering.sh`'s `MOUNTS` before acting on any row
here. Detail: *ServarrMedia переехал на 8 ТБ WD Blue* and *Архив 1970–2024
получил вторую копию* below.
```
- **first seen:** 2026-09-12

## 7a966544 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `g15 phase 1 done — where the only copies live (2026-09-07)` # `contradiction` # `project.md:2440-2444`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `g15 phase 1 done — where the only copies live (2026-09-07)` (L2428, 1187 B)
- **why:** an unqualified **future-dated action item that was superseded five
  days after it was written**. Left alone it produces a pointless drive return on
  2026-10-01, or worse, a belief that the archive's second copy depends on it.
- **evidence:** `project.md:2440-2444` says the Ventoy drive holds latitude's
  `xs700` archive-mirror partition and must be returned before
  `archive-mirror.timer` fires 2026-10-01 05:01. But
  `hosts/latitude/debian/archive-mirror.sh:71-73` → destination is
  `/mnt/immich-2024-backup`, and its header records: *"In between, the target was
  the Kingston XS2000 at `/mnt/xs` — a removable stick that then left the box"*.
- **bytes:** 345 → 529 (+184)
- **replacement — replaces L2440-2444 inclusive:**
```
- **The Ventoy drive was shared with latitude; the deadline is spent.** The same
  physical drive that carried `ubuntu-26.04.1-desktop-amd64.iso` also held
  latitude's exfat `xs700` partition, `archive-mirror.sh`'s destination at the
  time. The stick left latitude 2026-09-09 and that job now writes
  `/mnt/immich-2024-backup` (`archive-mirror.sh:71-73`), so the "return it
  before `archive-mirror.timer` fires 2026-10-01 05:01" deadline no longer
  binds. Secure Boot on g15 is OFF, so Ventoy needs no MokManager enrolment.
```
- **first seen:** 2026-09-12

## e0003b52 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)` # `contradiction` # `project.md:2147-2154`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Moving personal projects onto g15 — the WSL traps that cost the most (2026-08-28)` (L2029, 12627 B)
- **EITHER/OR — apply this ONLY if the `compress` item `01ba3c32` for this same
  section is DECLINED.** That item's replacement already folds this correction
  in, and L2147-2154 sits inside its range. Applying both double-edits the same
  passage.
- **why:** the stated *reason* for a standing do-not-delete order has moved into
  another repo, so the order now rests on a file that is not there.
- **evidence:** `project.md:2147-2154` orders `~/my/vps` never deleted because it
  is the `WorkingDirectory` of `resticprofile-backup@profile-wsl.service`,
  reading `vps/backup/wsl/profiles.yaml`. But `ls machines/backup/` →
  `desktop-wsl/` exists here with `profiles.yaml` + `install-tasks.sh`, and that
  script's body is `cd "$(dirname "$0")"; resticprofile schedule --all`.
  `AGENTS.md` dates the move 2026-09-01. `project.md:1095` separately records the
  `vps/backup/wsl/pass.txt` there as stale and deleted.
- **scoped narrowly on purpose:** this does **not** establish that `~/my/vps` is
  deletable. Whether desktop-wsl re-ran `install-tasks.sh` is not visible from
  g15, and the checkout may be wanted for `vps` work regardless.
- **bytes:** 559 → 794 (+235)
- **replacement — replaces L2147-2154 inclusive:**
```
**Desktop copies deleted 2026-08-29 — except `vps`.** `~/my/` on `desktop-wsl`
went 1.3 GB → 4.9 MB. `~/my/vps` was kept as the `WorkingDirectory` of the user
timer `resticprofile-backup@profile-wsl.service`, reading
`vps/backup/wsl/profiles.yaml`. **That reason is superseded:** the restic
profiles moved into `machines/backup/<identity>/` on 2026-09-01, so the source is
`backup/desktop-wsl/profiles.yaml` here, whose `install-tasks.sh` `cd`s next to
itself. Whether desktop-wsl has re-run it — what the live unit's
`WorkingDirectory` points at now — is not visible from another box; check there
before deleting either path. The gate is the portable part and is unchanged:
before deleting any project directory, `grep -rl '/home/me/my/'
~/.config/systemd/user/ /etc/systemd/system/`.
```
- **first seen:** 2026-09-12

## 5d32d3b4 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `What was still left of the g15 Ubuntu setup — audited on the box (2026-09-08)` # `contradiction` # `project.md:2774-2780`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `What was still left of the g15 Ubuntu setup — audited on the box (2026-09-08)` (L2714, 9880 B)
- **why:** two copies disagree on how many tier-body extractions in
  `tiers.test.sh` use the fragile `awk` range form — and **both are wrong against
  the file they describe.** This is the store's own rule
  (*"Механизм, который собираешься написать… — это ровно тот момент, когда его
  надо померить"*) failing on itself.
- **evidence:** `project.md:2774-2780` ("The other four tiers still use the
  fragile form") vs `project.md:3619-3624` ("only `tier_battery_limit` and
  `tier_lid_ignore` use the robust form"). Measured against the live suite
  2026-09-12:
  `awk "/awk '\/\^tier_/" provision/tests/tiers.test.sh | wc -l` → **8**;
  `sed -n '173p;248p' provision/tests/tiers.test.sh` → L173 is the robust form
  (`/^tier_battery_limit\(\)/{f=1} f&&/^tier_[a-z_]+\(\) *\{/&&!/^tier_battery_limit/{exit} f`)
  but **L248 is fragile** (`awk '/^tier_lid_ignore\(\)/,/^}/'`). Fragile sites:
  91, 133, 248, 281, 311, 347, 438 — seven, not four.
- **bytes:** 1577 (1141 + 436) → ~1180
- **replacement — TWO ranges, one decision. Replace `project.md:2774-2780` with
  the text below; `project.md:3619-3624` is deleted outright (`(none — deletion)`).**
  The surviving copy is the topical one because it alone names the `code()`
  filter, `tailscale-wsl.test.sh`, and the mutation that passed clean.
```
  - **A nested function in a tier broke five unrelated assertions at once.**
    `tiers.test.sh` extracted tier bodies with `awk '/^tier_x\(\)/,/^}/'`, which
    stops at the first column-0 `}` — `charge_mode`'s. The fix is in the test
    (run to the next tier definition, then trim back to the last column-0 `}`),
    NOT indenting the function's brace to placate the awk. **Measured on the
    live suite 2026-09-12: EIGHT tier-body extractions, exactly ONE robust —
    `tier_battery_limit` (line 173).** `tier_gortex_autoupdate` (91),
    `tier_statusboard` (133), `tier_lid_ignore` (248), `tier_oom_guard` (281),
    `tier_sysrq` (311), `tier_rapl_read` (347) and `tier_dotfiles` (438) all
    still carry the fragile range form; give the robust form to whichever of
    them first grows a nested function. Two earlier records of this were both
    wrong — "the other four tiers" (2026-09-08) and "only `tier_battery_limit`
    and `tier_lid_ignore` use the robust form" (2026-09-11 harvest); line 248
    is a plain `/^tier_lid_ignore\(\)/,/^}/`.
```
- **first seen:** 2026-09-12

## c079a0d5 · dedupe · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `memory-harvest 2026-09-11 — what the fleet transcripts held (Track A + B)` # `dedupe` # `project.md:3662-3666`
- **action:** dedupe
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `memory-harvest 2026-09-11 — what the fleet transcripts held (Track A + B)` (L3575, 11789 B)
- **survives:** the topical copy at `project.md:3017-3023`, under *RustDesk on g15…* — it alone names the `tier_gortex` precedent (untarring a pin unconditionally) and rejects per-asset `digest` pinning, and it sits in the section a future RustDesk session actually opens
- **why:** same decision, same reason, two copies. The dump copy is misfiled
  under `### Orca` and carries exactly one fact the survivor lacks — the observed
  rebuild dates — which is folded in rather than lost.
- **evidence:** `project.md:3017-3023` (survivor) and `project.md:3662-3666`
  (deleted). `awk '/RustDesk/{print NR}'` shows only these two statements of the
  rule.
- **bytes:** 936 → ~610
- **replacement:** `(none — deletion)` for `project.md:3662-3666`. **Fold into
  the survivor first**, at `project.md:3018`: insert the verbatim parenthetical
  `(rebuilt 2026-09-01 and again 2026-09-10)` after `replaced in place`, so the
  clause reads `…URL is stable but its BYTES are replaced in place (rebuilt
  2026-09-01 and again 2026-09-10); combine that with…`. **Carry before cutting.**
- **first seen:** 2026-09-12

## f6c079f9 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Доки роняет розетка, а не USB — и это два разных отказа (измерено 2026-09-10)` # `contradiction` # `project.md:3065-3068`
- **action:** contradiction
- **scope:** repo:machines — **and it has money attached**
- **apply on:** g15 (the marker), but the measurement is on **latitude**
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Доки роняет розетка, а не USB — и это два разных отказа (измерено 2026-09-10)` (L3049, 3322 B)
- **why:** the measured mechanism (a voltage dip shorter than the EC's AC-loss
  threshold) and the owner's 2026-09-11 statement (real home power outages)
  cannot both be simply true, and the two answers buy **different hardware**:
  an AVR-only UPS versus one specified for runtime/autonomy plus USB NUT for a
  graceful shutdown. **Three copies exist**, one of them auto-loaded every
  session, and they do not agree.
- **evidence:** `project.md:3065-3068` — dip shorter than the EC's threshold,
  *"Это и есть механизм"*; exactly one `ACPI: AC Adapter (off-line)` in six
  weeks, and not at a drop. Against `project.md:3752-3755` — *"confirmed by the
  owner on 2026-09-11 as **real home power outages**, not the brief voltage dips
  previously assumed"*. **Third copy, loaded every session:**
  `AGENTS.md:775-781`, which states the dip mechanism *and already prescribes the
  purchase* ("a UPS on the dock bricks closes the class"). Eight paired dock
  disconnects against one AC-off-line event is measured evidence against "real
  outage"; the owner's statement is evidence for it.
- **placement:** the marker goes in `project.md:3049` rather than `AGENTS.md`
  because that is where a dock session reads, and `AGENTS.md` is the copy a later
  pass would edit anyway once the pair is resolved.
  **`project.md:3752-3755` is neither moved nor deleted** — it sits inside the
  parked-host-facts block whose every fact is a last copy.
- **bytes:** 444 → ~1000
- **replacement — replaces `project.md:3065-3068`:**
```
- **`ACPI: AC Adapter [AC] (off-line)` за всё это время — РОВНО ОДИН раз
  (29.07T02:15), и не в момент падения.** Значит просадка короче порога, на
  котором EC замечает потерю AC: 65-ваттный кирпич ноутбука её переживает,
  дешёвые 12 В блоки доков — нет. Это и есть механизм.
  <!-- conflicts-with: "**the dual-dock disconnects were confirmed by the owner on 2026-09-11 as real home power outages**, not the brief voltage dips previously assumed" — этот файл, раздел «memory-harvest 2026-09-11 … (Track A + B)» → «Other boxes' host facts», и AGENTS.md *Key patterns* («the docks' cheap 12 V bricks dying on a dip … a UPS on the dock bricks closes the class»). Журнал за шесть недель даёт ОДИН `AC Adapter (off-line)` на восемь парных отвалов — настоящее отключение питания снимало бы AC каждый раз. Цена расхождения — покупка: AVR-UPS против «runtime/autonomy + USB NUT для graceful shutdown». Не разрешать по авторитету: замер — `journalctl --boot=all` по `AC Adapter` против времён `usb 4-*: USB disconnect`. -->
```
- **first seen:** 2026-09-12

## dc9d304c · dedupe · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Приёмка нового диска: identity-гейт впереди surface (2026-09-08)` # `dedupe` # `project.md:2905-2911`
- **action:** dedupe
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Приёмка нового диска: identity-гейт впереди surface (2026-09-08)` (L2850, 8780 B)
- **why:** three of the bullet's four claims are superseded — the bay layout, the
  forward instruction ("вернуть `immich-mirror` в стойку можно только после…":
  servarr moved, and the freed bay went to the archive instead), and the
  "g15-staging в единственном экземпляре" warning. Per this store's own rule at
  L3314 (*"Инструкция будущей сессии, ставшая ложной, опаснее устаревшего
  факта… Помечены закрытыми с датой, не вычищены"*) it is **struck with a date,
  not deleted**.
- **evidence:** `project.md:2905-2911` vs `project.md:3173-3175` + `AGENTS.md:786-788`
  (live topology: `u4-1:1` is HGST/`immich-2024-backup`, `u3-2.4:0` is
  immich-mirror in the NS1066 stopgap), `project.md:3088-3127` (servarr moved to
  wd8, 2026-09-10), `project.md:3279` (*"ждать освобождения `spare320` ради бэя
  Ugreen, возможно, не нужно вовсе"*), `project.md:2828-2835` (pgdata staging leg
  deleted 2026-09-10).
- **what is NOT asserted:** only the **186 G pgdata** leg is provably gone. The
  18 G `home-me` leg's fate is recorded nowhere in this slice, so the replacement
  says so rather than guessing — it could be the last copy.
- **bytes:** 764 → ~700
- **replacement — replaces `project.md:2905-2911`:**
```
- ~~**Свободных бэев нет: 8 ТБ занял бэй зеркала.** Док 4-1 — servarr +
  spare320, док 4-2 — новый 8 ТБ + immich-2024. Вернуть `immich-mirror` в
  стойку можно только после того, как ServarrMedia переедет на 8 ТБ и
  освободит свой бэй.~~ **ЗАКРЫТО 2026-09-10.** ServarrMedia переехал на wd8
  (раздел про ServarrMedia), а освободившийся HGST ушёл не под зеркало, а под
  вторую копию архива 1970–2024 (`/mnt/immich-2024-backup`). Живая расстановка
  бэев — в разделе про архив 1970–2024 и в AGENTS.md; ждать освобождения
  `spare320` ради бэя Ugreen, возможно, не нужно вовсе (раздел про 480 Мбит).
  Из `g15-staging` на зеркале удалена нога **`pgdata` (186 G), 2026-09-10**
  (см. «The DB leg is CLOSED»); о судьбе ноги **`home-me` (18 G)** записи нет —
  проверить на диске, прежде чем считать её и удалённой, и единственной копией.
```
- **first seen:** 2026-09-12

## b2014b67 · generalise · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `memory-harvest 2026-09-11 — what the fleet transcripts held (Track A + B)` # `generalise` # `project.md:3577-3595`
- **action:** generalise
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `memory-harvest 2026-09-11 — what the fleet transcripts held (Track A + B)` (L3575, 11789 B)
- **why:** `### The harvest machinery itself` is the **one subsection of this
  dated dump whose subject already has a topical `##` home elsewhere in the
  store**. Moving it lets the ingestion heading shed its only misfiled block
  without touching a single fact. Relocation, not deletion — every fact here is
  unique.
- **evidence:** `project.md:3577-3595` (4 bullets, 1278 B) against the topical
  home `project.md:3355` (`## memory-harvest / fleet-gather.sh gotchas (demoted
  from global.md 2026-09-11)`) and `project.md:3677` (`### Agent config`, inside
  the same dump).
- **bytes:** 1278 → 1278 (byte-neutral; the win is structural)
- **replacement:** (text moves verbatim; the map IS the change)
  - `project.md:3579-3582` "Run `/memory-harvest` BEFORE `memory-harvest` on the
    same box" → **`## memory-harvest / fleet-gather.sh gotchas`** (L3355). Its
    parenthetical *"(The `manifest.tsv` correction above is from the same run.)"*
    still resolves there — `manifest.tsv` is at L3366-3374 — but **re-read it
    after the move** rather than assuming.
  - `project.md:3583-3585` "latitude has no `~/.claude/projects` directory at
    all" → **L3355**.
  - `project.md:3586-3592` "Transcripts had a 30-day expiry until 2026-09-10" →
    **L3355**.
  - `project.md:3593-3595` "`enabledPlugins` in `agents/settings.json` loads at
    USER scope" → **`### Agent config`** (L3677), *not* L3355 — it is not a
    harvest fact.
  - Then delete the now-empty `### The harvest machinery itself` heading at L3577.
- **HAZARD for any relocation in this store:** cross-references here are
  **positional** ("см. раздел про гейты", "см. раздел про доки", "раздел про
  `.Mounts` ниже", "выше"). Re-point every one that crosses a moved boundary.
- **NOT A CANDIDATE, and this must not be re-derived next run:**
  `### Other boxes' host facts (parked here — their host-memory.md is
  branch-scoped)` at `project.md:3706-3755` says in its own text *"until then
  this is their only home"* — **every fact in it is by construction the last
  copy** and must never be deduped away.
- **first seen:** 2026-09-12

## 5b5d4e19 · compress · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `ServarrMedia переехал на 8 ТБ WD Blue (выполнено 2026-09-10)` # `compress` # `project.md:3116-3121`
- **action:** compress
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `ServarrMedia переехал на 8 ТБ WD Blue (выполнено 2026-09-10)` (L3088, 3448 B)
- **survives:** `/home/me/machines/AGENTS.md` *Key patterns* (L674-692) — loaded in every session, states the rule most fully, and already names `/mnt/xs` as the offending line **plus** the `rc >= 2` segfault refusal that the project.md copy omits
- **why:** third statement of one rule (a third mention sits at
  `project.md:3226-3232`). What is genuinely local — that the line is commented
  out because the disk is physically gone — is one sentence.
- **evidence:** `project.md:3116-3121` vs `AGENTS.md:674-692`
  (*"A stale fstab line used to switch this whole guard off… the `/mnt/xs` line
  had to be commented out for exactly that reason. The gate now compares
  candidate against current… It still refuses outright on `rc >= 2`"*), and
  `project.md:3226-3232`.
- **bytes:** 625 → ~255
- **replacement — replaces `project.md:3116-3121`:**
```
- **`/mnt/xs` в `/etc/fstab` закомментирован** — диск физически снят 2026-09-09.
  Механизм (одна чужая протухшая строка fstab вырубала
  `install-docker-ordering.sh` целиком; гейт с тех пор сравнивает кандидата с
  текущим файлом и отказывает на `rc >= 2`) — в AGENTS.md, *Key patterns*.
```
- **first seen:** 2026-09-12

## 15000ee6 · contradiction · /home/me/my/qaz-code/CLAUDE.md

- **id-inputs:** `/home/me/my/qaz-code/CLAUDE.md` # `CLI Commands` # `contradiction` # `qaz-code-CLAUDE.md:106-128`
- **action:** contradiction
- **scope:** repo:qaz-code — an **auto-loaded instruction file**, 64852 B, loaded in every session under that repo and its two worktrees
- **apply on:** g15 (the only box with `repo_groups: ["my"]`)
- **target:** `/home/me/my/qaz-code/CLAUDE.md`
- **anchor:** `CLI Commands` (L33, 4255 B)
- **why:** `## CLI Commands` states **two different signatures for `repo` and
  `umbrella`, 56 lines apart**, and an agent reading top-down hits the incomplete
  one first. This is a harvest that appended a correction and left the superseded
  text in place — the machine-written `conflicts-with` markers quote the
  superseded lines verbatim, so the tool knew and nobody closed the loop.
- **evidence:** `qaz-code/CLAUDE.md:50` + `:53` (the canonical fences) vs
  `:106-128` (the appended block); markers at `:127-128`:
  `<!-- conflicts-with: "python cli.py repo <root> [--scope codes,local,local-astana,...] [--no-repack]" -->`
  and `<!-- conflicts-with: "python cli.py umbrella <root> [--org kazakhstan-law]" -->`.
  Measured: `sed -n '106,128p' | wc -c` = 1180; L50 = 79 B; L53 = 53 B.
- **bytes:** 64852 → 64463 (−389, 0.6%)
- **replacement — THREE edits, one decision.**
  (1) replace L50 with:
```
python cli.py repo <root> [--scope codes,local,local-astana,...] [--no-repack] \
    [--built-on YYYY-MM-DD] [--render-workers N]
```
  (2) replace L53 with:
```
python cli.py umbrella <root> [--org kazakhstan-law] [--built-on YYYY-MM-DD]
```
  (3) replace L106-128 with:
````
One command the fences above do not name:

```bash
# Audit a rendered corpus for structural defects (needs the DB).
python cli.py audit-render [...]
```

`--built-on` (on `repo` and `umbrella`) names the annotated `build/` tag and
since 2026-09-10 reaches no committed blob — the scope READMEs carry no build
date at all any more. It defaults to today, which is what you want; how fresh
the *data* is rides in the tag's own watermark field. `--render-workers` is
`-1` by default, meaning read `ZANGOV_RENDER_WORKERS` and fall back to 4;
**`0` keeps the in-process path, which is what the determinism reference
runs**, so pass it when you are reproducing a recorded sha.
<!-- src: qaz-code 6eaadf7 | 2026-09-12 -->
````
  The `(on `repo` and `umbrella`)` clause is **required**: without it the prose
  trails an `audit-render` fence and reads as documenting *that* command's flags.
- **first seen:** 2026-09-12

## f13fc8e8 · contradiction · /home/me/my/qaz-code/CLAUDE.md

- **id-inputs:** `/home/me/my/qaz-code/CLAUDE.md` # `Tests` # `contradiction` # `qaz-code-CLAUDE.md:143-157`
- **action:** contradiction
- **scope:** repo:qaz-code — auto-loaded instruction file
- **apply on:** g15
- **target:** `/home/me/my/qaz-code/CLAUDE.md`
- **anchor:** `Tests` (L137, 1366 B)
- **why:** the section asserts the suite **is** three files and then, four lines
  later, that this is false — the file contradicts itself within one screen. The
  correction is right and the original enumeration is still useful as origin, so
  the fix is to mark it as origin in place rather than delete either half.
- **evidence:** `qaz-code/CLAUDE.md:143-147` (*"It covers the three pieces with
  non-obvious logic…"*) vs `:149-156` (*"The three-file list above is the suite's
  origin, not its current reach"*); machine-written marker at `:157` quotes the
  superseded sentence in full (342 B). Measured:
  `sed -n '143,157p' | wc -c` = 1328.
- **bytes:** 64852 → 64503 (−349, 0.5%)
- **replacement — replaces L143-157:**
```
The suite is pure unit tests — no database, no network, no Docker. It began as
three pieces with non-obvious logic: `tests/test_chunker.py` (anchor selection
and oversized-chunk splitting), `tests/test_sync_resilience.py` (page-skip /
retry behaviour in `iterate_documents` and `retry_failed_docs`), and
`tests/test_dashboard.py` (`DashboardState` transitions and bar rendering).

That three-file list is the suite's origin, not its current reach. It has
since grown to cover the repository build and its scope routing, the renderer
against frozen fixtures and goldens, the document split, the anchor grammar,
the blob cache, the render pool, the tag and umbrella writers, the delta-run
comparison, the CA pin and the client throttle. It is still hermetic — no
database, no network, no Docker — which is the property that matters and the
reason `render-capture` (the one DB-touching renderer command) is deliberately
outside it. <!-- src: qaz-code 6eaadf7 | 2026-09-12 -->
```
- **MEASURED NEGATIVE, worth recording so the next run does not re-open it:**
  both qaz-code `CLAUDE.md` items together save **738 B of 64,852 — 1.1%**. This
  file's size is **not meaningfully reducible** under the no-compressing-rules
  constraint. Its bulk is `## Architecture` (L159-718, 74% of the file), dense
  incident-derived rules, not narrative. Supporting measurement: 598 non-blank
  lines, 586 unique; the 12 duplicates are code-fence markers; **zero** non-blank
  lines over 40 chars repeat anywhere in the file. There is no internal verbatim
  duplication to remove.
- **first seen:** 2026-09-12

## 974de1d0 · contradiction · /home/me/my/qaz-code/CLAUDE.md

- **id-inputs:** `/home/me/my/qaz-code/CLAUDE.md` # `(whole file)` # `contradiction` # `qaz-baseline:849407c-detached`
- **action:** contradiction
- **scope:** repo:qaz-code — a **detached-HEAD worktree whose auto-loaded `CLAUDE.md` asserts the opposite of `main` in four places**
- **apply on:** g15 (the only box holding these checkouts)
- **target:** `/home/me/my/qaz-code/CLAUDE.md`
- **anchor:** `(whole file)` — the finding is about which revision of this file a
  session loads, not about a section of it
- **why:** `/home/me/qaz-baseline` is a **git worktree of `qaz-code`**, pinned 30
  commits behind `main` at a detached HEAD, **with no tag and no marker file**.
  Every session opened under it auto-loads instructions that contradict `main`.
  This is not fixable by editing text: an edit to the worktree's copy is lost on
  the next checkout, or lands on a branch nobody meant to change. **The fix is a
  tag or a marker file, and a human has to pick which.**
- **evidence:** measured 2026-09-12 on g15.
  ```console
  $ git -C /home/me/my/qaz-code worktree list
  /home/me/my/qaz-code   a9a1d5a [main]                     <- most complete
  /home/me/my/qaz-pool   47933ca [perf/parallel-render]     3 behind main, 0 ahead
  /home/me/qaz-baseline  849407c (detached HEAD)            30 behind main, an ancestor
  $ git -C /home/me/qaz-baseline describe --all --exact-match
  (nothing — no tag)
  ```
  All three remotes are `git@github.com:metheoryt/qaz-code.git`; `CLAUDE.md` is
  clean against HEAD in all three. The four contradictions the pinned copy
  asserts against `main`:
  - `embedding_model != EMBEDDING_MODEL` — main: *"there is no module-level
    `EMBEDDING_MODEL` constant"*
  - *"Layout under `laws/` (**12 dirs total**)"* — main: *"12 tier dirs. The
    **26** directories directly under `laws/` are the repositories themselves,
    one level up"*
  - *"**The past is preserved by** annotated `build/` tags"* — main:
    *"**designed, not yet built.** Verified 2026-09-11: zero tags in all 26
    published repositories"*
  - *"The corpus **self-hosts (no GitHub limits)**"* — main: *"**published on
    GitHub** — 26 public repositories under `kazakhstan-law` since 2026-09-09 —
    so GitHub's limits are live constraints"*
- **measured, and it rules out the obvious remedies:** no worktree holds
  unmerged content. `diff pool code` = 71 added, 0 removed — **qaz-pool is a
  strict subset of qaz-code**. Every line the worktrees have that `main` lacks is
  older text `main` has since edited. **Nothing to promote back, and no `dedupe`
  is possible**: writing "see qaz-code/CLAUDE.md" into a worktree copy dirties it
  against its own HEAD, and committing that would *delete* the content from that
  branch going forward. Pairwise shared lines: baseline∩code 520 (56,627 B),
  code∩pool 525, all three 520.
- **bytes:** n/a — this is a repo-state decision, not a text edit
- **replacement:** (none — a question for a human, with two answers and a reason
  each)
  1. **The pin is deliberate** — sitting beside `qaz-pool` on
     `perf/parallel-render`, `qaz-baseline` reads like a performance-comparison
     baseline, in which case **moving it forward destroys the comparison**. Then
     the fix is an annotated tag on `849407c` plus a one-line
     `qaz-baseline/BASELINE.md` saying what it is a baseline *for* and that its
     `CLAUDE.md` is frozen and not authoritative.
  2. **The pin is forgotten** — then `git -C /home/me/qaz-baseline checkout main`
     (or remove the worktree) and the four contradictions vanish with it.
  It cannot be told apart from outside the repo. Ask before doing either.
- **first seen:** 2026-09-12

## effa9c8c · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 8 — Prove the invariant held, then commit` # `skill` # `consolidate-phase.md:482-486`
- **action:** skill
- **scope:** repo:machines — the run's own brief
- **apply on:** g15 (or any box)
- **anchor:** `Step 8 — Prove the invariant held, then commit` (L458)
- **why:** the invariant check has a **false-positive mode the brief does not
  anticipate, and it fires as the most alarming possible result.** The check
  attributes any change to a memory store during the run to *the run* — "If
  either is not, the run edited a memory store" — but `~/machines` is a shared
  working tree and **another interactive session in the same repo can edit
  `.claude/memory/project.md` while Phase B is reading it.** That is not the
  `dotfiles-sync` case the brief already excuses (a merge commits, so the tree is
  clean either side of it); an interactive Lane-1 harvest write leaves the tree
  **dirty**, indefinitely. The run then reports its own invariant as violated,
  refuses to commit an otherwise-correct queue, and hands a human a scary first
  line pointing at the wrong culprit.
- **evidence:** this run, 2026-09-12 on g15. `before_repo` at Step 0 was empty;
  `after_repo` at Step 8 was ` M .claude/memory/project.md`. It was not this run:
  ```console
  $ stat -c '%y  %n' .claude/memory/project.md AGENTS.md provision/orca-serve.sh provision/orca-serve.test.sh
  2026-09-12 04:10:29  .claude/memory/project.md
  2026-09-12 04:10:16  AGENTS.md
  2026-09-12 04:11:40  provision/orca-serve.sh
  2026-09-12 04:06:39  provision/orca-serve.test.sh
  $ git diff --stat
   .claude/memory/project.md      |  42 +
   AGENTS.md                      |  10 +
   provision/orca-serve.sh        | 234 +++-
   provision/orca-serve.test.sh   |  36 +
  ```
  The added `project.md` section is `## Orca on g15 never self-updates: an
  EXTRACTED AppImage cannot (2026-09-12)` — a Lane-1 record of feature work
  (`ORCA_INSTALL_MODE`, 7 mutation-tested assertions) that Phase B neither did
  nor was tasked with; all nine pass-1 subagents were forbidden to write and each
  reported zero writes. And `ps` shows **three concurrent
  `claude --dangerously-skip-permissions` sessions with transcripts under
  `~/.claude/projects/-home-me-machines/`** (`96a76e02` = this run, plus
  `1abc7229` and `08aa9fe8`, both still being written at 04:16).
- **what this run did about it:** followed Step 8 literally — reported it as the
  report's first line, named the file, **committed nothing**, reverted nothing —
  and additionally copied `queue.md`, the run report and
  `docs/memory-consolidate/replacements/` to the scratchpad, because 61 items
  live in an uncommitted tracked file that a concurrent session's `git add -A`
  or `git checkout --` would absorb or destroy. **That backup step is not in the
  brief and it should be**, since "commit nothing" and "another session is
  editing this repo" together mean the night's entire output is unprotected.
- **run that hit it:** `docs/memory-consolidate/runs/2026-09-12.md`.
- **bytes:** n/a
- **replacement — replace the verdict paragraph at L482-486 ("Both diffs must be
  empty. …do not 'clean up' by reverting.") with:**
```
Both diffs must be empty. If either is not, **find out who wrote it before
calling it a violation** — `~/machines` is a shared working tree and another
session can be editing `.claude/memory/project.md` right now:

```bash
stat -c '%y  %n' ~/machines/.claude/memory/project.md      # when, to the second
git -C ~/machines diff --stat                              # what else moved with it
ps -eo pid,lstart,args | grep -c '[c]laude --dangerously-skip-permissions'
ls -lt ~/.claude/projects/-home-me-machines/*.jsonl | head # other live sessions
```

A change whose timestamp falls inside this run, alongside edits to files this
phase never touches (a provisioning script, a test, `AGENTS.md`), from a box
running more than one session, is **another session's work**. Say so, name the
file, and commit nothing either way — but report it as *concurrent edit*, not as
*this run edited a store*, because the two need different things from a human.
(The `dotfiles-sync` timer is not this case: a merge commits, so the tree is
clean on both sides of it.)

Whatever the cause, **do not "clean up" by reverting** — the edit may be the only
record of what went wrong, or someone else's uncommitted work.

**When you commit nothing, back the output up.** The queue is a tracked file with
this run's whole night in it, uncommitted; a concurrent session's `git add -A` or
`git checkout --` would absorb or destroy it. Copy `queue.md`, the run report and
`docs/memory-consolidate/replacements/` into the scratchpad and say where in the
report.
```
- **first seen:** 2026-09-12

## 57039cfc · skill · /home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md

- **id-inputs:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md` # `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` # `skill` # `consolidate-phase.md:328-349`
- **action:** skill
- **scope:** repo:machines — the Phase B brief itself
- **apply on:** g15
- **target:** `/home/me/machines/agents/plugin/skills/memory-harvest/consolidate-phase.md`
- **anchor:** `Step 5 — Standing checks (every run, regardless of what pass 1/2 found)` (L290, 3440 B)
- **why:** Phase A's `SKILL.md:49` says a `<!-- conflicts-with: "…" -->` marker
  **"is a work item for `/memory-harvest`, which owns deletion, merging and
  generalisation across the whole corpus."** This brief never mentions the string
  `conflicts-with` anywhere — no scan step, no standing check, no taxonomy note.
  So Phase A writes the markers and nothing drains them. They are a to-do list
  with no reader.
- **evidence — the run that hit it:** `runs/2026-09-12.md` (the 04:31 run, 20068 B)
  contains the string `conflicts-with` **zero times** while markers were already
  live in the corpus (`grep -c conflicts-with docs/memory-consolidate/runs/2026-09-12.md`
  → 0; the oldest surviving marker, `project.md:3519`, was written by `7a610ba`,
  Phase A of that same night). Live count on 2026-09-12 after this morning's
  Phase A: **19 markers** — `machines/AGENTS.md` 2, `machines/.claude/memory/project.md`
  11, `my/telegrind/.claude/memory/project.md` 4, `my/telegrind/CLAUDE.md` 2. Of
  those, exactly **two** are covered by an open queue item (`project.md:3519` by
  `60604a4f`, `project.md:4189` by `a216a4c2`) and both were reached by accident,
  through the store text rather than through the marker.
- **second, sharper half — a marker can be WRONG and nothing checks it.**
  `project.md:3487` quotes *"`git -C ~/machines pull --ff-only` … can abort on a
  clean tree"* but sits at the end of an unrelated sub-bullet about writing
  another box's host memory; the quoted bullet (L3393-3399) carries its own
  resolution and **no text between L3400 and L3486 mentions `ff-only` or
  `fast-forward` at all** (`grep -n 'ff-only\|fast-forward'` on the store:
  nearest other hits L2841 and L3459, neither contradicting). A reviewer sent
  there finds nothing to decide. Phase A knows this class exists — `c66abc2`
  ("point the mirror conflicts-with markers at the real text") repaired two
  Russian markers the same morning — but it repaired only the two it was looking
  at, and no later pass re-checks.
- **replacement — append as a new bullet at the end of `## Step 5`, after
  *"A store nobody reads"*:**
```
- **Drain the `conflicts-with` markers — they are Phase A's queue into this one.**
  Phase A never resolves a contradiction, it appends the new fact and marks the
  old text (`SKILL.md`: *"That marker is a work item for `/memory-harvest`"*).
  Nothing else reads them, so an undrained marker is a decision nobody will ever
  take.

  ```bash
  grep -rn 'conflicts-with:' $(bash "$D" scan | cut -f1) $(bash "$D" instructions | cut -f1)
  ```

  For each, resolve the quoted text to where it still lives — **normalise
  whitespace first**, because a store wraps prose and an exact substring match
  reports a false orphan (measured 2026-09-12: 11 of 19 markers looked orphaned
  under a literal `grep -F`, 2 under a whitespace-normalised one). Then:
  - quote resolves inside the corpus -> file one `contradiction` (or `delete`,
    when the new text verifiably supersedes), anchored on the section holding
    the **stale** text, discriminated by its line range.
  - quote resolves only to a file outside `scan`/`instructions` (a `README.md`,
    a spec) -> **not this phase's population**; say so in the report and file
    nothing.
  - quote resolves nowhere near the marker and nothing in the enclosing section
    contradicts it -> the marker itself is the defect; file it so a human can
    delete or move it.
  A marker already covered by an open item is suppressed like any other
  candidate — check the queue by TEXT, not only by id: the marker's anchor is
  the stale text's section, which is rarely the section an existing item names.
```
- **bytes:** 3440 -> ~5100 in Step 5 (+1660)
- **first seen:** 2026-09-12

## 15635b46 · promote · /home/me/.claude/memory/core.md

- **id-inputs:** `/home/me/.claude/memory/core.md` # `(branch: g15)` # `promote` # `core.md:55-57`
- **action:** promote
- **scope:** shared — `core.md` is injected VERBATIM into every session on every box
- **apply on:** g15  <- this box; `/dotfiles-promote` here, nowhere else
- **target:** `/home/me/.claude/memory/core.md`
- **anchor:** `(branch: g15)`
- **why:** the owner's own rule, written into `core.md` on this box at 08:19
  today, **exists on no other machine**. `core.md` is the one store injected in
  full in every session, so a non-negotiable that lives on one branch is enforced
  on one box and silently absent on the other four. This is not the
  already-rejected "branch is bigger than main" class: it is a merge-base line
  diff, the stricter test `a216a4c2` proposes as the standard.
- **evidence (merge-base, not size):**
  `merge-base origin/main origin/g15` = `21abe71`.
  `LC_ALL=C diff <(dotfiles show origin/main:.claude/memory/core.md) <(dotfiles show origin/g15:.claude/memory/core.md) | grep -c '^>'` -> **3 lines**,
  and they are exactly `core.md:55-57`:
  *"**Никогда не редактировать код в main checkout.** Любая правка — в git
  worktree или Orca workspace; в основном чекауте может идти чужая работа (и шла,
  2026-09-12). Его правило, 2026-09-12. Подробнее -> personality/habits.md."*
  Sizes: `origin/main` 3330 B, `origin/g15` 3664 B, `origin/latitude` / `origin/hub`
  3330 B (at main), `origin/desktop-wsl` 3385 B, `origin/air` 3004 B. Introduced by
  dotfiles commit `01565f1` (2026-09-12 08:19, g15 branch only).
- **paired with `4fb02c63`** — the bullet ends *"Подробнее -> personality/habits.md"*,
  and that `habits.md` section is unpromoted on the same branch. Promote both in
  one `/dotfiles-promote` run or `core.md` fleet-wide points at a section four
  boxes do not have.
- **budget check before promoting (both numbers, per Step 5):** file bytes
  **3664**, injected bytes **2942**
  (`bash ~/machines/agents/plugin/hooks/global-memory-load.sh ~/.claude core | wc -c`).
  The ~3.4 KB harness cap binds the injected number -> ~540 B of headroom, not
  urgent. The ~2 KB style budget binds the file number -> over, and open item
  `9b955990` already rules that "inside the cap and over the budget is the
  current state and a normal one". **No `compress` is proposed here**; this
  promote adds 334 B to four other boxes and that is inside the cap on all of
  them (largest other branch copy: `desktop-wsl` 3385 B).
- **bytes:** +334 B on `origin/main` and therefore on air, desktop, desktop-wsl,
  hub, latitude
- **replacement:** (none — a promote of the existing text verbatim)
- **first seen:** 2026-09-12

## 3b43d4ba · contradiction · /home/me/machines/AGENTS.md

- **id-inputs:** `/home/me/machines/AGENTS.md` # `Common Commands` # `contradiction` # `AGENTS.md:226`
- **action:** contradiction
- **scope:** repo:machines — an **auto-loaded instruction file**, so this is a standing context error for every session in this repo
- **apply on:** g15
- **target:** `/home/me/machines/AGENTS.md`
- **anchor:** `Common Commands` (L164, 7548 B) — the finding is the code comment at L226, under the `### Tests` sub-heading
- **why:** the file now asserts both halves of a mechanism. L226 tells a reader
  `roles.test.sh` "prints ALL PASS, nonzero on failure"; L287-295, added this
  morning, says **"`roles.test.sh` does not reliably print `ALL PASS`, and
  neither does every other suite… A loop that greps for that string undercounts
  failures — check each suite's exit code."** A reader who trusts the comment
  writes a green-looking loop that hides reds. Per this same file's own rule —
  *"If you catch this file asserting two incompatible things, the contradiction
  is the bug; do not pick the half that suits the task"* — the pair is filed, not
  resolved here.
- **evidence:** `AGENTS.md:226` (inside the `### Tests` fenced block) vs
  `AGENTS.md:287-295` + its marker `AGENTS.md:296`
  (`<!-- conflicts-with: "bash provision/tests/roles.test.sh      # prints ALL PASS, nonzero on failure" -->`,
  `<!-- src: machines 3816d27 | 2026-09-12 -->`). The correction is the newer and
  the measured one; the comment is the survivor only if someone re-measures it.
- **what a human decides:** keep the comment and delete the correction (only if
  `ALL PASS` is re-measured as reliable), or fix the comment. The cheap fix, if
  the correction stands:
- **replacement — replaces `AGENTS.md:226` verbatim:**
```
bash provision/tests/roles.test.sh      # check the EXIT CODE, not the output
```
  and the correcting paragraph at L287-295 then loses its `conflicts-with`
  marker, since the text it names is gone.
- **bytes:** 74 -> 72, and −~600 B if the now-redundant correction paragraph is
  folded down to one line. Net roughly neutral; the value is not bytes.
- **first seen:** 2026-09-12

## 8335998d · contradiction · /home/me/machines/AGENTS.md

- **id-inputs:** `/home/me/machines/AGENTS.md` # `Architecture` # `contradiction` # `AGENTS.md:629-632`
- **action:** contradiction
- **scope:** repo:machines — an **auto-loaded instruction file**
- **apply on:** g15
- **target:** `/home/me/machines/AGENTS.md`
- **anchor:** `Architecture` (L299, 40176 B) — the finding is under the `**`hosts/latitude/debian/`**` block, the `install-timers.sh` bullet at L629-632
- **does not overlap open item `fe27f639`**, whose range is the
  `restic-hub-selfcheck.sh` bullet (filed as `AGENTS.md:594-598`, now shifted by
  this morning's +118 lines) and whose action is `delete`.
- **why:** L629 writes a **count in prose** — "installs all **three** as system
  timers" — and L659-667, added this morning, states the opposite rule for the
  statusboard in the same block: **"The unit list is the script's own
  `UNITS`/`TIMERS` arrays… read those, never a count written in prose."** This
  file has already been burned twice by exactly this (its own *Tests* section
  records "16 recipes" and the "28 suites" that reached 30 of 40), and it tells
  the reader so three separate times. A hard-coded three is the same bug one
  paragraph away from the rule forbidding it.
- **evidence:** `AGENTS.md:629-632` — *"`install-timers.sh` + `systemd/` — installs
  all **three** as system timers (`mirror-refresh`, `archive-mirror`,
  `restic-hub-selfcheck`)"* vs `AGENTS.md:659-667` + its marker at `AGENTS.md:668`
  (`<!-- conflicts-with: "`install-timers.sh` + `systemd/` — installs all **three** as system timers" -->`,
  `<!-- src: machines 3816d27 | 2026-09-12 -->`).
- **note for the reviewer:** the three names are currently correct — the count is
  the defect, not the list. Deleting the names would lose the only record of
  which units latitude installs, so this is a rewrite, never a delete.
- **replacement — replaces `AGENTS.md:629-630` verbatim:**
```
- `install-timers.sh` + `systemd/` — installs latitude's timers as **system**
  units. **The set is the script's own unit list, never a count written here**
  (`mirror-refresh`, `archive-mirror`, `restic-hub-selfcheck` as of 2026-09-12);
```
- **bytes:** 232 -> 268 (+36). A correct pointer costs more than a wrong count.
- **first seen:** 2026-09-12

## 1272c058 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `memory-harvest / fleet-gather.sh gotchas (demoted from global.md 2026-09-11)` # `contradiction` # `project.md:3357-3360`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `memory-harvest / fleet-gather.sh gotchas (demoted from global.md 2026-09-11)` (L3355, 13182 B)
- **why:** one bullet states an absolute and refutes it thirty lines later
  without amending its own headline. L3357 says `SKILL_DIR`'s four-up **"resolves
  to `~/.claude/fleet.json` — which does not exist"**; L3383-3390 says the kernel
  resolves `..` physically after a symlink, so on `g614jv` the same expression
  **opened `/home/me/machines/fleet.json`** and "the local-only degradation is
  not universal". The headline is what a skimming reader and a
  REGISTER-style first-line read both take away, and it is the half that is
  wrong on at least one box.
- **evidence:** `project.md:3357-3360` vs `project.md:3383-3390`, marker at
  `project.md:3391` (`<!-- conflicts-with: "**Invoke `fleet-gather.sh` by its repo path, or pass `FLEET_JSON`.** It derives `SKILL_DIR` …" -->`,
  `<!-- src: airdrome c4d5423 | 2026-07-26 -->`). Both halves are dated
  measurements on different boxes, so neither is deletable: the 2026-07-26 one is
  the only record of the failure, the later one the only record that it is not
  universal.
- **what a human decides:** whether the surviving headline is "pass `FLEET_JSON`
  because it can break" (advice, always safe) or "it breaks" (a claim that is
  false on g614jv). The proposal keeps both measurements and demotes the claim to
  the advice.
- **replacement — replaces `project.md:3357-3360` verbatim (the bullet's opening;
  L3361-3390 are unchanged and the marker at L3391 is then removed):**
```
- **Invoke `fleet-gather.sh` by its repo path, or pass `FLEET_JSON` — the
  four-up derivation is NOT portable.** It derives `SKILL_DIR` with a plain
  `cd … && pwd` (logical, not `-P`). Whether that lands on
  `~/.claude/fleet.json` (absent) or on the real `~/machines/fleet.json` depends
  on the path layer: it failed where first seen 2026-07-26, and on `g614jv` the
  same expression opened the right file (measured, see the end of this bullet).
  So do not rely on either outcome. `fleet_hosts` then returns empty
```
- **bytes:** 279 -> 495 (+216)
- **first seen:** 2026-09-12

## 07e2fcbb · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `contradiction` # `project.md:977-987`
- **action:** contradiction
- **scope:** repo:machines — **security-relevant**; read this one before the byte counts
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737, 25858 B)
- **does not overlap** the two open `Backups` items: `83538d13` (contradiction,
  `project.md:849-854`), `b069cc28` (delete, `project.md:971-976`),
  `2a10559c` (delete, `project.md:942-945`), `7dc3f946`/`dd41f743` (compress,
  L800-803 / L901-906). This range L977-987 is untouched by all of them —
  `b069cc28` stops at L976, one line before it.
- **why:** three claims about latitude's restic REST hub were measured false on
  the box this morning, and one of them is a **safety posture** a reader would
  act on. The store says the hub is bound to `100.64.0.8:8001, not 0.0.0.0`, runs
  `--no-auth`, and therefore "reachability IS authorisation"; and that
  `--append-only` is deliberately NOT set. Live on 2026-09-12:
  `HostConfig.PortBindings` = `{"8000/tcp":[{"HostIp":"","HostPort":"8001"}]}` —
  a **wildcard** bind (`0.0.0.0:8001` and `[::]:8001`) — with
  `OPTIONS = --private-repos --append-only --prometheus` and htpasswd at
  `/data/.htpasswd`. The file also already contradicted itself before this
  morning: `project.md:1093` and `:2649` both say the hub serves `--append-only`.
  An agent trusting L977-987 concludes the LAN cannot reach the hub (it can:
  latitude has no host firewall at all, `iptables -P INPUT ACCEPT` plus a jump to
  `ts-input`, no ufw/nftables/firewalld) and that retention is manual (it is not:
  prune runs on latitude through per-client maintenance profiles
  `g614jv-maintenance`, `g513ie-maintenance`).
- **evidence:** `project.md:977-987` (the three stale claims) vs
  `project.md:3918-3931` in `Оффсайт, хаб и зеркало: что измерили 2026-09-12`,
  carrying all three markers at `project.md:3932`, `:3933`, `:3934`
  (`<!-- src: machines 3816d27 | 2026-09-12 -->`); plus the pre-existing internal
  disagreement at `project.md:1093` and `project.md:2649`.
- **one item, not three:** the three claims are one bullet-pair describing one
  container, and applying any one alone leaves the reader with a half-true
  posture — the worst of the three states.
- **replacement — replaces `project.md:977-987` verbatim:**
```
  - **`restic-server` REST hub** for other boxes — `vps/homeserver/restic-server`.
    **Measured on latitude 2026-09-12:** published on a **wildcard** bind
    (`HostConfig.PortBindings` = `{"8000/tcp":[{"HostIp":"","HostPort":"8001"}]}`,
    i.e. `0.0.0.0:8001` and `[::]:8001`), with
    `OPTIONS = --private-repos --append-only --prometheus` and htpasswd at
    `/data/.htpasswd`. So **authentication, not reachability, is what protects
    it** — and it has to be: latitude runs no host firewall at all
    (`iptables -P INPUT ACCEPT`, only a jump into `ts-input`; no ufw, no
    nftables, no firewalld), so a published port is open to every device on the
    home wifi.
    ~~bound to `100.64.0.8:8001, not 0.0.0.0`; runs `--no-auth`, so reachability
    IS authorisation; costs a boot race docker/tailscaled~~ — **retracted
    2026-09-12**, that describes a posture that was lifted. The tailnet-only
    bind is what the boot race belonged to; there is no such race on a wildcard
    bind.
  - **`--append-only` IS set** (see the OPTIONS above), and retention still
    works: `prune` runs on latitude through per-client maintenance profiles
    (`g614jv-maintenance`, `g513ie-maintenance`), each with its own key held
    locally — a client can never delete, the hub owner always can.
    ~~`--append-only` is deliberately NOT set: it would break `forget --prune`~~
    — **wrong twice, retracted 2026-09-12**: this file already said the opposite
    at `:1093` and `:2649`.
```
- **bytes:** 793 -> 1690 (+897). Byte-positive on purpose; the shorter version is
  the one that gets somebody's backups read off the wifi.
- **first seen:** 2026-09-12

## 836db99b · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Backups` # `contradiction` # `project.md:795-799`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Backups` (L737, 25858 B)
- **does not overlap** `7dc3f946` (compress, `project.md:800-803`), which starts
  on the line after this range ends, nor any other open `Backups` item.
- **why:** a **forward instruction that has become false** — the class this store
  itself calls more dangerous than a stale fact (`project.md:3314`: *"Инструкция
  будущей сессии, ставшая ложной, опаснее устаревшего факта"*). L797-799 says the
  offsite fix "remains cheap (rotate one dock's drive off-site)" and assigns it to
  Task 19. The owner rejected disk rotation outright on 2026-09-11 — *"езжу я раз
  в несколько месяцев, но не хочу таскать диски каждый раз"* — and the replacement
  design is an always-on box at the parents' house near Karaganda, logical name
  `offsite`, role `backup-offsite`, specced in
  `docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md` and planned
  in `docs/superpowers/plans/2026-09-12-village-offsite-backup.md`. An agent
  reading the old bullet proposes exactly what was already turned down.
- **evidence:** `project.md:795-799` vs `project.md:3937-3947` in
  `Оффсайт, хаб и зеркало: что измерили 2026-09-12`, marker at `project.md:3948`
  (`<!-- conflicts-with: "remains cheap (rotate one dock's drive off-site) rather than adding cloud/object storage" -->`,
  `<!-- src: machines 3816d27 | 2026-09-12 -->`). Corroborated in the repo itself:
  the `offsite-backup` branch merged as `f0d287e` ("the village offsite backup
  site, code half").
- **what survives:** the **gap** statement — every copy is in one apartment — is
  still true and is the reason the section exists. Only the remedy and its owner
  change. The struck text is kept with a date, per this store's own rule.
- **replacement — replaces `project.md:795-799` verbatim:**
```
- ~~Homeserver's immich backup targets `G:`/`H:`~~ — **superseded 2026-07-31**:
  g513ie has only `C:`; those drives now live in latitude's docks. **The offsite
  gap itself still stands** — every copy is in one apartment. ~~the fix remains
  cheap (rotate one dock's drive off-site) rather than adding cloud/object
  storage; Task 19 of the migration plan owns it~~ — **отвергнуто владельцем
  2026-09-11**: «езжу я раз в несколько месяцев, но не хочу таскать диски
  каждый раз». Замена — всегда включённая коробка в родительском доме под
  Карагандой (логическое имя `offsite`, роль `backup-offsite`): один раз
  засеивается привезённым диском, дальше получает дельты по оптоволокну. Дизайн
  `docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md`, план
  `docs/superpowers/plans/2026-09-12-village-offsite-backup.md`.
```
- **bytes:** 330 -> 900 (+570)
- **first seen:** 2026-09-12

## b09fa087 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Fleet network` # `contradiction` # `project.md:335-338`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L191, 40066 B)
- **does not overlap** the five open `Fleet network` items, whose ranges are
  L193-250 (`45e6a3cb`), L278-297 (`3b71c80d`), L301-314 (`90c837eb`),
  L471-480 (`7a8ce25a`), L532-546 (`131173da`) and L547-553 (`af15caff`).
  L335-338 falls in the gap between L314 and L471.
- **why:** the store asserts a **capability does not exist** that was measured
  existing this morning. L335-336: *"In Orca, the registered PATH **is** the
  environment — there is no environment / runtime / distro field"* (probed
  2026-07-26). L4076-4083: Orca on Windows has a per-project agent runtime —
  Windows, or a named WSL distro — and desktop's `machines` is set to
  `desktop-wsl`, so worktrees, terminals and the `claude` process all run inside
  the distro. An agent holding the old claim mis-reads where a desktop Orca
  session's code actually runs, which is the exact confusion `AGENTS.md` already
  warns about for this box ("on desktop means the distro, not the Windows
  profile").
- **evidence:** `project.md:335-340` vs `project.md:4076-4083`, marker at
  `project.md:4084` (`<!-- conflicts-with: "In Orca, the registered PATH *is* the environment — there is no environment / runtime / distro field" -->`,
  `<!-- src: machines 3816d27 | 2026-09-12 -->`). The 2026-07-26 probe is not
  deletable — the `projectHostSetup` shape it records (`projectId / hostId /
  path / kind / hookSettings`, `hostId` = `local` for Windows and WSL alike, and
  the per-`(projectId, path)` keying) is still the only write-up of that
  structure, and the newer bullet adds that **Orca keys projects by git remote**
  (`github:<owner>/<repo>`) and refuses a second path for the same repo.
- **what a human decides:** whether the 2026-07-26 shape still holds field for
  field, or only the "no runtime field" half has been superseded. The proposal
  assumes the narrower reading.
- **replacement — replaces `project.md:335-337` verbatim (L338-340 unchanged):**
```
- **In Orca the registered PATH used to BE the environment — that stopped being
  true.** Probed 2026-07-26: there was no environment / runtime / distro field,
  and a `projectHostSetup` carried only `projectId / hostId / path / kind /
  hookSettings`. **Superseded 2026-09-12** — Orca on Windows now has a
  per-project agent runtime (Windows, or a named WSL distro); see the
  *Orca's project model* subsection. What the 2026-07-26 probe still describes
  correctly is the record's own shape:
```
- **bytes:** 232 -> 520 (+288)
- **first seen:** 2026-09-12

## c15efa06 · contradiction · /home/me/machines/.claude/memory/project.md

- **id-inputs:** `/home/me/machines/.claude/memory/project.md` # `Гейт, который рапортует успех, ничего не сделав — общая форма (2026-09-10)` # `contradiction` # `project.md:3243-3244`
- **action:** contradiction
- **scope:** repo:machines
- **apply on:** g15
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Гейт, который рапортует успех, ничего не сделав — общая форма (2026-09-10)` (L3219, 4772 B)
- **why:** the section names an outstanding remedy — *"Настоящее лечение — увести
  зеркало с этого порта"* — for a problem that was cured two days later by a
  different fix. Measured 2026-09-10 and written up this morning: the hub was
  removed and the connectors re-crimped, the NS1066 now plugs straight into the
  laptop's USB3 port, negotiates 5000, `Cannot enable` is gone from the log,
  reads run at 80 MB/s (the 2.5-inch platter's own ceiling, not the bus) and a
  full `mirror-refresh` pass takes 31 seconds. The residual-risk paragraph is
  still correct about the self-healing receiver reporting `Result=success`; only
  its forward instruction is dead.
- **evidence:** `project.md:3243-3244` vs `project.md:3965-3972` in
  `Оффсайт, хаб и зеркало: что измерили 2026-09-12`, marker at `project.md:3973`
  (`<!-- conflicts-with: "Настоящее лечение — увести" (project.md, раздел «Гейт, который рапортует успех», продолжение строки: «зеркало с этого порта») -->`,
  `<!-- src: machines 3816d27 | 2026-09-12 -->`).
- **the marker's SIBLING is already covered, this one is not.** The same
  paragraph carries a second marker at `project.md:3974` quoting *"ждать
  освобождения `spare320` ради бэя Ugreen, возможно,"* — that text lives at
  `project.md:3279` and open item `dc9d304c` already cites it verbatim as
  evidence. Only the `:3243` half is unclaimed, which is why this is one item and
  not two.
- **replacement — replaces `project.md:3243-3244` verbatim:**
```
  след — строка `WARN … remounting once` в журнале. ~~Настоящее лечение — увести
  зеркало с этого порта~~ — **ВЫЛЕЧЕНО 2026-09-10 иначе**: хаб убрали, разъёмы
  переобжали, NS1066 воткнут прямо в USB3-порт (5000, 80 МБ/с, полный проход
  31 с) — см. раздел про 480 Мбит. Остаточный риск `Result=success` при этом
  никуда не делся и остаётся общей формой.
```
- **bytes:** 138 -> 420 (+282)
- **first seen:** 2026-09-12

## 67eec8cd · delete · /home/me/my/telegrind/.claude/memory/project.md

- **id-inputs:** `/home/me/my/telegrind/.claude/memory/project.md` # `Product invariants` # `delete` # `telegrind-project.md:8-14`
- **action:** delete
- **scope:** repo:telegrind — **the first queue item this repo has ever had**
- **apply on:** g15 (the only box with `repo_groups: ["my"]`; `telegrind` is checked out nowhere else)
- **target:** `/home/me/my/telegrind/.claude/memory/project.md`
- **anchor:** `Product invariants` (L6, 553 B)
- **why:** the section's two bullets describe a Sheets projection layer that
  `248fe9d` deleted whole. `## The workbook layer is gone (2026-09-11)` (L57)
  states it plainly: no `gspread`, no `projection` module, no `_config` /
  `_categories` worksheets, no `/link`, `/import`, `/rebuild`, `/reload`,
  `/unlink`; `/q` is the only command the router registers.
- **evidence of what supersedes it:** `telegrind/.claude/memory/project.md:59-66`
  vs the two stale bullets at `:8-11` and `:12-14`; both markers written by Phase
  A this morning at `:67` and `:68`
  (`<!-- src: telegrind 35574a2 | 2026-09-12 -->`).
- **NOT the last copy, and this is the load-bearing check:** the product
  invariant itself — *"Ничего из написанного не теряется"*, storage is
  unconditional into Postgres — is restated in the superseding bullet
  (*"Storage is unconditional into Postgres and stops there: the invariant
  survived the deletion, the projection did not"*). Only the **and-then-projects
  clause** is being removed. The `## Product invariants` heading keeps its
  reason to exist.
- **replacement — replaces `telegrind-project.md:8-14` verbatim:**
```
- **"Ничего из написанного не теряется"** is the product claim, not a slogan:
  every handler writes the message row to Postgres *unconditionally*, and that
  is where it stops — there is no projection layer any more (see *The workbook
  layer is gone*, 2026-09-11). Declining to extract (unknown command, voice,
  `??`) is never licence to drop the message.
```
- **bytes:** 456 -> 306 (−150), and the two markers at `:67-68` go with it
  (−~420 B in the superseding section, which no longer needs them)
- **first seen:** 2026-09-12

## aec2ecb9 · delete · /home/me/my/telegrind/.claude/memory/project.md

- **id-inputs:** `/home/me/my/telegrind/.claude/memory/project.md` # `Known drift` # `delete` # `telegrind-project.md:51-56`
- **action:** delete
- **scope:** repo:telegrind
- **apply on:** g15
- **target:** `/home/me/my/telegrind/.claude/memory/project.md`
- **anchor:** `Known drift` (L49, 338 B)
- **why:** the whole section is one bullet asserting that the root `CLAUDE.md`
  `## Architecture` section is stale — that it "still describes the
  `Outcome`/`Loan`/`Wish` `Sheet` subclasses and the `/start` onboarding FSM",
  and that the current shape is `llm.extract` -> `projection.apply_changes`. Both
  halves are now false. The `CLAUDE.md` Architecture section was rewritten and
  walks `middleware` -> `handlers` -> `store` -> `taxonomy` -> `extract` ->
  `query` -> `answer` -> `receipts` -> `coerce` -> `config` -> `models` -> `llm`;
  and **there is no `llm.extract` and no `projection.apply_changes` anywhere in
  the tree** — the drift note now names a shape more obsolete than the file it
  accuses.
- **evidence of what supersedes it:** `telegrind-project.md:79-82`
  (*"The root `CLAUDE.md` Architecture section describes the code that
  exists."*), marker at `:83`
  (`<!-- conflicts-with: "The `## Architecture` section of the root `CLAUDE.md` is stale as of 2026-09-10…" -->`,
  `<!-- src: telegrind 35574a2 | 2026-09-12 -->`).
- **last-copy check:** nothing here is the only record of anything. The section
  records a defect that no longer exists; the module walk it would have been
  useful for lives in `CLAUDE.md:81-189` itself.
- **deleting the whole `## Known drift` heading is correct**, not just the
  bullet: it has exactly one bullet and no other content. If the reviewer
  prefers to keep the heading as a slot for future drift, keep it with the
  bullet removed — either is fine, the bullet is the decision.
- **replacement:** (none — deletion of `telegrind-project.md:49-56`, heading
  included, plus the now-pointless marker at `:83`)
- **bytes:** 338 -> 0 (−338), plus −~370 B for the marker line
- **first seen:** 2026-09-12

## e5973531 · contradiction · /home/me/my/telegrind/CLAUDE.md

- **id-inputs:** `/home/me/my/telegrind/CLAUDE.md` # `Architecture` # `contradiction` # `telegrind-CLAUDE.md:96-120`
- **action:** contradiction
- **scope:** repo:telegrind — an **auto-loaded instruction file** (16410 B, loaded in every session opened in this repo)
- **apply on:** g15
- **target:** `/home/me/my/telegrind/CLAUDE.md`
- **anchor:** `Architecture` (L81, 5415 B)
- **why:** the file names two different columns as the thing that selects the
  extraction tail. `## Architecture` says it twice — the `/q` flow at L96
  (*"store the question, `extractable=False`"*) and the ingestion walk at L120
  (*"The slash catch-all first (stored with `extractable=False`, so a command
  never coins a category)"*). `## Message routing — the verdict column` (L295,
  added this morning) says **`message.verdict` — not `extractable` — is what
  selects the extraction tail**: a never-null string of `fact` / `question` /
  `talk` / `system`, only `fact` entering `unextracted_tail`; `/q` writes
  `question`, every other slash command and everything the bot sends writes
  `system`. `extractable` is still written in step with it and **is no longer
  read by anything** — the expand half of a deliberate expand/contract migration.
- **why this one bites harder than a stale fact:** the two flags currently agree,
  so nothing fails. When the contract half lands and `extractable` is dropped, a
  reader who learned the mechanism from `## Architecture` has no way to know
  which of the two the code was actually keyed on.
- **evidence:** `telegrind-CLAUDE.md:96` and `:120` vs `:297-305`, with markers
  at `:306` and `:307`
  (`<!-- src: telegrind db9de98 | 2026-09-12 -->`); the reasoning is written out
  in `docs/superpowers/specs/2026-09-11-claude-meta-layer-design.md`.
- **replacement — two one-line edits, applied together:**
```
# replaces telegrind-CLAUDE.md:96
  → handlers/query.py               # store the question, verdict="question"
```
```
# replaces telegrind-CLAUDE.md:120-121
**`telegrind/bot/handlers/handlers.py`** — ingestion. The slash catch-all first
(stored with `verdict="system"`, so a command never coins a category — see
*Message routing*), then
```
- **one item, not two:** applying one edit and not the other leaves the file
  still disagreeing with itself, in the same section.
- **bytes:** 175 -> 214 (+39)
- **first seen:** 2026-09-12
