# Fleet Roadmap

Living backlog for the machine fleet. Curated — tick/prune as items land. A new
session inherits the fleet state from `.claude/memory/project.md`; this file is
the "where to head next" companion. For any item worth real work, run
`superpowers:brainstorming` → `writing-plans` and drop the plan under
`docs/superpowers/plans/`.

_Last updated: 2026-09-07 — g15's Windows install was replaced by Ubuntu 26.04
and `g15-wsl` ceased to exist; "Where we are now" was carrying four claims the
rest of the repo had already corrected. Previously 2026-08-27 — `server`
returned to the fleet (P2 reversed) and was renamed `g15` the same day.
Previously 2026-08-01, rewritten after the latitude-server migration. The
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
| `g15` | `100.64.0.10` | **Ubuntu 26.04 resolute** (`g513ie`) | the personal-projects host. **Windows was wiped 2026-09-07** and with it the `g15-wsl` distro — one host replaces two. Reach it as `me@g15.gg.ez` (no `ssh` block in the manifest; `ssh.user` defaults to `me`). Its old tailnet node `100.64.0.3` is retired. **In restic since 2026-09-08** (`~/my` + `~/Music`); its 184 GB database is not, see the item at the end of P6 |
| `desktop` | `100.64.0.4` | Windows 11 (`g614jv`) | tailnet + sshd |
| `air` | `100.64.0.7` | macOS | **primary dev box** |
| `latitude` | `100.64.0.8` | **Debian 13 trixie** | **services host** — immich + servarr + speedtest + tugtainer |

`desktop-wsl` (`100.64.0.6`) is the one remaining self-declared WSL host: no
`fleet.json` entry, a gitignored `fleet.local.json` instead. It is
**`dispatch:parent`** since 2026-08-31 — reached as `wsl.exe -d desktop-wsl`
through `desktop`, because in `networkingMode=mirrored` its sshd lost port 22 to
the Windows OpenSSH server and answers on 2222 instead. Its own tailnet node is
still registered and no longer load-bearing. `g15-wsl` (`100.64.0.9`) is gone
with the Windows install it lived on.

**One LAN, not two.** Every member except `hub` sits behind the same router and
gets direct P2P — measured 2026-09-07 from `desktop-wsl`: latitude 2 ms, g15
3 ms, hub 6 ms via its public IP, 99 MB/s to latitude. This section said "two
separate LANs … cross-LAN pairs relay through our own DERP — expected and
accepted" until 2026-09-07, and that sentence is why a migration design first
wrote latitude off as a 7-hour staging target when it is the fastest box in the
fleet. **UPnP/router port-mapping is still not on this backlog** — now because
nothing relays, rather than because relaying was accepted. The one genuine DERP
pair was `g15-wsl`, which no longer exists.

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
  **And as of 2026-09-07 it is not mounted at all** — `sda3` is present, `/mnt/xs`
  is an empty dir, so the byte-verified second copy of the 663 G archive is
  offline. Same shape as the 2026-08-23 USB drop; remount and re-verify before
  counting it as a copy.

- [ ] **8 TB drive for `/mnt/servarr` — ORDERED 2026-09-07: WD Blue `WD80EAAZ`,
  188 090 ₸ at dns-shop.kz.** The criteria are written down here because the
  original plan (2026-08-16) lived only in a transcript and had to be recovered
  by grepping `~/.claude/projects`.

  **The first attempt was not a defective drive — it was a SUBSTITUTED one, and
  it is fully recorded** (confirmed 2026-09-08; this item said "how it failed was
  never recorded" until then, and that sentence is why the acceptance test was
  designed generic). 2026-07-30, sold as a new 6 TB WD Purple `WD63PURZ`, what
  arrived was a 2015 HGST Ultrastar `HUS726060ALE611` — 74 502 power-on hours,
  3.02 PB written — wearing a WD Purple sticker:
  `docs/superpowers/specs/2026-07-30-6tb-return-claim-ru.md` plus the raw SMART
  bundle beside it. **A surface test would have passed that drive.** So the
  acceptance test is now TWO gates on two different clocks — identity (~5 min,
  decides keep-or-return, runs on the shop's return window) before surface
  (~41 h, decides whether it may hold data, runs on the warranty) — scripted in
  `hosts/latitude/debian/disk-acceptance.sh`, unit-tested in
  `provision/tests/disk-acceptance.test.sh`, runbook in
  `docs/2026-09-08-8tb-acceptance-plan.md`.

  **Internal 3.5″ CMR, not a consumer external** — no shucking, warranty in your
  own name at an official store, and SMART reaching the host instead of being
  masked by a USB bridge (a defect has to be *provable* next time). CMR is the
  one non-negotiable spec: SMR handles a seeding library's rewrite pattern badly.
  `WD80EAAZ` is CMR, 5640 rpm, 256 MB — verified against vendor/reviewer
  documentation, not from recall. **Never trust a model list written from
  memory; check the exact part number off the box against the vendor's own
  CMR/SMR table before paying.**

  **The NAS-class premium was declined deliberately.** Same page carried
  IronWolf `ST8000VN004` (253 990 ₸ on shop.kz, 180 TB/yr, 3 y + Rescue, 7200 rpm)
  and the same `WD80EAAZ` at 249 600 ₸ — DNS was 61 500 ₸ cheaper for the
  identical part number, and 66 000 ₸ under the IronWolf. The reason it is the
  right call rather than a saving: this drive holds **ServarrMedia, the one
  dataset in the fleet this file marks "deliberately unprotected — replaceable
  torrent data"**. What is bought instead is 2 years of warranty and no workload
  rating, which is a real downgrade against wear but not against the failure
  actually experienced — infant mortality shows up in weeks and the acceptance
  test catches it. **If the 8 TB ever ends up holding something irreplaceable,
  this trade is void and it wants a NAS-class drive.** By the allocation below,
  the irreplaceable copies live on the freed HGST and on nvme, not here.

  **No enclosure purchase is needed for the new drive** — the two Ugreen CM198
  docks are already in place and one bay is being vacated (below). The standalone
  SATA-USB enclosure is for the *displaced* `spare320`, not for the 8 TB.

  **The "self-powered" argument does not survive measurement — buy for capacity,
  not for reliability.** Measured on latitude 2026-09-07: both docks are **Ugreen
  CM198** dual-bay units on JMicron **JMS561U** bridges (`152d:1561`), each with
  its own 12 V brick, and they sit on **ports 1 and 2 of the same xhci root hub**
  (`usb4`, 5 Gbps). So nothing on latitude is bus-powered, and the August reading
  of the 04:08/10:28 double drop — "shared bus power against four spinning
  drives" — is not supported by the topology. The element the two docks actually
  share is the host controller, which a new drive with its own PSU also shares.
  Whatever caused that drop is still undiagnosed; the reason to buy is headroom.

  **SMART passes through these docks** — `smartctl -i -d sat` returns model,
  rotation rate and `SMART support is: Enabled` on all four drives, so the
  acceptance test below is executable through a CM198 without extra hardware.
  Both docks run the `usb-storage` (BOT) driver, not `uas`, while the XS2000 on
  another bus does negotiate `uas`; assume BOT for anything plugged into them.

  **Bay allocation — the 8 TB takes `spare320`'s bay, and `spare320` leaves the
  docks.** All four bays are full: dock B (`670200210032`, `usb 4-1`, the flaky
  one) = {`sdc` spare320 bay 1, `sdb` servarr bay 2}; dock A (`6702002103E1`,
  `usb 4-2`) = {`sdd` library mirror bay 1, `sde` immich-2024 archive primary
  bay 2}. Both dock A bays hold drives that have to stay, so the only bay that
  can be freed is `spare320`'s. Move it (ST320LT020, 36 202 power-on hours) to a
  standalone SATA-USB enclosure, keeping it mounted at `/mnt/spare320` by UUID
  `3a78fd88-deb0-4c1a-a576-14abd0631d57` — restic repo `14f4eab544` lives on it
  and resticprofile addresses it by path — and check SMART pass-through on that
  enclosure the same way as on the docks.

  End state: dock B = {8 TB servarr, freed 931 G HGST as archive mirror},
  dock A = {library mirror, archive primary}, standalone = spare320. That does
  satisfy the August plan's "the freed drive lands on a different dock from the
  archive source", and it matches the standing rule in `project.md` — archive
  primary on dock A, its copy on flakier dock B, long writes into dock B with
  `--partial`. The cost to accept knowingly: the seeding library and the archive
  copy then share the flakiest dock. Both are replaceable-or-a-copy, which is why
  that is the acceptable side to load.

  **8 TB, not 16.** ~6.4 TB headroom after the move — ~14 months even at the
  2026-08-05 burst rate, years at the quiet rate; 16 TB is real money against
  growth nobody can measure. Sizing input the August plan didn't have: this
  purchase frees a 931 G spindle, and that spindle covers **either** the archive
  mirror **or** the deferred 815 G versioned backup above, not both.

  **Acceptance test — start it the day the drive arrives.** Runbook and the
  numeric FAIL gates: `docs/2026-09-08-8tb-acceptance-plan.md`. Return window is
  **14 days from 2026-09-07, i.e. 2026-09-21**, so the surface pass must START by
  **2026-09-18** to leave room for one restart after a bus fault. Two corrections
  to what this paragraph assumed: the round trip is **~41 h, not ~30 h** (the
  first hour runs the outer tracks and a CMR spindle falls to roughly half that
  rate at the inner ones, so extrapolating the first hour flat under-promises by
  half a day), and `badblocks` needs **`-b 4096`** — at the default 1024 B an
  8 TB drive is 7.8e9 blocks, past badblocks' own 2^32 ceiling, and it aborts.
  8 TB write+read is
  ~30 h round trip **if the path sustains ~150 MB/s — MEASURED 2026-09-08 at
  227 MB/s** on the WD80EAAZ's outer tracks, i.e. a 9.8 h write pass and ~27 h
  for write+read with the inner-track factor. That is the fleet's first
  throughput figure for a **3.5″** drive through a CM198, and it confirms this
  paragraph's own suspicion: the existing numbers were 2.5″ spindles hitting
  their own ceiling, not the bridge's. The sentence below is kept for the
  reasoning that led there:
  every existing throughput number on these docks (86 MB/s, 97 MB/s, 36 MB/s on
  the SMR drive) comes from 2.5″ 5400 rpm spindles hitting their own ceiling, not
  the bridge's. Measure the first hour of the write pass and extrapolate before
  promising anyone a finish time, and do not run it concurrently with the monthly
  archive copy — the two docks share a root hub. Either way a test begun late
  lands outside DNS's return window, which is the only window that matters here —
  the warranty behind it is 2 years, not 3. SMART baseline → full-surface write+read verify (`badblocks -w`,
  or `f3write`/`f3read`) → SMART after, checking Reallocated/Pending sectors and
  that `smartctl -d sat` returns attributes through the bridge at all. Nothing
  moves off the source until that passes, and the source stays intact until the
  copy is byte-verified. (`f3` is not installed on latitude; `badblocks` and
  `smartmontools` are, so the script uses those.)

  **The bay to borrow for the test is `/mnt/immich-mirror`'s (dock A bay 1), not
  `spare320`'s** — decided 2026-09-08. No container binds `/mnt/immich-mirror`
  (checked live against `.HostConfig.Binds`), it holds a copy rather than a sole
  copy, and `mirror-refresh.service`'s `ConditionPathIsMountPoint` makes the timer
  skip cleanly; evicting `spare320` instead would take the fleet's restic hub down
  for the whole 41 h, since `restic-server` binds `/mnt/spare320/restic-rest`.
  Testing in dock A also keeps the flaky dock out of the measurement.
  **Restoring that mount is a manual step** — the fstab entries are `nofail` and
  nothing re-pulls them when the device returns (2026-08-23, 20 h of silence).

  **The migration half of the August plan needs re-deriving at move time** — it
  names `sdf2` and a mounted `/mnt/xs`, and neither matches the current shape
  (servarr is `sdb2` at 72%, mirror is `sdd2` at 509 G used and now holds
  `g15-staging`). Two constraints from it that do still hold verbatim: mount the
  new drive at **exactly** `/mnt/servarr` (seven containers bind-mount
  `/mnt/servarr/ServarrMedia/{torrents,movies,tv,xxx}` and qbittorrent holds 39
  stored save paths — keep the path, swap the device, change no app config), and
  copy with **one single `rsync -aH` pass over all four dirs** (526 GiB actual
  vs 1.03 TB apparent; split it or drop `-H` and it will not even fit).

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

## P2 — ✅ DONE 2026-08-01, ↩ REVERSED 2026-08-27. `server` (g513ie) left the fleet, then came back as `g15`.

> **Reversed 2026-08-27 — the box is back in `fleet.json` as the
> personal-projects host.** Read this section as a record of what was *removed*,
> not of where the fleet stands: `hosts/server/` is still deleted, Forgejo is
> still wiped, the Caddy repoint still holds. What came back is the manifest
> entry, the `methe@server` trust line (the SAME key — the box was never
> reinstalled) and the `tier_fleet_ssh` member block, plus a new self-declared
> WSL host `g15-wsl` at `100.64.0.9`. The wipe this section kept gating never
> happened and is now off the table, so `C:` being unreviewed blocks nothing.
> **The box is `g15`, not `server`, since the same day** — `server` also names
> latitude's `linux.sh` profile, and one word for two things in one manifest is
> how the last revision of this file rotted.

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
  **Access path (SUPERSEDED 2026-08-27): `ssh methe@g15.gg.ez`.** The box was
  renamed to `g15` and put back into `fleet.json`, so the member block is
  restored and the bare `ssh g15` alias works again; `server.gg.ez` no longer
  resolves. **SUPERSEDED AGAIN 2026-09-07:** the username is `me`, not `methe` —
  the Windows install and its user are gone, and g15's manifest entry carries no
  `ssh` block at all.
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

- [x] **The `server` profile / `server` machine collision is gone** — resolved
  2026-08-27 by renaming the MACHINE to `g15`, not by touching the profile.
  `profile: server` on latitude and `plan server` in `provision/tests/tiers.test.sh`
  are now the only meaning of the word, which is what this item wanted. Renaming
  the profile instead would have churned every tier list for a name that is
  accurate.

---

## P3 — latitude's SSH story has no generator.

- [ ] **`tier_fleet_ssh` is darwin-only.** With `modules/home/ssh.nix` dead,
  nothing generates latitude's outbound `~/.ssh/config`. It is unmanaged and
  drifting. The failure mode is silent rather than loud: latitude has **no
  GitHub account block at all**, so a `cyphy671` repo cloned there would fall
  back to default identity resolution and quietly offer the wrong key.
- [ ] **The `ssh-server` role has no executor**, and neither does `base` —
  `provision/roles/` holds `agents`, `dotfiles`, `repos` and, since 2026-09-01,
  `backup-client` (`.sh` + `.ps1`) and `backup-hub`. (Corrected 2026-08-05: they
  were never "stubs that print a message"; there is no file for them at all.
  They fall through `provision.sh`'s fallback arm, which now names them in
  `PLANNED_ROLES` and fails `--apply` for any role NOT on that list — review
  item 6. Implementing one means deleting its name from that list, which is what
  the two backup roles did.) The capability
  exists three separate hand-rolled ways — the now-dead NixOS module,
  `windows.ps1` step 6, and `tier_ssh_trust` for POSIX tier boxes — which is why
  AGENTS.md reads as though the role is done. It is not, and with the NixOS
  module gone latitude's sshd has no generator either. Windows gotchas for
  whoever implements it are in project memory.
- [x] **`provision.ps1` had NO `PLANNED_ROLES` equivalent — closed 2026-09-02**,
  a day after it was found while adding `backup-client.ps1`. A role missing from
  its `$RoleExecutors` map fell through to a branch that printed "not yet
  implemented (skipped)" and left `$rc` at **0**: provisioned nothing, reported
  success, on both Windows members, for `base` and `ssh-server`.
  Now `-PlannedRoles`, defaulting to `base ssh-server`; an undeclared role with
  no map entry fails `-Apply`.
  **Two things did not port straight across, and both are the interesting part:**
  - The posix lever is `MACHINES_PLANNED_ROLES=""` — set but empty, meaning
    "declare nothing", which is how `fleet-profile.test.sh` forces the failing
    arm. On Windows `$env:X = ''` **removes** the variable, so that state does
    not exist and the negative arm would have been untestable. Hence a parameter:
    `-PlannedRoles @()`.
  - The posix side needs a padded-substring match (`*" $role "*`) so `ssh` cannot
    match the declaration of `ssh-server`. PowerShell's `-contains` is a
    whole-element match on the array, so the hazard does not arise. Do not port
    the padding; it would be cargo.
- [x] **The unknown-MACHINE gate, found while closing the one above and closed
  with it.** `provision.ps1` had no `fleet_has_machine` counterpart either, and
  its failure was worse than the role one: `Get-FleetPlatform` on a non-member
  returns `$null`, `Get-FleetRoles` returns `$null`, `foreach` over `$null`
  iterates **zero times**, so `-Machine typo` printed no roles and exited 0. The
  posix side has had that gate since 2026-08-01. `Test-FleetMachine` closes it,
  exit 2, message for message.
  Also fixed on the way: the pre-existing `Write-Error "no machine selected";
  exit 2` **could not return 2**. Under `$ErrorActionPreference = 'Stop'`,
  `Write-Error` throws and the process dies with exit 1 first. Any PowerShell
  guard in this repo must use plain stderr and then `exit`.
  Both arms pinned by `provision/tests/provision-ps-guards.test.sh` — exit codes,
  not messages — and mutation-tested by removing each guard in a worktree and
  confirming the suite goes red (`expected '2' got '0'`, `expected '1' got '0'`).

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
  **The mechanism in this item is WRONG — see the 2026-09-02 entry below.** The
  bash behaviour it describes does not reproduce on any fleet bash in any locale,
  and the historical "red" tree is green today. Left standing rather than rewritten
  because the item is a record of what was believed at the time; read the two
  together, and trust the measured one.
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

- [x] **Re-opened on latitude 2026-08-19, closed 2026-09-02 — and the answer was
  not "bash changed". It is that the mechanism was never real.** The failing
  assertion was `expansion-multibyte.test.sh`'s premise check:
  `unbraced expansion no longer fails under C.utf8 — bash changed; re-check this
  rule`. That item said "the bash version is the first thing to compare", so it
  was compared, and then some:

  | probe | result |
  |---|---|
  | `bash -c` and a real script file, `set -u`, `"$var…"` | exits 0, prints correctly |
  | bash 5.3.9 (desktop-wsl), 5.2.37 (latitude), 5.2.15 (hub) | same on all three |
  | `LC_ALL=C`, `C.utf8`, `en_US.utf8` | same in all three |
  | unbrace ONLY that line at HEAD, run `provision-wsl.test.sh` | **green** |
  | the whole `65aac22^` tree — the "red" state the brace fix greened | **green today** |

  So the explanation in the item above (and in `65aac22`'s message, and in
  `AGENTS.md`) — *"bash 5.x in a UTF-8 locale resolves `$var…` as a variable named
  `var…`"* — does not happen, on any bash in this fleet, in any locale. It is
  consistent with bash's identifier scan being ASCII-only in every build, which is
  why no locale could ever have changed it. **What the original red actually was is
  unidentified.** It is not this, and it is not "a bash that has since been fixed"
  either, because the historical tree passes now.

  Disposition, deliberately conservative: **the rule stays and the scan still fails
  the gate.** Bracing is correct regardless of why, it costs two characters, and an
  unexplained historical red argues for keeping a guard rather than dropping one.
  What changed is that the premise block now REPORTS (`NOTE`) instead of asserting —
  a `die` there made the gate red over bash declining to do something no bash does.
  The reasoning is written into the test file so the next reader does not re-derive
  it or, worse, restore a mechanism nobody measured.

- [x] **`fleet-ssh-config-ps.test.sh` was never an "environmental failure" —
  it was a missing flag.** Carried for a month as the second of two reds assumed to
  be the box's fault. The actual cause: it invoked `powershell.exe -NoProfile -File`
  with no `-ExecutionPolicy Bypass`, so the default policy refused the unsigned
  `.ps1` with a `SecurityError`/`UnauthorizedAccess` before the module ever loaded.
  One flag, and the module's 30-assertion self-test passes. Its candidate loop was
  also wrong on WSL — `pwsh powershell powershell.exe` always landed on Windows
  PowerShell **5.1**, because only the `.exe` spellings are on PATH there; `pwsh.exe`
  is now tried first and the self-test runs under PS **7.6.5**, which is what the
  Windows members actually have.

  **The lesson is the phrase, not the flag.** "Two known environmental failures" was
  repeated across many sessions as if it were a property of the machine. Neither was.
  A red whose cause has never been read is not a baseline — it is an unread bug
  report, and this is the second time P4 has had to say so.

**48 suites, 48 pass, 0 failures (2026-09-02).** No known-failing suite remains.

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

**Two one-line bugs found during g15 phase 4 (2026-09-07), both deliberately
left for their own change rather than fixed mid-migration:**

- [x] **`ts_mint_key`'s control-server default — FIXED 2026-09-08.** It defaulted
  to `ssh debian@cyphy.kz`, which resolves from nowhere in the fleet: the
  generated `~/.ssh/config` only has `Host hub hub.gg.ez` with
  `HostName cyphy.kz`, so the literal address matched no block, fell to the
  default identity with no `IdentityFile` and no `accept-new`, and failed with
  `Host key verification failed` (worked around during g15's migration with
  `HEADSCALE_SSH=hub`). The alias carries the User, the `id_fleet` identity and
  the host-key policy; the bare address carries none of them.

  The default now lives in **one** place, `ts_headscale_target()` — it was three
  (`ts_mint_key`, the progress line, the `--help` text), and a default
  duplicated across three sites is a default that drifts. Covered by three new
  cases in `provision/tailscale-wsl.test.sh`, mutation-tested against both
  regressions (reverting the value; re-inlining a second expansion).

  Worth keeping from writing that test: **it took three attempts because the
  assertion kept matching its own documentation.** A grep for `debian@cyphy.kz`
  hit the comment explaining why that address is wrong; a grep for
  `${HEADSCALE_SSH:-` hit the accessor it was protecting; a count over all lines
  hit the comment saying the accessor replaced three expansions. It asserts over
  non-comment lines now. An assertion about what runs must look only at what
  runs.
- [ ] **Delete latitude's `/etc/systemd/logind.conf.d/99-server.conf`.**
  `tier_lid_ignore` (2026-09-08) now writes lid policy on both posix profiles,
  closing the gap the 2026-08-03 review called the flagship —
  `docs/2026-08-03-repo-review.md:320`: that hand-written file was the only thing
  keeping the services host awake on a lid close, and nothing in the repo produced
  it. The two files coexist harmlessly (identical values; the tier's own warn names
  the survivor on every run), so this is tidying, not a fix — but do it AFTER
  latitude's next converge run has written `99-fleet-lid.conf`, not before, or the
  box spends the gap suspending on a lid close. `provision/lib/tiers.sh` is a
  `_touches_driver` trigger, so that run needs no prompting. The masked
  `sleep.target` / `suspend.target` / `hibernate.target` are NOT part of this and
  stay a host-local hand-edit — see the tier's comment for why that half is not
  portable.
- `fleet-selfpull` skips a dirty tree silently and forever — `air` was 43 commits
  behind for eight days across 87 skipped runs, evidenced only by a counter in
  `~/.local/state/fleet-selfpull/dirty-<path>`. It should escalate after N
  consecutive skips. This is a behaviour change to a timer on every box, so it
  wants its own change and its own suite.

**Also still missing, and bigger than a line each:** there is no
`tier_tailscale` (the transport the whole fleet depends on is hand-installed on
every Linux box), no tier installs `just` (the documented command surface —
`air` has it from brew, by luck rather than provisioning), and the `tier_*`
functions cannot be run outside a driver because `info`/`warn`/`ok`/`have` are
defined in `linux.sh` and `macos.sh` rather than a shared lib.

- [ ] **`SB_PARKS` in the status board is still keyed by sd node**, which
  2026-08-19 established is not an identity: `sb_series_keep` prunes a node that
  vanishes and does nothing when the letter survives onto a DIFFERENT disk, so
  after a replug a drive can carry the previous drive's park verdict. That verdict
  gates which spinner gets woken for smartctl, so getting it wrong costs load
  cycles on a drive already past 639k of them. NOT fixable the way the bay store
  was: `sb_drive_parks` is a smartctl fork, which is why it is cached at all — it
  needs a stable identity (serial, from `lsblk -no SERIAL` or sysfs) to invalidate
  against. `SB_TEMPS` has a milder version of the same: between round-robin visits
  a reused node shows the previous drive's temperature.

- [ ] **`provision/fleet-selfpull.ps1` has no dirty-streak escalation and no
  test coverage at all.** The bash side got both on 2026-08-03, after one
  untracked zero-byte `.zed/tasks.json` held desktop-wsl 28 commits behind for
  ~35 hours — 185 consecutive `SKIP dirty` lines under a green timer, one of the
  unpulled commits a key revocation. The PowerShell counterpart still reports a
  persistently dirty tree as an ordinary skip and exits 0, so `desktop` — the one
  Windows-native member left — can still freeze exactly that way, silently. The
  gap is named in `provision/fleet-selfpull.sh`'s header as review item 20;
  recorded here because a script comment is not where the backlog is read. Port
  `_streak_bump` / `_streak_clear` and `FLEET_SELFPULL_DIRTY_LIMIT`, and give the
  `.ps1` its first suite.

- [ ] **`provision/wsl-fixes.sh` should own desktop-wsl's ssh port**, and does
  not. In `networkingMode=mirrored` the distro shares the Windows adapters and
  `ssh.socket` loses the bind on `0.0.0.0:22` to the Windows OpenSSH server —
  `Dependency failed for ssh.service` every boot from 2026-08-29, unnoticed for
  five weeks while this repo documented the box as reachable. The fix is a
  drop-in moving it to 2222, now **tracked but not provisioned** at
  `hosts/desktop/wsl/ssh-socket-override.conf`: reprovisioning the distro still
  does not restore it. Doing it properly means gating on the real precondition
  (mirrored networking plus port 22 already taken, not the distro's name) and a
  Windows-side arm for the inbound firewall rule, which mirrored mode makes
  necessary and which `wsl-fixes.sh` has no business issuing today. A behaviour
  change to a script every WSL distro runs, for one host — its own change, with
  its own suite.

- [ ] **The dotfiles branch `origin/g15-wsl` is now the LAST copy of that box's
  host-local files. Do not delete it.** Host-local content is tracked on the
  machine branch and is absent from `main` by construction, so the branch is the
  only place those files exist as files. When
  `hosts/g15/staging/identity-snapshot.txt` recorded this on 2026-09-07 there
  were two copies — the branch and `latitude:/mnt/immich-mirror/g15-staging/home-me`
  — and the staging cleanup then freed 105 GB, taking that leg with it. The
  branch is the survivor, and it was the only tracked file saying so, which is
  why the note is here now and the snapshot is deleted. Retiring the branch means
  first deciding, file by file, what on it still matters — it is not a `branch -d`.

- [ ] **hub's `me@desktop-wsl-ubuntu-26-04` key** (`…DXi623`) is live —
  desktop-wsl's `id_ed25519` — and redundant only because desktop-wsl's ssh
  config pins `id_fleet`. Removing it is a real revocation, not a cleanup.
  Needs a deliberate decision.
- [ ] **latitude's migration debris**: 21M `~/immich-migration/` plus six
  `*.log` (`overnight.log` alone is 3.2M).
- [x] **The leaked telegrind credentials stay as they are — DECIDED 2026-08-01,
  do not re-raise.** *"let's not rotate anything, there's no risk."* Closed by
  decision, not by action: the values below are still live and still in the
  transcript. Recorded with the facts that were on the table, so the decision can
  be revisited on new information rather than re-argued on the same information.

  What leaked: `docker inspect --format '{{.Config.Env}}'` on the telegrind
  container printed `BOT_TOKEN`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` and
  `POSTGRES_PASSWORD` into a session transcript on `air`. **Use
  `{{.Config.Image}}` alone in future** — that part is a standing rule, unaffected
  by the decision.

  The exposure, measured rather than assumed: each live value in
  `latitude:~/my/vps/homeserver/telegrind/.env.prod` (0600) was tested for a
  byte-identical match under `~/.claude/projects/` on air. All four match, in
  **exactly one file** — one session transcript. `~/.claude/projects/` is
  path-keyed, machine-local and deliberately untracked, so the values are not in
  git, not on a shared host and not on another box. What did leave air is the API
  round-trip: they were sent to Anthropic as prompt context. **embedthat's
  `BOT_TOKEN` matches no transcript** and was never affected either way.

  If it is ever revisited, the mechanics are: each value is one line of that
  `.env.prod`, so replacing one is a one-line edit — `ANTHROPIC_API_KEY` at
  console.anthropic.com, `BOT_TOKEN` via BotFather `/revoke` then `/token`,
  `GOOGLE_API_KEY` at aistudio.google.com/apikey. `POSTGRES_PASSWORD` would stay
  excluded regardless: it never leaves latitude's docker network and is baked into
  the existing `telegrind_pgdata` cluster, so rotating it costs an `ALTER ROLE`
  plus a coupled `DATABASE_URL` edit for no exposure reduction.

  **This closes the leaked set only.** The Hermes entry below is a different
  situation — credentials abandoned without revocation rather than leaked, with no
  local copy left to replace — and was not part of this decision.
- [ ] **Hermes' credentials — a different situation, and still open.** Deleted from
  disk on 2026-08-01 *without* being revoked at source. Where the telegrind values
  above are known, local, and left in place by decision, these are the inverse: no
  local copy survives, so there is nothing to edit and nothing to inspect — only a
  blind revoke at each console, or a deliberate choice to leave them live upstream.
  Inventory in project memory.
- [x] **telegrind and embedthat are back up on latitude — 2026-08-01.** Both stacks
  live, both reusing their migrated volumes. What the bring-up took, and what it
  taught:
  - **Clone both `src/`** (`homeserver/*/src/`, gitignored build context, URLs in
    `repos.psd1`). Then **build the images BEFORE placing telegrind's
    `google-account.json`** — `src/` *is* the build context, so a `--build` with the
    key already in it can bake an RSA private key into an image layer. The app's
    `.dockerignore` and `.gitignore` both cover it, but building first makes that
    moot instead of load-bearing. Verified absent from the image afterwards.
  - **The key is at `homeserver/telegrind/src/google-account.json`** (0600), copied
    from `~/g513ie-prod-config/telegrind/google-account.json`. Note it lives INSIDE
    the gitignored clone, so a re-clone does not bring it and `git clean -fd` in
    `src/` would delete it (`git reset --hard` would not).
  - **Start postgres/redis before the app.** `depends_on` has no
    `condition: service_healthy`, so it waits for start, not readiness, and
    telegrind runs `alembic upgrade head` at startup.
  - **Verified with data, not with `docker ps`.** telegrind: **62 chats** (matches
    what memory recorded) and `alembic_version = 2700e0b3a8b6` present, which proves
    the right volume attached AND the credentials matched in one query; plus
    `Run polling for bot @telegrindbot`, a real Telegram API round-trip. embedthat:
    **5338 redis keys** restored, and within 25 seconds the worker had downloaded,
    ffmpeg-merged and sent a video to the dump chat — the whole pipeline, not a
    process that happens to be running.
  - **`server` still holds all five old containers**, `Exited` but present. Harmless
    only because their restart policy is `no` — otherwise a Docker Desktop start
    there would have put a second poller on the same bot tokens, which reads as an
    intermittent bug in the *new* deployment. Its `repos-deploy` task is also still
    `Ready`, firing every 3 min; also harmless only because the engine acts solely
    on already-running services.
  - **Diff the live `.env` against the harvested copy before trusting it.**
    `telegrind_pgdata` was restored as a raw tar, so the cluster's password is
    whatever server's file said; drift would surface as a connectivity error, not a
    credential one. All three copies were identical.
  - **embedthat's first build takes ~40 minutes and that is expected.**
    `faster-whisper` → CTranslate2 → NVIDIA CUDA/cuDNN wheels, ~GBs, on a box with
    Intel graphics only. Never GPU-accelerated even on the RTX-equipped server box
    (the compose requests no devices), so this is wasted download, not lost
    capability. Final image 592 MB.
  - **Re-read tugtainer's toggles instead of trusting the record.**
    `embedthat-redis-1` was `check_enabled=1, update_enabled=1` — unprotected —
    though `vps` memory said all three embedthat containers were toggled off on
    2026-07-14. `redis-stack:latest` is one of only two images here tugtainer can
    actually update, and this is the stack it has broken twice. All five now `0|0`.
- [ ] **Decide whether to port the poll-deploy engine to a systemd timer.** Now the
  only piece left, and worth naming plainly: **a push to either bot repo currently
  does nothing.** Push-to-deploy was the whole point of `deploy-repos.ps1` +
  `repos-deploy`, and neither runs on Debian. The bots are fine without it — they
  just never self-update, so every deploy is a manual `git pull` in `src/` plus
  `up -d --build`. Spec to reproduce: `vps/homeserver/DEPLOYING-A-REPO.md`.
- [~] **Headscale ACLs — DEFERRED BY DECISION 2026-08-01, do not re-raise as an
  oversight.** *"it doesn't burn right now."* The tailnet stays default-open.
  Recorded with what was on the table, so it can be reopened on new information
  rather than re-argued: `restic-server` runs `--no-auth`, so on a default-open
  tailnet **reachability is authorisation** for every repo on the REST hub — any
  tailnet node can read or write latitude's and desktop-wsl's backups. The natural
  trigger to revisit is a node joining that is not ours, which has never happened.
- [ ] **Drop `desktop`'s AWG.** It runs AmneziaWG beside Tailscale and its
  services already work over the tailnet. Remove once nothing depends on
  `10.0.0.6`, then drop the peer on hub.
- [ ] Enumerate `xs-keepers/home`'s ~20 config dirs; unbundle
  `qaz-code-feature-sync-dashboard.bundle`; decide
  `windows-reinstall-runbook.md`'s fate; confirm immich still has "Hardware
  decoding" ticked.

---

- **g15's database leg needs a drive, and that is the whole remaining item.**
  g15 got the `backup-client` role on 2026-09-08: `backup/g15/profiles.yaml`
  covers `~/my` (8.7 G — the gitignored half is what earns it: `qaz-code/laws`
  is 7.6 G of scraped corpus and is the INPUT the database was built from) and
  `~/Music` (89 G), retention and the weekly check run from
  `g513ie-maintenance` on latitude because the REST server is `--append-only`.

  `/data/qaz-code/pgdata` (186 G) is deliberately excluded, and **the reason is
  storage, not method**:
  - Method is settled and proven on this exact data — phase 1 staged it with
    the DB cleanly shut down and postgres 18.4 came up with a clean recovery.
    A `pg_dump` would be the wrong branch (hours, local space, and compressed
    custom-format output dedupes badly across snapshots). The container's
    STOPSIGNAL is `SIGINT`, i.e. postgres fast shutdown, and `me` is in the
    `docker` group, so `run-before`/`run-finally` need no privilege.
  - Scope needs root: PGDATA is `999:0` mode 700, so that leg is
    `schedule-permission: system` and one sudo'd `resticprofile schedule` on a
    box with no NOPASSWD sudo.
  - **Space is the blocker, and the first snapshot narrowed it.** The REST
    server's data path is `/mnt/spare320/restic-rest` on a 293 G drive.
    g15's repo landed at **83 G** (95.540 GiB processed → 88.945 GiB added →
    82.012 GiB stored), which leaves **82 G free** against latitude's own repo
    (12 G), desktop-wsl's (29 G) and the 89 G `music-from-g513ie` pile. So a
    DB leg does not fit today at all; dropping that pile would give 171 G,
    against an unmeasured ~120–130 G leg — feasible, with no growth headroom
    and no temp room for prune.

  **The decision is which drive, and the recommendation is to move rather than
  squeeze.** `/mnt/immich` (internal nvme0n1p1, 655 G free, not one of the
  flaky docks) is the obvious home, but `RESTIC_DATA_PATH`
  lives in the `vps` repo's `homeserver/restic-server` stack — the server is a
  service, and services live there — and moving it means relocating the 29 G
  g614jv repo too. Until then the 186 G staging leg at
  `/mnt/immich-mirror/g15-staging/pgdata` is the **only** second copy of that
  database and must not be deleted.

  **Update 2026-09-08 — the drive decision is DEFERRED pending the new 8 TB HDD.**
  It is in acceptance testing (identity gate passed, surface test to start by
  2026-09-18 — see project memory's *Приёмка нового диска*), and a disk that may
  yet go back to DNS is not something to build a backup target on. Until it is
  accepted, **the 186 G `pgdata` staging leg at
  `/mnt/immich-mirror/g15-staging/pgdata` stays put and must not be deleted** —
  it remains the ONLY second copy of that database, and it sits on `/dev/sdd2`,
  the dock this repo calls the flaky one. Space is no longer the binding
  constraint (see below); the drive is.

  Separately, and now DONE rather than pending:
  **`latitude:/mnt/spare320/music-from-g513ie` (89 G) is redundant to the restic
  snapshot** — verified 2026-09-08 against snapshot `b46c563d` directly, not
  through g15's live tree:
  - path+size manifest **identical, 14878 rows, `diff` empty**, byte totals equal
    to the digit (94,813,954,726 B both sides).
  - **five sha256 matches**, chosen to break a lazy comparison rather than to
    confirm one: the largest file (528 MB `.MPG`), the smallest non-empty (74 B
    `.url`), two random picks, and Cyrillic paths throughout
    (`OldMusic/Со старых дисков 2009-10/…`).
  - the restic side was restored from the snapshot and hashed, so the check
    covers the stored bytes, not an index claim.

  One trap that produced a wrong number first: **`restic ls <snap> <path>` is NOT
  recursive** — it listed 1 file and 3 dirs for a 14878-file tree, which reads
  exactly like a broken backup. `--recursive` is required whenever a path filter
  is given.

  **Deleted 2026-09-08 with the owner's go: spare320 went 82 G → 170 G free.**
  Two things worth carrying forward from doing it:
  - **The pile was root-owned**, so the unprivileged `rm -rf` failed part-way
    through with `Permission denied` on most of the tree (14878 files → 537) and
    left the directory standing. `sudo rm -rf` finished it. latitude has
    NOPASSWD sudo; g15 does not — the asymmetry that decides which box can do
    this kind of cleanup at all.
  - **The pre-flight guard asserted the exact file count and byte total before
    deleting**, which is what made a two-step deletion safe to finish: the
    identity was established on the full tree, so the partial state needed no
    re-derivation.

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
