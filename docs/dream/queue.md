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

