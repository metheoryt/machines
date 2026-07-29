# Latitude wipe — harvest, disk layout, and pre-install decisions

Status: **open**. Created 2026-07-28, ahead of retiring NixOS on `latitude` and
reinstalling it as a plain-Linux always-on server. Revised the same day after
the Kingston 1TB was seated in latitude and `server` was booted back up.

Latitude is `100.64.0.2` / OS hostname `latitude5520`, NixOS
`26.11.20260726.624af66`. Both boxes are currently up and reachable over the
tailnet, which is the working window for everything below.

## 1. What is already safe

Surveyed live 2026-07-28. **No code is at risk.** Every git checkout on
latitude is clean and fully pushed:

| Repo | dirty | unpushed | stashes |
|---|---|---|---|
| `~/machines`, `~/my/vps`, `~/my/airdrome`, `~/my/skep` | 0 | 0 | 0 |
| `~/pure/backend-api`, `backend-core`, `backend-schema-registry`, `claude-plugins` | 0 | 0 | 0 |

The dotfiles bare repo is on branch `latitude`, clean, nothing ahead of
`origin/latitude`. It tracks only **7 files** — almost nothing of latitude's
local configuration is version-controlled, so anything worth keeping has to be
taken deliberately.

No GPG secret keys exist — `gpg` is not installed, so there is no keyring to
lose.

## 2. Disk inventory

### Latitude, as it stands now

| Device | by-id | Size | Contents |
|---|---|---|---|
| `nvme0n1` | `nvme-KINGSTON_SNV2S1000G_50026B76861AC433` | 931.5G | single NTFS partition, label `Immich`, **773G used / 160G free**, holding `ImmichMedia` and `Media` |
| `nvme1n1` | `nvme-KBG40ZNS512G_NVMe_KIOXIA_512GB_718PHEWEQXD3` | 476.9G | `p1` 1G ESP `/boot`, `p2` 450.4G LUKS → ext4 `/`, `p3` 25.5G LUKS unidentified |

**Blocker B2 is resolved — the second slot is real and it is the better slot.**
The Kingston enumerates as its own PCIe device at `0000:01:00.0` and negotiates
**16.0 GT/s ×4 (PCIe 4.0 ×4)**, at its maximum. The internal KIOXIA boot drive
at `0000:73:00.0` runs **8.0 GT/s ×4 (PCIe 3.0 ×4)**. So the free slot is not a
WWAN slot, is not width-limited, and is a generation faster than the slot the
OS currently boots from.

### Server (booted 2026-07-28, reachable over SSH)

| Disk | Model | Size | Volume | Used |
|---|---|---|---|---|
| 0 | WD PC SN560 (internal NVMe) | 954G | `C:` | 441G of 953G |
| 4 | WDC WD10SPZX-21Z10T0 | 932G | `E:` `Immich 2024` — holds `admin` | 663G |
| 1 | HGST HTS541010A9E680 | 932G | `H:` `Immich 2024 backup` — holds `backup-homeserver` | 650G |
| 2 | ST1000LM024 HN-M101MBB | 932G | `G:` `Immich backup` — holds `backup-homeserver` | 158G |
| 3 | ST320LT020-9YG142 | 298G | `F:` `Public` | 177G |

> **Corrected 2026-07-29.** The `E:` and `H:` models were originally swapped in
> this table. Verified against live contents on latitude: `sdd2`
> (**WDC WD10SPZX**, dock A bay 0) holds `admin`; `sdg2` (**HGST
> HTS541010A9E680**, dock B bay 1) holds `backup-homeserver`. The migration
> plan's own Data Inventory table was right; this one was the outlier. Given this
> document exists so that identifiers are never retyped from memory, the error
> was the dangerous kind. Full per-drive health baseline and the dock bay map:
> `../specs/2026-07-29-storage-pool-hardware-baseline.md`.

Note the three "1TB" drives are 2.5-inch laptop mechanicals in the docks, not
3.5-inch drives.

## 3. Hazards created by the current physical state

**H1. Device renumbering — this is the wipe hazard.** With the Kingston
installed, *it* is `nvme0n1` and the internal boot drive has become `nvme1n1`.
Any installer step, script, or muscle memory that says `nvme0n1` now points at
773G of Immich data. Address disks by `/dev/disk/by-id/nvme-KINGSTON_…` and
`…KBG40ZNS…` throughout, never by `nvmeXn1`.

**H2 — closed.** udisks had auto-mounted the Kingston read-write at
`/run/media/me/Immich` (`ntfs3 rw,…,prealloc`). It is now **unmounted**
(`udisksctl unmount -b /dev/nvme0n1p1`), which is safer than read-only.
Remounting read-only over SSH fails — udisks needs a polkit agent on a
controlling terminal — so inspection needs either a console session or
`sudo mount -o ro`.

**H3 — resolved: `nvme1n1p3` is an orphan.** UUID
`034fee22-2cc4-4200-bfa2-9a6c63f162e0`, 25.5G `crypto_LUKS`, and it is
referenced by nothing: there is no `/etc/crypttab` at all, `/etc/fstab` names
only the root mapper, `hardware-configuration.nix` declares exactly one LUKS
device (`4f92beab-…`) and `swapDevices = []`, and the only active swap is
`/dev/zram0`. It is never unlocked at boot, so nothing this install produced can
be inside it — any contents predate the current NixOS install. Treat as
disposable. If curiosity is worth one command, try `sudo cryptsetup luksOpen`
with the usual passphrase before repartitioning; if it does not open, it is
unrecoverable anyway.

**H4 — decided 2026-07-28: no LUKS.** Root is LUKS today and a human types the
passphrase at the console, which would hang every unattended reboot. The new
install uses a plain root. Remote-unlock alternatives (dropbear-initramfs,
clevis + TPM) were considered and declined as not worth the complexity for a
box on a home network.

**Also decided:** the SSH host keys are **not** preserved — re-accept the
changed key on the other members after the install. And the AmneziaWG material
needs no rescue at all: AWG was retired in favour of the tailnet and now lives
only on the VPS, so latitude's `amnezia.cyphy.kz.conf` and
`~/.ssh/vps_awg_private.key` die with the disk by design. The copy that had been
taken to `air` was deleted.

**H5. `F:` is the 320GB drive slated for retirement, and it holds `secrets`.**
Its top level is `qb`, `restic-repos`, **`secrets`**, a GoPro folder, and
`G614JV-Ubuntu-24.04.tar`. The migration plan's own Task 16 gate requires that
"everything from `F:\secrets` is copied somewhere safe and is not only on that
drive." Do not retire this disk before that is done and verified. `F:` also
carries a third restic location (`F:\restic-repos`) distinct from
`G:\backup-homeserver` and `H:\backup-homeserver`.

## 4. What must come off latitude — the short list

The home directory is 31G and nearly all of it is deliberately worthless,
because the box is becoming headless: `.cache` 11G, Google Chrome profile 6.7G,
`.local/share` 9.1G, Slack 1.5G. **Do not copy the home directory.** Chrome and
Slack re-sync from their accounts; caches regenerate.

Genuinely irreplaceable, total well under 100 MB:

| Path | Why | Disposition |
|---|---|---|
| `~/amnezia.cyphy.kz.conf` | AmneziaWG client config for the VPS, untracked, only copy | **Re-issue on `hub`**, do not transport |
| `~/.ssh/vps_awg_private.key` | AWG private key, 45 B, blocked from dotfiles by the deny block | **Re-issue on `hub`**, do not transport |
| `~/.ssh/id_ed25519` | Passphrase-less, has GitHub push access | **Revoke + regenerate**, do not transport |
| `/etc/ssh/ssh_host_ed25519_key`, `ssh_host_rsa_key` | Wipe changes the host key; five boxes' `known_hosts` break | Either preserve, or plan the re-accept |
| `/var/lib/tailscale/tailscaled.state` | Headscale node identity for `100.64.0.2` | See §6 |
| `~/.config/gh/hosts.yml` | gh OAuth token | Low stakes — `gh auth login` again |
| `airdrome_db_data` Docker volume | Postgres for the running `airdrome-db-1`, in no repo | **`pg_dump`**, not a volume file copy |
| `~/Documents`, `~/Pictures` | 3 MB combined | Just take them |
| `~/.ssh/config.backup` | Dated 2026-05-10, predates the Nix-generated `~/.ssh/config` | Glance, then drop |

**Found 2026-07-29, missed by the first survey: `~/Downloads` holds the only copy
of legal and financial documents.** The first sweep sized the home directory by
its big consumers and moved on; it never listed `~/Downloads` (145 M) because
nothing about the size was interesting. The contents worth taking:

| Item | Count | Why it matters |
|---|---|---|
| `Consulting Agreement_ANBUBO_Maxim Romanyuk (signed).pdf` + RU translation | 2 | Signed contract |
| `Maxim_Romanyuk_INV-9y8643n-2026-{1,2}…pdf` + RU translations | 4 | Issued invoices |
| `Complete_with_Docusign_Durer_AI_Ltd_-_Non-Em*.pdf` | 2 | Signed NDA |
| `M.Romanyuk Invitation Letter Greece.docx.pdf` | 2 | Travel document |
| `Telegram Desktop/` (13 M) | ~20 | Includes `Билет.pdf`, `Билет (2).pdf`, an orders report `.xlsx`, a CV |

The rest of `~/Downloads` — `.mp4` files, `.torrent` files, `autounattend.xml`,
a meme `.png` — is disposable.

**Done and verified 2026-07-29.** All of `~/Downloads` was taken rather than just
the documents — 31 files, 151 903 729 B, into `~/latitude-harvest/Downloads` on
`air`, **31 of 31 verified `OK` against a source sha256 manifest, zero
mismatches**. Copying the disposable `.mp4`s and `.torrent`s too cost 145 MB and
removed the risk of a hand-picked file list missing something.

With that, **§4 is closed** — nothing irreplaceable remains on latitude's home
directory.

Also present and safely ignorable: nine `~/.claude.json.tmp.*` leftovers,
`~/.config/orca` and `~/.config/JetBrains` (regenerable), `~/.zoom`.
`~/my/airdrome/compose.yml` is committed; only the volume's contents are not.
The bind mount `~/gh/airdrome/initdb` is 12K and lives outside any repo — check
it before wiping.

**Prefer re-issuing over transporting.** For the AWG peer, the GitHub key, and
the Headscale node, minting a fresh identity on the surviving side is less work
and better practice than carrying a private key off a machine about to be
destroyed. `hub` runs the AmneziaWG server, so the AWG peer is a hub-side
operation.

## 5. Backup coverage — measured, and it is worse than the hold implied

**Correction to an earlier reading.** The hold gates on Task 15 of
`2026-07-27-fleet-migration-mac-primary-latitude-server.md`, which is a
**latitude-side** restore verification, not a server-side one. It also sits at
the end of a chain — Tasks 12–14 migrate Immich onto latitude and repoint the
public routes — **none of which has happened**. With NixOS retiring and latitude
being reinstalled, Phase D and Phase E of that plan are stale as written and
need re-planning, not execution.

The backup definition lives in the sibling `vps` repo at
`backup/homeserver/profiles.yaml`, checked out on server at
`C:\Users\methe\my\vps`, with `RESTIC_PASSWORD_FILE: pass.txt` relative to that
directory. restic 0.18.1 is installed. Three scheduled tasks exist and report
`Ready`.

| Profile | Source | Repo | Latest snapshot | Snapshot size |
|---|---|---|---|---|
| `immich-media` | `D:\ImmichMedia\library\library` | `G:\backup-homeserver\immich-media` | **2026-07-05** | 151.1 GiB, 6 420 files |
| `immich-media-2024` | `E:\admin` | `H:\backup-homeserver\immich-media-2024` | **2026-07-02** | 662.9 GiB, 22 613 files |
| `immich-postgres` | `pg_dumpall` via stdin | `G:\backup-homeserver\immich-postgres` | **2026-07-07** | 534.9 MiB |

Three things fall out of that table.

**5a. 622 GiB on the Kingston is backed up by nothing — but only ~13 GB of it
is irreplaceable.** The disk holds 773 GiB and the only profile touching it
covers `D:\ImmichMedia\library\library`, capturing 151.1 GiB. Measured
breakdown of the rest (`du --apparent-size`, mounted read-only at
`/mnt/kingston`):

| Path | Size | Status |
|---|---|---|
| `ImmichMedia/library/library` | 152G | **backed up** — matches the 151.1 GiB snapshot |
| `ImmichMedia/library/encoded-video` | 71G | regenerable — Immich transcodes |
| `ImmichMedia/library/thumbs` | 9.4G | regenerable — Immich thumbnails |
| `ImmichMedia/library/upload` | 9.4G | **irreplaceable, unprotected** |
| `ImmichMedia/library/backups` | 2.9G | Immich's own DB dumps — superseded by the logical `immich-postgres` snapshot, cheap to keep |
| `ImmichMedia/library/profile` | 185K | **irreplaceable** — user avatars |
| `ImmichMedia/postgres` | 802M | raw PGDATA — superseded by the 534.9 MiB logical dump, and cross-version raw restore is fragile anyway |
| `Media/config` | 500M | **irreplaceable** — servarr / qBittorrent state |
| `Media/movies` | 249G | re-acquirable |
| `Media/torrents` | 238G | re-acquirable |
| `Media/qb-incomplete` | 41G | disposable — partial downloads |
| `Media/tv` | 457M | re-acquirable |
| `Media/xxx` | 138M | re-acquirable |

So the hold collapses to **`upload` + `profile` + `Media/config` + `backups`
≈ 13 GB**, which copies in minutes and does not require the 6TB to be seated
first. The remaining ~487G of movies and torrents is a *convenience* decision —
keep it to avoid re-downloading, not because it is unrecoverable — and the
~120G of derivatives and partials is genuinely disposable.

**Scope decision, 2026-07-28: the Kingston is not being wiped.** Only the KIOXIA
512G — NixOS root plus home — gets reinstalled. The Kingston keeps its data,
media included. That demotes the 13 GB copy from a migration step to insurance
against an installer mistake, which is still worth having, and it makes **H1 the
single remaining data risk in the whole operation.**

**5d. The Kingston is NTFS, and that becomes a problem the moment latitude is
Linux.** `Media/config` is servarr and qBittorrent state, which is SQLite —
SQLite over `ntfs3` has no dependable locking and will corrupt. Immich's library
wants POSIX ownership, and Postgres on NTFS is not a supported configuration at
all. Bulk media reads (Jellyfin, the *arr* scanners) are fine over `ntfs3`;
anything that writes a database is not.

There is no in-place conversion, so making the Kingston Linux-native means
copying 773 GiB off and back — which *does* need the 6TB seated, just not before
the OS install.

**Decided 2026-07-28, two stages.** For the install and first bring-up, the
Kingston stays NTFS and is mounted read-mostly as a **media shelf only**;
`Media/config`, the Immich library and Postgres all live on a Linux filesystem
(KIOXIA now, 6TB later) — never on `ntfs3`. Then **tomorrow, once the 6TB is in
hand**: stage the Kingston's 773 GiB onto the 6TB, reformat the Kingston to
ext4, and copy back. That reaches the clean end state without a second
reinstall, which is exactly why the interim stage is acceptable rather than
permanent.

**5b. Backups stopped about three weeks ago.** Newest snapshots are 2026-07-05,
07-02 and 07-07 against today's 2026-07-28, and every snapshot is recorded under
host `methe-server` — the pre-rename hostname, retired 2026-07-20. Two plausible
causes, both in `base.yaml`: `schedule-ignore-on-battery: true` silently skips
when the G15 runs on battery, and the box has been off for stretches. Whatever
the cause, the gap is real and nothing raised an alarm.

**5c. `immich-media` is now broken by the disk move.** Its source is `D:\`,
which was the Kingston — now in latitude. The scheduled task still reports
`Ready`, so the next fire will fail on a missing source rather than tell anyone
the data is unprotected.

`E: admin` (663 G) is fully covered by the H: repo (662.946 GiB), so E: is the
one volume with real redundancy today.

Until 5a is closed, the Kingston is irreplaceable. It is currently **unmounted**
on latitude, which is the safest state; remounting for inspection must be
read-only.

## 6. Fleet-side consequences

- **`fleet.json` pins latitude.** `platform: "nixos"`, `tailnet.ip:
  "100.64.0.2"`, roles `base, ssh-server, dev, desktop, laptop, agents,
  dotfiles, repos, backup-client`. All of that changes: platform becomes
  Debian/Ubuntu, `desktop` and `laptop` come off, and a services / `backup-hub`
  role probably goes on.
- **The tailnet address may not come back.** Re-enrolling with a new machine
  key creates a *new* Headscale node; the old name can end up suffixed and the
  next free IP handed out instead. Delete the stale node on `hub` first so the
  name and `100.64.0.2` are free.
- **Latitude is the fleet's only Nix executor.** `just quick` hard-gates on a
  one-host dry build and `scripts/converge.sh`'s `touches_nix` path has no other
  runner. That gate breaks fleet-wide the moment latitude is wiped. Either run a
  final `nix flake check` now and record the result, or accept that the Nix
  surface is deleted as part of retirement — but decide *before* the wipe,
  because afterwards there is no way to validate it in order to delete it
  confidently.
- **`modules/system/fleet-selfpull.nix` and `machines-converge.nix` lose their
  only consumer**; latitude moves onto the same `post-merge` hook plus
  cron / systemd-user path as every other non-Nix member.

## 7. Capacity — the layout question the numbers now settle

Data in play, once the 6TB is in: `E:` 663G, `F:` 177G, `C:` 441G of which only
a fraction is worth keeping, and the Kingston's 773G. Call it roughly 1.5–2 TB
of real payload. That fits the 6TB comfortably.

The backup pool after retiring the 320G is **3 × 1TB = 2.79 TB**, against a 6TB
primary. A whole-disk mirror of the 6TB is therefore impossible, and spanning
the three drives to fake one would defeat the point of independent disks. What
*does* work is **per-dataset assignment**: Immich media (≈663–773G) fits on one
1TB drive; `Public` plus the `C:` harvest fits on another; the third is spare
or a second copy of the highest-value dataset. That assignment has to be
decided **before** the 6TB is laid out, because it sets the dataset boundaries.

A layout worth considering for latitude, given the verified link speeds:
KIOXIA 512G (Gen3 ×4) stays the boot and root disk; the Kingston 1TB (Gen4 ×4)
becomes hot data — Postgres, Immich thumbnails and cache, container volumes;
the 6TB carries bulk media over USB; the 1TB mechanicals are backup targets on
the two 10 Gbps USB-A ports.

> **Health data added 2026-07-29 — this section was being decided on capacity
> alone.** Per-drive SMART for all five disks now exists at
> `../specs/2026-07-29-storage-pool-hardware-baseline.md`, and it reorders the
> assignment: the `ST1000LM024` is the weakest keeper (`Multi_Zone_Error_Rate`
> normalised 001/100, max-ever 63 °C) and must not hold the years-archive backup;
> the `WD10SPZX` has the cleanest surface but a marginal link (UDMA_CRC 144, still
> accruing) that has to be fixed *before* the 664G consolidation copy; the HGST is
> past its nominal load-cycle rating and is the designated off-site copy. Both
> docks also share one 10 Gbps bus at 5 Gbps each, so "the two USB-A ports" are
> not independent bandwidth — bus 002 is the free one.

## 8. Runtime facts worth recording before the box is gone

- **`/sys/power/mem_sleep` reads `s2idle`, not `deep`** — the
  `mem_sleep_default=deep` kernel parameter documented in `CLAUDE.md` never took
  effect on this hardware. Irrelevant for a server, but the doc is wrong.
- **Battery health 63%** — `energy-full` 39.4 Wh against 62.3 Wh design. Still
  ~40 Wh of crude UPS for an always-on box, which a desktop would not have.
- **Both USB-A ports are genuine 10 Gbps.** `lsusb -t` shows two `xhci_hcd/4p`
  root hubs at `10000M` (buses 002 and 004) behind the Tiger Lake "On-Package
  USB 3.2 Gen 2x1 (10 Gbs)" controller. Docks can go on USB-A and leave both
  USB-C free. Caveat: both hubs share that one controller, so concurrent dock
  throughput is shared, not additive.
- **`/etc/ssh/authorized_keys.d/me`** (731 B, root-owned) is Nix-rendered; the
  new install must reproduce its content from `fleet.json`, not from this file.

## 9. Sequence

These steps are destructive and order-dependent. Written out in full prose
deliberately.

Steps 1 and 2 are the ones that matter. Everything else is ordinary work that
can be redone; those two protect data that currently exists in exactly one
place.

1. **Done and verified 2026-07-28.** `upload`, `profile`, `backups` and
   `Media/config` copied to `~/kingston-rescue` on `air` — 13 GB, and
   **2 819 of 2 819 files verified `OK` against the source sha256 manifest**,
   zero mismatches. One benign `tar` warning: `Media/config/qbittorrent/
   qBittorrent/ipc-socket` was skipped because it is a socket, not a file, which
   is why the remote `tar` exited non-zero while the extraction succeeded. Since
   the Kingston is no longer being wiped this is insurance against an installer
   mistake rather than a migration, but it is the only thing standing between
   **H1** and real loss.
2. **`F:\secrets` — leave it alone.** Decided 2026-07-28: it is itself an old
   backup, so it needs no rescue. It still must never be tracked in the dotfiles
   repo; the deny block forbids key material at every layer. What *does* still
   need a decision before the 320G drive retires is the rest of `F:` —
   `F:\restic-repos` holds the `laptop-music` and `wsl` repos, which die with the
   disk, plus `qb`, a GoPro folder and `G614JV-Ubuntu-24.04.tar`.
3. Decide **H4** (LUKS or not) and §7 (which datasets get a second copy). Both
   are install-time decisions; neither can be changed afterwards without
   redoing the install.
4. Fix or disable the `immich-media` scheduled task, whose source `D:\` no
   longer exists (**5c**), so it stops reporting `Ready` while protecting
   nothing. Decide separately whether the three-week backup gap (**5b**) is
   `schedule-ignore-on-battery` or downtime, because the fix differs.
5. **Done 2026-07-28** — `~/latitude-harvest` on `air` now holds `Documents`
   (1.1M), `Pictures` (1.8M), `gh/airdrome/initdb`, `.ssh/config.backup`, the
   airdrome dump, and `amnezia.cyphy.kz.conf`.

   Two deliberate deviations from §4. `~/.config/gh/hosts.yml` was **not**
   copied — spreading a live OAuth token to a second machine buys nothing when
   `gh auth login` regenerates it. And `amnezia.cyphy.kz.conf` **was** copied
   even though §4 says re-issue rather than transport; that keeps VPN access
   working without a hub-side operation, at the cost of the AWG private key now
   existing on two machines. Re-issuing on `hub` and deleting the copy is still
   the cleaner end state. Neither file may ever be tracked in the dotfiles repo.

   **`~/machines` on latitude has an uncommitted change** — four lines added to
   `agents/memory/personality/tone.md` recording the peer-review register
   confirmed on CFT-1018. It is a synced memory file whose entire purpose is to
   reach the other machines, and nothing in the auto-pull path ever commits, so
   it dies with the home directory unless it is committed deliberately.
6. **Done 2026-07-28: airdrome dumped.** `docker exec airdrome-db-1 pg_dumpall
   -U postgres` → `~/latitude-harvest/airdrome-pgdumpall.sql` on `air`, 45 760
   bytes, 15 `CREATE DATABASE`/`CREATE TABLE` statements. Postgres 18, trivial
   dev credentials from `compose.yml`. The `db_data` volume is now expendable.
7. Re-issue rather than transport: mint a fresh AmneziaWG peer for latitude on
   `hub`, remove latitude's current key from GitHub, and delete latitude's stale
   Headscale node so its name and IP free up.
8. **Done 2026-07-28: `nix flake check` → `all checks passed!`** 17 flake
   checks, `checks.x86_64-linux.nixos-latitude` evaluating to
   `nixos-system-latitude5520-26.11.20260726.624af66`, plus
   `checks.x86_64-linux.home-latitude`. Recorded here because after the wipe
   there is no fleet member left that can run it.

   Caveat on the revision: the pull ahead of the check failed (`У вас есть
   непроиндексированные изменения`), so it evaluated the tree at `d8bccd7`, not
   at HEAD. Every commit since is documentation-only, so the Nix surface is
   byte-identical and the result stands for it — but the check did not run at
   HEAD, and that distinction should not be papered over.
9. **Physically remove the Kingston from latitude for the OS install**, unless
   step 1 is complete and verified. Renumbering (**H1**) means an installer
   aimed at `nvme0n1` erases the data disk, and "not selected in the installer"
   is not sufficient protection when out of the chassis is available. Reseat it
   afterwards — the slot is verified good.
10. Update `fleet.json` (platform, IP, roles) and re-provision through the role
    front door. Re-accept the changed SSH host key on the other members.

### Readiness re-verified 2026-07-29

Surveyed again immediately before the install, because §1's "every checkout is
clean" was measured against `~/machines` and the `~/my` / `~/pure` checkouts
only — it had not looked at the orca worktrees or at `~/Downloads`.

| Check | Result |
|---|---|
| `~/machines`, `~/my/*`, `~/pure/*`, `~/gh/*` | clean, nothing ahead, no stashes |
| dotfiles branch `latitude` | **was 3 commits ahead — pushed, now `a364c8b`, 0 ahead** |
| Host-local dotfiles paths | exactly one, `.claude/host-memory.md`, and it is on `origin/latitude` |
| **12 orca worktrees** under `~/orca/workspaces/machines` | every branch has **0 commits not already on `origin/main`** — nothing unique in history |
| Worktree dirty files | only `.superpowers/sdd/progress.md` in 4 of them, plus one generated `.pre-commit-config.yaml` full of `/nix/store` paths |
| `~/kingston-rescue` on `air` | 13 G, **2 819 files** — matches the verified count exactly |
| `~/latitude-harvest` on `air` | 3.0 M — `Documents`, `Pictures`, `gh/airdrome/initdb`, `.ssh/config.backup`, `airdrome-pgdumpall.sql` |
| `~/CLAUDE.md`, `~/README.md` | dotfiles-tracked |
| `~/Desktop`, `~/Music`, `~/Projects`, `~/Public`, `~/Templates`, `~/Videos` | empty |
| `~/orca/workspaces` (373 M) | worktrees of `machines` only — regenerable |
| `~/Downloads` (145 M) | **NOT clean — see §4. The one open item.** |

**The four `progress.md` diffs were read after the box was woken, and they are
write-offs.** Each worktree's copy is the SDD ledger for *its own* plan — fleet
rename Layer 1, SSH-over-tailnet, the KB harvester — while `main`'s copy has moved
on to a later plan. Every one of those plans is complete and merged, so the diff
is a stale ledger reverting to finished work. Nothing to keep. The stray
`.pre-commit-config.yaml` is Nix-generated and full of `/nix/store` paths, so it
cannot even be used off this machine.

**Latitude sleeps.** It went unreachable at 00:40 local with uptime 2:56 and had
to be woken by hand. Harmless today; it is exactly the failure mode the
laptop-as-server settings below have to fix before this box is trusted to stay up.

### Deliberate write-offs — recorded so they are not re-litigated later

- **All Docker volumes.** `airdrome_db_data` is superseded by the logical dump.
  The rest are work dev databases and media volumes
  (`backend-api_postgres`, `backend-api_media`, `cft1018-mobi_postgres`,
  `cft-1018-mobi-cancel-webhook_*`, `backend-api_venv` / `_uv-venv` / `_uv-cache`,
  `kan-kan_venv`) plus a pile of anonymous hash volumes from removed containers.
  All are reproduced by `docker compose up` plus migrations. **Anything
  hand-seeded into a work dev database is the one exception, and only the user
  knows whether that exists.**
- **The GNOME keyring** (`~/.local/share/keyrings/login.keyring`,
  `user.keystore`). Chrome's saved passwords sync from the Google account and
  everything else in it is re-enterable. A headless box has no use for it.
- **Wi-Fi PSKs** in `/etc/NetworkManager/system-connections` (root-only, not
  read during this survey). The box becomes wired and always-on; re-entering a
  PSK is cheaper than transporting one.
- **`~/.config/systemd/user`** — `dotfiles-sync.{service,timer}`,
  `gortex-daemon.service`, the Ghostty unit. Generated by Home Manager and by
  `provision/roles/`; the new install regenerates them.
- **`~/.config/gh/hosts.yml`** — `gh auth login` mints a fresh token; see §9
  step 5.

### Outcome — installed 2026-07-29

Debian 13 trixie is on the KIOXIA; the Kingston was left seated and untouched.
Verified live: OS hostname `latitude5520`, `profile: server (from fleet.json)`,
dotfiles on branch `latitude` (26 files, clean, sync timer active),
`host-memory.md` restored from `origin/latitude`, tmux 3.5a with the shared
config live (`mouse on`, `history-limit 50000`, `set-clipboard on`).

Five things did not go to plan, and each is worth keeping:

**The tailnet IP came back as `100.64.0.8`, not `.2`.** The stale node was
deleted *before* re-enrollment and `.2` was demonstrably free, but Headscale
0.29 handed out the next address anyway and has no CLI to pin one. Harmless as
it turns out: the generated SSH config emits `HostName` only for the hub, so
every other member reaches latitude by name through MagicDNS. `fleet.json` now
records `.8`.

**`gh` blocked the dotfiles checkout.** `tier_agent_clis` ran `gh`, which wrote
`~/.config/gh/config.yml` — a path branch `latitude` tracks. Git refuses to
clobber an untracked file, so `_dotfiles_checkout` bailed, and per its design did
NOT record the branch or install the timer. The guard worked exactly as
intended; the fix was one `mv` aside (kept as `config.yml.pre-dotfiles`; the only
difference was a comment typo a newer gh had corrected). **This will recur on
every fresh box** — `gh` runs before `tier_dotfiles` by tier order, so the
collision is structural, not bad luck.

**The Windows members could not SSH to latitude — a pre-existing bug the
reinstall exposed.** `ssh-wsl.sh`'s renderer emitted `User` only when
`ssh.user != "me"`, silently assuming the *local* user is `me`. On `server` and
`desktop` it is `methe`, so a default-user member got no `User` line and ssh fell
back to the local name: `methe@latitude: Permission denied`. That took `fd_run`
with it, and so `/ship`'s fleet-pull and kb-refresh's fleet-gather. Fixed in
`45d3b45` (always render `User`). Then a second gap surfaced: `windows.ps1` step
7 only ever configured *inbound* SSH, so those boxes had no client config at all
— `c8839ac` adds `provision/lib/fleet-ssh-config.ps1` plus step 7g, in PowerShell
because Git Bash there has no jq. Applied to both boxes; `server` and `desktop`
now reach air, hub and each other as the right user.

**Two apparent "it suspended" events were a weak USB-C charger.** The box went
unreachable twice and came back hard-hung with no LEDs. It was plugged into a
low-power USB-C port, drained to 4%, and lost power outright — the previous
boot's journal ends on ordinary sshd lines with no suspend and no oops, which is
the signature of abrupt power loss rather than a failed resume. With a 20 V /
3.25 A (65 W) source it boots and charges normally. **Suspicion of s2idle was
wrong**; §8's note that `mem_sleep` reads `s2idle` is still true and still
untested.

**The laptop-as-server settings were already applied** by the USB bootstrap
script, not left pending: `sleep.target` and `suspend.target` masked (02:46) and
`/etc/systemd/logind.conf.d/99-server.conf` in place (03:13) with
`HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`,
`HandleLidSwitchDocked=ignore`, `IdleAction=ignore` all live per
`systemd-analyze cat-config`. And `charge_control_end_threshold` already reads
**85** — the value survives in the EC across an OS reinstall, so the charge-limit
task from §9 needs nothing. What remains is the BIOS auto-power-on setting, which
no OS-side change can reach.

### Install-time facts, in one place

Everything below was verified on the live box; the disk identifiers are the part
that must not be retyped from memory (**H1**).

- **Target the KIOXIA, by-id:** `/dev/disk/by-id/nvme-KBG40ZNS512G_NVMe_KIOXIA_512GB_718PHEWEQXD3`.
  With the Kingston seated it is `nvme1n1`, **not** `nvme0n1`. Best answer is
  still §9 step 9 — take the Kingston out of the chassis.
- **Hostname:** `latitude5520`, exactly. A different name silently resolves to
  the `workstation` profile.
- **User:** `me`.
- **Layout:** ESP 1 G, ext4 `/` ~470 G, 4 G swap, no separate `/home`, no LUKS,
  orphan `p3` deleted.
- **Task selection:** standard system utilities + SSH server. No desktop.
- **First command after first boot:** clone `machines`, then
  `bash provision/linux.sh` — profile resolves to `server` from `fleet.json`.
- **Laptop-as-server, none of which the Debian default gets right:**
  `HandleLidSwitch=ignore` and `HandleLidSwitchExternalPower=ignore` in
  `/etc/systemd/logind.conf`; mask `sleep.target suspend.target hibernate.target
  hybrid-sleep.target`; BIOS auto-power-on after AC loss; battery charge
  threshold ~90 % (health is 63 %). **The box suspending on 2026-07-29 at 00:40
  is exactly this failure mode, observed on the machine that is about to become
  always-on.**

## 10. What gets installed — decided 2026-07-28

**Debian 13 trixie**, netinst, no desktop task. The distro family was never
really open: `provision/linux.sh:91` dies unless `apt-get` exists, so it is
Debian or Ubuntu. trixie over hub's bookworm for the 6.12 kernel (Tiger Lake
VAAPI/QSV, if anything ever transcodes on the iGPU) and no snap layer; the cost
is running two Debian releases in the fleet, which the tiers tolerate because
they only name generic packages.

**Partitioning, KIOXIA 512G only:** ESP 1G, ext4 root ~470G, 4G swap (24 GB RAM,
no hibernation on a server), no separate `/home` on a single-purpose box, and the
orphan `p3` deleted. ext4 rather than btrfs because the backup tooling is already
restic — snapshots would be a second mechanism earning nothing.

**The OS hostname stays `latitude5520`.** Load-bearing, not cosmetic: profile
resolution matches `fleet.json`'s `detect.hostname`, and a renamed box falls
through to `workstation` and silently installs the dev layer it no longer wants.
A regression test now pins this.

### The `server` profile (implemented 2026-07-28)

`provision/linux.sh` gained a third profile, and `fleet.json` now carries
`"profile": "server"` for latitude:

```
tier_apt_min tier_apt_dev tier_agents_config tier_git_base
tier_agent_clis claude tier_shell_init tier_autofetch
tier_ssh_accounts tier_selfpull tier_ssh_trust tier_dotfiles
```

It is **workstation minus `gortex`, `codex`, `hermes`, `hermes_config`,
`hermes_dashboard`** — not a copy of the `hub` tier, which is lean only because
the hub is a 960 MB VPS. This box has 24 GB and 470 GB and a human SSHes into it,
so it keeps `apt_dev` (gh, ripgrep/fd/fzf, fish, starship, uv) and fish.

Three ordering facts that the tier list depends on, each verified rather than
assumed:

- **`ssh_accounts` is included here though `hub` forbids it.** The hub hazard is
  that pinning `github.com` to a freshly generated, unregistered key kills that
  box's only working GitHub auth. After a reinstall latitude has *no* key at all,
  so there is nothing to break — and it closes the gap the NixOS config left,
  where `modules/home/ssh.nix` rendered fleet hosts only and GitHub fell back to
  default key order with no per-account alias.
- **`dotfiles` stays last, and after `ssh_accounts`.** The bare-repo checkout is
  *refused* — not silently clobbered — when an untracked file already occupies a
  tracked path (`provision/roles/dotfiles.sh`, `_dotfiles_checkout`), and a
  refusal means no branch recorded and no sync timer, a timer that looks
  installed and never works. Two things make last safe: branch `latitude` tracks
  22 paths of which only `.claude/host-memory.md` is host-local, and none of them
  is `~/.gitconfig` or `~/.ssh/config` (unlike branch `air`); and after the
  2026-07-28 handover `agents/bootstrap.sh` `retire_link`s
  `~/.claude/{CLAUDE.md,memory,host-memory.md,statusline-command.sh}` rather than
  symlinking them, claiming only `~/.claude/skills/cyphy`, which the branch does
  not track. `ssh_accounts` must precede it because the private-repo clone needs
  a key.
- **`selfpull` stays unpinned.** Its default roots are `$HOME $HOME/my` — exactly
  `~/machines` plus `~/my/vps` here — and the data disks mount outside `$HOME`,
  so there is nothing to over-scan. `hub` pins `%h/machines` only because of its
  own `~/vps` checkout.

Not added, per the explicit decision to install the rest by hand: Docker, sshd
config, fstab mounts, resticprofile. Those were NixOS modules or `windows.ps1`
steps and have no tier today.

**Known overstatement, not fixed today:** `provision/roles/` contains only
`agents`, `dotfiles`, `repos`. `fleet.json`'s role list for latitude still names
`base`, `ssh-server`, `dev`, `desktop`, `laptop`, `backup-client`, none of which
has an executor — so the manifest promises more than provisioning delivers.

## 11. Standing holds

- The Kingston 1TB stays under the hold — no reformat, no repartition — until
  §5 is resolved. The ~980 MB/s SEQ1M Q8T1 enclosure benchmark demonstrates
  media health and a full Gen2 link; it is **not** a restore verification.
- The 320G `ST320LT020` (`F:` `Public`, 177G used) carries `secrets`,
  `restic-repos`, `qb`, a GoPro folder, and `G614JV-Ubuntu-24.04.tar`. It is not
  retirable until step 4 above is done.

  **Resolved 2026-07-29 — retiring is not wiping.** The drive was pulled from
  dock B bay 0 and shelved with its data intact, which frees the bay at zero data
  risk and needs no decision about `F:`'s contents. Step 4 is therefore *deferred,
  not done*: the `restic-repos` / `secrets` / GoPro / Ubuntu-tar call still has to
  be made before the disk is ever reused or disposed of. Its measured health
  supports the deferral — SMART PASSED, surface clean (0 reallocated / 0 pending /
  0 offline-uncorrectable), and its 10 logged ATA errors are all ≥2.6 years stale
  (newest at 13 478 h against 36 153 h now).

- **The 6TB that replaced it is a relabelled drive and is going back
  (2026-07-29).** Bought as a new WD Purple `WD63PURZ`, and the chassis carries a
  WD Purple sticker — but the disk seated in dock B bay 0 reports
  **`HUS726060ALE611`** (HGST Ultrastar 7K6000, 2015-era enterprise nearline)
  with **74 485 power-on hours / 74 419 head-flying-hours — 8.5 years** and
  3.02 PB written. Confirmed from four independent sources including the kernel's
  SCSI inquiry and the WWN's Hitachi `000cca` OUI, where a genuine Purple would
  show WD's `0014ee`. Its surface is clean (0 reallocated, 0 pending, 0
  uncorrectable, empty error log) and the firmware was *not* tampered with — the
  fraud is a sticker over an untouched old disk. The 22-hour `badblocks` burn-in
  is **cancelled**, not deferred: it cannot change the outcome and it spends the
  return window. **Consequence for planning: there is currently no 6TB.** The
  Kingston-to-ext4 conversion (§5d stage 2) and the whole consolidation stay
  blocked until a replacement lands. Evidence, dispute artefacts and layout
  consequences: `../specs/2026-07-29-storage-pool-hardware-baseline.md`.
