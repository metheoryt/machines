# Drive migration operational log — 2026-07

Archived 2026-08-01 out of `.claude/memory/project.md`, verbatim, to keep the
per-session memory load down. This is the point-in-time operational record of the
2026-07 storage migration onto latitude: drive identities, UUIDs, byte counts,
per-copy verification, SMART readings, and the reformats
(`/mnt/public` → `/mnt/spare320`, `/mnt/immich-backup` → `/mnt/immich-mirror`).

**Read this before touching any drive on latitude.** The durable *rules* distilled
from it stay in `.claude/memory/project.md` under `## Backups`; everything below is
the evidence behind them. Drive letters here are point-in-time and reshuffle on
every reboot — identify by UUID or bridge serial.

## The record (as written)

- ~~Fleet restic hub-and-spoke: every client backs up through resticprofile to/on
  the homeserver (REST server on port 8001, or local drives).~~ — **superseded
  2026-07-31**: the strategy is now mirror-the-bulk and **no restic repo is
  planned at all** (see the strategy bullet below). Kept as the pre-migration
  shape; g16's `laptop/music` profile was already retired 2026-07-07.
- ~~Homeserver's immich backup targets `G:`/`H:` are 2.5" HDDs in USB docking
  stations plugged into the homeserver~~ — **superseded 2026-07-31**: g513ie has
  only `C:`; those drives now live in latitude's docks. **The offsite gap itself
  still stands** — every copy is in one apartment, and the fix remains cheap
  (rotate one dock's drive off-site) rather than adding cloud/object storage.
  Task 19 of the migration plan owns it.
- **RustDesk restore is not a plain file-copy.** RustDesk runs as a LocalSystem
  Windows service that owns a master config and overwrites `%APPDATA%\RustDesk\config`
  (`RustDesk2.toml`) seconds after service start — so `restore.ps1` can never durably
  restore the custom ID/Relay ("retranslator") server by copying the file back. The
  restore script instead extracts those values from the backup and prints them for
  manual GUI entry (Settings → Network → ID/Relay Server).
- **`restore.ps1`'s `Find-Backups` auto-discovers the backup drive** by scanning every
  Windows volume for a `<letter>:\backup` folder, so it survives the backup SSD
  mounting on a random drive letter; sibling scripts (`backup.ps1`,
  `bootstrap-agents.ps1`) historically hardcoded a letter and needed the same
  auto-discovery.
- latitude5520 has no dedicated backup today (the g16 NixOS side this bullet used
  to name was retired 2026-07-08).
  Whatever home-manager declares in this repo is already "backed up" by being
  in git; anything outside home.nix's scope (browser profiles, ad hoc
  `~/.config` dirs, local documents) is not protected. User wants to back up
  latitude5520 into a private repo "someday" (stated 2026-07-07) — not urgent,
  no mechanism chosen yet (chezmoi/stow/plain git all unexplored as of this
  writing).
- **Never send `hdparm -Y` (SLEEP) to a drive in latitude's USB-SATA docks.**
  SLEEP can only be cleared by a bus/power reset, so the drive stops answering
  the bridge entirely — a `/sys/class/scsi_host/hostN/scan` rescan cannot wake
  it (`Spinning up disk... not responding`), and on these two-bay docks the
  sibling bay went with it. Use `-y` (STANDBY, wakes on access) when you want
  platters stopped, and accept that recovery otherwise needs the user to
  power-cycle the dock. 2026-07-30: `-Y` went to **`sdg`, the HGST in dock B
  bay 1 holding the `immich-media-2024` backup** — *not* to the returning 6 TB,
  which correctly got `-y`. `usb 4-1: reset SuperSpeed` followed 71 s later.
- **The docks also reset unprompted — check the journal before blaming your own
  command.** Same day, `usb 4-1` reset at 14:23:08, 94 min before `hdparm` was
  installed. Three-day fault count: dock B (`usb 4-1`) 4 disconnects + 2 resets,
  worst device on the box; plus hub children `2-1.3` / `2-1.4` / `3-1.4` / `2-2`
  dropping, and at 17:40:02 dock A and the XS SSD re-enumerated together.
  Marginal cabling and physical knocks are a chronic fault mode here. Check with
  `sudo journalctl -k --since today | grep -aE "usb [0-9.-]+: (reset|USB disconnect)"`.
  Layout consequence: archive *primary* on dock A, *copy* on flakier dock B, and
  give any long write into dock B `--partial --append-verify` so a drop resumes.
- **`nofail` in fstab applies at boot only.** After any dock power-cycle or bus
  drop, every affected mount needs an explicit `sudo mount <target>` — found
  `/mnt/public` silently unmounted this way 2026-07-30.
- **Every `/dev/sdX` letter on latitude reshuffles across a reboot — treat any
  letter written down anywhere in this file as point-in-time only.** The
  2026-07-31 00:03 reboot moved all five external drives at once:
  `/mnt/immich-2024` sdd2→sdc2, `/mnt/immich-2024-backup` sdg2→sdb2,
  `/mnt/immich-backup` sde2→sdd2 (that mount is now `/mnt/immich-mirror`),
  `/mnt/public` sdc1→sdg1, `/mnt/xs` sdf3→sda3.
  `sdd` therefore names a *different physical drive* before and after. Five
  bus-powered USB spinners plus a card reader race to enumerate, so ordering is
  not stable. Identify a drive by **UUID** (mounts), **bridge serial** in
  `/dev/disk/by-id/usb-*` (dock membership: `6702002103E1` = dock A,
  `670200210032` = dock B; suffix `-0:0` is bay 1, `-0:1` bay 2), or drive model
  — never a letter. Also note **USB port paths are not stable either**: dock A was
  `usb 4-2` and dock B `usb 4-1` after this boot, having previously been on host2.
- **A SCSI rescan force-spins-up every sleeping drive on that host, and re-adds
  bays you already detached.** So `echo 1 > /sys/block/<dev>/device/delete` is
  one-way only if you don't rescan afterwards; and reading SMART (`smartctl`)
  wakes a parked drive. To assert a device's identity *without* waking it, read
  `/sys/block/<dev>/device/{model,vendor}` plus `lsblk -dn -o SERIAL,WWN` —
  never `smartctl`. Note sysfs `model` is space-padded, so `grep -q` it rather
  than comparing with `[ = ]`.
- **Dock B bay 1 (HGST HTS541010A9E680 / `JD100ACC2V5ZVK`) holds the second copy
  of the 664 GB `/mnt/immich-2024` archive, and since 2026-07-30 it is a plain
  file copy, not a restic repo.** Reformatted to ext4, label
  `immich-2024-copy`, **new UUID `25f3c751-3df9-44d6-b626-3ff119cc82fe`** (the
  old NTFS `6C16E54216E50DC0` is gone), fstab mounts it `defaults,noatime,nofail`
  read-**write** at `/mnt/immich-2024-backup`. The `immich-media-2024` restic
  repo it used to hold (651 GB, 9 snapshots of `E:\admin` from `methe-server`,
  newest 2026-07-02) was deliberately destroyed by that reformat — the plain copy
  replaced it so recovery needs no password and is browsable. Copy verified
  byte-exact: **711832525257 bytes / 20456 files**, identical per-year across all
  19 dirs (1970, 2007-2024). Source stays `ntfs3,ro`: the **WDC WD10 SPZX-21Z10T0
  in dock A bay 1**, UUID `EAA6CAAEA6CA7A99`. Leaving either dock powered off drops the archive to a
  single copy. **Checksum-verified 2026-07-31 06:56: `rsync -rn -c` over all
  712 GB / 20456 files reported zero differing files.** So the WDC's 144
  `UDMA_CRC_Error_Count` never corrupted any stored data — those are
  bridge/cable-link events, not media errors. Both drives also passed
  `smartctl -t long` the same morning (`Extended offline / Completed without
  error` at 28835 h WDC, 27853 h HGST) with `Reallocated_Sector_Ct`,
  `Current_Pending_Sector` and `Offline_Uncorrectable` all 0 and zero bus faults
  across the 4-hour scan. Reading verifies but does not refresh magnetization —
  for that the only real answer is a periodic re-copy.
- **`/mnt/immich-backup` no longer exists. Dock A bay 2 (ST1000LM024 /
  `6702002103E1-0:1`) was reformatted ntfs3 → ext4 on 2026-07-31 14:30 and is now
  `/mnt/immich-mirror`** — label `immich-mirror`, **UUID
  `a7d7b61e-94b1-4673-af71-81152061199f`** (old NTFS `9CCED7D2CED7A2B6` gone),
  fstab `defaults,noatime,nofail,x-systemd.device-timeout=60`, 916 GiB usable
  (`mkfs.ext4 -m 0`). It holds `rsync -aHAX` of all of `/mnt/immich` (~731 GiB
  deduped) plus `var-backups/immich-db`. Excluded from the mirror:
  `ImmichMedia/postgres` (**never rsync live PGDATA — the copy looks like a backup
  and is unrestorable**; the `/var/backups/immich-db` dumps are the DB backup) and
  `lost+found`. Drive SMART is old but clean: PASSED, 0 reallocated / 0 pending /
  0 offline-uncorrectable / 0 CRC, 25396 h, Start_Stop 7707, Load_Cycle 344694.
  Two caveats on the mirrored content: **`Media/config` (514 M) contains jellyfin's
  and the *arr apps' live SQLite while those containers run**, so the mirrored copy
  is the same torn-copy class as PGDATA — treat it as best-effort, not restorable
  (jellyfin rebuilds its library, so it isn't worth stopping containers for). And
  **`/mnt/immich-mirror/staging/` (the GoPro second copy) is NOT in the mirror's
  source tree** — any future refresh run with `--delete` would remove it, so such a
  run needs `--exclude=/staging/`.
  The mirror's own verification compares against a **live** immich after a ~3 h
  rsync, so a couple of files landing mid-run can print `MIRROR HAS DIFFS`
  benignly. Benign = DIFFs confined to `library`/`thumbs`/`encoded-video` with
  src > dst and every `Media/*` OK; real = dst > src, any `Media/*` mismatch, or a
  large byte gap. On benign, re-run the same `rsync -aHAX` as a delta and re-verify.
- **Corrections to earlier notes about what lived on that drive — all four were
  wrong and each one would have driven a bad decision.** (1) `stage-nvme` (735 G)
  was **not** a backup of the immich library: it was `movies` + `torrents`, proven
  byte-identical to `/mnt/immich/Media/{movies,torrents}` (same 100 + 534 files,
  same 266826269121 + 521808368097 bytes). It ballooned to 735 G on NTFS only
  because the copy lost the hardlinks that make the same content 487 GiB on ext4 —
  direct proof that `-H` is load-bearing. (2) **The immich library was never
  single-copy: `~/immich-stage` (244 G) on `nvme1n1p3` (root) is a full second copy
  on a *different physical NVMe* from `/mnt/immich` (`nvme0n1p1`).** latitude has
  two NVMes — 931.5 G data + 476.9 G root — so an on-box second copy is a real
  second device, not a false one. (3) **g513ie has only `C:` (953 G, ~428 G used).
  There is no `G:` or `H:` — those were the external drives now plugged into
  latitude, so g513ie is NOT a fallback for anything.** The "most recent 2026-07-02
  backup on g513ie" was in fact the `backup-homeserver` restic repo on this very
  drive. (4) `/mnt/public` is **not** fully redundant: the overnight job copied only
  `qb`, leaving `restic-repos` (69 G) and `G614JV-Ubuntu-24.04.tar` (9.9 G)
  uncopied. `restic-repos` holds two `me-g614jv` repos — `laptop-music` (14
  snapshots of `C:\Users\methe\Music\PicardedMusic`, 65 GiB) and `wsl` (19
  snapshots of `/home/me`, 8.7 GiB); both need `sudo -E restic` because ntfs3's
  `uid=1000` mapping does not reach their subdirs.
- **The `backup-homeserver` restic repos: pgdump history kept, media history
  deliberately discarded (2026-07-31).** `immich-postgres` (474 M, 16 snapshots of
  `C:\pgdump.sql` to 2026-07-07) was copied to
  `/mnt/immich-2024-backup/restic-history/immich-postgres` and verified readable
  before the reformat. `immich-media` (158 G, 16 snapshots of
  `D:\ImmichMedia\library\library` ~151 GiB, newest 2026-07-05) was **destroyed** —
  no room to relocate it, and its content is superseded by two current full copies.
  What is gone is *version history* for photos between 06-20 and 07-05, i.e. the
  ability to recover something deleted in that window. Accepted knowingly.
- **`/mnt/xs` cannot be remounted read-write in place**: `mount -o remount,rw`
  fails with `ntfs3: Couldn't remount rw because journal is not replayed. Please
  umount/remount instead` — a dirty `$LogFile` from an unclean Windows shutdown. It
  needs a full `umount` + `mount -o rw`. `/dev/sda` is a **Ventoy stick**: `sda1`
  253.8 G exfat `Boot`, `sda2` 32 M `VTOYEFI`, `sda3` 700 G ntfs `data` → `/mnt/xs`
  (550 G free). No unallocated space to carve an ext4 partition from.
- **`/mnt/public` is gone. The ST320LT020 (320 GB) was reformatted ntfs3 → ext4 at
  18:17 on 2026-07-31 and is now `/mnt/spare320`** — label `spare320`, **UUID
  `3a78fd88-deb0-4c1a-a576-14abd0631d57`** (old NTFS `6C28DD2C28DCF654` gone),
  293 GiB, **empty and unassigned**. Everything on it was cleared first: `qb` 60 G
  verified on the HGST (1749 files / 63900157812 bytes both sides); `Настя Стас
  GoPro` 40 G copied to `/mnt/immich-mirror/staging/` and verified (162 files /
  41905063663 bytes) *before* the reformat; `restic-repos` 69 G and
  `G614JV-Ubuntu-24.04.tar` 9.9 G deleted on the user's instruction; `secrets`
  deleted (copies remain on `/mnt/xs`). Its by-id path carries a **fake bridge
  serial** (`usb-ATA_ST320LT020-9YG14_0123456789ABCDE-0:0`) — a cheap enclosure that
  doesn't pass the real serial through, so guard on the UUID too, not the by-id path
  alone.
- **The mirror completed and verified 2026-07-31.** `rsync -aHAX` finished 17:10
  `rc=0` after 2h40m at ~68 MB/s. The three checks that matter: **68932 files in
  source and 68932 on the mirror, 0 missing and 0 extra** (full-tree file-level
  equality); every one of the 10 tracked directories byte-equal; and **`Media`
  deduped to 488G on the destination rather than 735G**, which is the proof `-H`
  actually preserved the hardlinks. The only DIFF was `Media/config` — 6 jellyfin
  resized-image cache JPEGs plus 3 Android-TV client upload logs written *during* the
  copy, src>dst with nothing extra on the destination. A delta `rsync` of that one
  directory (11 files, 7.9 MB) cleared it. **Chasing byte-exactness on `Media/config`
  is futile while jellyfin runs** — verify it by *which* files differ, not by the
  byte total. Note the guard worked as designed: `public-reformat2.sh` refused to
  touch `/mnt/public` on the DIFF verdict and had to be re-released by hand after
  re-verification, which is the correct failure direction.
- **Both job logs are root-owned** (the scripts run under `sudo`), so appending a
  hand-adjudicated verdict needs `sudo tee -a` — a plain `>>` fails with *Permission
  denied* and the relaunched job silently re-reads the stale verdict.
- **The `laptop-music` restic repo was verified fully redundant before deletion**:
  zero of its 11904 entries are missing from
  `/mnt/xs/music-from-g513ie/PicardedMusic` (13665 entries), and all 1169 artist
  dirs are present. **`PicardedMusic` is GONE from desktop** (checked live) — that is
  **deliberate**: as of 2026-07-31 latitude is where the music collection lives, and
  the plan is to reorganize it with **airdrome**, serve it with **navidrome**, and
  mirror it onto a backup disk. Until that mirror exists, `/mnt/xs` +
  `~/staging/music` are its only two copies and that Ventoy stick is load-bearing,
  not scratch.
  Related: 19 of the 22 harvested WiFi profiles carry `<protected>false</protected>`
  plaintext PSKs, and desktop still has 20 live WLAN profiles covering all but
  `ipheoryt`, `J.Epstein` and `IDNET_41_RP` — a phone hotspot, an open network, and
  a repeater of a PSK already held. Nothing of value was unique to that backup.
- **Backup strategy decided 2026-07-31: mirror the bulk, restic almost nothing.**
  The axis is *can this be re-derived, and does a wrong write propagate?* — a mirror
  covers drive death, only versions cover your own `rm`, a bad app write, or bitrot.
  Mirror (`rsync -aHAX`): the 2024 archive, `Media/movies|torrents|tv|xxx`,
  `ImmichMedia/library`, `music-from-g513ie`, the GoPro video, `qb`. Versions
  genuinely needed for only ~1.5 GB: `Media/config` (jellyfin `encoding.xml`, the
  *arr SQLite DBs) and `secrets` — at that size a dated `tar.gz` + rsync beats
  restic, so **no restic repo is planned at all** and the old `immich-media` /
  `immich-postgres` repos are not being recreated. Two hard constraints: **`-H` is
  mandatory** (Media unique 523059206143 B vs 788634637218 B summed per-directory —
  265 GB of hardlink overlap, so without `-H` the target needs 734 GiB instead of
  487), and **never `rsync --delete` the immich library bare** — it is mutable and a
  photo deleted in the UI propagates; use `--backup-dir=…/deleted-$(date +%F)`.
- **Immich makes its own `pg_dumpall` backups — do not build a second mechanism.**
  Defaults (not stored in `system-config`, so absent from the overrides row):
  enabled, `0 02 * * *`, keep last 14. Filenames carry both versions —
  `immich-db-backup-<ts>-v<immich>-pg<pg>.sql.gz`, ~218 MB each, ~2.9 GB for 14.
  **Two separate mechanisms exist and must be pointed at the same place:** the UI
  backup writes to `/data/backups` *inside `immich_server`* (i.e.
  `UPLOAD_LOCATION/backups`), while `DB_BACKUPS_LOCATION` only mounts
  `immich_postgres:/backups` (`homeserver/immich/compose.yml`). Changing the env var
  alone moves nothing the UI writes. `bebf134` adds
  `${DB_BACKUPS_LOCATION}:/data/backups` to `immich-server` so both agree; on
  latitude it is **`/var/backups/immich-db` on the root NVMe (`nvme1n1`)**, a
  different physical disk from the database itself (`/mnt/immich`, `nvme0n1`) and
  never `nofail`, so there is no silent-write-into-an-unmounted-mountpoint risk.
  A stale pre-move copy sits at `/mnt/immich/immich-db-backups-old-20260731` —
  deliberately moved *out* of `library/` so immich never scans it as assets.
  Verified end-to-end at the 2026-07-31 02:00 run: dump landed in the new path
  (`…20260731T020000-v3.1.0-pg14.19.sql.gz`, 218950716 B, `gzip -t` clean) and
  retention pruned the oldest to hold at 14 files / ~3.1 GB. **Immich writes the
  dumps as `root:root` 644** — a non-root copy job can read them but cannot prune
  or rewrite, so size any mirror/rotation step accordingly.
  `.env` is gitignored (`**/.env`), so the path itself is machine-local; the
  tracked `.env.dist` still carries g513ie's `D:\` Windows paths.
- **Immich's realtime (on-the-fly HLS) transcoding 404s for every asset ingested
  before the `CreateAudioVideoTables` migration, and enabling it does not
  backfill.** Symptom: `GET /api/assets/<id>/video/stream/main.m3u8` returns
  `{"message":"Asset metadata is not yet ready for streaming","statusCode":404}`
  and video simply does not load in the browser. Cause:
  `VideoStreamRepository.getForMainPlaylist` **inner**-joins `asset_exif`,
  `asset_video` and `asset_keyframe`; the latter two are written only by the
  **Extract Metadata** job (`metadata.service.js`, the `keyframes`/`keyframePts`
  fields). On latitude 2026-07-31 those tables held **4 rows against 8729 video
  assets** — the 4 being uploads from 2026-07-03..07-12, i.e. after the feature
  landed. `ffmpeg.realtime.enabled` defaults to **false**, so this only bites once
  someone turns it on. Diagnosing it needs
  `logging: {"enabled":true,"level":"debug"}` in the `system-config` row — immich
  logs no successful requests at the default level, so an empty log proves nothing.
  Backfilling means **Extract Metadata → All**, which re-reads every original,
  including the whole 712 GB 2024 archive across the flaky dock-A USB bridge — do
  it deliberately, not casually. Falling back is one flag
  (`{ffmpeg,realtime,enabled}` → `false`); the pre-encoded `encoded_video` files
  exist for 8715 of 8729, so playback works immediately without it.
- **Immich's hardware-accel setting lives in the DATABASE, not compose.**
  `system_metadata` key `system-config`, `jsonb` column, path `{ffmpeg,accel}`.
  After the migration it was still `nvenc` (the G15's RTX 3050 Ti) even though
  `compose.yml` had been switched to `service: quicksync` — a compose commit cannot
  carry it. Same class of trap as jellyfin's `encoding.xml`. Set to `qsv` +
  `temporalAQ:false` 2026-07-31; old row saved at
  `~/immich-system-config.bak-20260731-0051.json`. Note only *overrides* live in
  that row, so an absent key means "default", not "unset" — and **immich rewrites
  the row on startup**, dropping keys that equal the default and adding ones it has
  migrated in (it dropped the `temporalAQ:false` and `accelDecode:true` written by
  hand, and added `realtime:{enabled,resolutions}`). That rewrite is a handy proof
  the app actually read your edit; it also means a hand-set value silently
  disappearing from the row does not imply the *effective* value changed. Because
  `realtime` was added rather than dropped, the rule is not purely drop-defaults —
  confirm effective values in the UI rather than trusting the row.
  **Verify accel with a real encode, not a codec list:**
  `docker exec immich_server ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30:duration=2 -c:v hevc_qsv -f null -`
  (passed; iHD driver, VA-API 1.23.0, container runs as root so `/dev/dri` perms
  are moot).
- **The restic password for the homeserver repos is already tracked** (it was the
  password for the now-destroyed `immich-media-2024` too) — dotfiles allow-line
  `!/g513ie-prod-config/vps/backup/homeserver/pass.txt` (13 bytes), harvested off
  g513ie. `~/my/vps/backup/homeserver/pass.txt` on latitude is now a **symlink**
  at it, so the live path resticprofile reads (`RESTIC_PASSWORD_FILE: "pass.txt"`,
  relative to the config dir) and the version-controlled copy are one byte-source.
  Don't create a second copy — the vps repo gitignores `**/pass.txt`, and
  `~/.gitignore` line 122 says explicitly not to track two.
- **On a read-only restic repo, always pass `--no-lock`.** `restic snapshots`
  against `/mnt/immich-2024-backup` (mounted `ro`) hung >15 min with no output and
  no error, because it could not create its lock file; `--no-lock` returns in
  seconds. Same for `cat config`.

