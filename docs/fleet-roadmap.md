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
| `server` | `100.64.0.3` | Windows 11 (`g513ie`) | **draining** — services moved to latitude, containers stopped, retirement pending |
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

## P2 — Finish the `server` (g513ie) decommission.

Coupled to P0: `backup-hub` is declared on `server` in `fleet.json` and exists
nowhere else, so backups cannot be fixed without deciding where it goes, and the
decommission cannot finish without the same decision. Do them together.

- [x] **Move the `backup-hub` role to `latitude`.** Done 2026-08-01 with P0 —
  `fleet.json` declares it on `latitude` and nowhere else.
- [ ] Repoint the six Caddy routes still aimed at the dead `100.64.0.3`:
  `speed` (2282), `tug` (9412), `jfin` (8096), `seerr` (5055), navidrome (4533),
  and the layer4 `:2222`. **`jfin` republishes Jellyfin publicly — needs an
  explicit go, not a silent repoint.**
- [ ] Remove `server` from `fleet.json` and drop `methe@server` from
  `provision/fleet-authorized-keys`. Not before the two above: it is still
  reachable and still holds the only copies of things.
- [ ] Archive or delete `hosts/server/windows/`.

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

## P4 — Green the test suite. It is the only gate, and `just test` runs it.

- [ ] **Three failures, all pre-existing** — they reproduce at HEAD in a clean
  worktree and are *not* fallout from the fleet-ssh work:
  `provision/tests/provision-wsl.test.sh`,
  `agents/tests/orca-profile-harvest.test.sh`,
  `agents/tests/orca-profile-link.test.sh`.
  With the Nix gate gone the bash suite is all the validation the repo has, and
  a red suite gives no signal at all. Run it with `just test`.
- [x] **`just test` now runs the suite** (landed with P1). It globs every
  `*.test.sh` — 27 suites, up from the 4 globs documented here — so a new suite is
  picked up without editing the recipe. `just test` previously meant
  `nixos-rebuild test`, one typo away from the suite; that footgun is gone.

---

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

---

## P6 — Housekeeping.

- [ ] **hub's `me@desktop-wsl-ubuntu-26-04` key** (`…DXi623`) is live —
  desktop-wsl's `id_ed25519` — and redundant only because desktop-wsl's ssh
  config pins `id_fleet`. Removing it is a real revocation, not a cleanup.
  Needs a deliberate decision.
- [ ] **latitude's migration debris**: 21M `~/immich-migration/` plus six
  `*.log` (`overnight.log` alone is 3.2M).
- [ ] **Rotate the leaked Anthropic API key and Telegram bot token.** Blocks
  bringing telegrind and embedthat back up. Hermes credentials were never
  revoked at source either.
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
