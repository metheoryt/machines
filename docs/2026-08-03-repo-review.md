<!-- Produced 2026-08-03 by a 24-agent review workflow on branch repo-review-cleanup.
     Coverage was enforced mechanically: 240 tracked paths in, 240 ledger rows out, 0 gaps.
     One agent (the `backups` suspicion) failed its schema-retry cap; that section was re-run on
     2026-08-03 as a dedicated 5-agent pass (investigate + three adversarial verifiers + merge)
     and now supersedes the placeholder. It is the one section produced by a second workflow. -->

# machines — whole-repo review

## Verdict in five lines

`machines` is a working cross-platform provisioner for four boxes, wrapped in a large and unmaintained archive of its own history: 240 tracked files, 113 of them Markdown, 90 of those dated plans and specs of which **not one carries a status marker**. The code is in better shape than that ratio suggests — 135 files earned a clean `keep`, all 28 suites the gate reaches are green, and `provision/lib/tiers.sh` carries ~508 lines of measured-failure rationale that is the repo's single most valuable asset. What it has drifted into is a repo that **describes itself four times over and checks itself once, badly**: `just test` reaches 28 of 38 suites, `provision --apply` exits 0 for four of latitude's seven roles, and every one of the four boxes carries load-bearing state that no file in either repo declares. The most important thing to do about it is not in the ledger: this review found live faults — a backup hub down since 2026-08-02, a fleet member frozen 28 commits behind on one empty file, a cron branch that silently never runs — that outrank all 86 `rewrite` verdicts combined. **Fix the live faults, make the gate honest, then treat the documentation sweep as the slow background job it is.**

---

## Coverage

> The full 240-row table lives at **`review/2026-08-03-path-ledger.md`** — deliberately outside `docs/`, because it is reference data and this review's own finding is that `docs/` is 2.1 MB nobody reads.

**240 tracked paths, 240 ledger rows, zero gaps.** I reconciled this by subtree rather than taking it on trust: 14 root-config (9 root files + 3 `.claude/` + `.gemini/` + `.superpowers/`), 26 `agents/` non-plugin, 31 `agents/plugin/`, 4 top-level `docs/`, 1 handoff, 45 plans, 44 specs, 58 `provision/`, 11 `hosts/`, 3 `install-media/`, 3 `scripts/`. Each count matches `git ls-files` exactly. **No tracked path went unreviewed.**

| Verdict | Count |
|---|---|
| keep | 135 |
| rewrite | 86 (one is a `rewrite->` retarget to another file) |
| needs-decision | 11 |
| delete | 6 |
| merge-> | 2 |

**The real gap is a modality, not a path.** The `backups` worker returned nothing. One of the three named suspicions got no first-class pass, and backups are half this repo's stated purpose. The section below is synthesised from four other workers' incidental findings; it is not the pass that was asked for.

**Untracked and ignored surfaces were never inventoried by any worker.** I checked: `git status --porcelain -uall` returns **0** — there are no untracked non-ignored files, which is a clean result worth stating rather than assuming. Four ignored paths exist and none was rowed: `.claude/settings.local.json` (5 lines), `.machines/` (live convergence state, stale-dated Aug 1), `agents/plugin/skills/orca-repair/__pycache__/*.pyc` (24 KB of build junk), and `provision/secrets/authkey` — an 88-byte reusable Headscale pre-auth key, correctly ignored, sitting on the primary dev box a week after the enrollments it was minted for completed.

**A parallel worktree was missed by every worker.** `git worktree list` shows `/Users/me/orca/workspaces/machines/machines-cleanup` on `metheoryt/machines-cleanup`, three commits ahead, touching exactly `provision/lib/tiers.sh` (+32/−3) and `provision/README.md` (+10/−2) — two `rewrite` rows. One of its commits refutes a drift finding (see below).

**Boxes examined:** latitude (ssh, read-only), air (local), hub (ssh, read-only), desktop-native (Git Bash via PowerShell), desktop-wsl (ssh). All four fleet members plus the WSL child were reached. `server`/g513ie was deliberately not examined — the C: review is the user's. One prescribed check was skipped by the worker on the box and run afterwards by hand: `core.symlinks` on desktop-native. It came back **false** — see Tier 2 item 10b.

---

## The three suspicions — confirmed or ruled out

### Git-sync timers — **RULED OUT as duplication. One narrow overlap CONFIRMED, two defects found underneath.**

The three ~10-minute jobs are three genuinely different jobs that share a cadence.

| | git-autofetch | fleet-selfpull | dotfiles-sync |
|---|---|---|---|
| **Scan roots** | `$HOME`, `find -maxdepth 4` — every repo incl. work checkouts | `$HOME my pure cyphy671 exactly`, depth 2, excludes `*thepureapp/*` and any repo with no upstream | exactly one: `$HOME/.dotfiles` bare, work-tree `$HOME` |
| **Writes** | fetch only, never touches a work tree | `merge --ff-only`, gated on branch==main + clean tree | the only one that commits and pushes |
| **Exit contract** | 1 only if **all** fetches fail (a masked `timeout` once made every fetch fail while launchd reported healthy) | non-zero on a real fetch error (always-0 let latitude sit 23 commits behind under a green unit) | **always 0**, even on conflict or failed push (both recur every tick; non-zero paints the timer permanently red) |
| **Unique safety gate** | shallow-clone skip (a `--depth 1` clone ballooned 60M→350M irreversibly) | not-main / dirty / diverged skip taxonomy | lock + 30-min stale sweep (no flock on macOS), enrollment guard, commit debounce, `merge-tree --write-tree` conflict preflight, vanished-tree guard |
| **State** | none | none | `$XDG_STATE_HOME/dotfiles-sync/{branch,lock,pending.hash,pending.since,conflict}` |
| **Cadence** | OnBoot 2min / 10min, jitter 30s | OnBoot 2min / 10min, jitter 2min | OnBoot 3min / 10min, jitter 2min |
| **tiers.sh lines** | 177 | 78 | 58 |

**Can they collapse, and what is lost?** No — and the exit-status row is why. One systemd unit cannot simultaneously go red only on total failure, go red on any fetch error, and stay green on conflict; each of those three contracts is documented against a specific past incident. Collapsing loses one capability per job. What *can* collapse is the **scheduler-install cascade**: `tier_autofetch:862-902`, `tier_selfpull:1193-1240` and `tier_dotfiles_sync:1343-1380` triplicate the same darwin/systemd-user/cron/warn arms, and only the launchd arm was ever factored out into `_launchd_periodic`. A `_schedule_periodic` helper removes roughly 100 of the 313 lines without touching a single job semantic. That is a factoring problem, not a formalism one.

`scripts/converge.sh` is **not a fourth timer** and does not belong in the comparison. It has no schedule anywhere: on POSIX it is fired detached from `agents/git-hooks/post-merge`; on Windows it is a trigger-less Scheduled Task fired by `schtasks /run`. The chain is a pipeline — selfpull moves HEAD → post-merge fires → converge applies — and the coupling is explicit in code (`tier_selfpull`'s `KillMode=process` exists so the detached converge is not SIGKILLed).

**The genuine overlap:** autofetch and selfpull fetch the same repos (`~/machines`, `~/my/vps`) on the same uncoordinated 10-minute cadence with the *same* systemd `OnBootSec=2min`. `provision/fleet-selfpull.sh:51-61` is a sleep-and-retry that exists solely to absorb the resulting `cannot lock ref` race — the only place in the repo where one scheduled job's implementation is shaped by another's existence. Stagger the boot offsets; keep the retry as defence in depth.

**Two defects surfaced while verifying.** (1) `tier_dotfiles_sync` appears in **no profile tier list** — on air and hub it is installed only by a one-time role run and convergence never refreshes it. Confirmed live on air by plist timestamps: git-autofetch and fleet-selfpull are both dated 2026-08-01 10:28; dotfiles-sync is dated 2026-07-28 18:38. Three reprovisions have refreshed two of three plists and never touched the third. (2) The cron fallback in `tiers.sh:1232` and `:1372` emits an unescaped `%`, which crontab(5) treats as end-of-command — confirmed live on desktop-wsl, whose journal logs `CMD (sleep $((RANDOM )`. On any box without a systemd user manager, fleet-selfpull and dotfiles-sync are scheduled and never execute.

### The `beat` service — **RULED OUT. Wrong repo and wrong function.**

`beat` does not exist in `machines`. `git ls-files | grep -i beat` returns nothing; all 14 textual hits are English prose or cross-references from migration paperwork. It lives at `~/my/vps/homeserver/beat/` and it is **not a heartbeat** — it is a busybox-crond launcher container whose single task (`tasks/reboot-archer.py`, `# cron: 0 6 * * *`) reboots the household TP-LINK Archer C20i over HTTP once a day. It is deliberately stopped by user decision 2026-08-01 and absent from every reachable box: not in latitude's 22 containers, not in hub's units, not in air's launchctl. There is nothing to clean up here and no redundancy with the statusboard, the three timers, or Tailscale keepalive. The premise was wrong on both counts; the classic machines/vps boundary error is exactly what happened, because the migration docs *in this repo* name the service.

If the intended target was "a homegrown periodic mechanism an off-the-shelf tool could replace," the live candidate is the timer triad above — and the answer there is also no.

### Backups — **CONFIRMED, and the largest live-fault surface in this document.**

*Produced 2026-08-03 ~02:15 +05 by a dedicated first-class pass across `machines` and `~/my/vps`, plus read-only probes of latitude, air, hub, desktop-wsl and desktop-native, then re-verified three times on independent lenses (live claims, the gap list, the `machines`/`vps` boundary). This section supersedes the "PARTIAL" placeholder. Where it corrects that block, or corrects its own first draft, it says so. Latitude's local time is **UTC+5**; the placeholder's "10:53" is the UTC stamp read as local.*

**The suspicion is confirmed, but not in the shape it was posed.** There are not three mechanisms — there are **seven**, and the three that were designed together are demonstrably the only three that were. Everything below is A–F of that question.

---

#### A. What is backed up, from where, to where, on what schedule, by which mechanism

| # | Mechanism | Source | Target | Schedule | Last run (evidence) | Size |
|---|---|---|---|---|---|---|
| 1 | **immich's own internal `pg_dump`** (app setting, declared in neither repo) | immich postgres, in-container | `/data/backups` → bind → `/var/backups/immich-db` (root fs, nvme1n1p3) | daily 02:00 | `docker logs immich_server`: `[Microservices:DatabaseBackupService] Database Backup Starting` 02:00:00 → `Database Backup Success` 02:00:39, today; `DB_BACKUPS_LOCATION=/var/backups/immich-db` | **14** `.sql.gz` + a marker, **2.9 G**; newest `…20260803T020000-v3.1.0-pg14.19.sql.gz`, 223,022,181 B |
| 2 | **`mirror-refresh.sh`** (machines, system timer) | `/mnt/immich` (nvme0n1p1) **+** `/var/backups/immich-db` | `/mnt/immich-mirror` (sdd2, `a7d7b61e-…`) | daily **03:30**, `Persistent=true`, `RandomizedDelaySec=15m` | `LastTriggerUSec=Sun 2026-08-02 03:30:25 +05`, `Result=success`; journal 265,816,677,471 B total / 213,858,619 B transferred | src **249 G** → dst **291 G** |
| 3 | **resticprofile `latitude`** (vps profile, machines-side box) | `/var/backups/immich-db`, `/mnt/immich/ServarrConfig`, `/mnt/immich/xs-keepers`, `/home/me/my/vps` | `/mnt/spare320/restic/latitude` (sdg1, `3a78fd88-…`) | daily **04:30** system scope; `check` **Sun 06:00** @ `read-data-subset: 5%` | backup `Sun 2026-08-02 04:30:00 +05`, `Result=success`; check `Sun 2026-08-02 06:00`, `Result=success`, `read 5.0% of data packs / no errors were found` | **3 snapshots**, latest `92532d61` 2026-08-02 04:30:01, **6.594 GiB** logical; repo **2.360 GiB** raw-data (1.84×), 2.4 G on disk |
| 4 | **`archive-mirror.sh`** (machines, system timer) | `/mnt/immich-2024/admin` (sdc2, `63c1de22-…`) | `/mnt/xs/immich-2024-archive` (sda3 exfat, `FBED-BCAA`) | monthly, **1st at 05:00** ± `RandomizedDelayUSec=30min`, `Persistent=true` | **NEVER FIRED — see §E.** `LastTriggerUSec=Sat 2026-08-01 18:07:38 +05` is the *enable* stamp; `NEXT = Tue 2026-09-01 05:01:54` | src **663 G** → dst **665 G**; `/mnt/xs` **95 % full, 36 G free** |
| 5 | **resticprofile `wsl`** on desktop-wsl → **the REST hub** | all of `/home/me` on the `desktop-wsl` distro (minus `backup/wsl/.resticignore`) | `rest:http://100.64.0.8:8001/g614jv` → `/mnt/spare320/restic-rest/g614jv` (**same sdg1 as #3**) | daily **06:00**, `schedule-permission: user_logged_on`, `Linger=yes`, timer `Persistent=true` | last **success** `41a19b13` **2026-08-02 06:00:28 +05**, `Result=success`; next `Mon 2026-08-03 06:00:00 +05` — **that run fails, the hub is down** | **2 snapshots**, 8.819 GiB logical; repo **4.972 GiB** raw-data (2.60×), 5.0 G on disk |
| 6 | **The dotfiles bare repo on latitude** (`~/.dotfiles`, branch `latitude`) — a backup nobody calls one | **45 tracked paths**, of which the 18-path `~/g513ie-prod-config/**` subtree (152 K) is the prod-config half | git remote, via the 10-min sync timer | 10 min, debounced | `dotfiles-sync.timer` last `2026-08-03 01:57:12 +05`; `0 0` vs `origin/latitude` | incl. **the restic password** and every prod `.env`; the other 27 paths are the `.claude/` memory set, `pure/backend-api/.claude/memory/project.md`, `.config/{bash,zed}`, `.gitattributes` |
| 7 | **The dotfiles bare repo on air** (branch `air`) — **air's only mechanism, of any kind** | 26 allow-listed `$HOME` paths | git remote `origin/air` | 10 min, debounced | clean, `## air...origin/air`, `0 0`; last auto-commit `2026-08-02 13:03:51 +0500 6f48b9e auto(air): .gitconfig`; no `conflict` marker | 26 paths (listed in §B) |
| — | **Hand-made migration copies** (no script, no schedule, no owner — not a mechanism, but it is what protects 129 G) | `~/staging/music`, `~/staging/Настя Стас GoPro` | `/mnt/spare320/music-from-g513ie`, `/mnt/immich-mirror/staging` | **none — one-shot, 2026-07-29/31** | `~/staging/pull-music.sh` (558 B, Jul 29 20:46) + `music-copy.log`, `gopro-copy.log`, `checksum-verify.log` | 89 G + 40 G, each duplicated |

**Row 1 was drafted as inference and has been discharged.** `system_metadata.'system-config'` on `immich_postgres` has no `backup` block, so immich's defaults are in force — but the producer names itself in the container log with a start time, an exit code and a destination env var, which settles identity, destination and the fact that it ran at 02:00:00–02:00:39 today. What remains unread is only immich's literal default cron expression. **Note the binary:** `latitude/profiles.yaml:63` and the retired `homeserver` profile both call this `pg_dumpall`; the line the container actually logs is `/usr/lib/postgresql/14/bin/pg_dump exited (0)`. The log is primary — it is `pg_dump`, and the profile comment is loose.

**Snapshots key on OS hostnames, not fleet names.** The two repos hold `latitude5520` and `g614jv`. A restore-time operator searching for `latitude` or `desktop-wsl` finds **nothing**, and for `g614jv` it is worse — that is the *Windows* host, not the distro. `backup/wsl/profiles.yaml:25-34` predicts this precisely and accepts it; `restic forget` output reads `snapshots for (host [g614jv], paths [/home/me])`.

---

#### B. What is NOT backed up by any of them

**On latitude:**

| Data | Size | Status |
|---|---|---|
| `telegrind_pgdata` docker volume | 55 M | **In no source.** Live postgres holding user conversation data — `select count(*) from chat` → **62**, confirmed first-hand. Not re-derivable. Its *config* is protected: `g513ie-prod-config/telegrind/{.env,.env.prod,compose.override.yml}` are dotfiles-tracked on branch `latitude`. Only the database is exposed. |
| `embedthat_redis_data` | 1.4 M | **In no source**, and it is durable state, not cache: `info keyspace` → `db0:keys=5358,expires=1222`, i.e. **4,136 keys with no TTL**. |
| `tugtainer_tugtainer_data` | 52 K | **In no source.** Holds the per-container `check_enabled/update_enabled` toggles; losing it re-arms tugtainer on immich, telegrind and embedthat — the failure `~/my/vps/.claude/memory/project.md` records happening twice. Downgraded from the draft's "not re-derivable": both the toggle set and the query that reads it are written down in that same project.md, which is restic'd *and* on private GitHub. Call it ~20 minutes of re-derivation, not a loss. |
| `immich_pgdata` docker volume | 803 M | **Not what the draft called it.** Live PGDATA is a *bind* at `/mnt/immich/ImmichMedia/postgres` (`docker inspect immich_postgres`), inside mirror-refresh's source tree and correctly excluded at `mirror-refresh.sh:39`. The named volume has **no container attached** — migration leftover, i.e. orphaned state nobody has decided about. Smaller finding than "the live DB is unbacked", and a different one. |
| `immich_model-cache` | 9.0 G | Re-downloadable. Not a gap. |
| `~/.ssh/config` | 1,274 B | **Unprotected and load-bearing.** Hand-written; `dotfiles ls-files --error-unmatch .ssh/config` on branch `latitude` → untracked (air tracks its own; latitude does not), and no restic source covers `/home/me` outside `my/vps`. Its `Host g513ie server` block is latitude's only route to `server` for the pending C: review. |
| `~/.config/gh/hosts.yml` | 208 B, 0600 | Untracked — while `.config/gh/config.yml` *is* tracked. The same "the file with the token is the one not tracked" failure as on air (§B, air). Fleet-wide, not air-specific. |
| `~/machines/.machines/` | 226 B | Untracked here, but **not a gap.** `scripts/converge.sh:58-67`: an absent `converged-rev` makes `range_low` empty, `changed_paths()` falls back to `git ls-files`, every path counts as changed and a full reprovision runs. Costs one extra convergence and fails safe. (It is also *present* in desktop-wsl's snapshot — see the scope note below.) |
| `~/staging/music` + `/mnt/spare320/music-from-g513ie` | 89 G ×2 | Two copies, two drives, **one machine**, no schedule. |
| `~/staging/Настя Стас GoPro` + `/mnt/immich-mirror/staging` | 40 G ×2 | Same. `mirror-refresh.sh:27-29` calls the mirror copy "the only second copy of the GoPro video" — it is the second of two, both on latitude. |
| `/mnt/servarr` | 632 G | **Deliberately** unbacked (`mirror-refresh.sh:16-18`: seeded, re-acquirable torrent data). Not a gap — but 632 G that no reader of the fleet docs would know is a decision. |
| `/mnt/immich-mirror/Media` | 514 M | Orphaned pre-move copy; `--delete` is off so it persists. Noted at `mirror-refresh.sh:31-33`. |

**Scope correction, on direct evidence.** The draft's "`~/machines/.machines/` is in no source **on any box**" is false. desktop-wsl's profile backs up all of `/home/me` and `.resticignore` excludes nothing under `machines/`:

```
$ restic -r /mnt/spare320/restic-rest/g614jv ls 41a19b13 --no-lock /home/me/machines/.machines
/home/me/machines/.machines/converged-rev
/home/me/machines/.machines/last-converge
```

A cross-check that concluded otherwise enumerated `latitude/profiles.yaml:62-66`'s four sources only and never looked at the wsl profile's `/home/me`; the `restic ls` is dispositive. The claim is true of the **latitude and air** copies of `~/machines`, and of those alone.

**On hub — still the worst exposure, but a third smaller than the placeholder said:**

- `restic`, `resticprofile`, `borg`, `rclone`, `duplicity`, `kopia` — **all absent.** No `*restic*` or `*backup*` unit beyond stock `dpkg-db-backup`; no user timer; `crontab -l` empty for both `debian` and `root`; `/etc/cron.d/` holds only `e2scrub_all`; no `~/.config/restic`. No `hub` profile exists in `~/my/vps/backup/` either (it holds `homeserver`, `latitude`, `wsl`).
- **`/etc/caddy` and `/etc/headscale` come off the unprotected list.** `sha256sum` says `/etc/headscale/config.yaml` (`967ef075…`) and `/etc/caddy/Caddyfile` (`637e5daa…`) are byte-identical to `vps/headscale/config.yaml` and `vps/caddy/Caddyfile`, which are tracked in the private `metheoryt/vps`, cloned on air and latitude, and inside restic source #4.
- What is genuinely unprotected, and sharper for being shorter: **`/var/lib/headscale/db.sqlite`** — 86,016 B with a **4,120,032 B WAL**, the only copy of the tailnet's control plane, and a naive file copy of it is torn; `derp_server_private.key` (72 B); `noise_private.key` (72 B); **`/etc/wireguard/wg0.conf`** (1,122 B — the repo carries only `vps/wg/wg0.dist.conf`, whose `PrivateKey = VPS_PRIVATE_KEY` is a placeholder); `/etc/amnezia/amneziawg/wg0.conf`; and the `proxy-config` volume behind the undeclared `mtproto-proxy` container.
- **Losing that VPS loses the fleet's identity**, and re-keying every node is the recovery path.

**On air (this box, the primary dev box) — one mechanism, and it covers 26 files:**

No restic. `restic`/`resticprofile`/`borg`/`rclone`/`kopia`/`duplicacy` all "not found". `tmutil destinationinfo` → **`No destinations configured.`** — no Time Machine, ever. No Arq/Backblaze/CCC/Chronosync in `/Applications`. `~/Library/LaunchAgents/` holds six plists: three Google updaters and the three fleet sync jobs. iCloud Drive holds **308 K**.

Mechanism 7 is genuinely live, not merely installed — clean tree, `0 0` against `origin/air`, an auto-commit from 2026-08-02 13:03, no conflict marker, state dir touched 02:11 today. (Its plist is still dated **2026-07-28 18:38** against the other two at 2026-08-01 10:28 — the committed review's `tier_dotfiles_sync`-in-no-tier-list finding. Stale-but-firing, not dead.) **Protected — the complete list:**

```
.claude/CLAUDE.md            .claude/skills/dotfiles-promote/SKILL.md
.claude/balance-refresh.py   .claude/skills/dotfiles-sync/SKILL.md
.claude/host-memory.md       .claude/skills/gortex-align/SKILL.md
.claude/memory/global.md     .claude/skills/gortex-align/type-governance-reference.md
.claude/memory/personality/{habits,practices,tone,values}.md
.claude/skills/update-balance/{SKILL.md,update-balance.py}
.claude/skills/worktree-agent/SKILL.md
.claude/statusline-command.sh
.config/gh/config.yml   .config/zed/settings.json
.gitconfig  .gitignore  .ssh/config  .tmux.conf  CLAUDE.md  README.md
.local/bin/{wt-setup,wt-teardown}
```

What is left unprotected on air is narrower than the draft claimed, and one of its three headline items is dead:

- **`~/machines/provision/secrets/authkey` is not a live credential — delete that alarm.** It prefix-matches Headscale key **id=7**: `Reusable false | Used true | Expiration 2026-07-28 17:56:18` — single-use, already consumed, expired six days ago. Only id=5 is live-and-reusable (expires 2026-10-14) and it is a different key. The draft's "it exists on no other box" was inferred from `provision/secrets/` being absent on latitude; that inference fails too — latitude holds its own persisted pre-auth key at `/etc/headscale/authkey` (89 B, `root:root 0600`, Jul 29), the path `provision/tailscale-wsl.sh:52` writes, with a different value. And any key is one `headscale preauthkeys create` away while hub's DB lives, so this exposure is *subsumed* by the hub-DB loss above.
- `~/orca/workspaces/machines/machines-cleanup` is **`[ahead 2]`** of `origin/metheoryt/machines-cleanup` — two commits of unpushed work on an unbacked box, on the branch the committed review flags as unreviewed and blocking two `rewrite` rows.
- **This review has no off-box copy either.** `git rev-parse --abbrev-ref repo-review-cleanup@{upstream}` → `no upstream configured`; `git rev-list --count origin/main..repo-review-cleanup` → **1** (`5d585d5`, the review plus the 240-row ledger). Same class as the point above, same box.
- **`~/.config/gh/hosts.yml` (84 B, mtime 2026-08-03 01:26) is present and NOT tracked** — `check-ignore -v` → `.gitignore:7:*`. `$HOME/CLAUDE.md`'s Secrets section names it explicitly among the rotatable credentials "tracked on purpose". It is not, on this branch. (`.netrc`, `.npmrc`, `.aws/credentials` do not exist here, so those are not gaps.)
- **`~/machines` / `~/my` / `~/orca` are not unprotected wholesale**, contra the draft. All three remotes are GitHub (`metheoryt/{machines,vps,dotfiles}`). `~/my/vps` is `0 0` against `origin/main` with an empty `git status --short --ignored` — nothing under air's `~/my` is unique to the box. `~/machines` is `0 0` on `main`; its air-unique content is exactly four ignored paths (`.claude/settings.local.json` 50 B, `.machines/`, `provision/secrets/`, one `__pycache__`) plus the two branch states above.

**`metheoryt/machines` is a PUBLIC repo** (`gh api repos/metheoryt/machines --jq .private` → `false`; `vps` and `dotfiles` are both private). Two consequences inside this lens: the one off-site copy of `machines` is world-readable — fleet topology, tailnet IPs, drive UUIDs, the `--no-auth` posture, the autologin + NOPASSWD pairing — and `docs/fleet-roadmap.md:388-419`, already on `origin/main`, states which telegrind credentials leaked and that they are deliberately unrotated. No secret *values* are in that entry. This document would publish the same class of detail on push.

**On desktop-native (Windows):** zero backup tasks. `schtasks /query /fo CSV /v` returns only `dotfiles-sync`, `fleet-selfpull`, `git-autofetch` (`Last Result = -196608` = the known phantom) and `machines-converge`, plus vendor/OneDrive noise. OneDrive is installed and its updater tasks run; nothing in either repo treats it as the Windows backup and its synced set was not enumerated.

**On desktop-wsl:** covered by mechanism 5 — and it also carries a plaintext credential its own config argues against. See §F, seam 1; the short version is that `~/my/vps/backup/wsl/pass.txt` (12 B, Apr 27) and a 231,702-byte `resticprofile-wsl.backup.log` sit inside the git work tree, and both are covered by `~/my/vps/.gitignore:13-14` (`**/pass.txt`, `**/*.log`), confirmed by `git check-ignore -v`. The same pattern exists on latitude, unmentioned by the draft: `backup/latitude/` holds root-owned `resticprofile-latitude.backup.log` (7,974 B) and `latitude.check.log` (1,154 B) inside the vps checkout.

**The ignored-but-load-bearing state, resolved precisely — and the two repos differ:**

- `~/my/vps` **is** a restic source (`latitude/profiles.yaml:66`), and restic copies the *filesystem*, not the git index. Its excludes are `**/.git/`, `**/node_modules/`, `**/.DS_Store`, `**/*.tmp` plus `exclude-caches: true` (`:72`, missing from the draft's list and load-bearing for this argument). So on latitude **every gitignored `.env` is backed up** — 8 live `.env`/`.env.prod` files under `homeserver/` (`beat, embedthat, immich, navidrome, restic-server, servarr, tugtainer`, plus `telegrind/.env.prod`), plus `.claude/settings.local.json`. That is the profile header's stated purpose (`:17-18`), and it works — though the header says *seven*, so it is stale by one.
- `~/machines` is in **no** restic source on latitude or air; on desktop-wsl it is, via `/home/me`.
- **Silent skip nobody has connected to the hardware.** `base.yaml:21` sets `schedule-ignore-on-battery: true`. The behaviour itself *is* documented — vps `CLAUDE.md:201` says "Backups skip when on battery power" — so the draft's "nobody has connected" is too strong; what nobody has connected is the consequence. latitude is a laptop-as-server with **no UPS**, so a mains cut at 04:30 silently skips the backup with nothing reporting it — and `resticprofile show` proves the flag is live on **both** of latitude's system schedules, so it takes out the weekly `check` too. The flag is inherited by the `wsl` profile as well, on an actual laptop, where 06:00-on-battery is far likelier. Its timer is `Persistent=true`, so a missed *boot* catches up; a battery skip is an exit-0 no-op with no catch-up. Both boxes are on AC right now (`/sys/class/power_supply/AC*/online` = `1`, latitude battery 84 %), so nothing below is pre-empted by it.

---

#### C. Overlap

**It is large, and — for the latitude trio — it is deliberate and argued.**

Three of restic's four sources sit **entirely inside** `mirror-refresh.sh`'s tree:

| Path | In mirror-refresh? | In restic? |
|---|---|---|
| `/var/backups/immich-db` (2.9 G) | yes — explicit second rsync, `mirror-refresh.sh:53` | yes — `profiles.yaml:63` |
| `/mnt/immich/ServarrConfig` (590 M) | yes — under `$S`, unexcluded | yes — `:64` |
| `/mnt/immich/xs-keepers` (3.5 G) | yes — under `$S`, unexcluded | yes — `:65` |
| `/home/me/my/vps` (35 M) | **no** | yes — `:66` |

The latest snapshot's logical size is **6.594 GiB**, of which `~/my/vps` contributes ~35 M — so essentially the entire restic profile is a second logical copy of bytes rsync already mirrored, stored in a 2.360 GiB repo. Only `~/my/vps` is restic-exclusive.

**This is not accidental duplication, and the header says why** (`backup/latitude/profiles.yaml:20-24`, verbatim):

> WHY THIS EARNS ITS KEEP ON TOP OF THE RSYNC MIRRORS: the mirrors give a second copy and nothing else. They cannot answer "restore yesterday's DB, today's is corrupt" — a corrupt source rsyncs straight over the mirror. restic adds versioned history, integrity you can verify (`check --read-data-subset`), and a format that can be shipped off-site as-is.

That is a correct argument, and the retention proves it was thought through: `keep-daily: 30` against `base.yaml:27`'s 7, justified at `:83-85` by "the dumps are ~220 MB each and dedupe well."

**A side effect nobody intended:** `base.yaml:11` (`lock:`) and `:20` (`schedule-log:`) are *relative* paths, resolved against the generated unit's `WorkingDirectory=/home/me/my/vps/backup/latitude` — which is restic source #4, with no `*.log` exclude. So restic backs up its own logs, and `skip-if-unchanged` (`base.yaml:23`) can never fire for this profile.

**The other overlaps are not argued:**

- `~/staging/music` (89 G) vs `/mnt/spare320/music-from-g513ie` (89 G) — a hand-made duplicate on the same box, on the same drive as both restic repos.
- `~/staging/Настя Стас GoPro` (40 G) vs `/mnt/immich-mirror/staging` (40 G) — same.
- **Both restic repos live on one physical drive.** `/mnt/spare320/restic/latitude` (2.4 G) and `/mnt/spare320/restic-rest/g614jv` (5.0 G) are both on sdg1, UUID `3a78fd88-deb0-4c1a-a576-14abd0631d57`, a 298 G drive that also holds 89 G of unrelated migration music (96 G used in total). `profiles.yaml:31-34` argues for that drive on *contention* grounds — different physical drive from every source, different USB bus from the archive target — and it is right about that. It never considers that the fleet's only two restic repositories then share one spindle and one enclosure.

---

#### D. The role-vs-reality question, per box

**The role system provides nothing.** `provision/roles/` contains exactly six files — `agents.{sh,ps1}`, `dotfiles.{sh,ps1}`, `repos.{sh,ps1}`. There is **no `backup-client.sh`, no `backup-hub.sh`** (nor `.ps1`, nor `base`, nor `ssh-server`). `provision.sh:83-88` handles the miss by printing `✗ <role> — apply: not yet implemented (skipped)` and never setting `rc`. latitude declares `base, ssh-server, agents, dotfiles, repos, backup-hub, backup-client`, so `just provision --machine latitude --apply` prints **four** crosses — `base`, `ssh-server`, `backup-hub`, `backup-client` — and exits 0. (The draft said two; it counted only the backup pair.)

| Box | Declares | What actually backs it up | Verdict |
|---|---|---|---|
| **latitude** | `backup-hub`, `backup-client` | **`backup-client`: real, and entirely undeclared in `machines`.** A hand-placed `/usr/local/bin/resticprofile` (21,020,834 B, Aug 1 16:01) + apt `restic` 0.18.0, plus four units in `/etc/systemd/system` generated by `resticprofile schedule` with `WorkingDirectory=/home/me/my/vps/backup/latitude` — driven from the *sibling* repo. Working: 3 snapshots, weekly check green. **`backup-hub`: DOWN — §E.** | **Both roles are provided by hand, neither by the role system.** The one that works does so from the other repo. |
| **hub** | `backup-client` | **Nothing.** No binary, no unit, no timer, no cron, no `~/.config/restic`, no `hub` profile in vps. | **A box carrying a backup role with no backup running.** |
| **desktop-wsl** | **cannot declare anything** — self-declared WSL host, no `fleet.json` entry, only a `fleet.local.json` nickname | **The fleet's only working REST client**, and the most comprehensively backed-up box in the fleet (all of `/home/me`). `resticprofile-backup@profile-wsl.timer` under `systemctl --user`, `Linger=yes`, binaries at `~/.local/bin/`. | **The inversion.** The one box actually exercising the hub is structurally incapable of declaring the role, because the role system reads `fleet.json` and this host is deliberately absent from it. |
| **air** | no backup role | Mechanism 7 only: 26 `$HOME` paths to a git remote. | Role-consistent — and it is the **primary dev box**, holding the only copy of this review and two unpushed commits. Consistency is not correctness. |
| **desktop** (Windows-native) | no backup role | Nothing (OneDrive unassessed). | Role-consistent. |

**Answer to "is there a box carrying a backup role with no backup running?"** — **Yes: `hub`.** It declares `backup-client` and has no backup mechanism of any kind, while holding the only copy of the tailnet control plane. And separately: **latitude declares `backup-hub`, and that role's service is down** — so latitude is simultaneously the box where a backup role works (client, by hand) and the box where one is broken (hub).

---

#### E. Live faults

**1. The hub is down. Confirmed — and the committed review is wrong on both the clock and the shape of the failure.**

```
docker ps -a --filter name=restic     →  restic-server   Exited (255) 10 hours ago
docker inspect restic-server          →  ExitCode=255  RestartCount=0  RestartPolicy=unless-stopped
  Error=failed to set up container networking: driver failed programming external
    connectivity on endpoint restic-server: failed to bind host port
    100.64.0.8:8001/tcp: cannot assign requested address
  StartedAt=2026-08-01T11:33:50.944016992Z   FinishedAt=2026-08-02T10:53:17.547240599Z
ss -lntp | grep 8001                  →  (nothing)
tailscale ip -4                       →  100.64.0.8   (the address exists now)
```

- **Service was lost at ~15:30 +05 on 2026-08-02, not 15:53, and there *was* a crash — the host's.** The previous boot's last journal entry is `Sun 2026-08-02 15:30:18 +05` and `last -x` records that boot as **`crash`**, not a clean shutdown. The box came back at `15:53:09`, and `FinishedAt` (`10:53:17Z` = `15:53:17 +05`) is the **failed restart eight seconds after boot**. So the draft's "a boot-time failure, not a mid-life crash" is wrong as written: there was a crash, it just was not the container's, and the outage is ~23 minutes longer than either the draft or the committed review says. The committed review's "10:53" needs correcting on both axes — UTC read as local, *and* the true service-loss time.
- **`RestartCount=0` after 10+ hours.** `restart: unless-stopped` does not retry when the failure is at network-setup time — the container never entered `running`, so the policy is never engaged. `homeserver/restic-server/compose.yml` both **predicted the symptom and asserted a mitigation that does not exist**: "*`restart: unless-stopped` covers the boot race — docker retries the bind and succeeds once the interface exists. If this container is ever found dead after a reboot, that race is the first thing to check, not the last.*" The diagnosis half is correct and cost one command; the mitigation half is refuted by `RestartCount=0`.
- **Exactly one client points at it, by enumeration.** `grep -rn 'repository:' ~/my/vps/backup/` returns five lines: one `rest:` URL (`wsl/profiles.yaml:35`), one local path (`latitude/profiles.yaml:48`), and three `G:\`/`H:\` Windows paths in `homeserver/profiles.yaml` belonging to the retired box, whose drives were reformatted. The REST hub's entire client population is desktop-wsl's `wsl` profile.
- **Nothing has failed yet, and the window is closing.** desktop-wsl's `41a19b13` landed `2026-08-02 06:00:28 +05` = `01:00 UTC`, well inside the hub's up-window. The next fire is **2026-08-03 06:00 +05**, and it is the first that fails.
- **How loudly would it fail? Silently.** The only signal is a `systemctl --user` unit on a WSL distro that this same review found **28 commits behind under a green timer with 185 consecutive `SKIP dirty` lines**. No `OnFailure=` on any of the four latitude units either, no alert, no push, no statusboard row. `--prometheus` is set in the hub's `OPTIONS`, so it *emits* metrics — and nothing scrapes them. The likely discovery path is somebody running `restic snapshots` months later.
- **The vps repo's own memory says it is down on purpose.** `~/my/vps/.claude/memory/project.md:79` — "Down on purpose: navidrome, **restic-server**, forgejo…". That line is from the 2026-08-01 bring-up and went stale within hours (the container's `StartedAt` is exactly commit `99bc734`, 2026-08-01 16:33 +05), but was never corrected. An operator consulting vps memory today gets a wrong answer about the hub, which compounds the silence.
- **Correction to the committed review's Tier-1 item 1, on evidence:** it offers "either bind `0.0.0.0:8001` … or add an ordering dependency on `tailscaled`." Binding `0.0.0.0` is the wrong branch and the compose file already argues why — that was the g513ie posture, and "publishing on 0.0.0.0 actually exposed it to every device on the wifi, guests included." The ordering fix is the only one consistent with the file's own reasoning. **And verify by rebooting, not by `docker start`** — this repo's own rule, "verify a scheduled job by firing its schedule, not by running the script," applies verbatim to a boot race.

**2. `archive-mirror.timer` has never fired once.** The airtight form is that no fire window has ever existed: `install-timers.sh -go` enabled it at `2026-08-01 18:07:38 +05`, *after* that month's 05:00 trigger point on the 1st, and `Persistent=yes` writes the stamp at enable time, so there is no catch-up run. `systemctl show -p LastTriggerUSec` returns exactly that enable timestamp; `/var/lib/systemd/timers/stamp-archive-mirror.timer` **and its parent directory** carry the same mtime. Corroboration: `journalctl -u archive-mirror.service` → `-- No entries --` while `mirror-refresh.service`'s `Aug 02 03:31` lines survive in the same journal across the same reboot — **but that contrast only reproduces under `sudo`**; run as `me` (in neither `adm` nor `systemd-journal`) both come back empty and a re-checker gets a false refutation. The 665 G at `/mnt/xs/immich-2024-archive` was placed by the hand-run `nohup` the script header describes. **First real fire: `Tue 2026-09-01 05:01:54`.**

The committed review calls both mirrors "healthy." One of them is. The other is an untested monthly timer whose first execution is four weeks out, guarding the fleet's largest irreplaceable dataset, onto a target that is **95 % full with 36 G free** — and that target is **partition 3 of a Ventoy installer stick**: `blkid` gives `/dev/sda1 LABEL="Boot"` exfat 253.8 G (Ventoy's ISO partition, not user data), `/dev/sda2 LABEL="VTOYEFI"`, `/dev/sda3 LABEL="xs700" UUID="FBED-BCAA"` → `/mnt/xs`. The only second copy of the 663 G 1970–2024 archive shares a device with bootable install media. `archive-mirror.sh:26-28` stakes the 37 GiB of slack on 1970–2024 being a closed set — a correct bet, but the free space is now inside the noise of a single large import.

**3. The `g614jv` repository has never been integrity-checked — and the config that says it should be is inert.** `check-before: true` is declared at `base.yaml:14` and *is* inherited: `resticprofile --config profiles.yaml -n wsl show` resolves `check-before: true`. It never runs. The 3,284-line / 231,702-byte `resticprofile-wsl.backup.log` spanning 2026-04-27 → 2026-08-02 logs every invocation (`DEBUG starting command:`) and the sequence is always `init` → `backup` → `forget`; `grep -c -i check` over it returns **0**. Same on latitude's backup log. A placement bug in `base.yaml` was hypothesised and disproved by the `show` output, so **the mechanism is unresolved — report it as declared-and-inert, not as a config error.** Either way `show` emits only `schedule backup@wsl` for wsl, versus both `schedule backup@latitude` and `schedule check@latitude` for latitude. So the draft's "the base's `check-before: true` is the only integrity touch that repo ever gets" is wrong: it gets none. `/mnt/spare320/restic-rest/g614jv` has been verified zero times since it was created on 2026-08-01, and it is the repo behind the down hub.

**4. latitude's `~/my/vps` is 11 commits behind `origin/main`, and nothing pulls it.** `## main...origin/main [behind 11]`; latitude is at `99bc734`, air at `24babcc`. This is the committed review's hub-`~/vps` finding repeating on the **backup host**, whose four root-scope system units run out of that work tree. Sized honestly, it is forward-looking risk rather than a stale-config fault: `md5sum` of `backup/base.yaml`, `backup/latitude/profiles.yaml` and `homeserver/restic-server/compose.yml` match air byte-for-byte, and `git diff --stat HEAD..origin/main -- backup/latitude backup/base.yaml homeserver/restic-server` is empty. All four backup-touching commits it lacks are `backup/wsl/profiles.yaml` only — including `0fff181 fix(backup): point the WSL profile's password outside the repo work-tree`. desktop-wsl's own checkout *is* at `24babcc`, so the running wsl profile is the current one; the drift is latitude-only. **Reproducibility caveat:** on latitude, `grep -rn 'repository:' ~/my/vps/backup/` does *not* return the five lines quoted above — it returns the pre-repoint `wsl/profiles.yaml:12: rest:http://server.gg.ez:8001/wsl` plus two log lines. Every `wsl/profiles.yaml:12-16 / :25-34 / :35 / :37-47` citation in this section resolves against air's and desktop-wsl's 78-line file, not latitude's 25-line one.

---

#### F. Were they designed together?

**Three of the seven were, and it shows in the code. The system was not, because the set is seven and the other four have no owner.**

**The designed core — `mirror-refresh` + `archive-mirror` + resticprofile `latitude`.** Built as one thing on 2026-08-01; each header cites the others by name and by clock:

- `backup/latitude/profiles.yaml:5-11` — "THIS DELIBERATELY DOES NOT COVER THE PHOTO LIBRARIES. /mnt/immich (242 G) and /mnt/immich-2024/admin (663 G) are protected by whole-filesystem rsync mirrors instead — `machines/hosts/latitude/debian/{mirror-refresh,archive-mirror}.sh`. There is no drive left in the fleet with 815 G free for a restic repo, so pretending otherwise would produce a config that fails every night."
- `:20-24` — the versioned-history argument for why restic overlaps the mirrors on purpose (quoted in §C).
- `:31-34` — repo placement chosen for physical-drive *and* USB-bus separation, "so a scheduled backup does not contend with a mirror run."
- `:77-80` — "03:30 mirror-refresh, 04:30 this. Separated so the backup reads a filesystem the mirror is no longer walking."
- `archive-mirror.timer` — 05:00 on the 1st "to clear mirror-refresh at 03:30"; `archive-mirror.sh:52-53` — "Do not run this at the same time as mirror-refresh.sh — both read from drives in the same dock, and contention is what provokes the resets"; the two services share `/var/lock/latitude-mirror.lock`.
- `install-timers.sh:7-19` records the scope decision (system, not the user scope the three git-sync timers use, because `rsync -aHAX` must reproduce `root:root` on immich's dump) and the copy-not-symlink decision.

Those five files form a genuine, argued, mutually-aware design with a **staggered clock (02:00 → 03:30 → 04:30 → 05:00), an explicit division of labour (rsync for the bulk that will not fit, restic for the small-and-irreplaceable), and hardware-level contention reasoning.** It is the best-documented thing in either repo, and it is why "they accreted" is the wrong answer to the question as posed.

**The four that have no owner:**

1. **The REST hub is a g513ie-generation artifact, repointed rather than redesigned.** `git show --stat 99bc734` → 27 insertions, 1 deletion; the sole functional change is `- "8001:8000"` → `- "100.64.0.8:8001:8000"`, and the other 26 lines are same-day rationale. The client side matches: `backup/wsl/profiles.yaml:12-16` — "Repointed off g513ie 2026-08-01. The old target was `rest:http://server.gg.ez:8001/wsl` … Nothing to migrate; this starts a fresh repo." The 06:00 schedule was **inherited, not chosen**: nothing argues it against latitude's stagger, it merely happens to land after all four. **One draft claim reversed here:** `--no-auth` and the absence of `--append-only` are *not* argued from a home-LAN threat model — the compose comments repudiate one. `restic-server/compose.yml:9-12`: "On g513ie that was papered over by 'it's a home LAN'; publishing on 0.0.0.0 actually exposed it to every device on the wifi, guests included." Commit `99bc734`'s body: "'it's a home LAN' was doing load-bearing work it cannot do." Both were written for latitude, that day, and the `--append-only` paragraph reasons about *latitude's* retention chore.
2. **immich's `pg_dump` is a load-bearing input that the live design does not declare — and it used to.** `mirror-refresh.sh:53` copies its output; `profiles.yaml:63` makes it restic source #1 and calls it "immich's own nightly pg_dumpall — albums, faces, people, stacks. No pile of JPEGs rebuilds this." Two of the three designed mechanisms depend on a producer that exists in no file in either repo, on no schedule either repo can see, and that no test verifies is still running. The sharper version of this than the draft found: the *retired* `backup/homeserver/profiles.yaml:8-18` declared it explicitly —
   ```yaml
   immich-postgres:
     backup:
       stdin-command: "docker exec -i immich_postgres pg_dumpall --clean --if-exists --username=postgres"
       run-before:    "docker exec immich_postgres pg_isready"
   ```
   — so the 2026-08-01 design **replaced a declared producer with an undeclared one**, and `latitude/profiles.yaml:26-29` justifies dropping the homeserver design on *drive* grounds only. It never records that the in-config dump went with it. Toggle immich's backup off in the web UI today and both downstream mechanisms keep succeeding — rsync and restic will happily copy a directory that has stopped gaining files, and every unit stays green. The ownership split in that directory is a small warning of the same class: files through `2026-07-15` are `me:me`, files from `2026-07-31` are `root:root`, a producer change nothing recorded.
3. **The dotfiles bare repo is doing backup work nobody assigned it.** It is a config-sync mechanism; on latitude it is the only thing protecting the restic password and every prod `.env`, and on air it is the only backup of any kind. Nothing in either repo's backup documentation mentions it. It has no retention policy, no integrity check, and — per `$HOME/CLAUDE.md` — an **allow-only** `.gitignore` in which adding a new file does not track it, so its coverage silently fails to grow. `~/.config/gh/hosts.yml` is that failure mode already realised, on two boxes.
4. **The hand-made migration copies are not a mechanism at all** — 129 G of one-shot rsync output from `~/staging/pull-music.sh` that has quietly become the only protection for two datasets.

**The seams, named:**

- **One password, both repos, never rotated — and it is inside the repo it unlocks.** `~/my/vps/backup/homeserver/pass.txt` is a symlink → `~/g513ie-prod-config/vps/backup/homeserver/pass.txt`, dotfiles-tracked on branch `latitude`; restic stores the symlink as a symlink, so the backup does not contain the password. Correct — but it makes **the git bare repo the sole off-box copy of the key**, and nothing in either repo says so. Three plaintext copies exist and the obvious check says they are three different secrets: `~/my/vps/backup/wsl/pass.txt` is 12 B ending `\n`, while `~/.config/restic/pass.txt` and latitude's tracked `homeserver/pass.txt` are 13 B ending `\r\n`, so `sha256sum` and `cmp` report three distinct files. **That check is the false negative** — restic trims the terminator, and the same **11 characters** are underneath all three. Two links are demonstrated and one is inferred, so take them separately: the work-tree copy is confirmed byte-identical to the live *operational* password after `tr -d '\r\n'` (`cmp` exit 0, 11 chars each), and the tracked homeserver copy's 11 chars are confirmed to open the latitude repo (`RESTIC_PASSWORD_COMMAND='head -c 11 …' restic cat config` → `"id": "14f4eab544d36684…"`). The remaining pairing — operational ≡ homeserver, the one that closes "one password, *both* repos" — rests on the two being the identical 13 B `\r\n` form against the work-tree copy's 12 B `\n`, not on a direct comparison. So the Apr-27 file left in the work tree is not stale material: it is the g513ie-era password, unchanged, and **both repos created from zero on 2026-08-01 as "a fresh repo … nothing to migrate" reuse the secret that also protected the old `G:\`/`H:\` repos** — the ones `archive-mirror.sh:11-13` says went in the same reshuffle and that `plans/2026-07-28-latitude-wipe-harvest.md` §11 still lists as an open decision on the shelved ST320LT020. `wsl/profiles.yaml:37-47` sets the password path outside the tree precisely to avoid a checkout copy, and designates `~/.config/restic/pass.txt` as "an OPERATIONAL copy, deliberately untracked and expendable" — so the second copy is intended; only the work-tree leftover is not, and `.gitignore:13` does guard it from an accidental commit. And `.resticignore` does not exclude `~/.config`, so `restic ls 41a19b13 /home/me/.config/restic` returns `pass.txt`: the live password is **inside the repository it unlocks**. Encrypted at rest, so not a leak — but a restore of the wsl snapshot re-materialises the key to both repos on disk.
- **The most comprehensively backed-up box in the fleet ships to the least-verified, currently-unreachable repository.** desktop-wsl backs up all of `/home/me` — its `~/machines` clone, its `.machines/` state, its operational password — into `g614jv`, which has **never been integrity-checked** (§E.3), sits on the same spindle as the only other repo, and whose server has been down since yesterday afternoon with the next run due to fail. None of those four facts is visible from any single file or any single box.
- **The key leaves the box every ten minutes; the data it unlocks never leaves at all.** Only the two dotfiles mechanisms cross a machine boundary in a working state, and between them they carry 45 paths and 26 files. Every byte of the ~1.5 TB they are the key to is latitude-local — source and target on the same box, sometimes the same enclosure. The single machine-crossing *data* path is desktop-wsl → the REST hub, and it is down. So a latitude-level loss — fire, theft, the flaky `usb 4-2` dock taking two bays with it — destroys the immich library, the mirror, the archive, both restic repos and 129 G of migration data, and leaves you holding the password to all of it. `profiles.yaml:23` names "a format that can be shipped off-site as-is" as a reason to run restic; nothing ships it.
- **The `machines`/`vps` boundary cuts the backup system in half, mid-mechanism.** `machines` owns the two rsync scripts and their units; `vps` owns the restic profiles, the REST hub compose, and the only password. The generated systemd units on latitude carry `WorkingDirectory=/home/me/my/vps/backup/latitude` — a `machines`-managed box running root-scope timers out of the sibling repo's work tree. Defensible as a boundary call, but **no single file, in either repo, lists what is backed up.** Reconstructing §A needed both repos plus four live boxes.
- **The one document that tries to be that list is wrong in four places.** vps `CLAUDE.md`'s Backups section says at `:200` "Password file: `pass.txt` in each profile directory (not committed)" — false for both live profiles (`latitude/profiles.yaml:49` is an absolute path to the dotfiles symlink, `wsl/profiles.yaml:48` points at `~/.config/restic/`), and that is precisely the belief that makes the work-tree `pass.txt` look like a dead file. Its `:178-183` Repositories table lists four repos, three of them dead `G:\`/`H:\` paths, and **omits `/mnt/spare320/restic/latitude`** — the fleet's primary working repo is absent from vps's own repository index. `:199` documents base retention that both live profiles override (`latitude:86-89` 30/12/24/10, `wsl:74-77` 14/8/12/5), so it applies to no running profile; `:202` points at an `install-tasks.*` that does not exist in `backup/latitude/`; `:154` says "two subdirectories" where there are three; `:170-174` omits the Sunday 06:00 check. `README.md:19,68` repeat two of these.
- **`install-timers.sh` installs two of the seven and knows about none of the other five.** Its `UNITS` array (line 26) is exactly the four mirror/archive files. Nothing installs the resticprofile units — `resticprofile schedule` does, by hand. Nothing in `machines` even mentions restic.
- **The role system is decorative here** (§D), and every mechanism bypasses it.
- **Nothing verifies anything.** No `OnFailure=`, no alert, no statusboard row, no test in `provision/tests/` touching a backup. The weekly `restic check --read-data-subset 5%` on the `latitude` repo is the entire scheduled integrity story for the fleet, and `schedule-ignore-on-battery` can silently skip even that. Combined with a never-checked second repo and a down hub, the failure this system is most exposed to is not corruption — it is **not noticing it stopped**, which is exactly the failure the 2026-08-01 session existed to fix ("a backup job nobody was watching failed for 13 days," `restic-server/compose.yml`).

**The one-line answer:** the latitude trio was designed together, carefully, in one sitting, and reads that way. The other four arrived from a retired machine, from inside a container, from a config-sync tool doing backup work by accident, and from a migration nobody closed out — and because no file lists all seven, the seams between them are invisible from any single place you would look.

---

#### What could not be established

- **Why `check-before: true` never executes.** It parses, it inherits, `show` resolves it — and no `check` has ever run under `run-schedule` for either profile. Mechanism unknown; the placement hypothesis was tested and disproved.
- **Whether OneDrive on desktop-native protects anything.** Its updater tasks run; the synced set and its state were not enumerated. If it is covering `C:\Users\methe`, that is an eighth mechanism and it is in neither repo.
- **Immich's literal backup cron expression.** Established by effect and by the container's own log line, not read out of immich's config — the `system-config` row has no `backup` key.
- **`server`/g513ie was not probed** (out of scope by instruction). It may still hold restic repos or `~/g513ie-prod-config` originals; `archive-mirror.sh:11-13` says the old `G:`/`H:` repos went in the migration reshuffle.
- **No restore was tested from either repo.** Snapshot listing, `stats --mode raw-data` and one `cat config` succeeded read-only against both, which proves the repos are readable and that one password opens them; it does not prove a restore produces a working immich DB.
- **The 4.1 MB headscale WAL was observed, not checkpointed or copied** — whether a consistent copy is possible without stopping headscale is unverified.
- **`/mnt/xs`'s 36 G of free space came from `df`**, not from a fresh `archive-mirror.sh -verify`; that run is read-only but walks 20 k files across the flaky source dock, and provoking a bus reset during an unattended review was not worth the confirmation. `/dev/sda1` was identified by label, not mounted.
- **`~/staging/music` vs `/mnt/spare320/music-from-g513ie` were matched by size only** (89 G each) — "duplicate" there is an inference from the migration logs, not a checksum comparison.
- **Disclosure:** the first two reads of the `latitude` repo (`snapshots`, `stats`) ran without `--no-lock` and each created and released a shared lock file. No repository content was altered. Every subsequent restic read used `--no-lock`. The authkey match was done by prefix comparison, printing only the key ID; no key or token file contents were printed. Nothing was written to any box, to either repo, to `/mnt/xs`, or to the 6 TB drive.

---

## Live-vs-declared drift

### latitude (Debian 13.6, 100.64.0.8) — declared tiers honoured; the substrate is undeclared

Almost every declared tier verifies: battery Custom-mode cap live (`start=80 end=85 charge_types=[Custom]`), RAPL reader, sudo NOPASSWD, apt/statusboard packages, shell_init, ssh_accounts, ssh_trust, dotfiles on branch `latitude`, all three user timers healthy, both backup units byte-identical to the repo, zero failed units in either scope.

**Undeclared, and the list is long.** The entire Docker substrate (5 apt packages, 21 containers, 7 compose projects) is declared in **neither** `machines` nor `vps`. Tailscale, plus an `/etc/systemd/system/tailscale-autoconnect.service` whose Description says "Auto-enroll this **WSL distro**" — hand-copied from `tailscale-wsl.sh` onto bare metal. restic + resticprofile + four units. `rsync` and `exfatprogs`, which this repo's own enabled timers hard-depend on (`rsync -aHAX`; `/mnt/xs` is exfat) and which appear in no tier. An autologin kiosk on tty1 sitting in front of `me ALL=(ALL) NOPASSWD: ALL`. A stale `statusboard.service` installed-but-disabled.

**The flagship.** `AGENTS.md:283-287` asserts as established fact that latitude never sleeps — four logind `ignore` settings plus three masked sleep targets. The box is configured exactly that way, via `/etc/systemd/logind.conf.d/99-server.conf`. **Nothing in the repo writes it**, and that path appears nowhere in the tree. A reinstall that follows the repo produces a services host that suspends on a lid close, with no error.

**Declared but absent:** `backup-hub`, `ssh-server` and `base` have no executor; `--apply` exits 0 for all of them. `~/.ssh/config`'s fleet span is hand-written (tier_fleet_ssh is darwin-only) and two of its parts are stale — its "MagicDNS cannot work here" rationale has expired (dhcpcd is inactive, `/etc/resolv.conf` says "generated by tailscale", all `*.gg.ez` names resolve), and it uses the nickname `desktop-ubuntu26`. Its `Host g513ie server` block is unmanaged but **load-bearing** — do not prune it, it is latitude's only route to `server` for the pending C: review.

### air (macOS, 100.64.0.7) — eleven of thirteen tiers clean; two things it cannot work without are unprovisioned

Verified clean: every brew formula, git config, gortex at the pinned `0.61.4`, the `~/.claude` link shape exactly as `bootstrap.sh` specifies, `core.hooksPath` set, all three launch agents healthy.

**`just` is installed by hand and no tier on any platform installs it.** The repo's entire 16-recipe command surface, including THE gate, is unprovisioned. **Tailscale likewise** — `tier_brew_cask`'s loop is `docker-desktop` only — so a Mac finished by `bash provision/macos.sh` ends with an `~/.ssh/config` full of `*.gg.ez` names it cannot resolve.

**Correction to the air report:** it lists `node` among undeclared hand-installed leaves and says "not required by anything here." That is refuted by the repo's own unmerged history — `cc826f9` on `metheoryt/machines-cleanup` adds `nodejs`/`node` to both dev tiers, with a commit body recording that a plugin's SessionStart hook failed on every session on air with `node: command not found`. The gap is closed on a branch nobody merged.

**Declared but absent:** `~/.ssh/authorized_keys` still trusts `methe@server`, which `provision/fleet-authorized-keys` no longer declares — latent only because sshd is not listening. `base` and `ssh-server` have no executor, and sshd being off means the box every other member's generated config names as `air.gg.ez` is unreachable. The fleet-ssh span still carries a `Host server` block — confirmation of a documented prediction, not a new defect. Leftovers: a 39 MB `chezmoi` binary from a mechanism retired 2026-07-28; an undocumented tailnet node `ipheoryt12` at 100.64.0.5.

### hub (Debian 12.15, 100.64.0.1) — least drifted on the declared axis, worst exposure off it

All eight hub-profile tiers materialised faithfully; the six unit files are byte-identical to the `tiers.sh` heredocs including `KillMode=process` and the pinned `Environment=FLEET_ROOTS=/home/debian/machines`; zero failed units.

**`PasswordAuthentication yes`** on the fleet's only internet-facing box, from a 27-byte cloud-init drop-in written 2025-02-17 and never revisited because the `ssh-server` role that would revisit it does not exist. Root is locked, but the `debian` account has a usable password *and* passwordless sudo, and nothing filters packets (`iptables -P INPUT ACCEPT`, no ufw, no nft filter table). An **`mtproto-proxy` container** on `0.0.0.0:8443` with an empty label set, belonging to no compose project in either repo — started by a bare `docker run` and reproducible from nothing.

**hub's `~/vps` is 4 commits behind and nothing will ever pull it.** Structural: hub lacks the `repos` role and `tier_selfpull` is deliberately pinned to `%h/machines`. The repo defining headscale/caddy/awg/rustdesk on that box drifts indefinitely. Also: a `me@desktop-wsl-ubuntu-26-04` key **outside** the managed trust span, which `tier_ssh_trust` structurally cannot revoke (already tracked as roadmap P6); six `authorized_keys` backup files; a stray 52 MB non-executable `~/caddy` alongside the apt one.

### desktop + desktop-wsl (100.64.0.4 / .6) — the Windows side is excellent; the WSL child is frozen

Windows-native is in the best shape of the fleet: clone clean on main at origin HEAD, converge `status=ok`, all three declared Scheduled Tasks returning `0x0`, and `windows.ps1` step 6 fully converged — sshd Automatic/Running, firewall scoped to `100.64.0.0/10` + `192.168.8.0/24`, default Any-rule disabled, password auth off, `administrators_authorized_keys` byte-identical to HEAD's 4-key trust file.

**desktop-wsl has not advanced in ~35 hours and is 28 commits behind**, because one untracked zero-byte `.zed/tasks.json` trips `selfpull_one`'s dirty gate. The journal holds **185 consecutive `SKIP dirty` lines and zero OK lines**, while the timer, the service and `.machines/last-converge` all report success. `.gitignore` covers `.idea/`, `.vscode/` and `*.sublime-*` and has **no Zed entry** (verified). The security consequence: `methe@server`'s key is still trusted on that box because the revoking commit is one of the 28 unpulled — the revocation mechanism works (the Windows side proves it) but reads the clone's copy of the key file, and the clone is frozen. The box also still runs pre-`65aac22` provisioning code, including the `set -u` UTF-8 bug the suite caught.

**A phantom Scheduled Task:** `git-autofetch` fires every 10 minutes at `scripts\git-autofetch.ps1`, returns `0xFFFD0000`, and reads `State: Ready`. That path has existed at no revision since `f3d63b2`; nothing in the repo registers the task; there is no Windows git-autofetch code left to repair it from, and the runbook's instructions for fixing it point into the deleted `modules/` tree. This is the mirror-refresh lesson repeating on another box.

**Also:** git-autofetch is genuinely double-scheduled on desktop-wsl (systemd timer *and* an active cron line, both firing ~1 min apart, because WSL gained `systemd=true` after the first provisioning run and `tier_autofetch` never removes the fallback). `fd_wsl_hosts` **boots stopped WSL distros** as a side effect of ordinary read-only fleet tooling. `hosts/desktop/windows/install.ps1` — the documented public bootstrap one-liner — throws unconditionally at line 67 handing off to a `restore.ps1` that exists at no revision. gortex on Windows is at 0.61.0 against a 0.61.4 pin with no installer on that path.

---

## What to act on, ranked

**Read this list as ordered by live consequence, not by ledger verdict.** The top items come from the drift reports and the completeness critic, and several touch files the ledger marked `keep` or scoped a `rewrite` too narrowly. Where the two disagree, this list is the reconciliation.

### Tier 1 — live faults

**1. Restore the restic REST hub on latitude, and fix the bind race properly.**
*Changes:* in the vps repo, add an ordering dependency on `tailscaled` — a systemd drop-in or an entrypoint retry loop.
*Why:* `backup-hub` is the role that names latitude; it has been down since **2026-08-02 10:53 UTC = 15:53 +05** and `restart: unless-stopped` demonstrably does not cover the boot race (`RestartCount=0`).
*Cost:* one compose edit plus a restart.
*Breaks:* nothing. **Do not take the `0.0.0.0` branch** — an earlier draft of this list offered it and the backups pass refuted it from the compose file's own comments: that was the g513ie posture, and "publishing on 0.0.0.0 actually exposed it to every device on the wifi, guests included." Verify by **rebooting**, not by `docker start` — this repo's own rule about firing a job's schedule rather than the script applies verbatim to a boot race.

**1b. The rest of the backup surface, from the dedicated pass — read that section before acting on any of it.** Four faults sit alongside the hub and none was in the first draft of this list: `archive-mirror.timer` has **never fired once** (enabled after August's trigger point; first real fire `2026-09-01 05:01:54`) and its target `/mnt/xs` is 95% full **on partition 3 of a Ventoy installer stick**; the `g614jv` repository has **never been integrity-checked** despite `check-before: true` resolving true, so the repo behind the down hub is unverified; **one 11-character password unlocks both repos**, is the g513ie-era secret both "fresh" repos reused, and lives inside the wsl snapshot it unlocks; and **no backup data ever leaves latitude** — a single-box loss takes the library, both mirrors, both restic repos and 129 G of migration data together, while the only thing crossing a machine boundary every ten minutes is the key.

**2. Add `.zed/` to `.gitignore`, and clear the untracked file on desktop-wsl.**
*Changes:* one `.gitignore` line; `rm -rf ~/machines/.zed` on the box (or commit it — it is a zero-byte file).
*Why:* unfreezes 28 commits including the `methe@server` revocation and the `set -u` fix. **This supersedes the `.gitignore` ledger row's scope**, which certified the surviving stanzas as "accurate and verified live" while the missing line was freezing a fleet member.
*Cost:* minutes.
*Breaks:* nothing. Pair it with the next item, because `SKIP dirty` will do this again.

**3. Make `SKIP dirty` visible in fleet-selfpull.**
*Changes:* count consecutive skips per repo and escalate — a non-zero exit, or a warning line the journal makes greppable, after N ticks.
*Why:* 185 silent skips under a green timer is the same failure class `fleet-selfpull.sh`'s own header was written to prevent ("the same silent failure that let latitude sit 23 commits behind"). The 2026-07 fix separated fetch failures from skips and left skips silent and unbounded.
*Cost:* ~10 lines plus a test.
*Breaks:* a deliberately-dirty repo now generates noise. That is the point; make the threshold generous.

**4. Escape the `%` at `tiers.sh:1232` and `:1372`.**
*Changes:* `%%` → `\%%` in the two `printf` cron lines. Verified present in both.
*Why:* cron truncates at the unescaped `%`, so on any box without a systemd user manager `fleet-selfpull` and `dotfiles-sync` are scheduled and never run.
*Cost:* two characters.
*Breaks:* nothing; `tier_autofetch`'s cron line has no `%` and already works, which is why only these two are inert.

**5. Decide the Windows `git-autofetch` task: remove it, or restore the script.**
*Changes:* either `schtasks /delete /tn git-autofetch` on desktop and strike the runbook step, or restore `git-autofetch.ps1` from tag `nixos-final` into `provision/` and register it from there.
*Why:* it fails every 10 minutes with `0xFFFD0000` while reporting `Ready`, and the only repair instructions point into a deleted tree.
*Cost:* small either way.
*Breaks:* removing it loses nothing operationally — the `fleet-selfpull` task already fetches. Removal is the honest answer.

### Tier 2 — cheap, safe, mechanical

**6. `provision.sh`'s fallback arm sets `rc=1` under `--apply`.**
*Changes:* two lines at `provision.sh:83-88`, plus an explicit opt-out (e.g. a `"planned"` list) so a known stub is a deliberate declaration rather than a silent one.
*Why:* `just provision --machine latitude --apply` reports success while doing nothing for four of seven roles. `provision.sh:43-47` already fixed this exact class one level up for an unknown *machine*, with a comment naming the failure; the guard was never applied to roles.
*Cost:* trivial. *Breaks:* every `--apply` on latitude/hub/air now exits non-zero until the opt-out list is populated — do both in the same commit.

**7. Widen the `just test` glob from 28 to all 38 suites.**
*Changes:* replace the four hand-listed directories at `justfile:55-56` with a recursive find; rename `agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh` to `*.test.sh`; add the assertion to `provision/tests/justfile.test.sh` so this cannot silently regress again.
*Why:* the recipe's own comment says a hand-listed set makes "coverage silently stop growing" — which is exactly what happened. **Two workers independently ran all ten orphaned suites by hand and all ten pass**, so this is low-risk. Disregard the one group note claiming the hook test writes into the real `~/pure/backend-api` — that test redirects `$HOME` into a `mktemp -d` at its lines 16-21.
*Cost:* one recipe edit plus one rename. *Breaks:* nothing measured. `test_distill.py` stays out (see the judgement calls).

**8. Make `dotfiles_sync` reachable from the driver on air and hub.**
*Changes:* add the `dotfiles` tier to `macos.sh`'s workstation list and `linux.sh`'s hub list (it reaches `tier_dotfiles_sync` transitively, matching how workstation/server already do it).
*Why:* convergence runs the driver, never the role dispatcher, so on those two boxes the timer is installed once and never maintained — the air plist has not been touched in three reprovisions.
*Cost:* two lines. *Breaks:* **coupled edit** — `provision/tests/tiers.test.sh:35-38,57-60` pin both lists by exact string and go red otherwise. Also note `tier_dotfiles:1258` hardcodes the platform as `wsl`; harmless today, worth fixing while you are there.

**9. Fix `agents/.gitignore:9`.**
*Changes:* move the trailing comment onto its own line above the pattern.
*Why:* gitignore does not strip inline comments, so the pattern is the whole line. Verified: `git check-ignore -v agents/settings.local.json` returns **NOT IGNORED**, and the root `.gitignore:39` rule covers a different path. It is the one line in that file with an inline comment, and it is the one the comment itself calls secret-bearing.
*Cost:* one line. *Breaks:* nothing.

**10. Force `tier_ssh_trust` on air to drop `methe@server`.**
*Changes:* re-run the tier (or the whole macos driver) on air; desktop-wsl gets it from item 2.
*Why:* the revocation is correct in the repo and has not propagated. Latent while sshd is off; live the moment `ssh-server` is implemented — and `server` is still powered on at 100.64.0.3.
*Cost:* one run. *Breaks:* nothing; the span rewrite is wholesale and idempotent.

**10b. `CLAUDE.md` is inert on the desktop-native checkout — every agent session there loads nothing.**
*Evidence, measured 2026-08-03 over Git Bash:*
```
core.symlinks=false
-rw-r--r-- 1 methe 197121 9 CLAUDE.md          # 9 bytes, a regular file
head -c 80 CLAUDE.md  →  AGENTS.md            # the literal target path, as text
git ls-files -s       →  120000 47dc3e3d …    # the index still says symlink
```
*Why:* the repo's whole agent-instruction contract is `CLAUDE.md` → `AGENTS.md`, and `AGENTS.md:3-5` mandates the symlink shape. With `core.symlinks=false` git checks the link out as a text file whose content is the target's path, so memory discovery on desktop reads nine bytes of nothing. This makes the ledger's `keep` on `CLAUDE.md` a portability finding rather than a clean row, and it means every agent that has ever run in `~/machines` on that box operated with no repo instructions at all — silently, because a 9-byte file is not an error.
*Changes:* three options, in order of preference. (a) Set `core.symlinks=true` on that clone and re-checkout the path — works only if the account has SeCreateSymbolicLinkPrivilege or Windows Developer Mode is on, which is the thing to check first. (b) Ship a `.gitattributes` rule, or a `windows.ps1` step, that materialises `CLAUDE.md` as a copy on Windows checkouts — diverges the two files, so it needs a guard. (c) Accept it and make `AGENTS.md` the discovered filename on that platform.
*Cost:* (a) is one command if the privilege is there. *Breaks:* nothing measured; verify by re-reading the file, not by re-running the checkout.

**11. Clear the junk, and decide the authkey.**
*Changes:* delete `statix.toml` (a Nix linter, zero `.nix` files, and neither invocation path it names exists) and the stray `.pyc`. Shred `provision/secrets/authkey` if the key is spent — Headscale pre-auth keys are revocable on hub and re-mintable per `provision/README.md:352`.
*Cost:* minutes. *Breaks:* nothing.

**12. Resolve `metheoryt/machines-cleanup` before editing `provision/lib/tiers.sh` or `provision/README.md`.**
*Why:* it is 3 commits ahead and already editing exactly those two files. Merging it also closes the `node` gap the air drift report reports as open.
*Cost:* a merge or a decision to abandon. *Breaks:* editing those two rows first guarantees a conflict.

### Tier 3 — real work with a clear payoff

**13. Close the four measured coverage gaps — but as three separate decisions.** Add `just` to `tier_brew_dev` and `tier_apt_dev` (one line each; the gate's own runner being unprovisioned is the most embarrassing gap in the repo). Add `rsync` to `tier_apt_min` and `exfatprogs` to the server profile, and consider a precondition check in `install-timers.sh` instead — that script is a deliberate hand-run, so the accurate claim is "an operator who follows the repo installs timers that fail on first fire," not "a reinstall boots broken." **Tailscale is not a package line** — there is no darwin and no bare-metal-Debian installer, enrollment is a flow, and `tailscale-mac.sh:13-16` records a real decision (no `--authkey` flag; argv is world-readable via `ps`). Put it on the roadmap next to P3.

**14. Implement the `ssh-server` role.** Two written specs already exist: `docs/2026-08-01-nixos-harvest.md` §1 gives the firewall shape (port 22 on `tailscale0` only, one verbatim `192.168.8.0/24` carve-out, password *and* keyboard-interactive both off, keys from `provision/fleet-authorized-keys`) and `docs/superpowers/specs/2026-07-17-fleet-ssh-tailnet-retire-awg-design.md` §A adds the rationale the harvest omits. **hub needs its own arm** — it must stay reachable off-tailnet, and it is the box currently running `PasswordAuthentication yes` with a password-bearing sudo account. Cost: real, but it is the role with the most spec and the least code. Breaks: get hub's arm wrong and you lock yourself out of the VPS — stage it with a second session open.

**15. Give hub a backup, and run the backups pass.** hub holds the only copy of the tailnet's identity and has no backup on either side of the boundary. Add a `hub` profile in `~/my/vps/backup/` and a client here. Then do the full pass: every client/target pair, last successful snapshot, reconciled against the role declarations — including air, which has neither.

**16. Fix the four contradicting documents in one pass, not one at a time.** `docs/fleet-roadmap.md:89-100` and `docs/2026-07-drive-migration-log.md:20,207-219` both state a pre-2026-08-01 restic world that the roadmap's own lines 118-128 overturn. A session grepping "restic" across `docs/` gets two stale hits and one current one; fixing one leaves the trap. Also repoint P2's header (it says "see the Forgejo item" when the real gate is C:), and reconcile AGENTS.md's "27 suites" (line 82) vs "28 suites" (line 132) — the true number is 38 tracked, 28 reached.

**17. Address the ~140 KB session-start load.** `AGENTS.md` (296) + `README.md` (195) + `.claude/memory/project.md` (1664) ≈ 2150 lines describing the same repo, two of them injected into *every* session — `CLAUDE.md` via memory discovery and `project.md` `cat`ed verbatim by `project-memory-check.sh:34`. `project.md` was deliberately pruned to 456 lines on 2026-07-24 and is 3.6× that nine days later, still tracking "Drop pylspFixOverlay from flake.nix" against a file that does not exist. This is the mechanism behind roadmap P5's measured cost — the answers are present but buried. Set an explicit division of labour: README = newcomer orientation, AGENTS.md = agent operating rules, project.md = durable decisions only, hard-capped.

**18. Status-banner the 90 plans and specs — group (b) first.** Two populations hide inside the 86 rewrites. *Implemented-and-accurate* needs a one-line `DONE` header. *Implemented-then-deleted-or-reversed* is actively misleading — chezmoi (built, then explicitly repudiated at `roles/dotfiles.sh:1-7`), phase5a, the `hosts` role (built in three commits, then retired in `52b66d8`), gortex-align, orca-serve. An agent reading those builds a false model and hunts for machinery removed on purpose. A four-word vocabulary covers everything: `DONE` / `DONE-THEN-SUPERSEDED-BY-<path>` / `ABANDONED` / `OPEN`. The repo already has the model banner at `specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md`. **Reconcile the apparent convention conflict once, in writing**: `plans/2026-07-20-fleet-hostname-normalization.md:17` and its spec at :115 say plans/specs are "dated history; not rewritten" — that rule is scoped to *rename sweeps* and forbids rewriting bodies, not adding headers; roadmap P5:367 is newer and asks for exactly a status line. Say so, or the next agent stalls on the same contradiction. **Cheaper alternative worth considering first:** a generated `docs/superpowers/README.md` index (path, date, one-line status) closes P5's cost for less than 90 hand-edited headers. Also note checkboxes are noise — one finished plan sits at 53/53, another at 8/79, and two completed ones at 0/66 and 0/38.

**19. Factor `_schedule_periodic`.** ~100 of the 313 timer lines, mechanical and testable, with `provision/tests/git-autofetch.test.sh` already demonstrating how to test an extracted heredoc.

**20. Close the PowerShell coverage hole.** `windows.ps1` is 25 KB and is desktop's entire provisioning path with zero tests; so are `dotfiles-sync.ps1`, `fleet-selfpull.ps1`, `provision.ps1`, `roles/*.ps1` and `Fleet.psm1`. The repo already knows the pattern — `provision/tests/fleet-ssh-config-ps.test.sh` runs a module's `-SelfTest` when pwsh is present and asserts platform-independent invariants unconditionally. It was never applied to the sync pair, which is why `fleet-selfpull.ps1` still carries the bare `git pull --ff-only` its POSIX twin removed months ago, and why `Fleet.psm1` still lacks the unknown-machine guard `fleet.sh:52` has.

### Tier 4 — the judgement calls

**The delete precedent — one question, not six rows.** `git log --diff-filter=D` over `plans/` and `specs/` returns exactly one commit, and it is a same-day rename. **No plan or spec has ever been deleted from this repo.** Four of the ledger's six deletes sit under that tree, and two of those contradict their own author's group note in the same submission. *My recommendation:* banner the four (`handoffs/2026-07-17-…`, `specs/…pre-commit-hooks-design`, `specs/…gortex-align-type-agnostic-design`, `specs/…orca-serve-wsl-design`) rather than delete them — the reasoning in each is why the corresponding code is gone, and gortex-align's spec is better *moved* to `~/.claude/skills/gortex-align/` (a dotfiles commit) than destroyed. Delete `statix.toml` outright. Delete `.superpowers/sdd/progress.md` — but for the **corrected reason** (superseded by the plan-scoped-workspace layout, not merely "finished") **and pair it with adding `.superpowers/sdd/` to `.gitignore`**, which the owning skill's own script header prescribes and which this repo lacks. If you want to break the never-delete precedent, do it knowingly and say so once at the top of the ledger.

The eleven `needs-decision` rows, each with my recommendation:

| # | Path | The question | My recommendation |
|---|---|---|---|
| 1 | `.gemini/settings.json` | Do you still drive Gemini here? No tier or bootstrap step installs the CLI on any box. | **Delete** unless you use it — it is a fourth agent config nothing provisions. Also note it hardcodes `GORTEX_INDEX_WORKERS: 8` where `.mcp.json` makes it overridable. |
| 2 | `agents/plugin/commands/.gitkeep` | Keep an extension point that has never held a file? | **Keep.** `agents/README.md:51` documents `commands/` as part of the plugin's structural contract; dropping it is a two-file change for zero gain. |
| 3 | `agents/plugin/skills/kb-refresh/tests/test_distill.py` | Add pytest to the toolchain, or rewrite importlib-style? | **Rewrite importlib-style**, following `orca-repair.test.sh`'s heredoc pattern, and rename to `*.test.sh`-callable form. `distill.py` is the skill's most intricate logic (watermarking, resume offsets, state merge) and is the only genuinely unexercised code in the plugin. Adding pytest to the fleet toolchain for one file is the worse trade. |
| 4 | `plans/2026-07-05-machines-fleet-layout-B-backup.md` | Delete the one factually-dead plan? | **Banner it `ABANDONED`.** `machines/backup/` never existed and `AGENTS.md:52` settled the boundary the other way; the file records why. Covered by the precedent decision above. |
| 5 | `plans/2026-07-28-home-config-generator-collapse.md` | Is the collapse still wanted? Its blocker expired rather than was met, and the fleet then moved the *opposite* way — the harvest records `me.nix`'s config being rehomed **into** `tiers.sh`, i.e. into more rendering. | **Banner it `ABANDONED — superseded by the tiers.sh consolidation`.** Its step 6 is done by accident; steps 2 and 5 are dead. |
| 6 | `specs/2026-07-05-windows-restore-script-design.md` | Do you still want a Windows restore flow? Never built; its companion `backup.ps1`/`restore.ps1` were deleted 2026-07-31. | **Decide together with `install.ps1` and the runbook (below)** — all three are one question. |
| 7 | `specs/2026-07-07-fleet-mesh-vpn-ssh-design.md` | Its world is retired, but §4's "pin, don't blind-TOFU" host-key rationale (preserve `ssh_host_ed25519_key` across reinstalls) is written nowhere else and still applies to the unimplemented `ssh-server` role. | **Keep, bannered.** Or lift §4 into the harvest and then banner. |
| 8 | `provision/tests/roles.test.sh` | It pins the `nixos` arms in `roles/*.sh`. Unlike the two protected fail-safe leftovers, those arms would actively provision a platform with no host. | **Keep the test; remove the arms and the assertions in one commit.** `fleet_platform` can never return `nixos`, so they are unreachable — but they are not fail-safe, and `roles.test.sh:42` dies with an explicit message if you touch them without updating it. |
| 9 | `provision/provision.ps1` | Wire it in, or retire the PowerShell role branch? Nothing invokes it — `windows.ps1` never mentions it, `justfile:80` runs `provision.sh`, and under Git Bash every `role_*` falls to "no posix executor (skipped)". So desktop's roles are provisioned by `windows.ps1` steps 4-7, not by the role system. | **Wire it in.** `windows.ps1` should call `provision.ps1 -Apply`, and `$RoleExecutors` should auto-discover the way `provision.sh` does with `declare -F`, or a future role silently no-ops on Windows. Retiring instead is defensible but makes `windows.ps1` the permanent Windows story and orphans three working executors. |
| 10 | `hosts/desktop/windows/install.ps1` | The public bootstrap one-liner throws unconditionally at line 67. | **Delete it, together with the runbook's Phase 1/4 automation** — unless you want the Windows restore flow (row 6), in which case rebuild all three as one piece. Note the commit that kept it misidentified it as "Win11 install media, unrelated"; the recorded intent-to-keep was formed about a different file. |
| 11 | `hosts/desktop/windows/windows-reinstall-runbook.md` | Already logged as open at `docs/fleet-roadmap.md:487`, and now overdue: two of its automation steps run deleted scripts, its `autounattend.xml` link points at the wrong directory, three steps route through the deleted NixOS tree, and the reinstall it documents already happened. | **Rewrite down to what is still true** (Ventoy + `autounattend.xml` + `winget import` + `windows.ps1`), or delete and keep only `winget-packages.json`, which stands on its own. Do not leave it as-is; it is the only reinstall instruction for the fleet's one remaining Windows box. |

Two filing calls worth making at the same time: `specs/2026-07-29-hus726060ale611-smart-evidence.txt` (raw SMART capture) and `specs/2026-07-30-6tb-return-claim-ru.md` (an **open** consumer dispute) are evidence, not specs — move them to `docs/evidence/` so the next reviewer does not apply a shipped/abandoned rubric to them. And the roadmap has **no storage section**, so `plans/2026-07-28-latitude-wipe-harvest.md` §11 is the sole tracker for two open, dated obligations (the shelved ST320LT020's restic-repos/secrets/GoPro decision; the consolidation blocked on the 6TB replacement).

---

## The framework question

**Don't build one — the thing declarativeness was going to buy you is a script, not a schema, and this review just produced it by hand.**

The premise deserves precision. What `f3d63b2` deleted was a per-platform *engine*, not the declarative *interface*. The interface is still here and already works: `fleet.json`, `provision/gortex.version` and `provision/fleet-authorized-keys` are read by the provisioner and whitelisted in `converge.sh`'s `_touches_driver` as reprovision triggers, and `gortex.version`'s own header states the principle verbatim — *"It is data, so it is a data file."* On top of that, `MACHINES_TIERS_DRY_RUN=1` prints each profile's resolved tier list and `provision/tests/tiers.test.sh:35-38,57-60` assert both lists by exact string equality inside the gate. That is a declared plan plus a gate-enforced drift check, already present, minus the framework. So "should this become declarative" is partly a question the repo has already answered yes to, three times.

The reason to stop there is not that declarative is bad. It is the **N=1 problem**, and the strongest version of it comes from the stance arguing *for*: this fleet is one Debian services host, one Mac, one Windows box, one Debian VPS, one WSL child. Every abstraction a declarative layer introduces generalises from a single instance validated by nothing — and the previous attempt's own post-mortem is the receipt. `docs/2026-08-01-nixos-harvest.md` §6 records `nvidia.nix` and `hardware/asus-rog.nix` "orphaned since g16 was retired… no host imported them," `desktop/gnome.nix` — "nothing to port," `laptop.nix` — "would now be actively harmful." That is a large fraction of 22 modules maintained for a fleet of one each. `macos.sh:72-84` has already learned the lesson in miniature: it has exactly one profile arm and its comment says why — *"a macOS server profile would be inventing a machine that does not exist."*

The second reason is the number the *for* stance produced honestly: bucketing every drift item, a declaration-plus-diff would have caught roughly **17 inventory items and zero of the six code defects**. It catches air's hand-installed `just`, latitude's Docker substrate and sleep masking, hub's mtproto container, desktop's phantom task. It catches none of: the restic bind race, desktop-wsl's 185 silent skips, the cron `%`, `install.ps1`'s unconditional throw, `fleet-selfpull.ps1`'s regressed pull, `Fleet.psm1`'s missing guard. Those are test-and-code problems, and the repo's test surface has two holes that map onto them exactly — 28 of 38 suites, and essentially no PowerShell coverage.

The third reason is that a declarative layer would make the *worse* half worse. This repo's demonstrated failure mode is description drifting from reality — 2.2 MB of docs, 90 dated files, none marked done, roadmap P5 measuring four re-derivations in one session, twice wrong first. A declaration file is a fourth description of the fleet. The only thing that would make it different in kind is a command that checks it, in the gate. Without that it is more prose. And a richer declaration increases the fraction of each box's state contingent on a pull landing — on the same week a pull has not landed on desktop-wsl for 35 hours under a green timer.

The strongest point from the *against* stance survives too, and it is the one to act on: **`fleet.json` already declares more than the executors implement.** 22 role-assignments across four machines; three role names have executors; the dispatcher's fallback prints a skip and never sets `rc`. That gap is not closed by a richer declaration language — it is widened by one. Close it with items 6 and 14 above.

And the reusable rule, from the *incremental* stance, so this does not get re-derived a third time: **the test is not "is it configuration?" but "does it decide what to do by reading the machine first?"** Probe-then-act stays imperative, permanently — `tier_battery_limit` (177 lines whose config surface is two integers, and whose whole reason for existing is that the declarative version wrote a threshold without the charge mode and displayed a ceiling it was not enforcing), `tier_rapl_read`, `tier_sudo_nopasswd`, `tier_brew_cask`, the three sync-job bodies, `linux.sh`'s PRIV/SUDO probe, `roles/dotfiles.sh`'s collision handling, `converge.sh`'s gating. Inventory-shaped things can move: the ~40 package literals across five tiers are data wearing a `for`, and lifting them into one flat file (matching the `gortex.version` / `disks.*.conf` precedent, not a new serialization format) would make item 13 a one-line edit and make "is X declared?" answerable by reading rather than by grepping five loops in a 1434-line file. If you do that, the de facto rule is: **a new declarative data file must be added to `_touches_driver` in the same commit**, or a change to it never reaches a box.

What to build instead of a framework: **the live-vs-declared sweep, as a script, in `provision/tests/`.** Four agents just performed it by hand across four boxes and it found more real drift in a day than the previous declarative layer found in thirteen months — because it compares against the box instead of against a file. It is scriptable (`brew leaves` / `apt-mark showmanual` / `systemctl list-timers` / `docker ps` diffed against the tier lists), it gets *cheaper* the more the repo declares, and it belongs in `provision/tests/` specifically because the gate's glob never reaches `agents/plugin/**/tests/`. That is the declarative benefit without the framework, and it is a week of work rather than a quarter.

---

## What this review did not establish

- **Backups DID get its first-class pass, on the re-run** — the section above is that pass, three-way verified. Its own residual unknowns are listed at the end of it rather than here. The one correction worth carrying: the placeholder's "hub down since 10:53" read a UTC stamp as local; latitude is UTC+5.
- ~~The desktop `core.symlinks` question is still open.~~ **Closed 2026-08-03, and it is a fault — see Tier 2 item 10b.**
- **`metheoryt/machines-cleanup` was discovered only in this final pass.** Its three commits were not reviewed; its `tiers.sh` diff (+32/−3) is unexamined against the ledger's `rewrite` scope, and its `node` commit already refutes one drift claim. There may be more in it.
- **The ledger and the drift reports were produced independently and this document is the first place they meet.** I folded the defects I could see; there may be others where a `keep` row and a live finding disagree and neither worker knew.
- **`hosts/` unit ExecStart paths were not verified against latitude's actual checkout path.** All four systemd units hardcode `/home/me/machines/hosts/latitude/debian/...`; nobody confirmed the match.
- **Whether the statusboard `--install` has actually been run on latitude** was inferred from the live tty1 kiosk, not from the repo's own perspective — nothing in the repo starts either board, by design, and no file records that latitude is where the install was done.
- **The `agents/settings.json` dead marketplace path** (`/home/me/pure/claude-plugins`, a Linux path on a Mac fleet) was found but its failure mode is untested — whether it degrades silently or errors at launch is unknown.
- **`.gitattributes` coverage was verified as complete and deliberate** across three files, but only for currently-tracked shebang scripts; nobody checked how the extensionless git hooks behave on the Windows checkout.
- **hub's nftables ruleset was observed as absent-of-filtering but not audited**, and its `mtproto-proxy` container's configuration (in the undeclared `proxy-config` volume) was not inspected.
- **N=4, one box per platform, one point in time.** The drift sweep is broad and shallow, and "undeclared" occasionally means "declared in the sibling `vps` repo," which is correct by the boundary rather than a gap — the resticprofile units are the clean example.
- **Ten of the eleven `needs-decision` rows carry my recommendation but nobody's decision**, and the delete precedent is a policy the user has not been asked about until now.
