# machines — shared-memory proposals, 2026-09-12

Filed by `/memory-harvest` Phase A. Lane 2 only: nothing here has been written.
`/memory-review` is what applies these. Rows are self-contained on purpose —
the transcripts behind them expire.

> **Branch names changed 2026-09-12.** Any row below whose destination reads
> `desktop-wsl` means the dotfiles branch now called **`g16-wsl`**, and
> `desktop` means **`g16`** — the machine was renamed and the old refs are
> deleted on origin. The rows are not rewritten (this file is append-only from a
> run's side); resolve the name here.

Source digests: `40ef9ef4-d45c-480b-be1b-8c36137324ef` (g15, 2026-09-11
17:14–19:55) and `96a76e02-1793-4233-ac7d-48537a2760ab` (g15, 2026-09-11 22:14).
Track B baseline `ac285c4..73a5334`.

Format: `tier | action | fact (exact text to paste) | target file | source | confidence`

## global

global | add | **Where a single-writer job lives depends on what the job IS, not on where the last one went.** A systemd timer running a shell script is happy on a headless services box; an *agent session* is not — it needs the agent CLI installed, a checkout of the repo it edits, and (here) the dotfiles bare repo with every branch fetched, i.e. a machine someone actually works at. The fleet picked its memory-consolidation publisher by analogy with an existing timer-based single writer and got the wrong box; the correction was to reason from the job's requirements instead. Uptime is usually not the deciding axis — check it, but check what the job needs to run at all first. | ~/.claude/memory/global.md (new bullet under *Fleet scripting conventions*) | machines 73a5334 (commit body + session 40ef9ef4) | high

global | add | **A "there must be exactly one X" rule is better expressed as a NAME than as a per-item boolean.** Two booleans can both be true; two names cannot, so the invariant stops being something a human has to remember and becomes something the config file cannot express otherwise — and moving X is editing one value. Make the reader print *nothing* when the key is absent, so the `[ "$(reader)" = "$me" ]` gate every caller writes is false everywhere rather than accidentally true somewhere. Test that the name still matches a real member: a typo means nobody does the job, and "nothing happened" reads exactly like "there was nothing to do". | ~/.claude/memory/global.md (new bullet under *Fleet scripting conventions*) | machines 0624418 (commit body + `provision/tests/memory-publisher.test.sh`) | high

## host:g15

host:g15 | add | **This box is the fleet's `memory_publisher`** (named at the root of `~/machines/fleet.json` since 2026-09-11, moved here from latitude 2026-09-12). It therefore runs `/cyphy:memory-harvest` Phase B — the whole-corpus memory consolidation — on top of Phase A, which every box runs. Phase B reads every machine's dotfiles branch out of the local bare repo, so it needs `dotfiles fetch --all` first and touches nothing remotely. If the job should move, edit that one value; never add a second publisher. | ~/.claude/host-memory.md | machines 73a5334 | high

host:g15 | add | **Repo discovery on this box finds far more repos than the fleet docs suggest — 67 as of 2026-09-12** — because `~/kazakhstan-law` is a git repo that also *contains* 27 nested per-region repos, and `~/kazakhstan-law-0912` is a second copy of the same tree. Any per-repo loop that does a fleet-wide ssh fan-out per iteration must be batched here, or a nightly job makes 67 fan-outs. Two of those repos share the basename `codes` (`~/kazakhstan-law/codes`, `~/split-test/codes`), so anything keyed on a repo's basename collides on this box specifically. | ~/.claude/host-memory.md | session 96a76e02 (measured live) | high

## Notes for the reviewer

- Nothing is proposed for `~/.claude/memory/personality/*` this run.
- The two `host:g15` rows are for THIS box, so they are writable from here —
  they are Lane 2 only because `host-memory.md` is a shared-store tier, not
  because they belong elsewhere.
- The mechanism-level memory-harvest facts from this run (the `--match`
  basename collision, the batched single gather, the substring transcript
  filter) went to Lane 1 in `machines/.claude/memory/project.md`, following the
  2026-09-11 decision to demote `fleet-gather.sh` mechanics out of `global.md`.

---

# machines — shared-memory proposals, 2026-09-12 (SECOND PASS)

A second Phase A run the same day. Everything above this line is the 03:27
filing and is untouched; these are additional rows. Lane 2 only — nothing here
has been written. `/memory-review` is what applies them. Rows are self-contained
on purpose: the transcripts behind them expire.

Track B baseline `73a5334..3816d27` (42 commits). Source digests: `2c9011f6`
(desktop-wsl, 2026-09-08..10), `1f85e506` + `0841a872` (desktop-wsl, 09-10/11),
`21e77c45`, `1abc7229`, `08aa9fe8`, `39d0667c`, `dbe42595`, `eaf499c8`,
`96603b2b`, `218b2f03`, `96a76e02`, `ff591452`, `54aa8a0b` (g15, 09-11..12).

Already proposed in the 03:27 pass and NOT repeated here: the memory_publisher
siting rule, the name-vs-boolean invariant, and the two `host:g15` repo-discovery
rows.

Format: `tier | action | fact (exact text to paste) | target file | source | confidence`

## global

global | add | **A test for a hazard must not be able to trigger the hazard.** Mutation-testing a resolver whose whole job is to never return a dangerous command name started the real hazard: the "no such command" case still had the system bin directory behind the shim directory on PATH, so the fall-through mutation executed the real binary — in this instance GNOME's `orca` screen reader, mid-suite, on a desktop box, ending in a `pkill`. Two general fixes: build the negative case against the shim directory **alone** (a guard that needs no external command needs no real PATH behind it), and put a shim of the hazardous name *beside* the good ones with an explicit assertion that nothing ever invokes it. A suite that can fire the thing it is defending against is not a test of the guard, it is a rehearsal of the incident. | ~/.claude/memory/global.md (new bullet under a testing/craft heading) | machines 3816d27, session 21e77c45 | high

global | add | **A Claude Code hook cannot give the model a turn — so "let Claude write down what matters before compaction" is not implementable as a hook at all.** Hooks are shell commands; the most a `PreCompact` hook can do is freeze state to disk for a `SessionStart` hook to hand back afterwards, and `PreCompact` stdout does not reach the model. The cheapest real lever is `/compact <instructions>`, which steers what the summary keeps. Two mechanics worth knowing: multiple `PreCompact` entries **coexist** rather than replacing one another (observed 2026-09-12: gortex's handler and a local one both fired on one `/compact`), and `PostCompact` is a real event too. Compaction itself is not truncation — the model writes a summary and the session continues from it plus a preserved tail, so nothing is deleted and things are lost by *omission*. | ~/.claude/memory/global.md (under *Harness behavior (empirical)*) | machines 3816d27, sessions dbe42595 + 96a76e02 | high

global | add | **An Orca-installed skill lives once and is linked twice: `~/.claude/skills/<name>` is a symlink into `~/.agents/skills/<name>`** (one inode, verified on both g15 and air, 2026-09-12). So a skill can exist under `~/.agents/skills` with no link in `~/.claude/skills` — and then it does not exist for any Claude session on that box, while the install looks complete (measured on air: `find-skills` was in `.agents` only). Any "is it installed?" check must read BOTH sides. `orca skills install` is a wrapper over `npx skills add`: always pass `--agent claude-code --agent universal`, because without it the CLI writes config for agents that are not on the box; and never `--all`, which drags in Linear and the iOS/Android simulator skills. The bundled skills come from `stablyai/orca`; `find-skills` is not in the Orca bundle at all and comes from `vercel-labs/skills` as a separate command. | ~/.claude/memory/global.md (new bullet under an Orca heading) | machines 3816d27, session eaf499c8 | high

global | add | **Orca voice mode: keep the default `parakeet-tdt-0.6b-v3-int8`, and do not go looking for a language switch.** Measured on Orca 1.4.200, 2026-09-12: it is the only entry in the voice catalog that handles Russian as well as English (v2 and Zipformer EN are English-only; Zipformer/Paraformer/SenseVoice are CJK; the one other RU-capable option is Whisper Tiny, which Orca's own description calls less accurate). The `language: "en"` setting is **inert** — the field is passed into the sherpa recognizer config on no branch, and the OpenAI request carries only `model`, `response_format` and `file` — so no engine ever sees it and mixed RU/EN speech is disambiguated by the model itself. v3 is not streaming, so text lands in chunks at pauses rather than word by word; every streaming model in the catalog is EN/CN/KR, so that is the price of bilingual, not a fault. | ~/.claude/memory/global.md (new bullet under an Orca heading) | machines 3816d27, session 218b2f03 | high

## host:g15

host:g15 | add | **Orca's CLI registration refuses to overwrite a symlink it did not make.** Measured on Orca 1.4.200, 2026-09-12: after the move to the whole-AppImage layout, Orca's skill/CLI install kept failing because `~/.local/bin/orca-ide` was a stale link into `~/.local/opt/orca/squashfs-root`. Orca treats a link pointing outside the current install as "non-Orca" and steps around it instead of replacing it, with no useful message; deleting the link by hand let it re-register on the next attempt. What is left on this box: `~/.local/bin` holds **no** orca command at all (`orca-cli` and `orca-serve-start` were deleted — they hardcoded paths into `squashfs-root`, i.e. would have run the old version), and Orca's own shim exists only while the app is running because it validates the mount's pid — so nothing headless works here. **Do NOT run `ORCA_INSTALL_MODE=serve` on this box to get a CLI back**: it rebuilds the unpacked layout and undoes the self-updating install. | ~/.claude/host-memory.md | machines 3816d27, session 08aa9fe8 | high

## host:desktop

host:desktop | add | **A bitmagnet DHT crawler plus its own Postgres 16 runs here as a Docker Desktop stack, and its two halves live on opposite sides deliberately.** The recipe is the compose file, canonical at `~/docker/bitmagnet/compose.yaml` inside the distro and tracked host-local on the dotfiles `desktop-wsl` branch (an earlier copy under `C:\Users\…\docker\` was deleted once git covered the same risk better). The data is named volumes inside `docker_data.vhdx` on C:, owned by Docker Desktop and by no distro, so wiping a WSL distro leaves the index untouched. One engine serves both sides, so `docker compose up -d` from the distro or from PowerShell is the same stack. Three load-bearing details: `--keys=dht_crawler` is what turns crawling on at all (without it `docker ps` is green, the web UI on :3333 answers, and nothing is ever indexed); `CLASSIFIER_DELETE_XXX=true` drops porn before it is written; Postgres is pinned to 16 because bitmagnet's migrations are. Inbound DHT never reaches it — published ports land on the Windows host behind the home router's NAT, and mirrored-mode WSL gives a LAN address, not an internet one — so outbound DHT walking is what fills the database. | ~/.claude/host-memory.md ON THE `desktop-wsl` BRANCH (not writable from g15) | machines 3816d27, session 1f85e506 | high

host:desktop | add | **The nightly agent automation on this box runs at 04:00 local (+05), and the ordering against the 06:00 restic backup is the durable half:** whatever the run commits is already in the tree when the snapshot is taken. The reason given in session for avoiding 03:00 was a twice-weekly collision with `man-db` (02:59 Sat) and `e2scrub_all` (03:10 Sun) — asserted, never confirmed against `systemctl list-timers`, so re-measure before treating those two times as facts. | ~/.claude/host-memory.md ON THE `desktop-wsl` BRANCH (not writable from g15) | machines 3816d27, session 1f85e506 | medium

host:desktop | add | **UNVERIFIED, and worth one check: Docker Desktop's "start on system startup" may be login-scoped rather than boot-scoped on this box.** If true, anything whose value is continuity (the bitmagnet crawler, any scheduled stack) does not come back after an unattended reboot until somebody signs in, `restart: unless-stopped` notwithstanding. This was claimed in session and no tool output confirmed it — check the Docker Desktop setting and `Get-ScheduledTask` before relying on it in either direction. | ~/.claude/host-memory.md ON THE `desktop-wsl` BRANCH (not writable from g15) | machines 3816d27, session 1f85e506 | low

## Notes for the reviewer

- Nothing is proposed for `~/.claude/memory/personality/*` this pass either.
- The `host:desktop` rows are for a box this run was not sitting on, so they are
  Lane 2 by the skill's own rule regardless of content; applying them means
  writing on that machine's own dotfiles branch.
- Facts about latitude's hardware, its REST hub, the mirror link and the UPS
  decision were routed to **Lane 1** (`machines/.claude/memory/project.md`)
  rather than to a `host:latitude` store, following this repo's established
  convention — `project.md` already owns latitude's storage, dock and power
  sections, and a services host has no `~/.claude` of its own to read one.
- Orca's project/`hookSettings` model, the `tiers.sh` call contract, the
  `npx`-is-in-`npm` finding and the memory-machinery facts went to Lane 1 for the
  same reason: they are `machines`-repo facts, not fleet-wide preferences.

---

# machines — shared-memory proposals, 2026-09-12 (THIRD PASS, evening)

A third Phase A run the same day. Everything above this line is the 03:27 and
second-pass filings and is untouched; these are additional rows. Lane 2 only —
nothing here has been written. `/memory-review` is what applies them. Rows are
self-contained on purpose: the transcripts behind them expire.

Track B baseline `3816d27..e63f1e1`. Source digests: `42e7be29` (air,
2026-09-12 09:54–11:40), `5ed920f1`, `6cd2582b`, `ce01f384` (g16-wsl, 2026-09-12
08:16–11:50) and `ff591452` (g15, 2026-09-12 07:36–08:26, a resumed session).

Already proposed in the earlier passes and NOT repeated here: the
memory_publisher siting rule, the name-vs-boolean invariant, the hazard-test
rule, the PreCompact findings, the Orca skills/voice rows and the g15
repo-discovery rows.

Format: `tier | action | fact (exact text to paste) | target file | source | confidence`

## global

global | add | **`git commit --only <paths>` is path-scoped, not content-scoped.** It bypasses the index — which is why it is the right tool in a shared checkout — but it commits the **work-tree** content at the named paths, whoever wrote it. Measured 2026-09-12: a harvest commit scoped to five paths also carried two dozen lines of `project.md` that a different, earlier session had left uncommitted in the same file. The `git show --stat` file-list check that this idiom is usually paired with proves no *path* leaked and is structurally blind to this. In a checkout other agents are using, inspect the diff content too, not just the file list. | ~/.claude/memory/global.md (under a git-hygiene heading) | machines e63f1e1, session ff591452 | high

global | add | **A rule written into `~/.claude/memory/core.md` is not fleet-wide until it is promoted.** `core.md` is the only memory store injected verbatim into every session, which makes it the right place for a hard rule — but it is a dotfiles-tracked file, and anything not promoted to `main` lives on exactly one machine's branch. Measured 2026-09-12: the owner's "never edit in the main checkout" rule sat in `core.md` on g15's branch alone, enforced on one box and absent on the other four. Writing a rule there and stopping is how a rule becomes a local habit. | ~/.claude/memory/global.md (under the memory-store heading) | machines e63f1e1, session ff591452 | high

global | add | **An ssh `Host` block that pins an `IdentityFile` the box does not have is strictly WORSE than no block at all.** It overrides the key that does work, and the failure reads as a name, DNS or rename problem rather than as an identity one. Proven both directions in one shell on 2026-09-12: a rendered stanza pinning an absent `~/.ssh/id_fleet` got `Permission denied`, while `ssh -i ~/.ssh/id_ed25519 <user>@<ip>` from the same shell connected. Before blaming a hostname, a tailnet node or a recent rename, retry with an explicit `-i` and `-o IdentitiesOnly=yes`. | ~/.claude/memory/global.md (under *Fleet SSH reachability*) | machines e63f1e1, session 6cd2582b | high

global | add | **`git branch -r` cannot answer "does this branch still exist on the remote".** It renders stale remote-tracking refs identically to live ones, so a branch deleted on origin still lists locally until someone prunes. `git ls-remote --heads origin` is the authoritative check. Measured 2026-09-12: two branches carried in a plan as needing deletion were already absent from the remote, and what an earlier session had seen were stale tracking refs. | ~/.claude/memory/global.md (under a git-hygiene heading) | machines e63f1e1, session 6cd2582b | high

global | add | **A dotfiles machine branch is the ONLY copy of that box's host-local files** — they are absent from `main` by design — so a machine branch is never debris to tidy up, however dead its name looks. Delete only on proof: `rev-parse` equality against the renamed ref for a remote branch, `git merge-base --is-ancestor` against the successor for a stale local ref. Both proofs were run before any deletion during the 2026-09-12 rename. | ~/.claude/memory/global.md (under the dotfiles heading) | machines e63f1e1, session 6cd2582b | high

global | add | **A work repo can gitignore `.claude/` wholesale, and then its memory never syncs anywhere.** In `pure/backend-api` the ignore is a bare `*` at `.gitignore:6`, so the harvest state file, `project.md` and any shared proposal written there are machine-local forever — only `AGENTS.md` is landable in that repo. `pure/claude-plugins`, by contrast, tracks `.claude/` normally. Verified with `git check-ignore -v` on 2026-09-12. Check which shape a repo has before promising that anything written into its `.claude/` will reach another box. | ~/.claude/memory/global.md (under the memory-store heading) | machines e63f1e1, session 42e7be29 | high

global | add | **Проверяя кандидатную сотовую SIM на CGNAT, смотреть надо на сам сотовый интерфейс, а не на `tailscale0`.** `100.64.0.0/10` — это одновременно CGNAT-пространство и адресное пространство нашего собственного тайнета, так что приватный `100.64.x.x` сам по себе не доказывает ничего. | ~/.claude/memory/global.md (под домашним каналом / сетью) | machines e63f1e1, session 5ed920f1 | high

global | add | **Замеренные ~1.68 ТБ/мес — это чистый WAN-трафик, и он не уменьшится от перестановки железа дома.** Обмен внутри LAN (latitude ↔ g16-wsl, ~99 МБ/с) через WAN не идёт, поэтому переносить сервисы между домашними машинами бесполезно как способ влезть в FUP сотового «безлимита». | ~/.claude/memory/global.md (под домашним каналом / сетью) | machines e63f1e1, session 5ed920f1 | high

global | add | **У Starlink Residential публичного IPv4 нет вообще, и опции докупить его не существует** — публичный адрес есть только на Priority-тарифах. По входящим доступам это шаг назад даже относительно сотового, а не компенсация цены. | ~/.claude/memory/global.md (под домашним каналом / сетью) | machines e63f1e1, session 5ed920f1 | medium

global | add | **A Kaspi listing is a reseller markup, not the channel price — do not build a market conclusion on it.** On 2026-09-12 the same WD80EAAZ 8 TB was 240 344 ₸ on Kaspi and 188 090 ₸ at dns-shop.kz, a ~52 000 ₸ spread on one part number; an "8 TB has risen ~33%" claim was withdrawn once DNS was rendered. Mechanics for checking KZ retail from a script, same date: dns-shop.kz returns 403 to plain `curl` and yields prices only under headless chromium (`chrome --headless=new --disable-gpu --no-sandbox --virtual-time-budget=20000 --dump-dom <url>`, parsing `catalog-product__name title="…"` + `product-buy__price`), while Kaspi answers a plain `curl` at `https://kaspi.kz/yml/product-view/pl/results?text=<urlencoded>&page=0&sort=relevance&ui=d&i=-1&c=750000000` with a browser UA and a `Referer`. Ozon.kz and AliExpress both refuse automated fetch. | ~/.claude/memory/global.md (new bullet under a shopping/retail heading) | machines e63f1e1, session ce01f384 | high

global | add | **Hardware-buying preferences, confirmed 2026-09-12.** The owner buys drives at dns-shop.kz — that is where the existing WD80EAAZ came from — and treats its price as the reference rather than a marketplace listing. He is willing to self-assemble a desktop-class box rather than buy an appliance, and asked explicitly that exotic options (ARM boards, Raspberry-Pi-class builds) be considered rather than dismissed. He has access to mail forwarders (shipper.kz, Globbing), not to a dropshipper who can handle goods — so an import can be received and reshipped but never inspected or powered on before the return window closes. | ~/.claude/memory/global.md (under user preferences) | machines e63f1e1, session ce01f384 | high

## host:g16

host:g16 | add | **`just` is not installed inside `g16-wsl`**, so the `machines` gate cannot be run here as `just test` (confirmed 2026-09-12, and it was already true under the name `desktop-wsl`). Run the gate's own definition by hand — `find . -name '*.test.sh' -not -path './.git/*'`, executing each and checking its **exit code**, never grepping for `ALL PASS`, which not every suite prints. | ~/.claude/host-memory.md ON THE `g16-wsl` BRANCH (this box, but a shared-store tier) | machines e63f1e1, session 6cd2582b | high

## Notes for the reviewer

- Nothing is proposed for `~/.claude/memory/personality/*` this pass either.
- The Orca `orca-data.json` key-shape, cross-OS-pid, `sshTargets` and
  `worktreeMeta` findings went to **Lane 1** (`machines/.claude/memory/project.md`),
  following the convention the earlier passes set: Orca's data model is a
  `machines`-repo fact because `/orca-repair` lives in this repo.
- The offsite hardware survey (AC-restore evidence, rejected classes, the
  8 TB-vs-12 TB ₸/TB tier, the HDD shortage lead time, and why a mail forwarder
  cannot run the disk-acceptance identity gate) went to Lane 1 in
  `docs/superpowers/specs/2026-09-12-village-offsite-backup-design.md`, with two
  `conflicts-with` markers against that spec's own "8 GB RAM" and "prune runs on
  the village box with its own key" lines — both contradicted by the shipped
  `hosts/offsite/debian/README.md`.
- **Open and unrecorded, for whoever picks it up:** at the end of session
  `6cd2582b` (2026-09-12) the dotfiles stores `core.md`, `global.md` and
  `practices.md` were not merging with `origin/main` on both checkouts on this
  box. That is current-state incident rather than a durable mechanism, so no row
  was filed for it — but nothing else is tracking it either.
