# Fleet Roadmap

Living backlog for the machine fleet. Curated — tick/prune as items land. A new
session inherits the fleet state from `.claude/memory/project.md`; this file is
the "where to head next" companion. For any item worth real work, run
`superpowers:brainstorming` → `writing-plans` and drop the plan under
`docs/superpowers/plans/`.

_Last updated: 2026-08-01 — rewritten after the latitude-server migration. The
previous revision (2026-07-14) had gone materially wrong: retired node names,
latitude at the wrong tailnet IP, and done items still open. If you find
yourself copying an unchecked box forward without re-verifying it, stop — that
is how the last revision rotted._

## Where we are now

Transport is **Headscale** (self-hosted, `cc.cyphy.kz`, MagicDNS `gg.ez`);
AmneziaWG survives on the VPS **only** as the relatives' obfuscated VPN.

| Node | Tailnet IP | Platform | State |
|---|---|---|---|
| `hub` | `100.64.0.1` | Debian VPS | Headscale control plane + embedded DERP; AWG relatives-hub |
| ~~`server`~~ | ~~`100.64.0.3`~~ | Windows 11 (`g513ie`) | **out of `fleet.json` 2026-08-01** — still powered on and on the tailnet. **Docker state now holds nothing unique** (forgejo wiped; every other volume duplicated on latitude or a regenerable venv). Only `C:` attached, ~430 GB used and unreviewed — that is what gates a wipe. Reach it as `methe@server.gg.ez` |
| `desktop` | `100.64.0.4` | Windows 11 (`g614jv`) | tailnet + sshd |
| `air` | `100.64.0.7` | macOS | **primary dev box** |
| `latitude` | `100.64.0.8` | **Debian 13 trixie** | **services host** — immich + servarr + speedtest + tugtainer |

`desktop-wsl` (`100.64.0.6`) is a self-declared WSL host: no `fleet.json` entry,
a gitignored `fleet.local.json` instead.

Two separate LANs. Same-LAN pairs get direct P2P (~3ms); cross-LAN pairs relay
through our own DERP — expected and accepted, which is why **UPnP/router
port-mapping is not on this backlog**.

**There is no Nix host left in the fleet, and the NixOS tree is deleted**
(2026-08-01, tag `nixos-final`). `modules/`, `flake.nix` and `pkgs/` no longer
exist — read P1 and `docs/2026-08-01-nixos-harvest.md` before restoring anything
from the tag.

---

## P0 — Backups. Largely fixed 2026-08-01; the remainder is DEFERRED by decision.

> **Deferred 2026-08-01, deliberately — do not re-raise it as an oversight.**
> Asked whether to build backup monitoring (a statusboard page, a notification,
> or a scheduled agent check), the answer was: *"we shouldn't focus on backups
> that much. If they will get broken, we will eventually know. Let's defer proper
> backups and monitoring to future."* The statusboard backups page was declined
> outright — that board is a local VT on latitude and the work happens on `air`,
> so the page would have been decoration.
>
> The accepted trade, stated once and then left alone: the three jobs below run
> unwatched, and the failure mode of an unwatched job is silence, which is how the
> `server` tasks went 13 days unnoticed. What is different now is that the data
> has a **second copy** rather than a single one, so silence costs currency, not
> the archive. That is the part that actually mattered and it is done.
>
> If this is picked back up: the enabling trick is already proven — a repo's
> newest snapshot age is readable from `<repo>/snapshots/` **file mtimes**, with
> no restic binary and no password, and because latitude is the hub it can see
> every pusher's repo including `desktop-wsl`'s. The design that was worked out
> and not built: one status script emitting rows (`--json` for agents), pure
> `sb_backup_*` helpers above the `STATUSBOARD_LIB_ONLY` guard so they are
> fixture-testable like `sb_docker_alerts`, and a severity policy keyed on each
> job's **declared expected period** rather than on periodicity — that rule is
> what keeps Debian's nine housekeeping timers off the page while catching the
> four that matter.

_This section was rewritten twice. The first version claimed "nothing has been
backed up anywhere since 2026-07-19", which was **wrong** — immich's own nightly
dump was alive throughout — and it pointed at the wrong fix, a scheduler, when
what was missing was a second copy. Kept visible because the corrected diagnosis
is what made the right work obvious._

### What is protected now

| Data | Size | Protection |
|---|---|---|
| immich DB (albums, faces, metadata) | 2.9 G | ✅ immich's nightly dump → mirror **and** restic, daily 04:30 |
| immich library, 2025→now | 242 G | ✅ rsync mirror → sdd2, **timer** daily 03:35 |
| **immich archive 1970–2024** | **663 G** | ✅ second copy on `/mnt/xs`, byte-verified; monthly refresh |
| `desktop-wsl` `$HOME` | 8.1 G | ✅ restic → latitude's REST hub, daily 06:00 |
| ServarrConfig, xs-keepers, vps `.env`s | 3.6 G | ✅ restic, versioned, daily 04:30 |
| servarr media | 526 G | ✅ deliberately unprotected — replaceable torrent data |
| **history for the photo libraries** | — | ❌ mirrors give a second copy, **not versions** |

### What died

- The three `immich-*` scheduled tasks on `server` last ran **2026-07-19** and
  have returned `0x8007010B` — *"the directory name is invalid"* — ever since.
  They target `G:\`/`H:\`. They are still `State: Ready` with a `NextRunTime`,
  so **the schedule reads healthy while backing up nothing.**
- **The restic repos no longer exist.** No `backup-homeserver` directory and no
  repo markers on any mount, on any box. G:/H: were repurposed into
  `immich-mirror` / `spare320` / `immich-2024` during the migration — the
  migration consumed the backup drives. Whatever gets built starts from zero;
  there is no history to recover.
- `restic-server` (the REST target on `server:8001`, which `desktop-wsl` pushed
  to) has been `Exited (0)` for 3 days. `latitude` has the restic binary but no
  repo, timer, or container; `hub` has no restic at all.

### Done 2026-08-01

- [x] **Disabled the three dead tasks on `server`.** All three now `Disabled`.
  Note `Disable-ScheduledTask -TaskName x` without `-TaskPath` silently no-ops —
  resticprofile registers under `\resticprofile backup\`.
- [x] **`/mnt/immich-2024/admin` has a second copy.** 662.9 GiB to `/mnt/xs`,
  clean on the first attempt in 2h10m at 97 MB/s with **zero** bus resets on a
  dock that had logged 24 the previous day. Verified byte-exact (20456 files,
  711832525257 bytes both sides), plus a 25-file md5 sample, plus the property
  that actually decides the monthly re-run: a second pass transfers **0 files,
  0 bytes**, so `--modify-window=1` copes with exfat's timestamp granularity.
  Script `hosts/latitude/debian/archive-mirror.sh`.
- [x] **Both mirrors are on timers** (`install-timers.sh`): library daily 03:35,
  archive monthly. System scope, one shared `flock`, `Nice`/`IOSchedulingPriority`
  to stay gentle on the bridge, `ConditionPathIsMountPoint` so an unplugged dock
  skips instead of failing.
- [x] **restic covers the small irreplaceable set** — repo `14f4eab544` on
  spare320, 6.5 GiB → 2.3 G, backup 04:30 daily and `check --read-data-subset 5%`
  Sundays. Restore verified byte-identical **and** `gzip -t` valid, so the dump is
  a usable archive rather than merely matching bytes.
- [x] **latitude is the `backup-hub`.** `restic-server` up, bound to
  `100.64.0.8:8001` rather than `0.0.0.0` — it runs `--no-auth`, so publishing on
  all interfaces had been exposing the fleet's backups to every device on the home
  wifi. Verified: tailnet answers, LAN address refused.
- [x] **`desktop-wsl` backs up again** — repo `8ca511f48c` via the hub, snapshot
  `c2c05a9f`, 8.1 GiB, user timer daily 06:00. It had **no** timer at all; the
  config pointed at the dead `server.gg.ez:8001`.
- [x] **Fixed a bug the timers exposed.** `mirror-refresh.sh -go` had *always*
  exited 1 — its last command was `[ -n "$DRY" ] && echo …`, false under `-go`.
  Invisible by hand; under a timer it meant every successful nightly run reported
  `Failed`, which is worse than silence because it teaches you to ignore the
  alert. rsync's status was not checked either. Both fixed; found by **starting
  the unit** rather than trusting a hand-run.

### Deferred (see the decision box at the top of P0)

- [~] **Nothing alerts.** Deferred by decision, not left open. The design is
  recorded in the box above so picking it up does not start from zero.
- [ ] **The full versioned backup of all 815 G, and offsite rotation** — needs
  hardware. No drive in the fleet has 815 G free, which is why the libraries get
  mirrors rather than restic repos. The consequence to be honest about: a
  corruption that rsyncs over the mirror is unrecoverable, because the libraries
  have a second copy but **no history**. Everything also still lands in one
  apartment on drives attached to one laptop; the dock drives are removable, so
  rotation needs no new infrastructure, but capacity does.
- [ ] **`/mnt/xs` is at 95%** (36 G free). Fine for a closed set, but it means
  the archive drive has no room for anything else — do not plan to share it.

- [ ] **Decide what the mirror does with the deleted `Media/` tree.**
  `/mnt/immich-mirror` is 287G against `/mnt/immich`'s 249G; the difference is
  the `Media/` tree deleted from the source on 2026-08-01, plus `staging/` and
  `var-backups/`. `--delete` is **off by design** (see the script header), so
  the mirror will never drop it on its own. Prune deliberately or accept it as a
  last-resort copy — but write down which.

---

## P1 — ✅ DONE 2026-08-01. The flake is deleted.

Tag **`nixos-final`** (annotated, pushed) preserves it. Commit `f3d63b2`.
`docs/2026-08-01-nixos-harvest.md` is the review, written before the delete —
read that before restoring anything from the tag.

- [x] **Reviewed module by module** against `tiers.sh` and against latitude's live
  Debian install. The result that justifies the delete: in both places where a Nix
  module and Debian disagreed, **Debian was right**. `laptop.nix` set
  `HandleLidSwitch = "suspend"`, which on the box latitude has become would drop
  immich, servarr, the REST hub and every backup timer on a lid close; latitude has
  lid+idle `ignore` *and* all three sleep targets masked. And the battery module
  wrote `charge_control_end_threshold` without the Dell EC's Custom charge mode, so
  it displayed an 85% ceiling while charging past it — `tier_battery_limit` writes
  the mode and adds a floor.
- [x] **Two live inputs rescued, not deleted.** `pkgs/gortex.nix` was grepped by
  `tier_gortex` on every box for the version to install — a Nix file as a POSIX
  provisioning input. Now `provision/gortex.version`, and `update-gortex.sh` no
  longer needs `nix store prefetch-file` for a hash nothing verified (it had been
  unrunnable fleet-wide while the pin it maintained was still being read).
- [x] **A real bug fixed.** `touches_nix` was the only gate treating `fleet.json`
  as a reprovision trigger, so it fired on one box while NixOS existed and on
  **none** afterwards: adding a fleet member wrote ok, advanced `converged-rev`,
  and never reached any box's `~/.ssh/config`. Now in `_touches_driver`, asserted
  on both tiers.
- [x] **28 of 33 justfile recipes pruned**, and `scripts/quick-check.sh` with them
  — `just quick` *hard-exited 1* without a flake.nix, so the documented gate did
  not degrade, it failed.
- [x] **`rustdesk-config.nix`'s peer identity map preserved** in the harvest — the
  only module holding data not derivable from anything else (RustDesk IDs are
  assigned, not chosen). The relay key is left in the tag, not copied.
- [x] AGENTS.md, README.md and `.claude/memory/project.md` rewritten. AGENTS.md's
  Hardware Context had been describing the NixOS install's LUKS root, ZRAM swap
  and S3 sleep — none of which survived the reinstall.

Still open, small: `agents/bootstrap.sh` keeps an inert `[ -e /etc/NIXOS ]` skip,
and `converge.sh` still *detects* a `nixos` class on purpose (folding it into
`linux` would run the apt driver on a Nix box and abort). Both are fail-safe if
Nix ever returns. Leave them.

## P2 — ✅ DONE 2026-08-01. `server` (g513ie) is out of the fleet.

**The hardware is NOT retired** — see the Forgejo item below before wiping it.

- [x] **Move the `backup-hub` role to `latitude`.** Done 2026-08-01 with P0 —
  `fleet.json` declares it on `latitude` and nowhere else.
- [x] **Caddy repointed — and it was SEVEN routes, not six.** `git.cyphy.kz`
  (3000) was missing from the list this file used to carry, which is the same
  undercount P1's header warns about. `speed` (2282), `tug` (9412), `seerr` (5055)
  and `jfin` (8096) now point at `100.64.0.8`, each verified answering **from
  hub** rather than from a dev box — hub reaches latitude over DERP, so an
  air-side probe proves nothing about what the proxy can see. All four went
  502 → live. `jfin`, `seerr` and `tug` were each confirmed as deliberate public
  exposure rather than swept along; `tug` can stop or update every container on
  latitude, though it does enforce auth (`/api/hosts/list` → 401 unauthenticated,
  checked before republishing). vps commits `954a8cc` + `7009448`.
- [x] **Two routes retired instead of repointed**, because a repoint to a port
  nothing listens on trades a 502 for a 502 (both verified refused from hub):
  navidrome (parked — its library was `Airdrome`, being rebuilt by hand) and
  Forgejo. Also corrected the `qb` block's note, which told the reader to reach
  qBittorrent at the dead `100.64.0.3:8084`.
- [x] **`server` removed from `fleet.json`; `methe@server` dropped from
  `provision/fleet-authorized-keys`.** The dropped key is server's OUTBOUND trust
  into latitude and hub, not anything's route in, and the file's own warning
  applies: the revocation lands when latitude and hub next provision, not now.
  **Access path: `ssh methe@server.gg.ez`** — bare `server.gg.ez` works only until
  `tier_fleet_ssh` next rewrites air's config and drops the member block, after
  which the FQDN hits the `Host *.gg.ez` catch-all's `User me` and is refused.
- [x] **`hosts/server/` deleted** — a `winget-packages.json` for a box leaving
  service, and a README whose only unique facts are recorded here. Git history
  holds both.
- [x] **Fixed a live defect the removal surfaced.** `--machine <not-a-member>`
  printed `platform: null`, emitted a raw `jq: error … Cannot iterate over null`,
  listed no roles and **exited 0** — provisioned nothing, reported success. The jq
  failure sat inside a process substitution, so `set -e` never fired. New
  `fleet_has_machine` guard exits 2 and lists the known members. Never specific to
  `server`; any typo did it.
- [x] **Two tests were hardcoding fleet membership** and broke on the removal
  while the code was correct: `fleet-ssh-tier.test.sh` named the five members in a
  loop and asserted `-ge 6` IdentityFile lines (both now derived from the
  manifest), and `statusboard.test.sh` fed the REAL manifest into the
  `sb_fleet_join` assertions (now a synthetic fixture — `sb_fleet_parse` above it
  is what legitimately pins the shipped file). Suite is back to the 3 pre-existing
  failures, no new ones.

### Forgejo: ✅ wiped 2026-08-01, not rehomed

- [x] **Wiped, on the owner's call — it was never used.** The volume agreed before
  anything was deleted: **zero repositories**, a 2.3M bare-install `gitea.db`, and
  nothing written since the 2026-05-03 install date. Removed the container and
  **both** volumes (`forgejo_forgejo_data`, 3.7M, the one the container actually
  mounted — compose prefixes the project name; and `forgejo_data`, an 8K stub
  Docker created on 2026-07-27 that nothing ever used), verified absent by name.
  Also deleted `homeserver/forgejo/` and both Caddy blocks in the vps repo
  (`8b0c91d`) — deleted, not re-commented, since there is nothing to restore to.
  It had been `Exited(137)` since ~2026-07-18, and `git.cyphy.kz` never had a DNS
  record, so its web half was unreachable for its entire life.
- **This had already been decided, and this file did not know it.** Both
  `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
  ("the container is stopped and `forgejo_data` is 4.0 K with no
  `git/repositories` — it hosts nothing. Delete it; do not export it") and
  `docs/superpowers/specs/2026-07-30-g513ie-to-latitude-migration.md`
  ("dropped by user decision") had established it days earlier, with the same
  measurement this wipe re-took. Treating it as an open blocker was a regression
  against the repo's own records — and a direct consequence of P5: 45 plans with
  nothing marked done, so nobody reads them for current state. Cheap here; the
  same gap on a destructive step would not be.
- [x] **All three flagged volumes checked 2026-08-01 — none is a unique copy, and
  server's Docker state now holds nothing that matters.** The repo's own spec had
  already answered both, and both were re-verified live rather than taken on trust:
  - **`telegrind_pgdata` is a duplicate.** `§19.3` of the migration spec records it
    exported as a raw tar (safe because `telegrind-postgres-1` had `Exited (0)`, a
    clean shutdown, so the data dir is self-consistent) with **sha256 identical on
    all three hosts** and restored onto latitude. Verified: latitude's volume holds
    987 files / 54.8 M, `PG_VERSION` 15, with `base/` and `pg_wal/` present — a real
    cluster matching the spec's count, not an empty shell.
  - **The two 7 GB anonymous volumes are Python virtualenvs**, and so are the two
    smaller ones (43 M, 37 M) that were also unidentified. All four carry a
    **`CACHEDIR.TAG`** plus `pyvenv.cfg` — tooling declaring its own directory
    disposable — and are `uv sync`-reproducible, four-fifths CUDA and torch wheels.
  - Every named volume that mattered is confirmed on latitude:
    `telegrind_pgdata`, `embedthat_redis_data`, `tugtainer_tugtainer_data` (plus
    `immich_pgdata` and the regenerable `immich_model-cache`). The
    `jellyseerr-data` pair were both stale even on server — jellyseerr's config was
    a **bind mount**, not a volume, which is the finding that reframed the whole
    migration.
- [~] **What is actually left to decide is `C:`, not Docker — AND THE OWNER IS
  DOING IT.** Stated 2026-08-01: *"i will check g15 myself for needed files."* Do
  not start a filesystem audit of that box; wait for the outcome. `server` now has
  **only `C:` attached** — 953 GB with 523.5 GB free, so **~430 GB in use**. Every
  external drive (D:/E:/G:/H:) already physically moved to latitude, which is also
  why the bind-mounted arr configs are gone from the box rather than pending. Docker
  accounts for roughly 20 GB of that 430 GB, so the remaining ~410 GB is the user
  profile, checkouts and downloads and has **not** been reviewed. That is the
  question to answer before wiping or returning the machine — and it is a
  filesystem review, not a volume audit.

- [ ] The `server` **profile** name survives the `server` **machine** — latitude
  uses `profile: server`, and `provision/tests/tiers.test.sh` exercises it as
  `plan server`. Not a bug, but the two now mean different things; do not "clean
  up" the profile thinking it is the retired box.

---

## P3 — latitude's SSH story has no generator.

- [ ] **`tier_fleet_ssh` is darwin-only.** With `modules/home/ssh.nix` dead,
  nothing generates latitude's outbound `~/.ssh/config`. It is unmanaged and
  drifting. The failure mode is silent rather than loud: latitude has **no
  GitHub account block at all**, so a `cyphy671` repo cloned there would fall
  back to default identity resolution and quietly offer the wrong key.
- [ ] **The `ssh-server` role executor is still an unimplemented stub** — it
  prints "not yet implemented (skipped)", as do `base` and `backup-client`.
  (`provision/roles/` holds only `agents`, `dotfiles`, `repos`.) The capability
  exists three separate hand-rolled ways — the now-dead NixOS module,
  `windows.ps1` step 6, and `tier_ssh_trust` for POSIX tier boxes — which is why
  AGENTS.md reads as though the role is done. It is not, and with the NixOS
  module gone latitude's sshd has no generator either. Windows gotchas for
  whoever implements it are in project memory.

---

## P4 — ✅ DONE 2026-08-01. `just test` is green: 28 suites, 0 failures.

First time the repo has had a working gate since the Nix one was deleted. The three
"pre-existing failures" turned out to be two different things, and telling them
apart mattered:

- [x] **`provision-wsl.test.sh` was reporting a REAL BUG in shipped code**, not
  rotting. Three scripts had an unbraced expansion against a multibyte character
  (`"$var…"`), which bash 5.x in a UTF-8 locale resolves as a variable named
  `var…` — fatal under `set -u`, fine under `LC_ALL=C`, invisible to `bash -n`.
  **`provision/provision.sh` carried it one line after the `Apply <role>? [y/N]`
  prompt, so `just provision --apply` aborted after taking consent and before
  running any role.** Fixed + guarded by
  `provision/tests/expansion-multibyte.test.sh`.
- [x] **The two `orca-profile-*` suites were genuinely test-only — and both failed
  for macOS-vs-Linux reasons, which is why they were red on `air` specifically.**
  The code was correct in all four cases; the dedup behaviour they check works.
  - 3 assertions in `orca-profile-harvest.test.sh` compared a count as a **string**:
    BSD `wc -l` pads to `"       1"`, so `= 1` fails on macOS and passes on Linux.
    Now `-eq`. (`grep -c` does not pad on either, which is exactly why only the
    `wc -l` sites broke — 15 other `grep -c` count assertions in this repo were
    always fine.)
  - 1 assertion in `orca-profile-link.test.sh` compared a **path spelling**. On
    macOS `/var` is a symlink to `/private/var`, so `mktemp -d` yields
    `/var/folders/…` while `orca-profile-sync.sh` prints the resolved
    `/private/var/folders/…`. It counted 0 matches and read as "synced twice".
    Fixed with a resolved `$profiles_real` for output comparisons, keeping the
    unresolved `$profiles` for the assertions that check a **stored symlink
    target** — the script keeps the spelling it was given, so both forms are
    needed and the file now says so.
  - Both repairs were **mutation-tested** (expect 2 instead of 1 → both fail) to
    prove the assertions still bite rather than having been loosened into
    vacuous truth.

**Keep it green.** The value showed up within the hour: when this session's earlier
change broke two suites, a green baseline made that obvious instead of something to
be diffed against a remembered failure count.

## P5 — Documentation drift.

- [x] **`AGENTS.md`** rewritten with P1 — the Nix-first Common Commands, the stale
  migration banner and a Hardware Context block claiming LUKS/ZRAM/S3-sleep are all
  gone. README.md too.
- [x] **`.claude/memory/project.md`** — the entries that stated *current* facts
  wrongly are fixed. Bullets explicitly marked HISTORY were left alone on purpose;
  they are records, not claims.
- [ ] **45 plans under `docs/superpowers/plans/`, none marked done.** Their
  checkboxes are unchecked even where fully executed, so the directory cannot be
  read as a backlog — worth a status line at the top of each, or at least of the
  two migration plans that are effectively complete.
- [ ] **The drift has a measured cost**: on 2026-08-01 four answers already written
  down in `docs/superpowers/` or in project memory were re-derived from scratch, two
  of them wrongly first — including one where the record was in **`vps`**, not here.
  Hence the rule now in `.claude/memory/project.md`: before correcting a recorded
  claim, check the sibling repo's memory too. The `machines`/`vps` boundary is
  exactly where a fact gets hunted in the wrong place.

---

## P6 — Housekeeping.

- [ ] **hub's `me@desktop-wsl-ubuntu-26-04` key** (`…DXi623`) is live —
  desktop-wsl's `id_ed25519` — and redundant only because desktop-wsl's ssh
  config pins `id_fleet`. Removing it is a real revocation, not a cleanup.
  Needs a deliberate decision.
- [ ] **latitude's migration debris**: 21M `~/immich-migration/` plus six
  `*.log` (`overnight.log` alone is 3.2M).
- [ ] **Rotate three leaked credentials. Do this before starting either bot, and
  note it is not what stops them starting** (the item after next is).
  `docker inspect --format
  '{{.Config.Env}}'` on the telegrind container printed `BOT_TOKEN`,
  `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` and `POSTGRES_PASSWORD` into a session
  transcript on `air` — `~/.claude/projects/…/*.jsonl`, plaintext, still on
  disk. Use `{{.Config.Image}}` alone in future. Each value is one line of
  `latitude:~/my/vps/homeserver/telegrind/.env.prod` (0600), so replacing it is
  a one-line edit once the new value exists. All three need a browser:
  - `ANTHROPIC_API_KEY` — console.anthropic.com: revoke, create, replace.
  - `BOT_TOKEN` — BotFather `/revoke` on the telegrind bot, then `/token`.
  - `GOOGLE_API_KEY` — aistudio.google.com/apikey: delete, create.

  **`POSTGRES_PASSWORD` is deliberately excluded.** It never leaves latitude's
  docker network, and it is baked into the existing `telegrind_pgdata` cluster —
  so rotating it means an `ALTER ROLE` inside a container that is currently down,
  plus a coupled edit to the `DATABASE_URL` two lines above it in the same file.
  Real risk of leaving the DB unopenable, no exposure reduced.

  **Still open and still needed, measured rather than assumed (2026-08-01).** Each
  live value in `.env.prod` was tested for a byte-identical match anywhere under
  `~/.claude/projects/` on air. All four telegrind values match, so nothing has
  been rotated yet and the file is still the leaked file. **embedthat's `BOT_TOKEN`
  is clean** — it appears in no transcript, so it needs no rotation; an earlier
  draft of this item said rotate it anyway on cost asymmetry, which the test made
  unnecessary. Re-run that comparison before rotating, in case you got there first.

  **Size the exposure honestly, because it changes the urgency.** The values are in
  exactly one file — this session's own transcript on air — and
  `~/.claude/projects/` is path-keyed, machine-local and deliberately untracked, so
  they are not in git, not on a shared host, and not on another box. What did leave
  the machine is the API round-trip: they were sent to Anthropic as prompt context.
  So this is not "a third party is holding your bot token", but it is not nothing
  either, and the plaintext file is a standing local copy until rotation makes it
  inert. Rotation is the fix; deleting the transcript is not, since it does not
  reach anything already transmitted.
- [ ] **Hermes' credentials — a different job, not this one.** They were deleted
  from disk on 2026-08-01 *without* being revoked at source, so unlike the three
  above there is no local copy to replace: it is revoke-blind-at-the-console and
  nothing to edit afterwards. Inventory in project memory.
- [ ] **Port the poll-deploy engine to Linux — the *other* half of the telegrind
  and embedthat blockage.** The rotation above is a real gate, but only on the
  security side: it says do not *start* the bots yet. It is not what stops them
  starting. Four separate things do, verified 2026-08-01, and `vps`'s own
  `.claude/memory/project.md` had already recorded the shape of this:
  - The engine is **PowerShell on a Windows Scheduled Task** — `vps`'s
    `homeserver/deploy-repos.ps1`, `register-repos-deploy.ps1`, `repos.psd1`, task
    `repos-deploy` every 3 minutes. None of it runs on Debian. latitude has no
    equivalent, so nothing polls, builds or recreates either stack.
  - **The engine could not do the first start anyway**, on any platform: it acts
    only when the gated service (`Service = 'bot'`) is *already running*. A fresh
    bring-up is manual once, then the engine keeps it current.
  - **Neither `src/` clone exists on latitude.** `homeserver/*/src/` is the
    gitignored build-context clone the engine manages, and both `compose.prod.yml`
    files use `build: context: ./src`. No src, no image.
  - **telegrind also needs its GCP service-account key placed.** `.env.prod` says
    `GOOGLE_SERVICE_ACCOUNT_FILE=local/google-account.json` and the compose mounts
    `./src:/app/local`, so the file belongs at
    `homeserver/telegrind/src/google-account.json`. It **is** preserved —
    `latitude:~/g513ie-prod-config/telegrind/google-account.json`, 0600 — and it
    embeds an RSA private key, so place it, never commit it.
  - Both named volumes already survived the migration onto latitude:
    `telegrind_pgdata`, `embedthat_redis_data`. Data is not the gap. Note
    telegrind crash-loops on a *freshly recreated* pgdata (alembic has no version
    seed) — a bring-up must reuse this volume, never `down -v`.

  Order: rotate → clone both `src/` → place the GCP key → start each stack by
  hand once → then decide whether to port the loop to a systemd timer. Porting is
  a separate decision; the bots run fine without it, they just never self-update.
- [ ] **Headscale ACLs.** The tailnet is default-open. Relatives never join it,
  but least privilege across our own boxes is cheap now and annoying later.
- [ ] **Drop `desktop`'s AWG.** It runs AmneziaWG beside Tailscale and its
  services already work over the tailnet. Remove once nothing depends on
  `10.0.0.6`, then drop the peer on hub.
- [ ] Enumerate `xs-keepers/home`'s ~20 config dirs; unbundle
  `qaz-code-feature-sync-dashboard.bundle`; decide
  `windows-reinstall-runbook.md`'s fate; confirm immich still has "Hardware
  decoding" ticked.

---

## Done

**2026-08-01 — latitude-server migration.** latitude reinstalled as Debian 13
and took over the services role: immich, servarr, speedtest, tugtainer live and
healthy. `/mnt/immich/Media` deleted after a four-way guard (526 GiB reclaimed,
nvme0 86% → 28%); 30G reclaimed on spare320. Fleet SSH made **authoritative** —
`provision/fleet-authorized-keys` is now rewritten as a managed span rather than
appended to, so deletions actually revoke and renames actually propagate; keys
renamed to logical fleet names on all five boxes; hub's dead `methe@lat5520`
pruned. Two recurring latitude scripts tracked under `hosts/latitude/debian/`;
16 one-off migration scripts deleted after harvesting their measurement rules
into `docs/2026-07-drive-migration-log.md`.

**2026-07-17 — AWG mesh retired from the repo.** SSH re-homed onto the tailnet.
Deleted `mesh-vpn.nix`, mesh params, `fleet.json` mesh blocks, and the
provisioner mesh roles/libs. Kept the AmneziaVPN client and the VPS AWG server.

**2026-07-14 — fleet-wide SSH over tailnet + name resolution.** `fleet.json`
gained `tailnet.ip`; the whole SSH story moved onto `100.64.0.x`.

**2026-07-13 — Headscale rollout.** 0.29.2 + embedded DERP on the VPS; every
node cut over; reusable pre-auth keys revoked afterwards.
