# dream — open decisions

Written by `/dream`, applied by `/dream-apply`. **Append-only from the run's
side**: a run never rewrites or reorders an existing item, so notes added by
hand survive. An item leaves this file only through `dream.sh decide`.

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
- **replacement:** (none — the action is an **attended** `/kb-refresh` run on g15)
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

## 98c3201a · demote · /home/me/.claude/memory/global.md

- **action:** demote · **scope:** shared → repo:card-processing
- **apply on:** whichever box has the `card-processing` checkout — **not g15**.
- **why:** this is **not** a backend-api row — it is about the `card-processing`
  checkout, whose audit doc (`wsa-code-audit-2026-08-24.md`) already sits beside it, and
  the section's own text draws the boundary ("Pure specifics stay in that repo… don't put
  Pure billing internals in these memory files"). A biographical/one-repo section does not
  need to be on every fleet box every session.
- **evidence:** global.md:1468-1495 · its own boundary statement at global.md:1475-1479
- **bytes:** 2177 → 0 in global
- **carry first:** verbatim `sed -n '1468,1495p'` (unmodified store) written to
  `<card-processing checkout>/.claude/memory/project.md` as `## What this project is, and
  what the audit found (2026-08-24)`. **Two bullets must survive verbatim wherever it
  lands** — they are what prevents a future wrong attribution:
  `**AES-ECB for PAN-at-rest was the project head's decision, not his.**` and
  `**Three of seven audit findings needed context that exists nowhere in the repo** … Ask
  him before concluding on a decision that looks odd in this codebase.`
- **replacement:** (none — deletion after the carry)
- **first seen:** 2026-09-11

## 8dd3022d · demote · /home/me/.claude/memory/global.md

- **action:** demote · **scope:** shared → host (desktop)
- **apply on:** **desktop** — not this box.
- **why:** two blocks whose mechanism is dead and whose remainder is host-local. Accept/reject each part independently.

### Part 1 — the `orca-profile-harvest.sh` pointer (416 → 0)
`agents/orca-profile-harvest.sh` was deleted 2026-09-09 with the other two
`orca-profile-*.sh` scripts, and no box had a `~/.claude-profiles` when that was
checked. What remains is a desktop-only location pointer — and it may be the **last
surviving Pure profile copy**, so it must be carried, not dropped.
- **evidence:** global.md:595-600 · AGENTS.md (2026-09-09 deletion) · probed 2026-09-11 g15: `~/.claude-profiles` and `machines/agents/orca-profile-*` both absent
- **carry first / replacement:** (delete from global.md; move this verbatim into **desktop's** `host-memory.md`:)
- **Last Pure profile copy on this box:** `~/.claude-profiles/pure`, a stale
  snapshot from the deleted `orca-profile-harvest.sh` (the WSL account dir was
  deleted 2026-08-04), plus a full tarball in
  `~/.claude-migration-backup-20260804/`. Confirm both still exist before relying
  on either.

### Part 2 — the multi-account plan, superseded twice (1098 → 292)
"abandoned" (2026-08-04), "partly reversed" (2026-08-20), and since 2026-09-09 the
fleet uses Orca's own account switcher — mirror scripts deleted, `claude-accounts`
empty on air and absent on g15. The `~/.claude-personal` config dir and the
`.claude-profile` wrapper were never built.
- **evidence:** global.md:551-565 · AGENTS.md (2026-09-09)
- **replacement:**
- **One Claude account per machine; account selection is Orca's own switcher.**
  The 2026-08 plans for a global multi-account merge and for a `.claude-profile`
  wrapper setting `CLAUDE_CONFIG_DIR` per repo were both superseded 2026-09-09 and
  were never built. Per-machine account layout is a host-memory fact — check the
  box, not this file.
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

## 489f253b · contradiction · /home/me/my/qaz-code/CLAUDE.md

- **action:** contradiction · **scope:** repo:qaz-code · **59.5 KB auto-loaded every session — the largest instruction file in the corpus**
- **why:** two incompatible-assertion pairs. Accept/reject each part independently.

### Part 1 — "self-hosts, so GitHub limits don't apply"
Under `### Why rebuild from scratch instead of incremental updates` the file says the
corpus *"self-hosts (no GitHub limits), so size/force-push restrictions don't apply"* and
defers README wording to *"if/when the repo is published"* — while the **same file** sizes
the repository split against *"GitHub's 1 GB recommendation"* (L176) and sets the 128 KiB
part budget *"measured against the published `codes`"* and GitHub's render ceiling
(L501, L549). Verified: `~/kazakhstan-law` holds **26 published scope repositories**,
public since 2026-09-09. **The file's entire split-and-budget design is driven by limits
this sentence says do not exist.**
- **evidence:** qaz-code/CLAUDE.md:660 · :176, :501, :549 · qaz-code project.md:120-129
- **bytes:** 155 → 316
- **replacement:**
The corpus is published on GitHub — 26 public repositories under `kazakhstan-law` since 2026-09-09 — so GitHub's limits are live constraints rather than hypothetical: they are what the repository split and the 128 KiB part budget are sized against, and the force-push expectation is stated in every scope README.

### Part 2 — do the `build/YYYY-MM-DD` tags exist?
L668 states **as settled mechanism** that *"the past is preserved by annotated
`build/YYYY-MM-DD` tags, never by the branch"*, and that the build date *"moved out of the
READMEs and into those tags"*. The repo's memory store says ***"no repository carries any
tag"*** — Task 7 step 1 of the incremental-updates plan, to be done before `main` ever
moves again. Checked directly: `git tag` returns **zero in all 26 repositories**. Two
auto-loaded files disagree about whether the corpus's only history-preservation mechanism
exists at all.
- **evidence:** qaz-code/CLAUDE.md:668 · qaz-code project.md:120-129 · `git tag` in all 26 repos → empty
- **bytes:** 513 → 710
- **replacement:**
**The past is preserved by annotated `build/YYYY-MM-DD` tags, never by the branch — designed, not yet built.** Verified 2026-09-11: zero tags in all 26 published repositories; this is Task 7 step 1 of the incremental-updates plan and must land before `main` ever moves again. One tag per build, never deleted, carrying the build date, the sync watermark, the divergence date and the reason class — that last pair because a Tier 1 title correction rewrites every SHA from its act's first date forward while `git diff` stays empty, which is indistinguishable at a glance from a determinism regression. The build date moved out of the READMEs and into those tags for the same reason it had to leave the bytes.
- **first seen:** 2026-09-11

## 0165c530 · contradiction · /home/me/my/qaz-code/CLAUDE.md

- **action:** contradiction · **scope:** repo:qaz-code
- **why:** two more pairs. Accept/reject each part independently.

### Part 1 — two different comparands for one re-embed trigger
Within `### Retrieval / RAG` the trigger is written `embedding IS NULL OR embedding_model
!= EMBEDDING_MODEL`; **eleven lines later** `### Embedding providers` says `provider.name`
*"is the only thing distinguishing two models' vector spaces — both the re-embed trigger
in `embed_pending_chunks` and the vector-leg filter in `hybrid_search` compare against
it"*. **Tiebreak:** no module-level `EMBEDDING_MODEL` constant exists
(`indexing.py:236` compares `is_distinct_from(provider.name)`), so L304 is the stale half
— hence a replacement rather than a blind pick. The repo's memory store carries a **third**
copy of the stale form at :210-213.
- **evidence:** qaz-code/CLAUDE.md:304 vs :328-332 · qaz-code project.md:210-213 · `indexing.py`:236
- **bytes:** 221 → 323
- **replacement:**
  - `embed_pending_chunks()` is remote, costly and fallible. Its trigger is `embedding IS NULL OR embedding_model IS DISTINCT FROM provider.name` (see "Embedding providers" below — there is no module-level `EMBEDDING_MODEL` constant), so swapping the model is a batched re-embed of stale rows rather than a full re-chunk.

### Part 2 — `laws/` layout describes the pre-split tree
Under `### File Organization`, *"Layout under `laws/` (12 dirs total):"* describes the
pre-split tree. Since the 2026-08-18 split — documented 400 lines earlier in the **same
section** — `<root>` is *"the parent directory, not a repository"* and `laws/` holds **26
repository directories**; the 12 tier dirs live one level down. Confirmed on disk.
**Only the containment framing is wrong** — the FORM→tier list under it is live.
- **evidence:** qaz-code/CLAUDE.md:579 vs :143-146, :186-188 · `~/kazakhstan-law/` → 26 scope dirs
- **bytes:** 37 → 144
- **replacement:**
Layout *inside each scope repository* — 12 tier dirs. The 26 directories directly under `laws/` are the repositories themselves, one level up:
- **first seen:** 2026-09-11

## baa736d5 · dedupe · /home/me/my/qaz-code/CLAUDE.md

- **action:** dedupe · **scope:** repo:qaz-code
- **survives:** `qaz-code/CLAUDE.md` (both copies are auto-loaded; the GIN write-up is misplaced, not redundant in content)
- **why:** the GIN-index drop is measured **twice**. `### Key Models` ends the `first_seen`
  bullet with *"that ordering is what took the run from 27 hours to 22 seconds once the
  GIN index on `elements` was gone"*; `### Content Rendering` carries the full write-up
  with the same two numbers over the same 806,735 rows. Bytes are small (~120) — **the
  real problem is placement**: the full paragraph is a `models.py` / database fact sitting
  under the `convert.py` heading because the paragraph above it happened to mention a
  containment query.
- **evidence:** qaz-code/CLAUDE.md:482-490 · :388 (tail clause)
- **bytes:** 120 → 0
- **replacement:** (none — delete the duplicated clause at :388; **move** the 482-490
  paragraph under `### Key Models`, where `models.py` already keeps the recreate statement
  in a comment. Leave the distinct ordering rule — column before index, or every write is
  a non-HOT update — where it is.)
- **first seen:** 2026-09-11

## b43527e5 · delete · /home/me/my/qaz-code/.claude/memory/project.md

- **action:** delete · **scope:** repo:qaz-code
- **why:** a migration narrative whose outcome is settled, and **every load-bearing claim
  in it is now false** against the repo's own auto-loaded CLAUDE.md:
  it says 89,343 acts / 274,073 versions / "roughly 42%" (CLAUDE.md records **211,892 acts
  and 806,735 versions**); *"`cli.py chunk` had **never been run**"* (25,468,309 chunks
  over 524,587 versions, default-scope embed pass done 2026-08-11/12); *"Local embedding
  provider is planned but not started"* (`tools/zangov/embeddings.py` ships both
  providers); and it asks someone to *"add an `embedding_model` filter"* to `search.py`
  (the guard is in, and raises). **It is auto-loaded every session in this repo alongside
  the correct figures.**
- **evidence:** qaz-code project.md:197-220 · qaz-code/CLAUDE.md:309-375, 388
- **bytes:** 1564 → 0
- **replacement:** (none — deletion)
- **note:** a second agent this run proposed `compress` on this same section with a
  3-fact keep-list (mixed-vector-space ranking, shared `EMBEDDING_MODEL`, incremental
  chunk/embed, tmux + `--start-page N`). **The two proposals disagree on whether anything
  survives** — this one says CLAUDE.md already carries all of it. Resolve that before
  applying either: if CLAUDE.md does carry them, delete; if not, compress.
- **first seen:** 2026-09-11

## 9e7161ce · dedupe · /home/me/my/qaz-code/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:qaz-code
- **survives:** `qaz-code/CLAUDE.md` — rules live there, at the place a reader editing that code will be
- **why:** five rules restate rules CLAUDE.md already owns, **in fuller form**: the
  `indexing.py` ↔ `Act.is_amendment` SQL mirror (CLAUDE.md:305, :618), `joint_key()` /
  Windows `MAX_PATH` (:603), `--unchanged-streak-stop` after a backfill (:42-44, :135),
  `--workers N` buying no throughput (:638), and the 2026-07-29 source-IP filter (:640).
  Both files are auto-loaded in every session in this repo, so each is paid for twice.
- **TWO BULLETS MUST STAY — do not delete the whole section:** "the generated repo is
  disposable, the DB is not / `laws/` is gitignored here", and the "routing around a block
  is off the table" judgement. Neither is in CLAUDE.md.
- **evidence:** qaz-code project.md:232-235, 236-238, 242-245, 246-248, 249-253 · qaz-code/CLAUDE.md:305, 618, 603, 42-44, 638, 640
- **bytes:** 1413 → 0 (for the five duplicated bullets only)
- **replacement:** (none — deletion of the five; keep the two named above)
- **first seen:** 2026-09-11

## c84614b2 · compress · /home/me/my/qaz-code/.claude/memory/project.md

- **action:** compress · **scope:** repo:qaz-code
- **why:** the section's own opening says its motivation dissolved, and **it dissolved
  again** when the WSL checkout it was measured against was destroyed 2026-09-07. Its
  Docker-Desktop-shared-engine paragraph is now simply **false** on g15 (native engine, no
  Windows host), while the path-length measurement and the missing `.gitattributes` are
  real corpus properties worth keeping.
- **evidence:** qaz-code project.md:258-290 (esp. 279-288) · `test -d /mnt/c` → no-c ·
  `uname -a` → `Linux g513ie 7.0.0-31-generic` · `command -v docker` → `/usr/bin/docker` (native)
- **bytes:** 2132 → 1406
- **replacement:**
## Corpus path-length invariant (measured 2026-08-20)

Measured for a Windows-checkout plan that has since dissolved twice over — the
real problem was per-project Claude auth, and the WSL checkout it was to sit
beside was destroyed with the 2026-09-07 g513ie reinstall. The corpus property
is what survives:

- **The generated corpus is Windows-clean by design, not luck.** Across all
  108,334 paths in a full `laws/` build: max path length **199** (median 149,
  p99 190), zero over 200, zero forbidden characters (`: * ? " < > |`), zero
  components ending in a dot or space, zero reserved names (`CON`, `NUL`,
  `COM1`…), zero case collisions, zero non-ASCII. That 199 is what
  `JOINT_INLINE_LIMIT = 3` buys. Against the 260 limit, **60 characters remain
  for the clone root**, so any Windows checkout must sit near the drive root.
- **There is no `.gitattributes`** — Git for Windows defaults `core.autocrlf=true`,
  so a native clone would check out CRLF against LF here, silent divergence in a
  repo whose product is generated text. One committed line (`* text=auto eol=lf`)
  fixes it, not per-machine config.
- The repo itself is trivially portable: 78 tracked files, 760 KiB pack, longest
  tracked path 67 chars, no symlinks.

The Docker-Desktop-shares-one-engine paragraph is deleted: there is no Docker
Desktop and no Windows host on g15, and the general trap lives in global memory.
- **first seen:** 2026-09-11

## f552b204 · dedupe · /home/me/my/qaz-code/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:qaz-code · **survives:** `qaz-code/CLAUDE.md`:12-14
- **why:** the compose-project-name bullet is a near-verbatim restatement of the repo's own
  `CLAUDE.md`, auto-loaded unconditionally in every session here. The CLAUDE.md copy
  survives because it sits next to the `docker compose up -d` command a reader actually
  runs; the memory copy adds nothing.
- **evidence:** qaz-code project.md:21-24 · qaz-code/CLAUDE.md:12-14
- **bytes:** 1346 → 1060
- **replacement:**
## Working in this repo

- **Trunk-based, and branches stay local** (2026-08-01). Work lands on `main`.
  A worktree carries a *local* branch that is never pushed; either commit into
  `main` directly, or commit on the branch and merge it in, then remove the
  worktree together with its branch. `main` is the only ref pushed to `origin`.
  Pushing a feature branch and deleting it from the remote afterwards is churn
  this repo does not want.
- Everything runs through `uv`: `uv sync`, `uv run pytest`, `uv run ruff check .`,
  `uv run ruff format .`. Python 3.14+ is a hard floor (`requires-python`).
- `uv run pytest` is fast and hermetic — no DB, no network, no Docker. There is no
  integration suite, so a green test run says nothing about ingestion actually
  working against zan.gov.kz.
- `.gitignore` excludes `.claude/*` (machine-local config) with explicit negations
  for the two knowledge-base files: `.claude/kb-harvest-state.json` and
  `.claude/memory/project.md`. Adding another tracked file under `.claude/` needs
  its own negation line.
- **first seen:** 2026-09-11

## 6045d1e8 · generalise · /home/me/my/qaz-code/.claude/memory/project.md

- **action:** generalise · **scope:** repo:qaz-code
- **why:** the headline is a **WSL2 VM freeze on a machine that no longer exists** — this
  project moved to native Ubuntu 2026-09-07, so `Wsl/Service/0x8007274c` cannot recur here
  and a session reading this will chase a dead symptom. The DB-write-bound mechanism
  underneath is host-independent and is the part worth carrying.
- **evidence:** qaz-code project.md:331-341 · `test -e /proc/sys/fs/binfmt_misc/WSLInterop` → NOT-WSL · `uname -a` → `Linux g513ie 7.0.0-31-generic` · the same store at :76-80 records the move
- **bytes:** 963 → 849
- **replacement:**
## Known issues (operational)

- **A long `sync` is DB-write-bound, and that is the portable half.**
  `process_doc` commits per document, so a multi-day backfill is a sustained
  WAL-fsync stream into the pgvector container. Candidate sync-side fixes (batch
  commits; `synchronous_commit=off` for the bulk load) are in
  `docs/known-issues/sync-wsl-freeze.md`.
- The symptom that produced that doc — the whole WSL2 VM freezing
  (`Wsl/Service/0x8007274c`, 2026-08-06, load 84 → 0 on killing the distro) —
  was a **WSL2 sparse-VHD** amplification of the write load. This project runs on
  native Ubuntu on g15 since 2026-09-07, so it cannot recur here; the doc's
  `~/bin/wsl-loadwatch.sh` and the `.wslconfig` mitigation on `desktop` apply only
  to a WSL box. Treat heavy sync I/O as a real cost on any host, the freeze as
  WSL-specific.
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

## aed78e2f · delete · /home/me/.dotfiles

- **action:** delete · **scope:** the dotfiles bare repo (a branch, not a file)
- **apply on:** any box (it is a remote-ref deletion), but it is a **human's call**
- **why:** `origin/g15-wsl` is a **dead branch that holds zero unique facts.** The distro
  was destroyed 2026-09-07. The skill's own Step 3b warns that *"a retired box's branch
  can be the last copy of a fact"* — so this run checked rather than assumed, **by blob
  hash**, and the answer is that nothing on it is unique.
- **evidence:** `ls-tree -r --full-tree origin/g15-wsl -- .claude/memory` → `core.md`
  `d26f23b6`, `global.md` `dd800fdc`, `habits.md` `825483fb`, `practices.md` `c193248a`,
  `tone.md` `8fc67df2`, `values.md` `93a920d1` — **every one byte-identical to
  `main`'s**. It carries **no `.claude/host-memory.md` at all**, so there is no host-local
  store to rescue. `merge-base --is-ancestor main origin/g15-wsl` → true, 0 ahead / 0
  behind. Tip 2026-08-27.
- **contrast, so the check is not mistaken for a blanket rule:** `origin/desktop-wsl` is
  alive and holds `pure/backend-api/.claude/memory/project.md` (58333 B) that exists on no
  other branch — **never delete a branch without running this hash comparison first.**
- **bytes:** n/a
- **replacement:** (none — the action is `git push origin --delete g15-wsl` on the
  dotfiles remote, plus retiring the dead Headscale node. Do NOT do it unattended.)
- **first seen:** 2026-09-11

## f7082e6e · skill · /home/me/machines/agents/plugin/skills/dream/SKILL.md

- **action:** skill · **scope:** repo:machines
- **run that hit it:** `docs/dream/runs/2026-09-11.md` (the first run)
- **what the run could not do:** **the `(target, anchor, action)` id triple cannot express
  more than one finding per section per action, and `index` cannot name half the places
  findings actually live.** Three concrete failures tonight:
  1. **Same-triple collisions.** `Fleet network` (39 KB, the largest section in the
     corpus) produced **three** distinct `contradiction` findings and **three** distinct
     `delete` findings. `Repo tooling & scripts` produced three `delete`s; `Backups` two
     `contradiction`s; `Fleet migration 2026-07` two `compress`es and two
     `contradiction`s. Every one after the first would have been **suppressed as `open`**
     against its own sibling. The run worked around it by merging same-triple findings
     into one item with numbered `### Part N` sub-decisions — which **violates the
     skill's own "one item, one decision"** and forces a human to accept or reject parts
     inside a single ledger entry the ledger cannot represent.
  2. **`index` lists `##` only, but findings land under `###`.** A subagent returned the
     anchor `A WSL-era shim survived the native reinstall and shadowed xdg-open
     (2026-09-08)` — real, at project.md:2798, but a `###`, so absent from `index` output.
     The run remapped it to the enclosing `##`. Nothing in the skill says to; a different
     night will map it differently and produce a second id for one finding — **exactly
     the "comes back forever" failure Step 6 exists to prevent.**
  3. **Whole-file and whole-branch findings have no anchor at all.** The fleet pass
     (Step 3b) is *built* to produce them — unpromoted drift on a branch, a dead branch, a
     store with no home — and the item shape assumes target+heading. The run invented
     `(whole file)` and `(branch: <name>)` and wrote the convention into its report so the
     next run can match it, but **a convention that lives only in a run report is not a
     convention.**
- **evidence:** this run filed 127 items; ids `452333da`/`bf5d7852` (Fleet network),
  `5980c12b`/`33fcd037` (Repo tooling), `51df5bf5`/`0631997a` (Backups) are the merged
  multi-part items · `dream.sh index /home/me/machines/.claude/memory/project.md` → 39
  rows, all `##` · `grep -n 'WSL-era shim survived' .claude/memory/project.md` → `2798:###`
- **proposed changes (a human picks; do NOT self-apply):**
  - Make the id a **four**-tuple by adding a short discriminator — the finding's first
    evidence line range, e.g. `project.md:465-474`. It is already in every row, it is
    stable across nights as long as the section is unedited, and it makes one item per
    finding possible again.
  - Either teach `dream.sh index` to emit `###` rows (with their level), or state in
    Step 6 that a `###` finding uses the enclosing `##` and names the `###` in the `why`.
  - Write the whole-file / whole-branch anchor convention into the Step 6 table as a
    fourth row, so it is not re-invented each night.
- **first seen:** 2026-09-11

## 35ce7179 · skill · /home/me/machines/agents/plugin/skills/dream/SKILL.md

- **action:** skill · **scope:** repo:machines
- **run that hit it:** `docs/dream/runs/2026-09-11.md`
- **what the run found wrong:** **Step 3b's worked example cites a branch that no longer
  exists**, and its general claim about dead branches was **false for the one dead branch
  the fleet actually has** — so a run following it literally looks for a ref that is gone
  and carries an expectation the evidence contradicts.
  - The text says: *"`origin/server` (2026-07-28) still holds a 4109 B
    `pure/backend-api/.claude/memory/project.md` that exists on no live branch;
    `origin/g15-wsl` is likewise dead."* **`origin/server` is not in the branch list at
    all.** It was deleted at some point after the 2026-08-27 rename.
  - `origin/g15-wsl` **is** still there and **holds zero unique content**: all six shared
    stores are byte-identical to `main`'s by blob hash, and it carries no
    `host-memory.md`. So the "a retired box's branch can be the last copy of a fact"
    warning, stated with these two as its evidence, currently has **neither** example.
  - The live instance of that warning is a **different** branch: `origin/desktop-wsl`
    holds `pure/backend-api/.claude/memory/project.md` at **58333 B**, tracked on no other
    branch and **not on `main`**. That is the one that matters, and it is not named.
- **evidence:** `git --git-dir=$HOME/.dotfiles branch -r` → `air desktop desktop-wsl g15
  g15-wsl hub latitude main` (no `server`) · `ls-tree -r --full-tree origin/g15-wsl`
  → `core.md d26f23b6`, `global.md dd800fdc`, `habits.md 825483fb`, `practices.md
  c193248a`, `tone.md 8fc67df2`, `values.md 93a920d1` — identical to `main` on all six ·
  `dream.sh branches` lists `origin/desktop-wsl … pure/backend-api/.claude/memory/project.md 58333`
- **the general lesson, which is the reason this is worth a skill item and not just a
  correction:** the paragraph told a run what it would *find*, and a run that trusted it
  would have archived or skipped `g15-wsl` on the stated premise rather than hashing it.
  **Name the check, not the expected result.**
- **proposed change (a human picks; do NOT self-apply):** replace both named examples with
  the check that produced them — compare each dead branch's blobs against `main`'s by hash
  before concluding anything, and treat a branch whose blobs all match `main` as carrying
  nothing. Cite `origin/desktop-wsl`'s 58 KB per-project store as the live example of a
  branch that genuinely holds a last copy, since a per-project store is the thing the
  dotfiles branches can hold and `main` does not.
- **first seen:** 2026-09-11

## e9310fe2 · skill · /home/me/machines/agents/plugin/skills/dream/SKILL.md

- **action:** skill · **scope:** repo:machines
- **run that hit it:** `docs/dream/runs/2026-09-11.md`
- **what the run got wrong because of this step:** **the `core.md` budget check measures
  the wrong number.** Step 5 says *"It is injected verbatim into every session and Claude
  Code truncates a hook's stdout near 3500 bytes. Over ~2000 bytes → file an item; over
  3000 → file it as urgent."* The run read `wc -c` = **3004** and filed the item as
  **urgent, i.e. near-truncation**. That framing is false:
  - **The loader strips HTML comments**, so the 597-B header block in `core.md` never
    reaches the model. The hook emits **2442 B**, not 3004 — comfortably under the cap.
  - Therefore `mem_warn_if_over` was **never firing**, and the ~2000-byte figure is a
    **file-byte convention** from `~/.claude/CLAUDE.md:86`, not a truncation margin. The
    step conflates the two, and the conflation is what turned a style budget into a
    reported emergency.
  - The real saving available is **2442 → 1937 injected**, which is the number a human
    should be deciding against.
  - It also matters in the other direction: `origin/desktop-wsl`'s `core.md` is
    **3385 B** on disk, which *sounds* like it is inside the cap by this step's framing —
    but its injected size was not measured by this run, and 3385 file-bytes could be more
    or less than 2442 depending on how many comments it carries.
- **evidence:** `wc -c ~/.claude/memory/core.md` → 3004 ·
  `bash global-memory-load.sh ~/.claude core | wc -c` → **2442** · `~/.claude/CLAUDE.md`:86
  (the "keep core.md under ~2 KB" convention) · queue item `7f7db67c`, which carries the
  correction inline because the run caught it only after filing
- **proposed change (a human picks; do NOT self-apply):** make Step 5 measure the
  **injected** size — `bash <config-dir>/hooks/global-memory-load.sh <config-dir> core | wc -c`
  — and state the two thresholds separately: the ~3.4 KB figure is the harness cap on hook
  stdout, the ~2 KB figure is the repo's own style budget on file bytes. A run should
  report both numbers and never call a file-byte overage "urgent" without the injected
  number beside it.
- **first seen:** 2026-09-11

## 06ccc498 · skill · /home/me/machines/agents/plugin/skills/dream/SKILL.md

- **action:** skill · **scope:** repo:machines
- **target:** `agents/plugin/skills/dream/SKILL.md`
- **anchor:** `Step 2 — Re-verify before writing`
- **why:** filed FROM a run, per Step 2b's own requirement — see
  `runs/2026-09-11.md` and the 2026-09-11 `/dream-apply` session. An item names the
  site where it found an error, **not every site carrying that error**, and applying
  it as written leaves the store still contradicting itself. Three times in one
  session:
  - `51df5bf5` — dock A/B swapped against `disks.latitude5520.conf`. Item named
    2 sites; there were **3** (the serial↔port pair, the "worst offender" port, and
    the `/dev/disk/by-id` bullet). The missed one names which physical box carries
    immich-2024.
  - `031261e5` — a wrong tailnet address table. Item named 1 site; there were **2**,
    both saying latitude `.2` and `server .3` when the manifest has latitude `.8`,
    g15 `.10` and no `server`.
  - `2ae4f3c7` — a `gh pr edit` duplicate. Item said 2 copies; there were **3**, and
    the third carried two facts the survivor lacked.
- **evidence:** ledger rows `51df5bf5`, `031261e5`, `2ae4f3c7`, `d402ad05` (the
  third gh copy, filed in-session because no item covered it)
- **bytes:** +~450 in SKILL.md
- **proposed addition to Step 2 (a human picks the wording):**
  **An item names one site; the error may live at several.** Before applying a
  correction, grep the WHOLE store for the fact being corrected — the serial, the
  address, the filename, the claim — and fix or cut every occurrence in the same
  edit. A half-applied correction is worse than none: the store still contradicts
  itself, and the next reader has no way to tell which half is current. This cost
  nothing to catch and would have shipped three self-contradicting stores.
  Corollary for a `dedupe`: the item's copy count is a lower bound, never the count.
- **also fixed this session, no item needed:** `dream.sh decide` cut from the item
  header to the next `/^## /`, but an item's replacement text IS a memory-store
  section and routinely contains `##` headings — so the cut stopped there and left
  the item's tail in the queue as orphan text. 92 such lines from 7 decided items.
  Fixed in `484971c` with three regression assertions; the ` · ` separator is
  deliberately out of the new pattern because `·` is two bytes in UTF-8.
- **first seen:** 2026-09-11
