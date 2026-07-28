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
| 4 | HGST HTS541010A9E680 | 932G | `E:` `Immich 2024` — holds `admin` | 663G |
| 1 | WDC WD10SPZX-21Z10T0 | 932G | `H:` `Immich 2024 backup` — holds `backup-homeserver` | 650G |
| 2 | ST1000LM024 HN-M101MBB | 932G | `G:` `Immich backup` — holds `backup-homeserver` | 158G |
| 3 | ST320LT020-9YG142 | 298G | `F:` `Public` | 177G |

Note the three "1TB" drives are 2.5-inch laptop mechanicals in the docks, not
3.5-inch drives.

## 3. Hazards created by the current physical state

**H1. Device renumbering — this is the wipe hazard.** With the Kingston
installed, *it* is `nvme0n1` and the internal boot drive has become `nvme1n1`.
Any installer step, script, or muscle memory that says `nvme0n1` now points at
773G of Immich data. Address disks by `/dev/disk/by-id/nvme-KINGSTON_…` and
`…KBG40ZNS…` throughout, never by `nvmeXn1`.

**H2. The Kingston is mounted read-write.** udisks auto-mounted it at
`/run/media/me/Immich` with `ntfs3 rw,…,prealloc`. Data still under the hold
should not be writable on a box that is about to be reinstalled. Unmount it, or
remount read-only, until §5 is settled.

**H3. `nvme1n1p3` is still unidentified** — 25.5G `crypto_LUKS`, not mounted,
not in the captured fstab. Probably old swap or hibernation, but that is a
guess, and a disk with an unreadable partition on it cannot be certified safe
to erase. Needs the sudo password:

```console
sudo cryptsetup luksDump /dev/nvme1n1p3
grep -rn nvme1n1p3 /etc/crypttab /etc/fstab
```

Note the device name changed with the Kingston installed — this is `p3` of
`nvme1n1` now, not `nvme0n1`.

**H4. LUKS on an always-on headless server.** Root is LUKS today and a human
types the passphrase at the console. As an always-on server, any unattended
reboot hangs at that prompt. Decide at install time — plain root, or LUKS plus
remote unlock (dropbear-initramfs, or clevis with the TPM). Not revisitable
without a second reinstall.

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

## 5. The hold on the Kingston — what it actually says

**Correction to an earlier reading.** The hold gates on Task 15 of
`2026-07-27-fleet-migration-mac-primary-latitude-server.md`, which is a
**latitude-side** restore verification (`restic check --read-data-subset 5%`
plus a real test restore out of `/srv/backup-1/backup-homeserver`), not a
server-side one. It also sits at the end of a chain — Tasks 12–14 migrate
Immich onto latitude and repoint the public routes — **none of which has
happened**. With NixOS retiring and latitude being reinstalled, Phase D and
Phase E of that plan are stale as written and need re-planning, not execution.

**Whether the Kingston is the only copy is now an open question, not an
assumption.** The server holds `E: Immich 2024` (663G, an `admin` tree) plus
two restic locations (`H:\backup-homeserver` 650G, `G:\backup-homeserver`
158G), and the Kingston holds a 773G `ImmichMedia` + `Media` pair. Those may
overlap substantially. Resolve it with `restic snapshots` against each repo and
a spot restore — not by comparing volume sizes, which proves nothing about
content.

Until that is resolved, treat the Kingston as irreplaceable and keep it
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

1. Remount the Kingston read-only, or unmount it (**H2**). Do this first — it
   costs nothing and it removes the only way the hold can be violated by
   accident.
2. Resolve **H3**: identify `nvme1n1p3` and, if it holds nothing, record it as
   disposable. Do not proceed with an unidentified encrypted partition on the
   disk you are about to repartition.
3. Resolve §5: establish by `restic snapshots` and a spot restore whether the
   Kingston's contents are also present in `H:\backup-homeserver` or
   `G:\backup-homeserver`. This determines whether the hold still binds, and it
   requires the server, which is up now.
4. Harvest `F:\secrets` off the 320G drive to at least two places, verify it,
   and only then consider that disk retirable (**H5**). Also take
   `F:\restic-repos` into account when planning the new backup layout — it is a
   third restic location.
5. Decide **H4** (LUKS or not) and §7 (which datasets get a second copy). Both
   are install-time decisions; neither can be changed afterwards without
   redoing the install.
6. Harvest the §4 short list to a destination that is **neither the Kingston
   nor any disk about to be installed** — `air` or `desktop` over the tailnet.
   Everything in §4 must be off-box before anything is erased.
7. `pg_dump` the airdrome database out of the running container, verify the dump
   is non-empty and restorable, and only then treat the Docker volume as
   expendable.
8. Re-issue rather than transport: mint a fresh AmneziaWG peer for latitude on
   `hub`, remove latitude's current key from GitHub, and delete latitude's stale
   Headscale node so its name and IP free up.
9. Run a final `nix flake check` and record the output in this document, so the
   last known-good state of the Nix surface is on record before it stops being
   verifiable.
10. **Physically remove the Kingston from latitude for the OS install**, unless
    step 3 has proven the data exists elsewhere and been verified. Renumbering
    (**H1**) means an installer aimed at `nvme0n1` erases the data disk, and
    "not selected in the installer" is not sufficient protection when out of the
    chassis is available. Reseat it after the install — the slot is verified
    good.
11. Update `fleet.json` (platform, IP, roles) and re-provision through the role
    front door. Re-accept the changed SSH host key on the other members.

## 10. Standing holds

- The Kingston 1TB stays under the hold — no reformat, no repartition — until
  §5 is resolved. The ~980 MB/s SEQ1M Q8T1 enclosure benchmark demonstrates
  media health and a full Gen2 link; it is **not** a restore verification.
- The 320G `ST320LT020` (`F:` `Public`, 177G used) carries `secrets`,
  `restic-repos`, `qb`, a GoPro folder, and `G614JV-Ubuntu-24.04.tar`. It is not
  retirable until step 4 above is done.
