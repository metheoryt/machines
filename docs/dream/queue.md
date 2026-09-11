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

## 452333da · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction
- **scope:** repo:machines
- **target:** `/home/me/machines/.claude/memory/project.md`
- **anchor:** `Fleet network` (L192, 39369 B — the largest section in the corpus)
- **why:** three separate incompatible-assertion pairs inside one section. All three
  are the shape `AGENTS.md` warns about by name: *"If you catch this file asserting
  two incompatible things, the contradiction is the bug; do not pick the half that
  suits the task."* Filed together because they share one anchor; **accept or reject
  each part independently.**

### Part 1 — g15's ssh user: `methe@` vs `me@`
The superseded-header's "live correction" says reach g15 as `methe@`; the same
slice's closing section records that regenerating the config cleared that
Windows-era `User methe` and that `ssh.user` defaults to `me`. An actionable
address that is wrong is worse than none.
- **evidence:** project.md:194-201 · project.md:723-727
- **bytes:** 641 → 779
- **replacement:**
- **SUPERSEDED 2026-08-27 — the box is `g15` and is back in `fleet.json`.** Read
  the bullet below as history, not as the present. The rename and re-enrollment
  are recorded under *`g15` (ex-`server`) back in the fleet* further down this
  file; `AGENTS.md` carries the current facts. Two live corrections to what
  follows: **reach it as `me@g15.gg.ez`** — `server.gg.ez` no longer resolves,
  and `methe@` was the Windows-era user (`ssh.user` defaults to `me`; `d7427db`
  regenerated the block and dropped its stale `User methe`) — and the member
  block is restored, so the bare `ssh g15` alias works from any box that has
  re-provisioned since. What the decommission *did* is not undone:
  `hosts/server/` stays deleted, Forgejo stays wiped, `C:` stays unreviewed.

### Part 2 — "two separate LANs, DERP relay expected and accepted"
Disproven. `AGENTS.md` records the 2026-09-07 measurement (every member but `hub`
direct P2P, latitude 2 ms) and project.md:2142 already carries the correction —
this is the surviving stale copy, and `AGENTS.md` names this exact sentence as the
one that wrote latitude off as a 7-hour migration target when it is the fastest box
in the fleet.
- **evidence:** project.md:465-474 · project.md:705-707
- **bytes:** 744 → 749
- **replacement:**
- Probe PASSED 2026-07-13 (spec/plan/results under `docs/superpowers/`): SSH +
  RustDesk over the tailnet work, and DERP fallback through our own relay is
  reliable. **Its other finding — "the fleet spans two separate LANs; cross-LAN
  pairs relay via our own DERP, EXPECTED and ACCEPTED" — is DEAD.** It rested on
  latitude sitting on a hotspot behind this ISP's CGNAT. Measured 2026-09-07:
  every member except `hub` is behind the one router and gets direct P2P
  (latitude 2 ms, g15 3 ms, 99 MB/s), and that sentence is why a migration design
  wrote latitude off as a 7-hour target. "Expected and accepted" is how a stale
  measurement survives — measure a relayed pair before accepting it. Backlog
  lives at `docs/fleet-roadmap.md`.

### Part 3 — the `machines`/`vps` boundary, again
This bullet gives `machines` "NixOS/Windows" provisioning and hands Forgejo to
`vps`. The same file records Forgejo wiped 2026-08-01, the Nix tree deleted, and
the backup profiles moved INTO `machines` 2026-09-01. `AGENTS.md` records that a
contradictory boundary statement already sent a whole round of backup work to the
wrong repo — this is the same contradiction still live in the memory store.
- **evidence:** project.md:262-264 · project.md:203-208
- **bytes:** 222 → 392
- **replacement:**
- Boundary: `machines` (this repo) owns the machines — Debian/Windows/macOS
  provisioning **and the restic backup profiles** (`backup/<identity>/`, moved
  here from `vps` 2026-09-01); the sibling `~/my/vps` repo owns the services
  (Immich, Navidrome, Caddy, RustDesk server, the restic REST server container,
  the VPS's AmneziaWG hub). Forgejo is not on that list — wiped 2026-08-01.

- **first seen:** 2026-09-11

## 51df5bf5 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **target:** `/home/me/machines/.claude/memory/project.md` · **anchor:** `Backups` (L728, 25366 B)
- **why:** two incompatible-assertion pairs under one heading. Accept/reject each part independently.

### Part 1 — dock A and dock B are swapped against the live map
This bullet maps dock A to serial `6702002103E1`/`usb 4-2` and dock B to
`670200210032`/`usb 4-1`. The statusboard bullet at 1274-1288 and the authoritative
`provision/statusboard/disks.latitude5520.conf` say the **opposite**. So "archive
primary on dock A, copy on flakier dock B" names opposite physical boxes depending
on which bullet you read — and dock B is the one carrying immich-2024.
- **evidence:** project.md:835-850 · project.md:1274-1288 · `provision/statusboard/disks.latitude5520.conf`
- **bytes:** 1232 → 1436
- **replacement:**
- **The docks also reset unprompted — check the journal before blaming your own
  command.** Marginal cabling and physical knocks are a chronic fault mode here;
  dock B is the worst offender. Check with
  `sudo journalctl -k --since today | grep -aE "usb [0-9.-]+: (reset|USB disconnect)"`.
  Layout consequence: archive *primary* on dock A, *copy* on flakier dock B, and
  give any long write into dock B `--partial --append-verify` so a drop resumes.
- **Neither dock is bus-powered, and both hang off ONE root hub** (measured
  2026-09-07). Both are Ugreen **CM198** two-bay units on JMicron **JMS561U**
  bridges (`152d:1561`), each with its own 12 V brick, occupying ports 1 and 2 of
  the same xhci root hub (`usb4`, 5 Gbps). Serial ↔ port ↔ label:
  **dock A = `670200210032` = `usb 4-1`**, **dock B = `6702002103E1` = `usb 4-2`**
  — the flaky one, and the one carrying immich-2024. This bullet had A and B
  swapped until 2026-09-11; the authority is the live map
  `provision/statusboard/disks.latitude5520.conf`, which the board reads and
  which is re-measured in the room. Consequence for diagnosis: two docks dropping
  *together* is explained by the shared host controller, NOT by shared bus power
  — a "buy a self-powered drive" fix does not address it, and the 2026-08-16
  double drop stays undiagnosed. Consequence for scheduling: two long jobs on
  "different docks" still contend for one 5 Gbps uplink.

### Part 2 — "no restic repo is planned at all"
Flatly contradicted later in the same section: latitude runs restic to
`/mnt/spare320/restic/latitude` daily at 04:30 plus a REST hub for other boxes.
The only durable fact in the three bullets is the offsite gap.
- **evidence:** project.md:781-795 · project.md:947-970
- **bytes:** 1067 → 515
- **replacement:**
- **The offsite gap stands: every copy is in one apartment.** The fix remains
  cheap (rotate one dock's drive off-site) rather than cloud/object storage;
  Task 19 of the migration plan owns it. The pre-migration homeserver shape
  (hub-and-spoke restic to `G:`/`H:`) died with those drives — but restic itself
  came BACK on 2026-08-01, so the 2026-07-31 "no restic repo is planned at all"
  in the strategy bullet below is dead: see *The backup topology, rebuilt
  2026-08-01* for what latitude actually runs.

- **first seen:** 2026-09-11

## 0631997a · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines
- **target:** `/home/me/machines/.claude/memory/project.md` · **anchor:** `Backups` (L728, 25366 B)
- **survives:** the same two facts at project.md:754-756, under the newer 2026-09-01 heading
- **why:** "`schedule --all` ignores `-n`" and "unit names come from the profile,
  not the directory" are both already stated at 754-756; this 2026-08-29 pair
  restates them. Only the rename-strands-a-timer consequence is unique, and the
  replacement keeps it while pointing at the surviving copy.
- **evidence:** project.md:1016-1023 · project.md:754-756
- **bytes:** 554 → 396
- **replacement:**
- **Renaming a *profile* strands its timer and orphans its snapshots.** Unit names
  derive from the profile, not the directory (`resticprofile-backup@profile-latitude`
  — see the `schedule --all` bullet above), so relocating a config directory
  overwrites the same unit files rather than creating a second set. That is why
  the relocation froze every profile name and every repository URL.
- **first seen:** 2026-09-11

## 05d9c0ce · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** this bullet prescribes keeping `ConditionPathIsMountPoint` on any unit
  whose destination is a removable disk. That condition was **removed** from both
  mirror units on 2026-09-10 because a skipped unit is `Result=success` — it
  reported success for 90 minutes with the destination gone. The unit file now says
  the opposite in its own header.
- **evidence:** project.md:1985-1989 · `grep -rn ConditionPathIsMountPoint hosts/latitude/debian/`
  → `mirror-refresh.service:4: # NO ConditionPathIsMountPoint HERE, AND THAT IS THE FIX, NOT AN OVERSIGHT.`
  · `0d4444e fix(latitude): a Condition on a backup destination reports success forever`
- **bytes:** 357 → 592
- **replacement:**
- **`ConditionPathIsMountPoint=/mnt/immich-mirror` on `mirror-refresh.service`
  saved this run and was removed anyway.** On 2026-08-23 the 03:39 run logged
  "skipped, unmet condition check" instead of rsyncing 254 G of immich into the
  root filesystem. But a skipped unit is `Result=success`, so on 2026-09-10 the
  same mechanism reported success for 90 minutes while the destination dock was
  gone and nothing was mirrored (`0d4444e`). Both mirror units are Condition-free
  now and assert their mounts by UUID inside the script — never gate a backup
  DESTINATION on a `Condition*`.
- **first seen:** 2026-09-11

## 031261e5 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** two incompatible-assertion pairs under one heading. Accept/reject each part independently.

### Part 1 — "no `role_services` exists" / "declaring an unimplemented role is safe"
Both false now: five executors exist, and a role that is neither implemented nor in
`PLANNED_ROLES` makes `--apply` exit 1. The cited line numbers point at unrelated code.
- **evidence:** project.md:1667-1669 · `ls provision/roles/` → agents, backup-client, backup-hub, dotfiles, repos · `provision/provision.sh`:72, 103-117
- **bytes:** 209 → 465
- **replacement:**
- **A role with no executor is no longer safe to declare.** `provision.sh`
  carries `PLANNED_ROLES` (`base ssh-server`): a declared-planned role prints
  "no executor yet (declared)" and continues, but a role that is neither
  implemented nor listed there prints `✗ … not declared in PLANNED_ROLES` and
  makes `--apply` exit 1 (`provision.sh:103-117`; a dry run still exits 0).
  Executors today: `agents`, `dotfiles`, `repos`, `backup-client`, `backup-hub`.

### Part 2 — the recorded tailnet address table is wrong on every Linux member
It says latitude `.2` and `server .3`; the manifest has latitude `.8`, g15 `.10`
and no `server` at all. An agent acting on it ssh'es to the wrong node. The
bullet's actual lesson (read Headscale, not the manifest) survives without the list.
- **evidence:** project.md:1645-1649 · `jq -r '.machines|to_entries[]|[.key,.value.tailnet.ip]|@tsv' fleet.json` → latitude 100.64.0.8, air .7, desktop .4, g15 .10, hub .1
- **bytes:** 559 → 358
- **replacement:**
- **Never infer a tailnet address from `fleet.json` — read Headscale.** The
  manifest holds only fleet members (today latitude `.8`, air `.7`, desktop `.4`,
  g15 `.10`, hub `.1`), while an iPhone and every self-declared WSL host are real
  nodes that never appear in it. Addresses move with a rename: `server .3` became
  `g15-retired` and g15 is `.10`.
- **first seen:** 2026-09-11

## e547ec7a · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** two settled narratives recorded as live deliberation. Accept/reject each part independently.

### Part 1 — the Kingston / M.2 / Thunderbolt / staging-drive run (1917 → 1047)
A settled hardware decision written as open deliberation, including a
`dmidecode`-under-NixOS recipe for an OS no fleet box runs and a work branch that
no longer exists. Only the slot-table lesson and the residual backup gap transfer.
- **evidence:** project.md:1616-1644 · `git branch -a | grep fleet-migration` → empty · `ls flake.nix` → absent (`f3d63b2`) · `backup/latitude/profiles.yaml`:5
- **replacement:**
Plan: `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
(the `worktree-fleet-migration-mac-primary` work branch is gone). Settled:
the Kingston NVMe went into a **Thunderbolt enclosure** — latitude has TB4
(`00:0d.0`/`00:0d.2`, `bolt` enabled) and no free M.2 2280 socket.

- **A DMI slot table omits the occupied socket, so absence proves nothing.** On
  the Latitude 5520 `dmidecode -t slot` reports three PCIe slots and the live
  KIOXIA (`00:1d.0`) is in none of them; the three are the card reader, the
  Wi-Fi AX201 and an empty **x1** WWAN port. Cross-check every entry's
  `Bus Address` with `lspci -t -v`, and decide on lane width — an SSD needs its
  own root port, and an x1 one is never wired for one.
- **The live photo tier still has no off-site copy, by decision.** The 2 TB
  staging drive was deferred and never bought; `backup/latitude/profiles.yaml`'s
  header now records the standing choice (the libraries are protected by
  whole-filesystem rsync mirrors on the same box, not by restic).

### Part 2 — the `[HISTORY]` passphrase block (1268 → 483)
1.27 KB about a deleted unit whose outcome (passphrase stripped) is already
recorded twice further down the same section. Keep only the transferable mechanism.
- **evidence:** project.md:1670-1683 · superseded in-file at 1744-1752 and 1760-1766
- **replacement:**
- **[HISTORY — unit deleted in `9b8d63c`] A passphrase-encrypted key breaks every
  systemd-run git pull, silently.** latitude's `nix-repo-auto-pull` logged
  `Permission denied (publickey)` every 5 min and still exited 0, so it sat 100+
  commits behind with `systemctl` reporting success: a service has no ssh-agent
  and no TTY, while interactive pulls work. Resolved by stripping the passphrase
  (see the `id_ed25519` entry below). The lesson binds for any unattended puller.
- **first seen:** 2026-09-11

## 1e2ea8d5 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** two pending items whose blocking premises are stale. Accept/reject each part independently.

### Part 1 — pre-commit git hooks: closed, cannot recur (1295 → 356)
The item closes itself in its own last paragraph — `git-hooks.nix`, `.envrc`, the
`nix develop` box and the whole Nix tree are gone, so the per-box `rm` can never be
needed. Only "shell linting is unenforced" still points anywhere.
- **evidence:** project.md:1575-1590 · `ls flake.nix` → absent · `f3d63b2`
- **replacement:**
- **Pre-commit git hooks: CLOSED, cannot recur.** The `git-hooks.nix` mechanism
  (`2af7c5b`) and the whole Nix tree are gone, and the only box that ever ran
  `nix develop` was reinstalled. `just fmt` / `just check` / `just shell` no
  longer exist; shell linting is unenforced — if that ever matters, `shellcheck`
  in `just test` is the shape to add.

### Part 2 — VPS base-machine reproducibility (882 → 449)
Still a real open idea, but stale in both directions: it names `mesh-hub`/
`mesh-member` executors that no longer exist and lists `backup-client` as
unimplemented, when it got an executor 2026-09-01. Only `base` and `ssh-server` block it.
- **evidence:** project.md:1592-1602 · `ls provision/roles/` → no `mesh-*` · `provision.sh` `PLANNED_ROLES="base ssh-server"`
- **replacement:**
- **VPS base-machine reproducibility (idea, NOT started — 2026-07-11).** Bring a
  fresh cloud VM back to the VPS baseline reproducibly. Still blocked on the
  unimplemented `base` and `ssh-server` roles (roadmap P3) — `backup-client` got
  its executor 2026-09-01. Scope when built: base machine only; services stay the
  `vps` repo's `setup-*.sh`. Open: Debian vs Ubuntu LTS — both apt-family, so
  `base` can be family-generic; deferrable.
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

## f1d3be7d · dedupe · /home/me/my/embedthat/CLAUDE.md

- **action:** dedupe · **scope:** repo:embedthat
- **survives:** `/home/me/my/embedthat/AGENTS.md`
- **why:** `diff` shows CLAUDE.md and AGENTS.md differ **only** in the title line and one
  sentence — ~12.8 KB paid **twice** in every embedthat session, because the harness
  loads both. Adopt the airdrome pointer-stub pattern, already proven in this repo group.
- **evidence:** `diff CLAUDE.md AGENTS.md` → `1c1 # CLAUDE.md / # AGENTS.md` and `3c3` only; sizes 12863 / 12856
- **also fix in the same pass:** AGENTS.md:3 is a botched find-and-replace reading
  *"This file provides guidance to Codex (Codex.ai/code)"*. Once CLAUDE.md is a pointer,
  that mislabeled line becomes the canonical greeting every Claude session reads.
  Replace it with: `This file provides guidance to Claude Code (claude.ai/code) and other agents when working with code in this repository.`
- **bytes:** 12863 → 135 (−12728 per session)
- **replacement:**
See [AGENTS.md](AGENTS.md) for all project guidance. This file is a pointer kept for tooling that looks for `CLAUDE.md` by convention.
- **first seen:** 2026-09-11

## 9d35c9b2 · dedupe · /home/me/my/skep/CLAUDE.md

- **action:** dedupe · **scope:** repo:skep
- **survives:** `/home/me/my/skep/AGENTS.md`
- **why:** skep's CLAUDE.md and AGENTS.md are **byte-identical**, so the harness loads the
  same 914 B twice in every skep session. Same airdrome pointer-stub fix as embedthat —
  smaller, but zero-risk and the diff is exact.
- **evidence:** `diff ~/my/skep/CLAUDE.md ~/my/skep/AGENTS.md` → no output, rc=0; both 914 B
- **bytes:** 914 → 135
- **replacement:**
See [AGENTS.md](AGENTS.md) for all project guidance. This file is a pointer kept for tooling that looks for `CLAUDE.md` by convention.
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

## 89560bba · generalise · /home/me/CLAUDE.md

- **action:** generalise · **scope:** shared → fleet-wide (loaded in EVERY session under `$HOME`)
- **why:** the enumeration names `server`, a branch that does not exist — renamed to
  `g15` on 2026-08-27, "the only logical name ever renamed". It is also **incomplete in
  the other direction**: `desktop-wsl` and `g15-wsl` have branches while appearing in no
  `fleet.json`, so "one branch per machine" does not describe the set. Swapping
  `server`→`g15` only defers the same staleness to the next rename, so the fix points at
  `dotfiles branch -a` and keeps the rule sentence.
- **evidence:** `~/CLAUDE.md`:54-56 · `dotfiles branch -a` → `air desktop desktop-wsl g15 g15-wsl hub latitude main` (no `server`) · `machines/AGENTS.md` on the rename and on self-declared WSL hosts
- **bytes:** 224 → 395
- **replacement:**
- **`main`** — content shared across every machine, byte-identical everywhere.
- **One branch per identity**, named by its **logical fleet name**, not the OS
  hostname. Ask `dotfiles branch -a` rather than any list written here: `server`
  was renamed to `g15` on 2026-08-27, and the set is wider than `fleet.json` —
  self-declared WSL hosts (`desktop-wsl`, `g15-wsl`) carry branches too.
- **first seen:** 2026-09-11

## fdaea448 · generalise · /home/me/machines/.claude/memory/project.md

- **action:** generalise · **scope:** repo:machines
- **why:** this row consumes BOTH adjacent sections (`findmnt --verify` 3515-3550 and
  `Condition*` 3551-3614). Nearly every mechanism in them is already in **AGENTS.md
  *Key patterns*** — `Condition*`→`Result=success` plus the 90 minutes, `findmnt -no
  SOURCE` vs UUID, remount-once/never-umount-a-bound-tree, flock 75/78, `.Mounts` vs
  `.HostConfig.Binds`, the whole `rc>=2` segfault paragraph. **AGENTS.md's copy survives
  because it is auto-loaded in every session in this repo.** What remains is one named
  general rule with **five** instances (two extra, from the restic section: `run-before`
  checks for the `config` object rather than repository completeness; a merely-*stopped*
  timer is clean in `systemctl --failed`) plus the repo-specific residue AGENTS.md lacks.
- **evidence:** project.md:3515-3614 · AGENTS.md:600-643
- **bytes:** 10810 → 5181 (−5629, the single largest saving filed this run)
- **replacement:**
## Гейт, который рапортует успех, ничего не сделав — общая форма (2026-09-10)

Пять отказов одного класса за один день на latitude. Механизмы и итоговые
правила лежат в `AGENTS.md` (*Key patterns*: `Condition*`/`Result=success`,
гейт `findmnt --verify`, конвенция кодов 75/78, `.Mounts` вместо
`.HostConfig.Binds`) — он грузится каждой сессией, здесь только то, чего там
нет.

- **Форма, по которой их узнавать:** защита, чей отказ неотличим от «работы не
  было». Проваленная `Condition*` → `Result=success`; гейт `findmnt --verify`,
  выключавший сам себя из-за чужой строки в fstab; `rollback`, направляющий
  `DATA_ROOT` на путь, который уже не точка монтирования (docker создаст пустой
  bind-источник, и откат уничтожит то, что должен вернуть); `run-before` в
  restic-профилях, проверяющий наличие объекта `config`, а не ПОЛНОТУ
  репозитория; просто остановленный таймер, который в `systemctl --failed`
  чист. Спрашивать надо «как выглядит этот гейт, когда он не сработал», а не
  «что он проверяет».
- **Обоснование в комментарии было ещё и фактически ложным.** `/mnt/immich` —
  это `/dev/nvme0n1p1`, второй ВНУТРЕННИЙ NVMe, никакого дока; «источник
  отключили» там не бывает в принципе. Комментарий пережил переезд ФС,
  на которой был написан.
- **Остаточный риск, названный явно:** самолечение приёмника даёт
  `Result=success`. Диск, отваливающийся каждую ночь, теперь перемонтируется и
  копируется — из «невидимо и сломано» стало «невидимо и работает». Единственный
  след — строка `WARN … remounting once` в журнале. Настоящее лечение — увести
  зеркало с этого порта (см. раздел про 480 Мбит).
- **У `install-docker-ordering.sh` не было ни одного теста** — при том что он
  стоит между Docker и автосозданием bind-источника на корне (два инцидента:
  servarr 03.08.2026, immich-2024 03.09.2026). Чтобы файл стал сорсабельным,
  блок запуска ушёл в `main()` за `[ "${BASH_SOURCE[0]}" = "$0" ]`.
- Сегфолт `findmnt --verify` в тесте **подменён функцией-заглушкой**, а не
  воспроизведён: иначе кейс отвалится на util-linux, где багу починят.
- `fstab_patch` **переписывает строку в выровненные колонки**, поэтому `remove`
  обратен `add` по полям, но не по байтам — и наивный diff `/etc/fstab` после
  прогона показывает изменённой каждую охраняемую строку.
- Грабли тестов на юниты: оба зеркальных скрипта **описывают** в комментариях
  тот `findmnt -no SOURCE`, который заменили, — утверждение «этой строки нет»
  сначала запретило объяснять, зачем меняли; комментарии режутся `sed` перед
  проверкой. И `archive-mirror.sh` держит два присваивания в одной строке, так
  что якорь `^…UUID=` на регистр не сработал.
- Мутации: `docker-ordering.test.sh` — снятие `rc>=2` 4 падения, возврат гейта
  на весь файл 4, retirement-скан без пропуска членов набора 2;
  `latitude-timer-units.test.sh` — 7 из 7.
- **Апостроф внутри `ssh box '…'` разрывает команду.** Питон-правку с
  `connector's` в комментарии съело на середине, `assert` ушёл в bash. Скрипт
  правок — через stdin: `ssh box 'sudo python3 -' < file.py`.
- **first seen:** 2026-09-11

## 78e36627 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines → **the fix lands in AGENTS.md**
- **why:** **the one case in this run where the surviving-copy heuristic inverts.** The
  auto-loaded `AGENTS.md`:701-703 sentence is wrong **twice**: `immich-mirror` is not on
  dock `4-2` (it is on `u3-2.4` in the NS1066 stopgap, project.md:3440-3442), and "is the
  flaky one" is July–August state (16 TB through 4-2 in 26 h with **zero** resets since
  17.08). AGENTS.md also says nothing about the **power-drop** class, which is the
  failure that actually recurs — 8 events, both docks in the same second.
- **evidence:** project.md:3343-3347 · AGENTS.md:701-703
- **bytes:** 492 → 891
- **replacement:**
16 ТБ за 26 ч с нулём CRC и нулём сбросов.

**Поэтому AGENTS.md:701-703 неверен дважды и его надо править:** «The dock
carrying `immich-2024` and `immich-mirror` is the flaky one — it logged 24
`usb 4-2: reset` events» — во-первых, `immich-mirror` висит не на этом доке, а
на `u3-2.4` в стопгап-корпусе NS1066; во-вторых, «is the flaky one» — это
состояние июля-августа, а не свойство дока. И про главный, питающий класс
отказа там нет ни слова.

**Не сваливать одно в другое.** `disconnect` обоих доков = питание;
`reset` одного под нагрузкой = линк. Первое лечится UPS, второе — кабелем/доком.
- **first seen:** 2026-09-11

## 4b32b623 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** two bullets are **standing orders that were satisfied the same day** and now
  misdirect a future session. "Правильная проверка … отложено осознанно" was implemented
  that day (project.md:3523-3525), and "Освобождать только после проверки, что в
  qBittorrent нет errored-торрентов" reads as an open guard although qBittorrent rehashed
  every torrent against wd8 and the disk was freed (project.md:3443-3450).
  **A false instruction is more dangerous than a stale fact — it forbids an action
  already taken.**
- **evidence:** project.md:3377-3385 · project.md:3443-3450, 3523-3525
- **bytes:** 1006 → 1101
- **replacement:**
- **`/mnt/xs` в `/etc/fstab` закомментирован** (диск физически снят): живой
  `[E]` в `findmnt --verify` полностью блокировал `install-docker-ordering.sh
  -go`. Это был латентный дефект самого скрипта — любая посторонняя протухшая
  строка вырубала главный guard фленки; **исправлен в тот же день** (гейт
  сравнивает кандидата с текущим файлом), см. раздел про гейты, рапортующие
  успех.
- Старая копия servarr на `/mnt/servarr` (sdb2, HGST 931 G) держалась до
  проверки, что в qBittorrent нет errored-торрентов. **Условие выполнено в тот
  же день** — qBittorrent перехешировал все раздачи против wd8, диск освобождён
  и принял вторую копию закрытого архива 1970–2024 вместо снятого `/mnt/xs`.
- **first seen:** 2026-09-11

## a88a78f4 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** 6 KB narrating one evening's install, with the boot journal reconstructed
  spawn by spawn and the same conclusion ("nothing is open on the client any more")
  restated in three bullets. Every durable fact survives — preview-build-only, why it is
  deliberately **not** a tier, the seat/greeter mechanism and its headless limit,
  both-configs seeding, the id, direct-IP-off, the rejected alternative.
- **evidence:** project.md:3228-3308
- **bytes:** 6007 → 3355
- **replacement:**
## RustDesk on g15: unattended Wayland works, greeter included — but only in a preview build (2026-09-10)

- **Upstream's own capability, not a community hack** — announced 2026-08-14 for
  **x86_64 Debian/Ubuntu only**, which is exactly g15. **NOT in stable 1.4.9**;
  it ships as a separate preview build, installed here as
  `rustdesk-unattended-wayland` 1.5.0 (.deb from the `nightly` tag). Trust
  `rustdesk.com/blog/unattended-remote-access-wayland` over third-party
  writeups — both found were partly wrong, and the DRM/KMS capture backend
  (discussion #15417) is a PROPOSAL, not a release.
- **The mechanism, proven across a reboot on this box.** The packaged unit is
  `User=root`, but root captures nothing itself: it `sudo -u <user>`s a
  `rustdesk --server` into each graphical session on the seat, injecting that
  session's `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`.
  At boot one of the spawns is **`gdm-greeter` (uid 60578)** carrying the
  greeter's own `wayland-0`. **So it does not need a logged-in user; it needs a
  graphical session on the seat, and the GDM greeter is one** — and GDM
  auto-login is OFF here, so the login-screen pass was a real one. The corollary
  is the limit: a box with **no display manager running** offers nothing to
  attach to, so this is no route to a headless server's console.
- **Deliberately NOT a `tier_rustdesk`, and the reason is the tag.** The
  `releases/download/nightly/...` URL is stable but its BYTES are replaced in
  place; combine that with the `tier_gortex` precedent of untarring the pin
  unconditionally and any provision run for any reason silently swaps the box's
  remote-access daemon. Pinning the per-asset `digest` only trades silent drift
  for break-on-every-upstream-rebuild. **Revisit when it lands in a stable
  release, not before.**
- **Both configs must be seeded, and `systemctl is-active` proves nothing.** The
  service reads `/root/.config/rustdesk/RustDesk2.toml`, the tray reads the
  user's; seeding one leaves the other on the public `rs-ny.rustdesk.com`. The
  actual proof the options took effect is that RustDesk **rewrites its own
  top-level `rendezvous_server` to `cyphy.kz:21116`** on restart. Seeding is
  `hosts/g15/ubuntu/rustdesk-seed.sh` — a merge, never a clobber. The unattended
  password is set in the tray, never by script: it lives in `RustDesk.toml` as an
  encrypted per-install secret, which is why the seed script never touches that
  file.
- Live state: id **`1722388240`** against our own `cyphy.kz` hbbs
  (`[keys_confirmed] cyphy = true`; peer map in
  `docs/2026-08-01-nixos-harvest.md` §2). The server's public key had not rotated
  since the NixOS tag — checked against the live `hbbs` container, not the tag.
  **Direct IP access is OFF, and that is the default, not a regression:** nothing
  listens on 21118, so a connect to `100.64.0.10` reaches nothing and it is not a
  tailnet fault. Connect by ID.
- **The rejected alternative, so it is not re-derived:** `gnome-remote-desktop`
  50.2 is ALREADY installed on g15, ships a headless unit and `grdctl` sets
  credentials non-interactively — Wayland-native unattended RDP with no
  rendezvous server at all. Rejected only because RustDesk is one tool across
  Windows/macOS/Linux/Android; it stays the fallback if the preview regresses.
- **first seen:** 2026-09-11

## 398b5299 · contradiction · /home/me/machines/AGENTS.md

- **action:** contradiction · **scope:** repo:machines · **auto-loaded in EVERY session under `~/machines`**
- **note:** canonical path is `AGENTS.md`; `machines/CLAUDE.md` is a symlink to it.
- **why:** **four** incompatible-assertion pairs under this heading. The file instructs
  its own readers: *"If you catch this file asserting two incompatible things, the
  contradiction is the bug; do not pick the half that suits the task."* So each part is
  filed with **both halves quoted and no replacement — a human picks.** Accept/reject
  each part independently.

### Part 1 — does a role with no executor fail, or print a plan?
`### Key patterns` says *"A role with no executor degrades to a printed plan rather than
failing"*; `### The provisioner is the whole story now` says that since 2026-08-05 *"a
role that is neither implemented nor named there makes `--apply` exit 1"*.
`provision/provision.sh:117` prints `✗ $role — no executor, and not declared in
PLANNED_ROLES` and fails — so L555 is the **pre-2026-08-05 half**, i.e. the exact
"reported success while doing nothing" failure the other paragraph was written to close.
- **evidence:** AGENTS.md:554-555 · AGENTS.md:379-385 · `provision/provision.sh`:117
- **bytes:** 166 → 120 · **replacement:** (none — a human picks which half is true)

### Part 2 — is g15 a `platform: windows` dispatch target?
`### Fleet networking` says `fleet-dispatch.sh` goes through Git Bash *"keyed on
`platform: windows` … which since 2026-08-27 means `desktop` **and** `g15` again"*;
`## Repository Overview` says *"Its `fleet.json` platform is `debian`, on an Ubuntu box,
deliberately"*. `fleet.json`:24 reads `"platform": "debian"`; only `desktop` (L17) is
`windows`. L460-462 is the stale half — Windows on g15 was destroyed 2026-09-07.
- **evidence:** AGENTS.md:455-462 · AGENTS.md:67-74 · `fleet.json`:17,24
- **bytes:** 565 → 430 · **replacement:** (none — a human picks which half is true)

### Part 3 — `g15-wsl` described in the live present tense
`### Fleet networking` says *"The one genuine exception **is** `g15-wsl`… It **runs** in
NAT networking mode… g15 **has** both a Windows node (`100.64.0.3`) and a distro node
(`100.64.0.9`)"*, while `## Repository Overview` says *"Windows and the `g15-wsl` distro
are GONE — reinstalled 2026-09-07"* and *"Headscale nodes 3 … and 9 (`g15-wsl`) are
dead"*. **This is precisely the trap the entry at L58-61 says the file keeps falling into.**
- **evidence:** AGENTS.md:433-443 · AGENTS.md:58-61, 82-83
- **bytes:** 841 → 250 · **replacement:** (none — a human picks which half is true)

### Part 4 — does `hosts/desktop/windows/` carry a backup script?
`### Host configurations` says it *"carries install/reinstall + backup scripts"*;
`## Repository Overview` says *"**It carries no backup or restore script** — `backup.ps1`
and `restore.ps1` were both deleted 2026-07-31"*. `ls hosts/desktop/windows/` returns
only `install.ps1`, `windows-reinstall-runbook.md`, `winget-packages.json`. L546 is the
stale half — **and it is the half a reader reaches for when planning a reinstall.**
- **evidence:** AGENTS.md:546 · AGENTS.md:92-94 · `ls hosts/desktop/windows/`
- **bytes:** 69 → 45 · **replacement:** (none — a human picks which half is true)
- **first seen:** 2026-09-11

## 93ec8377 · contradiction · /home/me/machines/AGENTS.md

- **action:** contradiction · **scope:** repo:machines · auto-loaded in every session here
- **why:** **inside the single g15 host entry, twenty lines apart.** L52-53 lists its roles
  as `base, ssh-server, agents, dotfiles, repos` — five, **no `backup-client`** — while
  L71-72 argues that a wrong platform token *"would have skipped `dotfiles`, `repos` and
  `backup-client`"*, asserting g15 **has** `backup-client`. `fleet.json`:26 lists six
  roles including `backup-client`, so the roles list is the stale half.
- **evidence:** AGENTS.md:51-57 · AGENTS.md:67-74 · `fleet.json`:26
- **bytes:** 520 → 530
- **replacement:** (none — a human picks which half is true)
- **first seen:** 2026-09-11

## e05f4c1e · contradiction · /home/me/machines/AGENTS.md

- **action:** contradiction · **scope:** repo:machines · auto-loaded in every session here
- **why:** the file states the **don't-write-counts-into-prose rule three times** — *"`just
  --list` is the full menu — ask it rather than trusting a number written here"*; *"Don't
  write the suite count into prose"*; *"Trust the number `just test` prints in front of
  you over this one"* — and then **writes live counts into prose anyway**. Every one is
  the rule's own stated failure mode. Filed as ONE row naming every instance, per the
  instruction-file rules.
- **the instances:** "there were 21" recipes (L138-139) · "55 suites, 0 failures" (L230) ·
  "22 modules" (L22) · "(7 live branch cases)" (L357) · "(14 cases…)" (L368) ·
  "(28 cases)" (L611) · "7/7" (L639) · "18 images / ~15 GB" (L704)
- **evidence:** AGENTS.md:226-237 (the rule, thrice) · AGENTS.md:137-143, 22, 357, 368-369, 611, 639, 704
- **bytes:** 585 → 430
- **replacement:** (none — a human picks: either the rule goes, or the numbers do. Note
  the rule's own text already concedes the per-suite case counts are a different class
  from the totals, so a split verdict is legitimate.)
- **first seen:** 2026-09-11

## d20809a1 · dedupe · /home/me/machines/AGENTS.md

- **action:** dedupe · **scope:** repo:machines
- **survives:** `machines/.claude/memory/project.md`:3515-3535 («Гейт `findmnt --verify` был выключателем самой защиты»)
- **why:** the `### Key patterns` fstab bullet is the **fuller-in-the-store** case: the
  memory copy carries everything AGENTS.md has **plus** the fstab self-admitting comment
  and the no-tests origin. Both files load in every session in this repo, so the write-up
  is paid for twice — **the rule stays here, the incident stays in the store.**
- **caveat a reader must know:** the surviving copy is in **Russian**, so an English grep
  of AGENTS.md for `findmnt --verify` will find only the pointer after this.
- **evidence:** AGENTS.md:600-613 · `.claude/memory/project.md`:3515-3535
- **bytes:** 1055 → 922
- **replacement:**
    - **A stale fstab line used to switch this whole guard off.** `fstab_apply`
      refused its candidate whenever `findmnt --verify` reported anything at all,
      anywhere in `/etc/fstab`, so **one dead entry disabled the ordering guard
      for every other mount** (that is why the `/mnt/xs` line had to be commented
      out). The gate now refuses only findings its own edit introduced — but it
      **still refuses outright on `rc >= 2`**, because util-linux 2.41's
      `findmnt --verify` SEGFAULTS on a short fstab entry and a crashed checker
      emits nothing to compare. Full write-up (RU):
      `.claude/memory/project.md` § «Гейт `findmnt --verify` был выключателем
      самой защиты». `provision/tests/docker-ordering.test.sh` covers the
      decisions; the root-only halves — `chattr`, the bind mount of `/`,
      `systemctl` — are not and cannot be there.
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

## 5f6b88d0 · contradiction · /home/me/my/vps/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:vps
- **why:** the whole section describes a **PowerShell poll-deploy engine running as a
  Windows scheduled task out of `C:\Users\methe\my\vps`** — that box was reinstalled as
  Linux 2026-09-07, and embedthat left the engine 2026-09-08 for a Docker Hub
  tag-triggered deploy. The store contradicts **itself**: this section says everything
  auto-deploys every 3 min, while L90 says *"Still no self-update: a push to either repo
  does nothing."*
- **evidence:** vps project.md:28-36 · contradicted by the same file:90 · `hostname` →
  g513ie, `ls /mnt/c/Users/methe` → No such file or directory, `docker ps -a` shows none
  of the five old containers · `homeserver/embedthat/compose.prod.yml` → `image:
  metheoryt/embedthat:latest`, **no `build:`**
- **bytes:** 4118 → 4368
- **replacement:**
## Deploy pipeline (poll-and-build, local)

- **THE ENGINE HAS NO HOST.** It ran as a Windows scheduled task (`repos-deploy`, every 3 min, `conhost.exe --headless` — that is what killed the flashing-window bug from the old per-bot `Interactive` tasks) out of `C:\Users\methe\my\vps`. That box was reinstalled as Linux on 2026-09-07: the path, the user `methe`, Docker Desktop and the task are all gone, and the services it deployed run on latitude where nothing runs it. **Every deploy is manual today** — `git pull` in `homeserver/telegrind/src/`, then `up -d --build`. `deploy-repos.ps1`, `register-repos-deploy.ps1` and `repos.psd1` are still tracked; read the rest of this section as the spec for an engine that is not running, and read every `C:\Users\methe\my\<name>` as `/home/me/my/<name>`.
- **`embedthat` is NOT poll-deployed any more and must not be added back** (it left `repos.psd1` on 2026-09-08). It deploys from Docker Hub: a `v*` tag makes GitHub Actions publish `metheoryt/embedthat:latest` and Tugtainer pulls it; a push to `main` publishes nothing since 2026-09-10. `homeserver/embedthat/compose.prod.yml` carries `image: metheoryt/embedthat:latest` and has **no `build:` and no `./src` clone at all**. Re-adding an entry would rebuild `embedthat:local` over the pulled image on every source change and the two would fight, each undoing the other. `telegrind` is the only remaining entry, and `telegrind-bot:local` is still a local-only tag so Tugtainer cannot pull-update over it.
- **How the engine works, if it is ever ported.** `deploy-repos.ps1` reads `homeserver/repos.psd1` (entries: `Name`/`Url`/`Branch`, optional `Service`); per-entry defaults `Dir=homeserver/<Name>`, `Src=<Dir>/src`, `Compose=<Dir>/compose.prod.yml`, `Service='bot'`. App source is a **gitignored `src/` clone** (build context only; survives `git reset --hard`); prod compose is vps-tracked at `homeserver/<name>/compose.prod.yml` and `extends ../compose.base.yml` (shared base: `restart: unless-stopped`, json-file log rotation, `fleet.poll-deploy=true` label; `extends` inherits scalar/map only — `volumes`/`depends_on`/`networks` stay local). The engine only acts when the gated service is already running (maintains running stacks, never cold-starts). The four legacy scripts and the `embedthat-deploy`/`telegrind-deploy` tasks are GONE, the submodules are GONE, and `.gitmodules` is empty.
- **Marker `homeserver/.<name>-last-deployed` = `sourceSHA:configHash`** (SHA256 of `docker compose config`) — the source of truth. A change to app source, prod compose, OR the base file each triggers exactly one redeploy.
- **A `repos.psd1` `Branch` that no longer exists upstream freezes that repo's deploys SILENTLY.** Hit for real 2026-07-25: telegrind's default branch was renamed `master` → `main`, the entry still said `master`, and since the engine fetched without `--prune` the stale `origin/master` remote-tracking ref kept resolving to the frozen SHA — the log printed `[telegrind] up to date` every 3 min and every future push would have been dropped with no error. Fixed by pinning `main` **and** adding `--prune` to the engine's fetch, which turns the same class of failure into a loud `git rev-parse` error. After any default-branch rename, update `repos.psd1`.
- **Never develop in `homeserver/<name>/src/` — the engine runs `git reset --hard origin/<branch>` in it on every deploy and will silently destroy uncommitted work.** It is a deploy-only build context. The real dev clones are siblings of the vps clone: `/home/me/my/telegrind`, `/home/me/my/embedthat`. Fix app bugs there and push — do NOT edit prod source in place. (Handy for read-only probes, though: `docker exec embedthat-worker-1 /app/.venv/bin/python ...` runs against the real deps/env.)
- **To add/migrate a repo, follow `homeserver/DEPLOYING-A-REPO.md`** (written for the config-driven flow). Earned gotchas still apply: secrets kept OUT of `./src` + in the app's `.dockerignore`; never `down -v`; keep project + volume names stable. Live volumes preserved across the 2026-07-15 cutover: `embedthat_redis_data` (redis) and `telegrind_pgdata` (postgres, 62 chats). telegrind = branch `main`, services `bot`+`postgres`, secret `.env.prod` + runtime `google-account.json` in `src/`. Design spec: `docs/superpowers/specs/2026-07-15-poll-deploy-ci-generalization-design.md`.
- **first seen:** 2026-09-11

## de96aa30 · contradiction · /home/me/my/vps/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:vps
- **why:** this bullet asserts *"`server` still holds the five old containers, `Exited`
  with restart policy `no`"* — that box was reinstalled 2026-09-07 and `docker ps -a`
  shows none of them, so **the only stated reason a second poller would not grab the bot
  tokens is gone** (the risk is gone too). It also states *"Still no self-update: a push
  to either repo does nothing,"* which stopped being true for embedthat on 2026-09-08.
- **evidence:** vps project.md:90 · `docker ps -a` on g513ie lists only `sb-spike-*`,
  `telegrind-dev-postgres-1`, `airdrome-db-1`, `qaz-law-db-1` · `homeserver/repos.psd1`
- **bytes:** 1760 → 1687
- **replacement:**
- **`telegrind` and `embedthat` are UP on latitude since 2026-08-01**, both reusing their migrated volumes (`telegrind_pgdata` 62 chats + `alembic_version=2700e0b3a8b6`; `embedthat_redis_data` 5338 keys). Verified end to end, not by `docker ps`: telegrind logged `Run polling for bot @telegrindbot` (a real Telegram API round-trip) and embedthat's worker downloaded + ffmpeg-merged + sent a video within 25s of start. **The leaked credentials were NOT rotated — user decision, do not re-raise** and do not reintroduce a "rotate first" step; basis in `machines/docs/fleet-roadmap.md` P6. Bring-up order that matters for **telegrind**: build the image BEFORE placing `google-account.json`, because `src/` IS the build context and a `--build` with the key present can bake an RSA private key into a layer (`.dockerignore` covers it, but building first makes that moot); the key goes at `homeserver/telegrind/src/google-account.json` 0600 from `~/g513ie-prod-config/telegrind/google-account.json`, INSIDE the gitignored clone, so a re-clone does not bring it and `git clean -fd` there would delete it; start postgres/redis before the app since `depends_on` waits for start, not readiness. **Self-update is now split:** a push to `telegrind` still does nothing (the PowerShell poll-deploy engine lost its host — see *Deploy pipeline*), so that one is a manual `git pull` in `src/` + `up -d --build`; `embedthat` self-updates from Docker Hub on a `v*` tag via Tugtainer and is no longer built on the host at all (the old ~40-min `faster-whisper`/CTranslate2/CUDA-wheel build on this Intel-only box is history, and it was never GPU-accelerated anyway — the compose requested no devices).
- **first seen:** 2026-09-11

## ff910bb2 · contradiction · /home/me/my/vps/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:vps
- **why:** this gotcha pins its mechanism on `D:\Media\config\jellyfin` and a "Docker
  Desktop **Windows bind mount**", but the same store says **four sections later** that
  servarr moved to latitude on 2026-08-01 with `CONFIG_ROOT=/mnt/immich/ServarrConfig` and
  *"the old `D:\Media` path on the Windows box is dead"*. The one-process-per-config-dir
  rule survives; **the Windows framing makes a reader think it no longer applies.**
- **evidence:** vps project.md:74 · contradicted by the same file:81
- **bytes:** 760 → 982
- **replacement:**
- **Servarr apps deadlock if two containers mount the same `/config` (SQLite lock).** Seen 2026-07-20: Jellyfin hung ~5 min at ~0% CPU / frozen `.db-wal` on the `AddKeyframeData` migration because a second `jellyfin`-named container (a stray `jellyfin-test`) briefly shared the config dir — then `D:\Media\config\jellyfin` on Docker Desktop, where a **Windows bind mount** makes SQLite locking especially fragile. **That path is dead: servarr moved to latitude 2026-08-01 and `CONFIG_ROOT` is now `/mnt/immich/ServarrConfig` on native Linux Docker**, so the Windows-bind-mount aggravation is gone but the rule is not — one process per config dir is mandatory on any filesystem. Symptom = stuck "Server is still starting up" at ~0% CPU with no BlockIO progress. Fix: `docker ps -a | grep <app>`, remove the duplicate; if the DB was left mid-migration, wipe that app's config dir and re-init (only safe pre-setup). A single instance boots clean in seconds on the same bind mount.
- **first seen:** 2026-09-11

## cac27f8d · dedupe · /home/me/my/vps/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:vps
- **survives:** `machines/AGENTS.md` *Key patterns* (the incident) + `machines/hosts/latitude/debian/install-docker-ordering.sh` (the remedy)
- **why:** the symptom/cause half is the same incident `machines/AGENTS.md` writes up at
  length, and the remedy (the `MOUNTS` array) lives **only** in `machines`; vps'
  `CLAUDE.md` already carries the cross-repo pointer. Keep the two things `machines` does
  **not** have — the host-vs-container device comparison and the `--force-recreate`
  requirement — and point at the owner for the rest.
- **evidence:** vps project.md:108-124 · `machines/AGENTS.md` *Key patterns* · `vps/CLAUDE.md`:95-101 (`775ed1e`)
- **bytes:** 1295 → 1377
- **replacement:**
## Docker bind mounts vs. late disk mounts (learned 2026-09-08)

- **The rule and the incident live in `machines`, not here** — the `MOUNTS` array
  and the boot-ordering guard are
  `machines/hosts/latitude/debian/install-docker-ordering.sh`, and
  `machines/AGENTS.md` (*Key patterns*) carries the full write-up of the two
  incidents (servarr 2026-08-03, immich-2024 2026-09-03, five days of ENOENT on
  every 2007–2024 photo download while the container reported `(healthy)`).
  **Adding any `/mnt` bind to a compose file here means adding that mount to
  `MOUNTS` there and re-running the script** — `CLAUDE.md` step 1 of *Adding a New
  Service* says so at the point the bind is written.
- Two operational bits worth keeping on this side, because they are about
  diagnosing a live container rather than installing the guard:
  - **Detect a stale bind by comparing devices, host vs. container:**
    `findmnt -no SOURCE --target <hostpath>` vs
    `docker exec <c> grep <ctrpath> /proc/mounts`. A bind whose container-side
    device is the root fs while the host-side is a data disk is stale.
  - **Fixing it needs `docker compose up -d --force-recreate <svc>` — a plain
    `restart` does not re-resolve binds.**
- Immich's integrity check only *reports*; after the 2026-09-03 remount it had
  flagged nothing `isOffline`/`trashed`, so no DB repair was needed.
- **first seen:** 2026-09-11

## 37c0a0ba · compress · /home/me/my/skep/.claude/memory/project.md

- **action:** compress · **scope:** repo:skep
- **why:** **skep is the structural outlier of the corpus — 53 KB in three `##` sections,
  ~17 KB each.** One bullet holds five build-journal stories (Plan 1 executed, Plan 2
  executed, shim spike, L0 mailbox, L0.1 hardening + close-out) at 9785 B — dates, branch
  names, merge SHAs and test counts wrapped around a dozen real rules. `ARCHITECTURE.md`
  §7 is the authoritative status table, so the **status** half is relocated, not lost;
  **every mechanism is kept at full length** and re-split into properly scoped bullets.
- **evidence:** skep project.md:197-321 · `ARCHITECTURE.md`:384-447 (§7 owns Phase 1–4 /
  L0–L5 status) · `grep -c` in ARCHITECTURE.md: `auth_error` 0, `detach_if_current` 0,
  `PermanentDeliveryError` 0, `shared_secret` 0, `strict-mcp-config` 0 — **the rules below
  exist nowhere else**
- **bytes:** 9785 → 5210 (−4575)
- **replacement:**
- **Phase 2 (queen/worker split + WS transport) and L0/L0.1 (mailbox +
  hardening) are SHIPPED and merged.** For *what is built and what is not*, read
  `ARCHITECTURE.md` §7 — it owns the Phase 1–4 / L0–L5 status tables and is
  overwritten in place. What follows is only the set of decisions and incidents
  that section does not carry. Structurally: `transport.py` is the seam
  (`EventSink`/`CommandHandler`/`QueenInbox` + `InMemoryEventSink`), with
  `wire.py`, `auth.py`, `ws_transport.py`, `discovery.py`, `queen/app.py`,
  `worker/app.py`, `queen/onboarding.py` on top; formatting descriptors emit
  PLAIN text and escaping happens on the queen. **`telegram_gw.py` /
  `formatting.py` deliberately stayed at `src/skep/` instead of moving into
  `queen/`** — the `Config`→`QueenConfig` split had coupled them through
  type annotations, and moving them dragged that coupling along. Watch for
  similar annotation couplings before relocating a module.

- **Four WS-transport rules, each of which cost a real bug:**
  - **Auth is FOUR frames** (`challenge`/`auth`/`auth_ok`/`auth_error`).
    `handshake_server` sends `auth_error` *before* rejecting, so a peer parked on
    `recv()` under `gather` does not deadlock.
  - **An empty or whitespace `shared_secret` must fail CLOSED** — both `serve()`
    paths raise `SystemExit`. It used to fail open.
  - **Reconnect-clobber race → `QueenRouter.detach_if_current`**, a
    compare-and-clear: a late disconnect from a superseded connection must not
    clear the live one.
  - **Idempotent topic re-attach needs per-item `try`/`except`** — one bad item
    otherwise turns the replay into an unguarded loop.
  All three of the first bugs were caught by a **whole-branch (opus) review that
  per-task reviews missed**; run one before merging a multi-task branch.

- **The L0 MCP shim is one FastMCP streamable-HTTP app PER AGENT**, on an
  ephemeral `127.0.0.1` port, with the worker-local `tid` **closed over** (not
  one server per worker keyed by token). Identity is therefore spoof-proof by
  construction (closure + server-side `agent_sender`), which is why the spike's
  token→tid map was dropped. Bind to the worker-local `tid`, synchronously at
  spawn — NOT the queen's `ref`, which is assigned async/fire-and-forget; the
  queen resolves `from`→`ref` through bookkeeping. Injected via `--mcp-config`
  **without** `--strict-mcp-config`, so the agent keeps its profile MCP servers
  (e.g. gortex). The seam is fire-and-forget both ways but mailbox tools are
  request/reply, so there is a `req_id` + `dict[req_id, Future]` correlation
  layer on the WS (`mailbox_send`/`mailbox_ack`/`inbox_read`/`inbox_reply`),
  persist-before-ack, link-down returns a retryable error and never hangs.
  **L1 memory reuses that exact layer.** Mailbox policy defaults: 20/min, depth
  10, dedupe 60 s, body 16 KB, pure-pull inbox. `fake_claude` cannot call MCP, so
  a real tool round-trip is integration/manual — unit-test the shim handlers and
  the seam's req/reply directly.

- **Four mailbox-delivery rules that are load-bearing:**
  - **A body over 4096 chars is a PERMANENT Telegram 400, and it is inside the
    16384-byte cap** — so a drain-all-stop-at-first loop wedged the whole CEO
    queue forever. `deliver_ceo` maps `TelegramBadRequest` →
    `PermanentDeliveryError`; redelivery dead-letters + alerts + skips permanent
    failures and retries only transient ones. `_safe_alert` keeps a failed alert
    from crashing the pipeline. CEO delivery is at-least-once and decoupled from
    the Telegram push: `Mailbox.pending()` is a non-destructive peek,
    `redeliver_ceo()` marks read only after a successful push, under an
    `asyncio.Lock`.
  - **`MailboxShim.stop()` catches `(Exception, SystemExit)`, deliberately NOT
    bare `BaseException`** — uvicorn's bind-collision `SystemExit` is swallowed
    while `CancelledError` still propagates.
  - **The recipient-gone re-check in `handle_send` is defence-in-depth, not a
    live bug.** Verified: the WS `_dispatch_mailbox_send` awaits `handle_send`
    inline on the queen loop and `handle_send` runs resolve→insert with ZERO
    awaits between, so `on_done`→`handle_recipient_gone` cannot interleave today.
    The guard closes the window the moment an `await` is added there.
  - **`src/skep/queen/assembly.py` must NEVER import `skep.app`** — it is the
    shared MailboxService assembly (`build_mailbox_service`, the CEO retry
    helpers, `_mailbox_db_path`) used by BOTH `build_queen` and the
    single-process `app.main`, and `queen.app` still imports `build_dispatcher`
    from `skep.app`. Importing back creates a cycle. Before this existed the
    single-process path had an inert mailbox (switch built, target never set →
    `MailboxUnavailable`) — a whole feature silently unwired, which is also what
    the whole-branch review caught in L0 itself.

- **Keep `src` pyright-clean (0 errors, `uvx pyright src`).** Plan-faithful
  rewrites regressed it once because the plan predated this repo's pyright
  governance; mirror the `_task()` assert-helper and the `Callable[...]` factory
  annotation idiom rather than reintroducing `Any`.
- **first seen:** 2026-09-11

## 3bda2df8 · dedupe · /home/me/my/skep/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:skep
- **survives:** `skep/ARCHITECTURE.md` §6 (Sessions glossary table) and §7
- **why:** the Sessions A3 bullet's **status half** is reproduced term-by-term in
  `ARCHITECTURE.md` §6 (`parked`/`parked_until`, the park sweep in both shapes,
  `origin="sweep"` logging, `detect_usage_limit` as heuristic, `_live_sessions` dedup) and
  §7 (A3 built-not-merged, deferred P2/P3). Only the five mechanisms and the
  no-give-up-counter residual are unique; those are kept **verbatim**.
- **evidence:** skep project.md:8-50 · `ARCHITECTURE.md`:344-372, :384-447
- **bytes:** 3133 → 2257
- **replacement:**
- **Sessions A3 — usage-limit park & auto-resume.** `ARCHITECTURE.md` §6
  (Sessions table) and §7 own the status and the term-by-term map
  (`parked`/`parked_until`, `detect_usage_limit` and its heuristic residual, the
  park sweep, `origin="sweep"`, the deferred P2 multi-account pool and P3
  per-subagent model). Five things live only here, because each is a mechanism
  that is easy to re-break:
  (1) **Dedup lives in `Supervisor.resume`, not `cmd_resume`.** `cmd_resume`'s
  `status != 'running'` is a cheap FILTER — it never writes status, and `running`
  is only set when the worker's `task_started` round-trips into
  `rebind_invocation`, so two callers can race. The real claim is
  `Supervisor._live_sessions: set[int]`, taken with no intervening `await` and
  released in both `resume`'s failure branch and `run_events`' `finally`; a
  duplicate raises `ValueError`. The spec asserted the opposite and was corrected
  (§5/§6).
  (2) **`build_worker_and_router` must call `router.mark_online(...)`.** Without
  it the in-process worker read as detached forever and the sweep — which skips
  offline workers — auto-resumed nothing.
  (3) **The two shapes reject differently, and both are load-bearing.**
  `RemoteWorker.resume` is fire-and-forget (returns 0, never raises), so
  rejections come back later as a `spawn_rejected` frame; single-process raises
  `CapacityError`/`ValueError` synchronously into the sweep's own `except`.
  (4) **`origin` rides the resume frame and is echoed into `spawn_rejected`**
  (alongside `action`, so the verb matches). Without it a full worker produced one
  owner Telegram message every sweep tick — 30 s apart, forever. A human's
  `/resume` still notifies, because it answers optimistically and the failure
  arrives async.
  (5) **`Supervisor.resume` seeds the new row with
  `resume_token=prev.resume_token`** — `latest_invocation` is
  `ORDER BY id DESC LIMIT 1`, so a tokenless newest row made every later resume
  fail permanently.
  **Residual:** sweep-origin suppression is TOTAL — a permanently-failing parked
  entry retries every tick forever at INFO with no give-up counter, and the
  exception type is not a usable discriminator ("already has a live invocation"
  is benign).
- **first seen:** 2026-09-11

## 7f2a658f · contradiction · /home/me/my/skep/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:skep
- **why:** the L1 bullet's load-bearing assumption says profile isolation holds *"ONLY
  because personal (`~/.claude`) and work (`~/.claude-work`) live on separate WSL distros
  with separate daemons"* and tells the reader to revisit **BEFORE** they are co-located.
  **They already are:** this box is Linux-native with a single `~/.claude`, so the
  work-notes-leak-to-a-personal-agent case the paragraph warns about is **live, not
  hypothetical**.
- **evidence:** skep project.md:512-516 · `ls -d ~/.claude*` → `/home/me/.claude` only;
  `~/.claude-work` and `~/.claude-pure` absent · `machines/AGENTS.md`: the `pure` /
  `~/.claude-pure` profile was folded back into `settings.json` in `d48c09a` · `hostname` → g513ie
- **bytes:** 421 → 867
- **replacement:**
  **DOCUMENTED ASSUMPTION, NOW BROKEN (re-checked 2026-09-11):** gortex has **no
  per-profile scope** (one daemon per user per machine). Profile isolation used to
  hold because personal (`~/.claude`) and work (`~/.claude-work`) lived on separate
  WSL distros with separate daemons + tracked-repo sets. **That premise is gone:**
  the fleet ships exactly one committed profile (`settings.json` → `~/.claude`; the
  `~/.claude-pure` work profile was folded back in `machines` commit `d48c09a`), and
  on g513ie only `~/.claude` exists — work and personal repos are already co-located
  under one daemon. So the leak this paragraph said to revisit BEFORE it happened
  has happened: a personal agent can recall a work repo's operational notes. Decide
  whether skep must scope memory itself, or whether the repo-path `--index` argument
  is enough of a boundary.
- **first seen:** 2026-09-11

## 66eee368 · contradiction · /home/me/my/skep/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:skep
- **why:** the rule names `~/.claude-work` as the work profile skep must bind work repos
  to, but **no such directory exists and nothing provisions one** — the profile registry
  is the committed `settings.<postfix>.json` set, and only `settings.json` is committed.
  The routing rule itself is **owner-confirmed design and must survive**; only its
  mechanism is stale.
- **evidence:** skep project.md:688-696 · `ls -d ~/.claude*` → `/home/me/.claude` only ·
  `machines/AGENTS.md` (the profile registry; `d48c09a`; "Orca's own account switcher is what the fleet uses now")
- **bytes:** 706 → 1302
- **replacement:**
- **Profile↔repo binding (owner-confirmed 2026-07-05): the work profile operates
  ONLY on work-related repos; personal (`~/.claude`) on personal repos.** A task's
  repo dictates its eligible profile — profiles are NOT interchangeable labor
  pools. Plan usage limits are INDEPENDENT per profile (separate OAuth accounts),
  but you generally CANNOT dodge a rate-limited profile by rerouting its work,
  because the eligible profile is fixed by the repo: work-repo +
  work-profile-exhausted ⇒ PARK (no personal fallback). The L4 "route around the
  exhausted division" idea only applies if a task is ever profile-agnostic or a
  class ever has >1 account — not the case today. **The dir name in this rule is
  stale and there is currently no second profile to bind to** (checked
  2026-09-11): the committed `settings.<postfix>.json` set IS the profile
  registry and only `settings.json` → `~/.claude` is committed, so nothing
  provisions a `~/.claude-work`; the `pure` / `~/.claude-pure` profile was folded
  back into `settings.json` in `machines` commit `d48c09a`, and g513ie carries
  only `~/.claude`. Work-account separation is Orca's account switcher now, not a
  config dir — so read this as a rule about *accounts*, and re-derive the
  mechanism before building routing on it.
- **first seen:** 2026-09-11

## ed4baa7e · promote · /home/me/my/skep/.claude/memory/project.md

- **action:** promote · **scope:** repo:skep → shared (global.md)
- **survives:** `/home/me/.claude/memory/global.md` under the existing `## Harness behavior (empirical)` heading
- **why:** both bullets are **`claude` CLI behaviour that applies in every repo on every
  box**, not skep facts, and global.md carries neither. A harness fact buried in one
  project store is a fact nobody else will find.
- **evidence:** skep project.md:642-660 · `grep -n 'permission-prompt-tool\|input-format' ~/.claude/memory/global.md` → no matches (only `--resume … --model` at :723) · global.md:636
- **carry first:** move skep project.md:644-660 **verbatim** into global.md under
  `## Harness behavior (empirical)`.
- **bytes:** 1061 → 765 in skep; +~1 KB in global.md
- **replacement:** (what stays in the skep store:)
## Gotchas

- **Both former entries here were `claude` CLI behaviour, not skep facts, and
  moved verbatim to `~/.claude/memory/global.md` under
  `## Harness behavior (empirical)`:** `--permission-prompt-tool` was REMOVED in
  `claude` 2.1.201, and `claude -p … --input-format stream-json` BLOCKS on stdin
  until EOF. skep's two consequences stay here: a Phase-3 gated-ops brake must be
  a **blocking `PreToolUse` hook** (allow/deny), never that flag; and **Phase 1
  deliberately omits `--input-format` and uses `stdin=DEVNULL`**
  (`agent.py._argv` / `start`), so the Phase-3 soft-steer must reintroduce
  `--input-format stream-json` *and* actually write a stream-json user message to
  stdin *and* keep the pipe managed — don't naively re-add the flag.
- **first seen:** 2026-09-11

## 219aad1c · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** `machines/AGENTS.md` *Tests* (auto-loaded every session)
- **why:** the finding, the `-ExecutionPolicy Bypass` cause, and the whole nested
  "multibyte brace rule guards nothing" subsection are already in AGENTS.md. Only the
  `pwsh.exe`-first PATH-ordering fact is unique to the store.
- **evidence:** project.md:2392-2434 · AGENTS.md:239-257
- **bytes:** 2804 → 565
- **replacement:**
## "Environmental failure" was never a category — both reds were bugs (2026-09-02)

The finding and both post-mortems now live in `AGENTS.md` (*Tests*: "Known
environmental failure" is not a category, plus the measured retraction of the
multibyte brace mechanism). Kept here is the one detail that is not there:

- **On WSL, put `pwsh.exe` FIRST in any shell-out candidate list.** `for c in
  pwsh powershell powershell.exe` always lands on Windows PowerShell **5.1**,
  because only the `.exe` spellings are on PATH there; the Windows members run
  PS 7. `pwsh.exe` under `WindowsApps` is a real binary (7.6.5), not a Store stub.
- **first seen:** 2026-09-11

## 4f3a0a16 · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** `machines/AGENTS.md` Windows-front-door paragraphs
- **why:** four of the six bullets (`Write-Error` cannot guard, `$env:X=''` removes the
  variable hence `-PlannedRoles`, `foreach` over `$null`, `Test-FleetMachine`) are
  restated nearly verbatim in AGENTS.md. Three bullets have **no second source** and are
  kept in full.
- **evidence:** project.md:2435-2464 · AGENTS.md:387-411
- **bytes:** 1915 → 935
- **replacement:**
## PowerShell provisioning traps (2026-09-02, closing roadmap P3)

`Write-Error` cannot implement a guard, `$env:X = ''` REMOVES the variable (hence
`-PlannedRoles` as a parameter, not an env var), and `foreach` over `$null`
iterates zero times — all three are written up in `AGENTS.md`'s Windows
front-door paragraphs. Three traps that are only here:

- **Do not port the padded-substring match.** posix needs `case " $PLANNED " in
  *" $role "*)` so `ssh` cannot match `ssh-server`. PowerShell's `-contains` is a
  whole-element match on the array; the hazard does not arise and the padding
  would be cargo.
- **Defining a function in a `.psm1` and exporting it are separate acts.**
  `Export-ModuleMember`'s backtick-continued list is easy to miss, and an
  unexported guard simply never runs. The suite asserts the name reaches that line.
- **`provision.ps1` runs end to end from WSL** via `pwsh.exe` against the real
  Windows side, which makes the exit-code assertions real coverage rather than a
  source grep. ~8s for a full dry run, ~1s for the unknown-machine arm.
- **first seen:** 2026-09-11

## 1335a42c · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** the code, which ships its own reasoning
- **why:** both bugs are fixed and each fix carries its rationale in a load-bearing
  comment — `provision/orca-serve.sh`:124-137 narrates the cache-key/extract-gate bug,
  `justfile`:79-82 carries the `< /dev/null` fix. Keep the generalised rules, drop the
  incident narrative about a **dead distro** (g15-wsl destroyed 2026-09-07).
- **evidence:** project.md:2504-2553 · `provision/orca-serve.sh`:124-137 · `justfile`:79-82
- **bytes:** 3592 → 1420
- **replacement:**
## Orca IDE on g15-wsl never upgraded — the cache key was the word "latest" (2026-09-07)

Both bugs are fixed and each fix ships with its reasoning in the code —
`provision/orca-serve.sh:124-137` for the upgrader, `justfile:79-82` for the
gate's `< /dev/null`. What generalises past that one dead distro:

- **`apt`'s `orca` package is the GNOME screen reader**, not Orca IDE, and
  `which orca` under non-interactive ssh finds `/usr/bin/orca` FIRST because
  `~/.local/bin` is not on that PATH. Orca IDE on Linux is only ever the AppImage
  under `~/.local/opt/orca`. `orca --version` does not exist on this build — it
  prints help — so the one truthful record of what is EXTRACTED is
  `squashfs-root/orca-ide.desktop`'s `X-AppImage-Version`, compared with the
  leading `v` stripped from BOTH sides.
- **A cache key that never varies is a cache that never misses.** Naming the
  download `…-${VER:-latest}` and gating on "the file exists" made the upgrader
  run green while doing nothing, for nine days. Resolve the tag up front, name
  the cache file by the resolved tag, download to `.part` (a truncated file at
  the final name is a permanent cache hit — the same bug again), and gate the
  extract on the extracted version, never on the directory existing.
- **A test runner that hands each suite the loop's own stdin truncates itself.**
  A suite that execs PowerShell reads that fd to EOF; the gate then printed
  "all 32 suites passed" while skipping 17, and only on boxes where PowerShell is
  on PATH. `just test`'s printed total is a floor, not the repo.
- **first seen:** 2026-09-11

## f9d54642 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** the 2026-09-06 conclusion *«автоочистки нет ни при каком ratio для уже
  скачанного; настройка ratio влияет только на новые закачки»* was **falsified the next
  day by this store's own measurement**: 25 already-downloaded torrents were auto-removed
  with files after `max_ratio_act` went Pause → Remove. A reader hitting the earlier
  section first concludes qBittorrent cannot clean up existing torrents — **on a host that
  is still running.**
- **evidence:** project.md:2472-2476 · project.md:2554-2564
- **bytes:** 568 → 612
- **replacement:**
- **`Remove Completed Downloads: True` этого не спасает.** Он работает по
  очереди *arr, а *arr забывает торрент после импорта: замерено 2026-09-06 —
  очередь Radarr 3 записи, Sonarr 0, при 46 живых торрентах.
  **Ограничителем был не ratio, а `max_ratio_act = Pause`** — правило срабатывало
  и ничего не удаляло. Опровергнуто на следующий день (см. ниже, 2026-09-07):
  с `max_ratio_act = 3` (Remove torrent AND files) qBittorrent снял 25 **уже
  скачанных** торрентов вместе с файлами. То есть ratio действует и на старые
  закачки; «влияет только на новые» было неверно.
- **first seen:** 2026-09-11

## 1fcf9087 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** the section's own header bullet declares the "only copies" premise **closed**
  (2026-09-10), and everything else describes the pre-wipe staging state of a machine
  reinstalled 2026-09-07. Its closing bullet still calls `tier_docker` undecided, which
  contradicts `provision/lib/tiers.sh`:278 and AGENTS.md. **Compress rather than delete:**
  the Ventoy bullet is a **live obligation** (`archive-mirror.timer` fires 2026-10-01).
- **evidence:** project.md:2590-2641 · `provision/lib/tiers.sh`:278 · AGENTS.md `tier_docker`
- **bytes:** 3939 → 980
- **replacement:**
## g15 phase 1 done — where the only copies live (2026-09-07)

**Closed. The wipe happened 2026-09-07 and the staging is fully unwound
(2026-09-10):** `pgdata` deleted from the mirror by the owner's decision — the
live `qaz-law-db-1` runs on g15 at `/data/qaz-code/pgdata` (126 G) and is
rebuildable; `home-me` is back on g15 and off staging; `Music` (152 G) is on g15
inside the restic profile `g513ie-maintenance`. The one-copy question was decided,
not deferred — do not re-raise it. `tier_docker` is no longer "undecided": it
exists (`provision/lib/tiers.sh`) and AGENTS.md documents it.

Two things outlive the phase:

- **The Ventoy drive is shared with latitude.** The same physical drive that
  carried `ubuntu-26.04.1-desktop-amd64.iso` also holds latitude's `xs700`
  archive-mirror partition, and `archive-mirror.timer` next fires
  **2026-10-01 05:01** — return the drive before then. Secure Boot on g15 is
  OFF, so Ventoy needs no MokManager enrolment.
- **Why Ubuntu and not Debian:** asus-linux names a **6.19+ kernel floor**;
  trixie ships 6.12, Ubuntu 26.04 ships 7.0 out of the box. Spec:
  `docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md`.
- **first seen:** 2026-09-11

## 514c862d · generalise · /home/me/machines/.claude/memory/project.md

- **action:** generalise · **scope:** repo:machines
- **why:** this paragraph's whole ranking is measurements **between two WSL distros that
  no longer exist** (g15-wsl destroyed 2026-09-07), and its one surviving number —
  desktop-wsl → latitude at 99 MB/s — is already in AGENTS.md *One LAN, not two*. Replace
  the dead route table with the two rules that still hold anywhere.
- **SCOPE WARNING:** the replacement covers **only this paragraph**; it must not touch the
  nested `###` subsections that follow at 2168.
- **evidence:** project.md:2138-2166 · AGENTS.md *Fleet networking*, "One LAN, not two"
- **bytes:** 2092 → 905
- **replacement:**
Transport, for the next time something big has to move. The g15-wsl route table
here is dead (that distro was destroyed 2026-09-07) and the live fleet numbers
are in AGENTS.md's *One LAN, not two*. Two rules survive it:

- **A relayed pair cannot be fixed with a faster radio; only by leaving the
  relay.** Two NATed WSL distros had no direct path and sat at 3.3 MB/s through
  hub's DERP in Kazakhstan — unchanged after both laptops moved to a 1201 Mbps
  WiFi 6 rate. NAT blocks reaching *in*, not going out, so the winning route was
  always the distro **pushing outbound** to a LAN address (78 MB/s), or the LAN
  route through the Windows host's sshd into `wsl.exe` (44 MB/s, 13x the relay,
  same radio). A direct Ethernet cable on APIPA (169.254.x, no DHCP) gave
  117 MB/s and turned 8 hours into 40 minutes.
- **Two traps that produced three false zero-byte "measurements":** `ssh` to a
  **bare IP** does not pick up the fleet identity (the generated config keys on
  `Host *.gg.ez`) — pass `-i ~/.ssh/id_fleet -o IdentitiesOnly=yes`, or it fails
  in 0.2 s having transferred nothing, which looks exactly like no bandwidth. And
  **only port 22 is open inbound** on a Windows box, so `nc` to any port you pick
  is refused and the transfer must ride ssh.
- **first seen:** 2026-09-11

## 514fbd58 · generalise · /home/me/machines/.claude/memory/project.md

- **action:** generalise · **scope:** repo:machines
- **why:** the whole section is scoped to a distro destroyed 2026-09-07, and its "State
  now" bullet (unit active on `:6768`, both clients paired to `ws://100.64.0.9:6768`)
  describes a node that no longer exists. Three of its findings are **runtime properties
  of Orca/Electron/WSLg** that still apply to `desktop-wsl` and to any headless serve.
- **evidence:** project.md:2308-2354
- **bytes:** 3231 → 1490
- **replacement:**
## Orca headless serve: what survives from g15-wsl (2026-08-29)

The host is gone (g15 was wiped to native Ubuntu 2026-09-07), so the paired
`ws://100.64.0.9:6768` environment and its three worktrees are history. The
reason serve exists is not: **`orca serve` + `environment add --pairing-code` is
the only way one box can drive another's Orca** — there is no ssh-remote mode,
and Windows Orca reaches only its own host's distro. The 2026-07-21 removal
("Orca runs on Windows now") was host-local, and the abandoned 2026-08-01 spec
abandoned *two distros per host*, not the serve model; don't re-read either as
"serve was tried and rejected". Four findings that still hold:

- **Serve needs an X display and under WSLg cannot make its own.** Orca starts an
  Xvfb on `:99` when `DISPLAY` is unset; WSLg mounts `/tmp/.X11-unix`
  **read-only**, so Xvfb never binds and Electron dies with `Missing X server or
  $DISPLAY` — a crash loop (72 restarts before it was caught), not the "browser
  panes may be unavailable" the warning suggests. WSLg already serves `:0` on
  that tmpfs; hand serve that.
- **Electron flushes a non-tty stdout only at exit**, so under systemd the
  journal shows nothing until the process dies and the documented "read the
  pairing URL from `journalctl`" never works. `script -qefc … /dev/null` gives it
  a pty; `-e` preserves the exit status for `Restart=on-failure`.
- **Judge a serve run by whether the unit stays active, never by shutdown
  lines.** Piping serve into `grep | head`, or capping it with `timeout`, makes
  Chromium tear down noisily ("Network service crashed", "GPU process isn't
  usable. Goodbye.", `SIGTRAP`). Two fixes were spent on that phantom (SUID
  `chrome-sandbox`, `ELECTRON_DISABLE_SANDBOX`); both were reverted, neither was
  needed.
- **Backticks inside an UNQUOTED heredoc run as a command substitution.** A
  comment reading `` `script -e` `` executed `script`, spawned an interactive
  bash and hung the provisioner. And a `timeout` that kills the local ssh client
  does NOT kill the remote script — `pkill -f "bash /tmp/orca-serve[.]sh"`, where
  the bracket keeps the pattern from matching your own command line.
- A pairing code is **not single-use**: the runtime's identity is stable across
  restarts, so the same code paired two clients.
- **first seen:** 2026-09-11

## f48622f0 · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** this bullet ends with a **standing order** — «Но удалять его пока нельзя…
  Сначала лег в restic, потом удаление» — to preserve the 186 G `pgdata` staging copy and
  add PGDATA to restic. **The owner reversed both two days later**; the same file and the
  roadmap record the leg as CLOSED and the copy deleted. Keep the reusable
  `system_identifier` method, drop the void order.
- **evidence:** project.md:3108-3120 · superseded by project.md:3043-3050 and :2834-2836 · `docs/fleet-roadmap.md`:952-960 ("CLOSED 2026-09-10 — the leg is not wanted at all")
- **bytes:** 1374 → 824
- **replacement:**
- **`g15-staging/pgdata` доказан избыточным 2026-09-09 — сверкой кластера, не
  на глаз.** `system_identifier` из `global/pg_control` staging-копии и из
  `pg_control_system()` живого `qaz-law-db-1` на g15 совпали:
  **7659741180334813227**. Первые 8 байт `pg_control` — это и есть
  `system_identifier`, читается питоном без `pg_controldata`, который всё равно
  не прочёл бы файл v18. **Стоявший здесь запрет «удалять пока нельзя, сначала
  лег в restic» СНЯТ 2026-09-10** — БД признана перестраиваемой, лега не будет,
  staging-копия удалена; см. «The DB leg is CLOSED» ниже.
- **first seen:** 2026-09-11

## 79129a06 · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** project.md:3043-3050 (the later dated entry, same file)
- **why:** this paragraph argues the 186 G `pgdata` staging leg is KEPT deliberately
  because *"g15's roles are `base, ssh-server, agents, dotfiles, repos` — no
  `backup-client`, so nothing about g15 is in restic at all"*. **Both halves are now
  false** — g15 has the role and a repo, and the leg was closed and the copy deleted.
- **evidence:** project.md:2789-2796 · superseded by :3043-3050 and :2815-2818 · `ls machines/backup/` → `base.yaml desktop-wsl g15 latitude …`
- **bytes:** 611 → 0
- **replacement:** (none — deletion)
- **first seen:** 2026-09-11

## 754828b4 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **ANCHOR NOTE:** the finding sits under the `###` subsection *"A WSL-era shim survived
  the native reinstall and shadowed xdg-open (2026-09-08)"* at L2798. `dream.sh index`
  lists `##` only, so the anchor is the **enclosing `##`**. See the `skill` item on anchor
  granularity.
- **why:** the symptom narrative is settled and its stated class ("every host-local shim
  installed for WSL is still sitting in `~/.local/bin`") **is now empty on g15** — no WSL
  shim remains. Compress to one generalised bullet keeping the mechanism and the check.
- **evidence:** project.md:2798-2814 · `ls ~/.local/bin` → bat ciadpi claude fd
  git-autofetch gortex just orca-cli orca-ide orca-serve-start resticprofile uv uvx
  wt-setup wt-teardown (**no `xdg-open`, `wslview`, `wslopen`**)
- **bytes:** 1093 → 734
- **replacement:**
- **A host-local WSL shim can outlive the distro and shadow a system binary.**
  `$HOME` survived the 2026-09-07 Windows→Ubuntu reinstall, so `~/.local/bin`
  still held `xdg-open`→`wslopen` (plus `wslview`), the opener
  `provision/wsl-fixes.sh` installs; it shells out to `powershell.exe`, so every
  `shell.openExternal` in every Electron app silently exited 1 — the symptom was
  Orca refusing to add a second Claude account. `~/.local/bin` precedes
  `/usr/bin`, the shims are untracked, so no provision run removes them and
  nothing reports them. All three deleted 2026-09-08 and none remains on g15.
  **When a GUI/tooling failure on g15 makes no sense, check `command -v <tool>`
  before believing the app is broken.**
- **first seen:** 2026-09-11

## 06b4c635 · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** project.md:3043-3050 (canonical) + `docs/fleet-roadmap.md`:952-960
- **why:** **third copy** of the PGDATA-leg story, still framed as an open storage blocker
  with superseded free-space arithmetic and the closure bolted on at the end. Collapse to
  the settled decision plus the method facts that would otherwise be re-derived.
- **evidence:** project.md:2828-2836 · :3043-3050 · `docs/fleet-roadmap.md`:952-960
- **bytes:** 718 → 461
- **replacement:**
- **PGDATA is excluded, and since 2026-09-10 permanently — do not "fix" this by
  adding the source.** The method was never the blocker and is proven on this
  exact data: a cleanly stopped PGDATA copied physically (the container's
  STOPSIGNAL is SIGINT = postgres fast shutdown, `me` is in `docker`, reading it
  needs root at `999:0` mode 700). It is excluded because the DB is rebuildable
  and its corpus (`~/my/qaz-code/laws`) is already a source here.
- **first seen:** 2026-09-11

## 56099df2 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** half this bullet is arithmetic in service of the DB-leg decision ("that is the
  number that decides the DB leg", the 89 G music pile that would free space), and **both
  are settled** — the leg is closed and the pile was deleted 2026-09-08. The snapshot
  measurement itself is worth keeping; the free-space bookkeeping is not.
- **evidence:** project.md:2876-2882 · closure at :3043-3050 · music-pile deletion at :3035-3042
- **bytes:** 517 → 283
- **replacement:**
- **`e5940ee8`** — 124985 files, 95.540 GiB processed → **88.945 GiB added,
  82.012 GiB stored**, in **36:34** (≈44 MB/s end to end, not the 99 MB/s
  tailnet ceiling: the `laws` corpus is ~125k small files and per-file overhead
  dominates the music half). На диске **83 G**.
- **first seen:** 2026-09-11

## 0a184245 · dedupe · /home/me/machines/.claude/memory/project.md

- **action:** dedupe · **scope:** repo:machines · **survives:** `machines/AGENTS.md` (the `tier_*` list + the latitude entry)
- **why:** four bullets restate what AGENTS.md already documents — the 2026-08-03 flagship
  gap, both posix profiles, two keys not four, masks no sleep target, the
  `/proc/acpi/button/lid` gate, reload-not-restart. **AGENTS.md is the canonical home for
  `tier_*` behaviour** (it carries every sibling tier in one list), so that copy survives;
  memory keeps only what was measured on the boxes. The trailing "Suite green, 54 suites"
  also violates AGENTS.md's own don't-write-suite-counts rule **and is already stale (55)**.
- **evidence:** project.md:3153-3192 · AGENTS.md:300-313 and :685-697
- **bytes:** 2887 → 1637
- **replacement:**
## Lid close no longer sleeps a mains-bound box — `tier_lid_ignore` (2026-09-08)

What the tier is and why it exists is in `AGENTS.md` (the `tier_*` list, and the
latitude entry). Only what was measured on the boxes is kept here.

- **g15 shipped stock: `HandleLidSwitch=suspend`, `HandleLidSwitchExternalPower=suspend`**,
  and logind's own config was the whole lever — `/etc/systemd/logind.conf.d/` did
  not exist, GNOME's idle suspend is already `nothing` on AC and battery
  (`org.gnome.settings-daemon.plugins.power sleep-inactive-*-type`), and
  `systemd-inhibit --list` showed **no** `handle-lid-switch` block from gsd-power
  (GNOME only takes that one with an external monitor attached). That negative is
  the reusable part: do not re-investigate GNOME here.
- `HandleLidSwitchDocked` and `IdleAction` are already `ignore` upstream
  (`systemd-analyze cat-config systemd/logind.conf`, systemd 259 on g513ie / 257
  on latitude), which is why the tier writes two keys and why deleting latitude's
  hand-written `99-server.conf` changes nothing.
- **Drop-ins merge in filename order, so read back the merged config, not the
  file you just wrote.** `cat-config`'s LAST assignment is the effective one; the
  tier warns by name about a competing drop-in, and latitude's `99-server.conf`
  sorts after `99-fleet-lid.conf` and will keep nagging until P6 retires it.
  Retire it AFTER latitude's next converge run, never before: `tiers.sh` is a
  `_touches_driver` trigger, so that run comes on its own.
- Both mutations bite: masking a sleep target, and dropping the `/proc/acpi/button/lid`
  gate, each turn an assertion red.
- **first seen:** 2026-09-11

## cd0c04cc · contradiction · /home/me/.claude/host-memory.md

- **action:** contradiction · **scope:** host (g15) · **apply on:** g15 — this box
- **why:** the store tells **every session on this box** that *"Gortex tracks nothing on
  this box (`repos: []`)"* and that the CLAUDE.md mandate cannot be honoured — but
  `~/.gortex/config.yaml` lists **five** tracked repos and the live MCP hook blocked four
  greps during this very pass. **This bullet actively licenses the wrong tool choice on
  five repos.** Related: the shared-scope gortex contradiction filed against
  `~/.claude/CLAUDE.md` this run.
- **evidence:** `~/.claude/host-memory.md`:25-29 · `cat ~/.gortex/config.yaml` → `repos:`
  with `/home/me/my/airdrome`, `/home/me/machines`, `/home/me/my/vps`,
  `/home/me/my/telegrind`, `/home/me/my/embedthat` · a bare-word grep in this session
  returned `[Gortex] BLOCKED: "repos" matches 1 indexed symbol(s)`
- **bytes:** 606 → 792
- **replacement:**
## Notes

- **Gortex tracks five repos on this box** — `~/.gortex/config.yaml` lists
  `airdrome`, `machines`, `vps`, `telegrind`, `embedthat` — and the MCP server is
  live: its PreToolUse hook actively blocks `Grep`/`Read` inside those trees and
  redirects to `search`/`explore`. The mandate in `~/.claude/CLAUDE.md` applies
  here. Coverage is path-prefix, so native Read/Grep/Glob is the correct fallback
  only OUTSIDE those five paths (e.g. `~/my/qaz-code`); `gortex track <path>`
  followed by an MCP reconnect adds one.
- `~/.claude/host-memory.md` (this file) did not exist on the `g15` branch until
  2026-09-07; its `!/.claude/host-memory.md` allow-line was added to
  `~/.gitignore` at the same time. The sync timer runs `add -u` and would never
  have staged it on its own.
- **first seen:** 2026-09-11

## 4ad05022 · dedupe · /home/me/.claude/host-memory.md

- **action:** dedupe · **scope:** host (g15) · **apply on:** g15
- **survives:** `~/my/qaz-code/.claude/memory/project.md` (*Machine move*), auto-loaded in that repo
- **why:** the BGE-M3 demo-dependency bullet and the 1,326 chunks/min figure exist in
  **both** stores. The qaz-code copy survives for both because it carries the consequences
  the host copy drops — cold cache degrades to full-text **silently**, "warm the cache on
  whatever machine runs the talk", and the ~250 h / ~82 GB `--all-versions` arm. The host
  copy keeps only what is genuinely machine-scoped.
- **evidence:** host-memory.md:42-48 · qaz-code project.md:100-104 and :97-99
- **bytes:** 867 → 708
- **replacement:**
## qaz-law / KazHackStan work

Machine-local facts only — the reasoning behind them lives in
`~/my/qaz-code/.claude/memory/project.md` (*Machine move*), which is auto-loaded
in that repo.

- Base checkout `~/my/qaz-code` on `main`; the active worktree is
  `~/orca/workspaces/qaz-code/kazhackstan-2026` (Orca-managed, branch
  `metheoryt/kazhackstan-2026`). Postgres runs from the worktree's compose stack
  on **port 5436**, project name pinned to `qaz-law`, so both checkouts share
  one database — **184 GB** as of 2026-09-07, plus 7.6 GB of built `laws/`.
- `~/.cache/huggingface` holds the BGE-M3 weights (4.3 GB), downloaded here
  2026-09-07. Not a cache to clear — the repo store explains why.
- **first seen:** 2026-09-11

## b7426f5c · promote · /home/me/my/airdrome/.claude/memory/project.md

- **action:** promote · **scope:** repo:airdrome → shared (global.md)
- **why:** the third bullet says Docker is unreachable and therefore `uv run pytest`
  *"cannot run from a worktree here at all"* — it describes the **`g614jv` WSL distro
  destroyed 2026-09-07**, while airdrome now runs on **native Docker on g15**. The Docker
  Desktop shim mechanism is still true of the live `desktop-wsl` and is **NOT** in
  global.md (whose WSL/Docker section covers compose project-name collisions, a different
  failure), so it must move up rather than be deleted.
- **evidence:** airdrome project.md:20-24 · `command -v docker` → `/usr/bin/docker`, server
  29.8.0; `docker ps` → `airdrome-db-1 Up 4 hours`; `git worktree list` → single entry ·
  global.md:900-918 covers only project-name collisions
- **bytes:** 1100 → 778 in airdrome; +~1 KB in global.md
- **replacement:** (what stays in airdrome's store:)
## Worktrees

- A fresh worktree (Orca or plain `git worktree add`) starts **without `.venv` and
  `.env`** — both are gitignored, so nothing carries over from the base checkout. No
  `uv run` command works until you `uv sync` and create `.env` (`DB_DSN`, `LIBRARY_DIR`
  — see README *Configuration*). The repo has no `.orca/worktree-setup.sh`, so this is
  manual per worktree.
- The test suite additionally needs the compose Postgres up (`docker compose up -d`,
  port 5437). **On g15 (native Ubuntu, Docker 29.8.0 at `/usr/bin/docker`) this works
  from any checkout** — verified 2026-09-11, `airdrome-db-1` up 4 h. The old "Docker
  is unreachable, use another box" caveat described the destroyed `g614jv` WSL distro
  and is now in global memory as a WSL-only trap.
- **carry first — APPEND to `~/.claude/memory/global.md` under `## Docker Desktop shares one engine across all WSL distros`:**
- **Inside a WSL distro, `command -v docker` succeeding proves nothing.** Docker
  Desktop puts a shim on `PATH` in every distro, but if the distro is not enabled
  in Docker Desktop's WSL integration list every invocation dies with
  `The command 'docker' could not be found in this WSL 2 distro` — so a probe that
  tests for the binary passes and the compose stack still cannot start. Test with a
  real `docker version`/`docker ps`, never `command -v`. (Hit on the Ubuntu-26.04
  distro on `g614jv`, which hosted Orca worktrees; a native-Docker Linux box has no
  such split.)
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

## b10ab39d · contradiction · /home/me/machines/.claude/memory/project.md

- **action:** contradiction · **scope:** repo:machines
- **why:** two false claims plus a duplicate. The `ConditionPathIsMountPoint` bullet ends
  *«у mirror-refresh.service эта Condition всё ещё стоит»* — **untrue by the end of the
  same day** (project.md:3559 and AGENTS.md:619-621 both say both mirror units are
  Condition-free); the `install-docker-ordering.sh` add/remove bullet is verbatim in
  AGENTS.md:586-599; and bullet 1 uses «24 reset'а за сутки» as a **live** reason,
  contradicting the docks section above it.
- **nothing is lost:** the compressed-out verify numbers (2075 files / 2041 inodes /
  736 552 035 464 bytes) survive verbatim at project.md:3361-3367.
- **evidence:** project.md:3431-3513 · AGENTS.md:586-599, 614-621
- **bytes:** 9074 → 6019
- **replacement:**
## Архив 1970–2024 получил вторую копию — и почему не на 8 ТБ (2026-09-10)

- **Комната была не той осью.** `/mnt/wd8` с 6.4 T свободного выглядел
  очевидным приёмником для 663 GiB архива, и это худший выбор из доступных:
  wd8 и источник `immich-2024` — два отсека ОДНОГО дока Ugreen (`usb4/4-2`),
  один общий линк 5 Гбит; HGST на `4-1` имеет свой линк. Контроллер один
  (10 Гбит) и он никогда не был ограничением. **Мерить топологию (`udevadm info
  -q path -n sdX`) до выбора отсека, а не размер.** Довод «на 4-2 24 reset'а за
  сутки» в этом выборе НЕ участвует: тот шторм кончился 17.08 — см. раздел про
  доки.
- Живая расстановка на 2026-09-10: `u4-1:0` spare320, `u4-1:1` HGST
  (`/mnt/immich-2024-backup`), `u4-2:0` wd8, `u4-2:1` immich-2024,
  `u3-2.4:0` immich-mirror в стопгап-корпусе NS1066.
- **HGST освобождён под архив, потому что копия servarr была ДОКАЗАННО
  избыточна**, а не потому что «прошло достаточно дней»: verify PASS на живом
  стеке (цифры — в разделе про ServarrMedia) плюс qBittorrent уже перепроверил
  все раздачи хешами против wd8. Выдержка по календарю стоила дороже, чем
  давала: невосстановимые фото лежали в одной копии, пока единственный
  подходящий отсек держала избыточная копия скачиваемой медиатеки.
- Приёмник стал ext4 вместо exfat, и это сняло весь набор уступок:
  `-aHAX` вместо `-rlt --no-perms --no-owner --no-group --modify-window=1`.
  Восстановление больше не требует `chown`.
- **`rollback` в `migrate-servarr-wd8.sh` теперь отказывается, если источник
  пуст.** Старое тело направило бы `DATA_ROOT` на путь, который уже не точка
  монтирования; docker создаёт отсутствующий bind-источник, стек поднялся бы на
  пустом каталоге на `/`, и базы *arr свели бы библиотеку к нулю. Проверка —
  «есть ли файлы», а не флаг: маркер пришлось бы обновлять тому, кто удалял
  источник, а именно этот класс забывчивости здесь и ломается.
- **`du -sb` НЕ считает `st_size` каталогов** — измерено на GNU coreutils 9.7
  (latitude) и uutils 0.8.0 (desktop-wsl). Я утверждал обратное — что гейт
  `archive-mirror.sh` на равенстве `du -sb` напечатал бы ложный `INCOMPLETE`, —
  и это было неверно дважды: механизм не тот, а «доказательством» служило
  сравнение недокопированного дерева с полным (каталог, в который ещё пишут, не
  достиг конечного размера). **Механизм, который собираешься написать в
  сообщении коммита, — это ровно тот момент, когда его надо померить.**
- **Оси групп хардлинков в этом гейте нет НА ПРОВЕРЕННОЙ предпосылке** — в
  дереве 0 файлов с `nlink>1` (2026-09-10 и обзор 2026-08-01). Скрипт теперь эту
  предпосылку проверяет и кричит, если она перестанет держаться; тогда нужна
  группировка, как в `migrate-servarr-wd8.sh phase_verify`.
- **Асимметричное sudo снова.** `-verify` читал источник через `sudo find`, а
  приёмник голым `find`: под каталогом, который не обойти, `find` недосчитывает
  МОЛЧА и печатает MISMATCH на здоровой копии. Ровно та форма, что заставляла
  самопроверку хаба звать живые restic-репозитории MISSING. Выживает потому, что
  ловится только ручным прогоном — юнит работает от root.
- **Нельзя править файл скрипта, пока его юнит работает**: bash дочитывает
  скрипт с диска по ходу, а `git pull` может усечь тот же инод. Правильно —
  остановить юнит (rsync возобновляемый, `--partial-dir` держит недокачанный
  файл), подтянуть, запустить снова.
- Метка ext4 обрезается до **16 байт** без ошибки, только с
  `Warning: label too long` — `immich-2024-backup` стал `immich-2024-back`.
  Живёт как `immich-2024-bak`.
- **`just` на desktop-wsl нет, и ручной прогон сюит требует `</dev/null`** —
  без него цикл проглатывает часть сюит (тест, читающий stdin, выедает остаток
  подстановки процесса). Это НЕ дефект гейта: рецепт `test` уже делает
  `bash "$t" < /dev/null`. Ловушку репозиторий уже знал; переоткрыл её я.
- **first seen:** 2026-09-11

## d4622cef · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** narrative prose from the same evening; the durable content is four rules —
  verify with `restic check` not rsync, baseline before the copy; `fleet-selfpull` will
  pull your commit mid-migration so writers stop at `sync`; what the move did **not** buy;
  what it freed.
- **ordering note:** the `generalise` item on the guards-that-report-success section now
  also carries the `run-before` / `systemctl --failed` instances, but they are **kept
  inline here too** so this row stands alone if that one is rejected.
- **evidence:** project.md:3387-3429
- **bytes:** 4174 → 3618
- **replacement:**
## Оба restic-репозитория на 8 ТБ — и почему гейт «поздний pull» не гейт (2026-09-10)

Хаб `restic-rest` (112 G: g513ie + g614jv) и собственный репозиторий latitude
(12 G) переехали `/mnt/spare320` → `/mnt/wd8` скриптом
`hosts/latitude/debian/migrate-restic-wd8.sh`. Балк-проход 40 мин (123 G,
~58 МБ/с), дельта под остановленными писателями — ноль байт, обе проверки
чистые с первого раза (в отличие от servarr: репозиторий append-only, и хаба
за время копии никто не трогал).

- **Проверять надо не rsync.** Байт-в-байт необходимо и недостаточно;
  сохраняемое свойство — «restic этим может пользоваться». `restic check` по
  всем трём репозиториям, до и после: 33 / 19 / 4 снимка, одинаково. Baseline
  снимался на источнике ДО копии — иначе падение проверки на приёмнике нечем
  объяснить.
- **Коммит с новыми путями нельзя придержать до `cutover`.**
  `fleet-selfpull.service` — пользовательский таймер, который сам делает
  ff-merge всех fleet-репозиториев; он подтянул коммит за 25 минут до конца
  копии, и `profiles.yaml` указал на `/mnt/wd8` поверх наполовину
  скопированного дерева. Ничего не сломалось только потому, что до 04:30 не был
  запланирован ни один писатель: `run-before` в профилях — половина гейта, он
  проверяет наличие объекта `config`, а не ПОЛНОТУ репозитория, так что
  `forget --prune` в этом окне отработал бы по частичной копии. Поэтому
  писателей останавливает `sync`, в начале, а не `cutover`: это суточные
  задания, вся миграция меньше часа — держать их выключенными дешевле, чем
  угадывать окно. И `status` печатает, сколько таймеров стоит: брошенная между
  `sync` и `cutover` миграция иначе тихо оставляет бэкапы выключенными, а
  `systemctl --failed` на просто остановленный таймер чист.
- **Что переезд НЕ купил.** На `/mnt/wd8` лежит и ServarrMedia, отдельного
  диска у репозиториев больше нет; радиус поражения теперь ограничивает
  off-site копия, а не выбор отсека. И опасность пустой точки монтирования
  никуда не делась: доки роняет розетка, а 8 ТБ стоит в таком же доке.
- **Освободилось:** место для PGDATA-ноги g15 (~130 G) — это был единственный
  storage-блокер, теперь 6.4 T свободно. Копии на `/mnt/spare320` не тронуты —
  сносить только после выдержки, и это то, что освободит отсек дока.
- **first seen:** 2026-09-11

## dca1d781 · compress · /home/me/machines/.claude/memory/project.md

- **action:** compress · **scope:** repo:machines
- **why:** a session narrative («Спросил «я у g15, го»…»), and its `/etc/sysctl.d`
  lexical-order bullet is already in AGENTS.md *Key patterns* under `tier_sysrq` (the
  auto-loaded copy survives), as is the `fleet-selfpull.test.sh` fix, already committed as
  `f568fbb`. The durable lessons all survive — dirty tree on a box is invisible work AND a
  stopped selfpull, `git apply --3way` as the transfer, which tier was actually live,
  NOPASSWD dropped rather than granted, stale prohibitions.
- **evidence:** project.md:3664-3715 · AGENTS.md:479-495
- **bytes:** 5680 → 4184
- **replacement:**
## 280 строк защиты от зависания лежали незакоммиченными на g15 (2026-09-11)

- **Работа, сделанная НА боксе, на боксе и осталась.** `~/machines` на g15 был
  грязным с 9 сентября: 280 строк — `tier_oom_guard` + `tier_sysrq`, AGENTS.md,
  README.md, `linux.sh`, `tiers.test.sh`. В репозиторий не попало ничего.
  Проверять надо не только «зелёный ли гейт», а **чистое ли дерево на каждом
  боксе фронта** — грязное дерево к тому же останавливает `fleet-selfpull`, так
  что g15 два дня не подтягивал ничего.
- **Перенос: `git apply --3way` из `git diff` по ssh.** Патч сначала в
  scratchpad, `--3way` чтобы конфликт был маркерами, а не тихой промашкой, и
  `git stash` на боксе (а не `checkout --`), пока не доказана избыточность —
  единственная копия работы была именно в том diff.
- **Из двух тиров применён был только один, и не тот, что казалось.**
  `tier_sysrq` жив с той ночи, а `tier_oom_guard` — нет: `user-.slice.d` не
  существовало, лимиты `infinity`. Защита при этом БЫЛА, но пользовательским
  файлом `~/.config/systemd/user/app.slice.d/50-memory-guard.conf`, то есть
  только для того, что запускает рабочий стол; по ssh то же самое не
  покрывалось. После прогона `bash provision/linux.sh` на его клавиатуре:
  user-1000.slice MemoryHigh=18.2 G / MemoryMax=22.7 G / MemorySwapMax=2 G,
  вживую. (Про лексический порядок `/etc/sysctl.d` и конкурирующий
  `60-sysrq.conf` — в AGENTS.md, *Key patterns*.)
- **NOPASSWD на g15 снят со списка, а не сделан.** Он был там ради ноги бэкапа
  qaz-law/PGDATA, а её владелец отменил 2026-09-10: база пересобираема, а корпус
  `~/my/qaz-code/laws` (7.6 G), из которого она строится, уже лежит в restic
  g15. Спорили, выходит, про 186 G производного индекса. Плюс
  `provision/tests/tiers.test.sh` прямо утверждает, что профиль `workstation`
  NOPASSWD не выдаёт никогда.
- **Четыре живых места в репо приказывали не удалять то, что удалено вчера** —
  `backup/g15/profiles.yaml`, `hosts/g15/ubuntu/README.md`,
  `docs/fleet-roadmap.md` и этот файл. Инструкция будущей сессии, ставшая
  ложной, опаснее устаревшего факта: она запрещает действие, которое уже
  совершено. Помечены закрытыми с датой, не вычищены.
- **Побочно: `fleet-selfpull.test.sh` три недели писал в живое состояние.**
  `FLEET_SELFPULL_STATE` подменялся не с начала файла, и вызовы `selfpull_one`
  выше писали в `~/.local/state/fleet-selfpull` — тот самый каталог, куда каждые
  10 минут пишет реальный таймер (62 файла здесь, 34 на g15). Подмена перенесена
  в начало, мусор удалён. Один прогон гейта из трёх дал одиночный красный именно
  на этом сьюте и не воспроизвёлся; причину я не поймал — общее изменяемое
  состояние с работающим таймером это объясняло бы, но доказательства нет, и
  «environmental» это не диагноз.
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
