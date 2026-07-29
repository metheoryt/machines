# Storage pool hardware baseline — latitude, 2026-07-29

Measured live on `latitude5520` (Debian 13, kernel 6.12.96) with
`smartmontools 7.4`, immediately after the 320G was swapped out for the new 6TB.
Written to be the input to the data-layout decision (§7 of
`../plans/2026-07-28-latitude-wipe-harvest.md`), which was previously being made
on capacity numbers alone with no drive-health data at all.

**Every identifier here was read off the live box. Do not retype disk paths from
memory — see H1 in the wipe-harvest plan.**

## 1. The headline: the new 6TB is not the drive that was ordered

Ordered: **WD Purple 6TB, `WD63PURZ`** — a new 5400-rpm-class surveillance drive
with a 3-year warranty and 180 TB/yr workload rating.

Delivered and now seated in Dock B bay 0:

| Field | Value |
|---|---|
| Device Model | **`HUS726060ALE611`** — HGST Ultrastar 7K6000, 6TB |
| Serial | `NAGUNU1X` |
| Firmware | `APGL0001` |
| Rotation | **7200 rpm** (not Purple's 5400 class) |
| Form factor | 3.5 in |
| Sector size | 512 logical / **4096 physical** (512e) |
| SATA | 3.1, 6.0 Gb/s negotiated |
| **Power_On_Hours** | **74485 — 3104 days, 8.50 years** |
| Power_Cycle_Count | 44 |
| Start_Stop_Count | 133 |
| Load_Cycle_Count | 1046 |
| Logical Sectors Written | 5 904 970 852 764 → **3.02 PB** (unit defined by the devstat log, see below) |
| Newest self-test in log | **8852 hours** — i.e. ~65 600 hours / 7.5 years ago |

### The identity and the age are corroborated four independent ways

This matters because the drive carries a physical **WD Purple sticker** and was
sold as new (§1.1), so the evidence had to be strong enough to dispute a sale.
No single source is being trusted:

| Source | Reports |
|---|---|
| Kernel SCSI inquiry — `/sys/block/sdf/device/model` | `HUS72606` `0ALE611`, rev `0015` — read by the kernel, no smartctl involvement |
| `lsblk` | `HUS726060ALE611  NAGUNU1X  5.5T  0x5000cca242cbab63` |
| **WWN `0x5000cca242cbab63`** | OUI **`000cca` = Hitachi Global Storage Technologies**, burned in at manufacture. WD's own OUI is `0014ee`. |
| SMART vendor attributes | POH 74 485, Power_Cycle 44, Load_Cycle 1046 |
| **ACS Device Statistics log** (a separate log page from the vendor attributes) | Power-on Hours **74 485** · **Spindle Motor Power-on Hours 74 419** · **Head Flying Hours 74 419** · Head Load Events 1046 · Lifetime Power-On Resets 44 · Logical Sectors Written 5 904 970 852 764 |

Two consequences:

- **`Head Flying Hours 74 419` is the decisive figure.** It is not a
  reinterpretable counter — the platters physically spun under flying heads for
  74 419 hours, 8.49 years. Every counter across two independent log pages agrees
  to the hour, which also means SMART was *not* tampered with. Whoever sold this
  drive did not bother faking the firmware; they applied a label.
- **The earlier "unit-unverified" caveat on the petabyte figure is resolved.** It
  was raised because vendor attribute 241 has no decode for this model (the drive
  is `Not in smartctl database 7.3/5528`). But the Device Statistics log's
  *Logical Sectors Written* is a standardised ACS field with defined units, and
  the drive reports 512-byte logical sectors. 5 904 970 852 764 × 512 = **3.02 PB
  written**, confirmed rather than inferred — 11.3 MB/s sustained across the
  drive's whole life, ~356 TB/yr, inside the 7K6000's 550 TB/yr rating.

`hdparm -I` returns nothing through these USB bridges — hdparm has no SCSI-ATA
translation layer, unlike smartctl's `-d sat`. Not a gap in the evidence, just a
tool that does not apply here.

It is a different product line from a different era. HGST was absorbed by WD, so
"WD" is not strictly wrong, but the Ultrastar 7K6000 is an enterprise
nearline drive that shipped around 2015 — its warranty expired years ago.

**The wear profile is unmistakably ex-datacenter:** 74 485 hours of power-on
against only 44 power cycles and 1046 load cycles. It was spun up, left running
for eight and a half years, and never parked. That is the *good* kind of duty
cycle, and it explains the surprisingly clean surface below — but 8.5 years of
service life is 8.5 years regardless of how gently it was accumulated.

### The surface itself is genuinely clean

| Attribute | Raw |
|---|---|
| Reallocated_Sector_Ct | 0 |
| Reallocated_Event_Count | 0 |
| Current_Pending_Sector | 0 |
| Offline_Uncorrectable | 0 |
| Spin_Retry_Count | 0 |
| Seek_Error_Rate | 0 |
| UDMA_CRC_Error_Count | 0 |
| Raw_Read_Error_Rate | 4 |
| Temperature | 32 °C now, max-ever 55 °C |
| ATA error log | **No Errors Logged** |
| Health (attribute-based) | PASSED |

Zero reallocated sectors, zero pending, zero uncorrectable and an empty ATA error
log after 8.5 years is a healthy platter set. Whatever this drive did, it was not
abused.

## 1.1. Conclusion: the drive is relabelled, and it goes back

Confirmed with the buyer 2026-07-29: it was **bought as new**, and **the physical
drive carries a WD Purple sticker.** That resolves what SMART alone could not.

A genuine WD Purple 6TB reports a `WDC WD63PURZ-…` model string and a WWN under
WD's `0014ee` OUI. This drive reports `HUS726060ALE611` under Hitachi's `000cca`
OUI, from four independent sources including the kernel's own SCSI inquiry. Those
are different products from different production lines — WD Purple is a
consumer surveillance line; the Ultrastar 7K6000 is a 2015-era enterprise nearline
drive. No rebadging explains it.

**So the label is fake or transplanted, and this is a misrepresented sale.** The
remedy is a return or chargeback, not a burn-in. Note also what was *not* faked:
every counter agrees across two independent log pages, so the seller did not
touch the firmware — the fraud is a sticker over an untouched 8.5-year-old disk.

**Do not run the 22-hour `badblocks` on it.** It cannot change the outcome —
identity and 74 419 head-flying-hours already decide it — and it spends a day of
the return window.

### Evidence to keep, if the sale is disputed

- The four-source identity table above, plus the raw `smartctl -d sat -i -A -l
  devstat` output.
- **The sticker's serial against the firmware's `NAGUNU1X`.** This is the
  strongest single artefact. WD serials are `WD-`/`WX`-prefixed — the genuine WD
  drive in this same pool reads `WD-WX91E575272W`. `NAGUNU1X` is HGST format. If
  the sticker shows a WD-format serial, the label demonstrably belongs to a
  different physical drive.
- WD's warranty-check page against the sticker serial: a genuine `WD63PURZ`
  returns the product and a warranty end date. An error, or a different model,
  shows the serial is fabricated.
- Photographs of the sticker (look for re-application tells — bubbles,
  misalignment, adhesive residue, wrong font) alongside the SMART output.

### If it is kept anyway

Should the dispute fail and the drive be kept, it is *functional* — clean surface,
no logged errors, and enterprise drives that reach 8.5 years with zero
reallocations often keep going. It would then be a **bulk-media and staging disk
only**. At 8.5 years it must never be the sole copy of anything, per §5.

Two deliberate consequences of that decision:

1. **The 22-hour `badblocks` burn-in is on hold.** Running it would put another
   ~12 TB of I/O on the drive, consume a day, and weaken the "this is not what I
   ordered" position while the return window is open. Identity and age already
   settle the decision; surface quality is not the deciding variable.
2. **If the drive is knowingly kept** — e.g. it was sold as recertified at a
   price that reflects it, and the seller will not remedy — then it is usable,
   but only under the constraint in §5: it must never be the sole copy of
   anything. A clean 8.5-year-old Ultrastar is a reasonable *bulk media* disk and
   a bad *only* disk.

## 2. Dock topology — the bay map

Two identical externally-powered 2-bay docks, both confirmed to accept 3.5"
drives. The USB bridge serial identifies the dock and the `-0:N` LUN suffix
identifies the bay, which makes "which physical bay is this device" answerable
without opening anything:

| Dock | Bridge serial | Bay 0 (`-0:0`) | Bay 1 (`-0:1`) |
|---|---|---|---|
| **A** | `6702002103E1` | WDC WD10SPZX (`sdd`) | ST1000LM024 (`sde`) |
| **B** | `670200210032` | **HUS726060ALE611 6TB** (`sdf`) | HGST HTS541010A9E680 (`sdg`) |

`/dev/sd*` letters are not stable across replug — the 6TB inherited `sdf` from
the 320G it replaced. Always address disks by `/dev/disk/by-id/usb-*`.

## 3. Link and bus facts

- Both docks sit on **bus 004**, a single 10 Gbps xHCI root hub, each
  negotiating **5000M (USB 3.0)**. Throughput across the two docks is *shared,
  not additive*.
- Both docks bind `usb-storage`, **not `uas`** — no command queueing. Fine for
  sequential bulk, weaker under concurrent random I/O.
- **Bus 002 (the second 10 Gbps root hub) is now completely free** — the Ventoy
  install SSD has been unplugged. That is the best home for anything that should
  not contend with the docks.
- SMART passthrough over these bridges is **partial**: `-d sat` returns the full
  attribute table, capability page and error/self-test logs, but the `SMART
  STATUS` command is rejected (`Incomplete response, ATA output registers
  missing`), so `-H` falls back to an attribute-based assessment. Sufficient for
  monitoring; `badblocks` does not depend on it.
- The bridges **mask the physical sector size** — `/sys/block/sdf/queue/
  physical_block_size` reports 512 while the drive reports 4096. Partitioning
  tools cannot auto-detect correct alignment here, so rely on the standard 1 MiB
  alignment default rather than any 4K auto-detection.

## 4. The existing pool — health baseline

All four incumbent drives, measured the same session. This is the first
health data recorded for any of them.

| Drive | Bay | Current role | POH | Surface | Notable |
|---|---|---|---|---|---|
| **WDC WD10SPZX-21Z10T0**<br>`WD-WX91E575272W` | A0 | `E:` years archive `admin`, **664G, only online copy** | 28 796 (3.3 y) | 0 realloc / 0 events / 0 pending / 0 uncorr / 0 seek / 0 read-error — **cleanest surface in the pool** | **UDMA_CRC 144, age unknown** (see below); Start_Stop 91 599; Load_Cycle 122 818 |
| **HGST HTS541010A9E680**<br>`670200210032` bay 1 | B1 | `H:` restic `immich-media-2024`, 650G; designated off-site copy | 27 816 (3.2 y) | 0 pending / 0 uncorr, **23 realloc events** (0 sectors) | **Load_Cycle 639 701 — past the ~600k typical rating**; Start_Stop 116 800; Power_Cycle 14 413; CRC 18 |
| **ST1000LM024 HN-M101MBB**<br>`S2U5J9ECA34541` | A1 | `G:` restic `immich-media` + `immich-postgres`, 159G | 25 361 (2.9 y) | 0 realloc / 0 events / 0 pending / 0 uncorr / 0 seek; CRC 0 | **Most wear indicators in the pool**: `Raw_Read_Error_Rate` raw 1 578, `Calibration_Retry_Count` / `Load_Retry_Count` 897, `G-Sense_Error_Rate` 783, `Spin_Up_Time` normalised 089 (worst 076), **max-ever temp 63 °C**, Load_Cycle 342 862. Samsung Spinpoint M8 family with a weak field record |
| **ST320LT020-9YG142**<br>`W047MMKS` | *(removed)* | `F:` `Public`, 177G — retired, shelved | 36 153 (4.1 y) | 0 realloc / 0 pending / 0 uncorr | 10 ATA errors but **newest at 13 478 h — 2.6 years stale**; `Reported_Uncorrect` 11 and `Command_Timeout` 299 both historical; past thermal excursion (`190 In_the_past`) |

### What that table changes

- **The drive being retired is healthier today than one being kept.** The 320G's
  scars are all 2.6 years old with a clean surface since; the ST1000LM024 carries
  the pool's only cluster of live wear indicators.

  > Do **not** hang that judgement on `Multi_Zone_Error_Rate 001`, as an earlier
  > revision of this document did. That attribute is misscaled on the Samsung
  > Spinpoint M8 family and its threshold is `000`, so it can never trip
  > `WHEN_FAILED` — inferring degradation from its normalised value is the same
  > mistake as reading "still accruing" into the CRC counter below. The case
  > stands on converging *raw* counters instead, none of them ambiguous:
  > 1 578 raw read errors, 897 calibration/load retries, 783 G-sense shock
  > events, spin-up time degraded to 089 with worst-ever 076, and a max-ever
  > 63 °C. Its surface is still clean (0 realloc / 0 pending / 0 uncorrectable) —
  > this is a *mechanism* wearing out, not a platter going bad.
- **The years archive's only online copy shows 144 CRC errors — but their age is
  unknown, and that distinction was initially overstated here.** An earlier
  revision of this document called the count "still accruing," reasoning from
  `VALUE 200` against `WORST 199`. That divergence only proves the counter
  degraded at *some* point across 28 796 power-on hours; it does not establish
  that it is ongoing. CRC counters are cumulative and never reset, so a single
  reading cannot distinguish 144 errors last week from 144 during a dock reseat
  years ago — and a dock was reseated recently. **Only a delta under load
  settles it.**

  CRC errors are interface corruption (cable, connector, bridge PHY, bay
  contacts), never a platter defect. They are detected and retried rather than
  silent, so the risk they carry is a device that drops mid-copy, not corrupted
  data.

  **Test protocol, started 2026-07-29 19:21 (`~/disk-baseline/` on latitude):**
  baseline recorded at CRC **144** / POH 28 797 for the WD10SPZX and CRC **0** /
  POH 25 361 for its dock-mate, then a non-destructive full-surface read
  (`dd … of=/dev/null conv=noerror,sync`, ~2.3 h at ~113 MB/s) to exercise the
  link under sustained load. Re-read attribute 199 afterwards:

  - **Delta 0** → the 144 is historical scar tissue from reseats. Nothing to fix.
  - **Delta > 0** → the link is degrading now. Swap the two drives between bays
    A0/A1 and repeat: if the delta follows the drive it is the drive's connector,
    if it stays with the bay it is the bay's PHY. The shared path — cable and
    upstream bridge — is already exonerated, since the dock-mate on the same
    cable reads CRC 0.

  The sweep does double duty: ~113 MB/s sustained is near-native for this drive,
  which argues against severe link degradation, and it is the first end-to-end
  readability check the 664G archive has ever had.
- **Every incumbent shows heavy head-parking wear** (Start_Stop 91k / 116k / 23k;
  Load_Cycle 639k / 122k). The docks park aggressively. Whatever 6TB ends up
  seated should have APM checked (`hdparm -B`) and aggressive spindown disabled
  before it accumulates the same wear over the next three years.
- **`smartd` is not configured.** None of these numbers was being watched; the
  639k load cycles and 144 CRC errors accumulated unobserved. Recording the
  baseline is only half the fix.

## 5. Layout conclusions

Capacity was never the binding constraint — §7 already established that ~1.5–2 TB
of payload fits a 6TB comfortably, and that a whole-disk mirror is impossible
against a 3 × 1TB backup pool (2.79 TB). Health data adds the ordering:

1. **No dataset's only copy belongs on an 8.5-year-old disk.** If the Ultrastar
   stays, it is a bulk-media and staging disk, and the irreplaceable data —
   `admin` years archive, Immich `upload` + `profile`, `Media/config` — keeps a
   second copy on the 1TB pool at all times.
2. **Rank the backup pool by measured health, not by size.** Best surface first:
   WD10SPZX (fix its link first) → HGST (worn, and see the caveat below) →
   ST1000LM024 (weakest keeper). The years-archive backup should not land on the
   ST1000LM024.

   > Caveat on that ordering: the HGST reports `Reallocated_Sector_Ct 0` but
   > `Reallocated_Event_Count 23`. That combination is **unexplained, not
   > benign** — on some firmware attribute 196 counts remap *attempts* including
   > ones that recovered in place, but this has not been confirmed for this model.
   > If those 23 are genuine remap events, the HGST's surface is weaker than its
   > 0-sector count implies and it may not deserve second place. Resolve with a
   > `smartctl -t long` before assigning it the years-archive backup.
3. **The off-site copy is on the pool's most cycled drive.** The HGST is past its
   nominal load-cycle rating and is the copy nobody inspects for months. If it
   goes off-site, run `restic check --read-data` before it leaves and on every
   rotation.
4. **Resolve the A0 CRC question before the 664G consolidation copy**, not after —
   and note that "resolve" may mean "confirm it is historical and do nothing."
   **The WD10SPZX is not a retirement candidate.** It has the cleanest surface in
   the pool and its only fault is an interface counter; retiring it would discard
   the best disk over a connector. Its long-term role is the years-archive backup
   target, once a real 6TB exists and `admin` moves off it.
5. ~~**`/etc/fstab` has no data-disk entries at all**~~ — **done 2026-07-29, see
   §7.** Root, ESP and swap only; every `/mnt/*` mount was transient, so a reboot
   brought latitude up with empty mount points and any service pointed at
   nothing. UUID + `nofail` entries were a prerequisite before services come up,
   independent of the layout choice.
6. **Reserve bus 002 for the primary disk.** Both docks share bus 004; putting
   the primary there makes it contend with its own backup targets during copies.

## 6. Correction to an existing doc

`../plans/2026-07-28-latitude-wipe-harvest.md` §2 ("Server, booted 2026-07-28")
maps the models to the wrong volumes — it records the HGST as `E: Immich 2024`
(the `admin` archive) and the WD10SPZX as `H: Immich 2024 backup`. Live contents
say the opposite: `sdd2` (WD10SPZX) holds `admin`, `sdg2` (HGST) holds
`backup-homeserver`. The migration plan's own Data Inventory table is correct;
§2 is the outlier. Corrected in place, since that document exists specifically so
disk identifiers are not retyped from memory.

## 7. Mount policy and the rules for hot-swapping

### 7.1. What got written (2026-07-29)

`/etc/fstab` now carries UUID entries for the three volumes that were attached at
the time. Backup of the original at `/etc/fstab.bak-20260729`.

| UUID | Mount point | Device then | Options |
|---|---|---|---|
| `5A3014505F7576FA` | `/mnt/immich` | Kingston `nvme0n1p1` | `ro,noatime,uid=1000,gid=1000,iocharset=utf8,nofail` |
| `EAA6CAAEA6CA7A99` | `/mnt/immich-2024` | Dock A0, `sdd2` | same + `x-systemd.device-timeout=60` |
| `9CCED7D2CED7A2B6` | `/mnt/immich-backup` | Dock A1, `sde2` | same + `x-systemd.device-timeout=60` |

Choices, and why:

- **`ro` on all three.** Every one holds data whose restore has not been verified
  yet. Read-write is a deliberate later step, never a side effect of a reboot.
- **`nofail` on all three, including the internal NVMe.** The Kingston is slated
  for an ext4 conversion, which changes its UUID; without `nofail` the first boot
  after the reformat hangs on a UUID that no longer exists.
- **`x-systemd.device-timeout=60`, not 10.** `nofail` alone already removes the
  mount from `local-fs.target`'s hard requirements, so a missing device cannot
  block boot at any timeout. What a short timeout *adds* is a window a cold dock
  spinning up can miss — boot completes, the mount is silently absent, nothing
  retries. That is the exact trap these entries exist to prevent.
- **`pass 0`.** `ntfs3` has no fsck; never let boot try.

**Verified:** `systemctl daemon-reload` + `mount -a` clean, all three
`mnt-*.mount` units `active mounted`. **Not yet verified:** actual boot behaviour
and late-attach auto-mount — both need a reboot or a dock power-cycle, and the
CRC sweep on Dock A was in flight. Two open items:

1. **Reboot test** after the sweep finishes.
2. **Does a dock powered on *after* boot mount itself?** `systemd-fstab-generator`
   does wire device→mount dependencies, but this has not been confirmed on Debian
   13 for a late-appearing USB device. If it does not, the fix for the two dock
   entries is `noauto,x-systemd.automount,x-systemd.idle-timeout=600` — an
   automount unit that mounts on first access. Dock B is the safe test bed: it is
   already powered off and shares nothing in flight with Dock A.

Dock B's two volumes have **no entry yet** — the dock was off, so their UUIDs
could not be read (the vanished devices are absent from the `blkid` cache too).
A `TODO` block in `/etc/fstab` names the two drives, their intended mount points
and the capture command.

**Follow-up:** these lines were hand-typed into `/etc/fstab`, which is exactly the
kind of state this repo exists to make survivable. They belong in a `provision/`
step so a reinstall reproduces them. Not a blocker — services need the mounts
now — but recorded so it is not forgotten.

### 7.2. The stale-mount failure, observed live

Two mounts were found pointing at devices that no longer existed:
`/mnt/public` on `sdb1` and `/mnt/immich-2024-backup` on `sdc2`. `findmnt` listed
both as mounted; `blkid` had no entry for either; `ls` returned EIO. `dmesg`
reconstructs the whole sequence and it is worth keeping, because it demonstrates
the mechanism rather than asserting it:

```
[47615] dock B attached:      sdf (320G, 1 partition) + sdg (HGST, 2 partitions)
[51860] usb 4-1: USB disconnect          <- dock B powered off
[51896] dock B back:          sdf = 6TB "Very big device", sdg = HGST
[52728] usb 4-1: USB disconnect          <- dock B off again, 6TB pulled for return
```

The drives were `sdb` and `sdc` at boot and got mounted. The dock was then cut
without unmounting. Two consequences followed:

1. **The mounts went stale, not away.** The mount table kept the entries, so
   every path under them returned EIO while still *looking* mounted to anything
   that reads `/proc/mounts` — including a naive health check.
2. **The stale mounts kept `sdb` and `sdc` allocated.** The kernel does not
   release a `sd` letter while the block device is still referenced by a mount.
   So the *same two drives*, replugged, came back as `sdf` and `sdg`. That is the
   H1 renumbering hazard in the migration plan, caught in the act — and the
   reason nothing may ever be addressed by `/dev/sdX`.

Both were cleaned with a plain `umount` (read-only, nothing dirty to flush;
`umount -l` is the fallback when a process holds the path). No I/O errors
anywhere in `dmesg` — nothing was damaged, because the mounts were `ro`.

### 7.3. Rules for the connected disks

**Yes, the disks are hot-swappable — the docks are USB, and USB is designed for
it. What is not hot-swappable is a *mounted filesystem*.** Every rule below
follows from that one distinction.

1. **Unmount before pulling a drive or cutting dock power. Always, both bays.**
   ```
   sudo umount /mnt/immich-2024 /mnt/immich-backup   # dock A, both bays
   sync                                              # only matters for rw mounts
   ```
   Powering a dock off is identical to yanking both its drives at once.
2. **`ro` protects the data, not the mount table.** A yanked read-only NTFS
   volume loses nothing — there is nothing dirty. It still leaves the stale mount
   and still holds its `sd` letter. §7.2 is what that looks like.
3. **A yanked *read-write* `ntfs3` volume is a different matter.** The NTFS
   journal is left dirty; Windows will demand `chkdsk` and Linux may refuse
   anything but a read-only remount. This is a live concern the moment any of
   these volumes goes `rw`.
4. **Never hot-swap while a long job is touching the drive** — `dd`, `badblocks`,
   `restic`, a copy. Beyond killing the job, a disconnect on that dock's cable
   generates `UDMA_CRC` events, which corrupts the very measurement the sweep in
   §4 exists to take.
5. **Expect the letters to move, and never depend on them.** Address disks as
   `/dev/disk/by-id/usb-<bridge-serial>-0:<bay>` and mount by `UUID=`. The
   `by-id` path also encodes which physical bay a device is in (§2).
6. **After a replug, let udev settle before acting**: `sudo udevadm settle`, then
   `lsblk`. If a `by-id` link is missing for an attached device, something did
   not finish — do not start writing.
7. **A mount that is present is not a mount that works.** `findmnt` alone cannot
   tell a live mount from a stale one; the cheap probe is
   `ls "$m" >/dev/null 2>&1`, which returns EIO on a vanished device. Anything
   that reports disk health needs this check, not just a mount-table read.

## 8. Retirement, shelving, and how long a shelf keeps data

### 8.1. Is any drive unfit even to shelve?

**No.** Shelving asks only that a drive read back once, later, and every drive in
the pool reports **0 reallocated sectors, 0 pending sectors and 0 offline
uncorrectable** — including the 320G already pulled and the 8.5-year-old
Ultrastar. A drive genuinely unfit to shelve would show pending sectors, growing
reallocations, or a real `SMART STATUS` failure. Nothing here does.

The useful distinction is different, and it is between **service** and **shelf**:

| Drive | Fit to shelve? | Fit for service? |
|---|---|---|
| **WD10SPZX** (A0) | yes | **yes — best in pool.** Cleanest surface; only fault is an interface counter |
| **ST320LT020** (pulled) | yes | no, and irrelevant — 177G, already shelved with data intact |
| **HGST HTS541010A9E680** (B1) | yes | **not for a role nobody inspects.** Past its ~600k load-cycle rating; the 23 realloc events are still unexplained |
| **ST1000LM024** (A1) | yes | **no — first out of service.** The pool's only cluster of live wear indicators (§4) |

So: **the ST1000LM024 is the retirement candidate**, not the WD10SPZX. It is
physically fine to shelve — its surface is clean — but it should stop being a
*live backup target*, which is what it is today (`immich-media` +
`immich-postgres`, 159G). It cannot be retired until that 159G has a second home,
which needs the 6TB. Until then it stays in service and is simply the drive whose
data must never be the only copy.

### 8.2. How long does a shelved drive keep its data?

**Practical answer: plan on 5 years, verify every 12 months, and rewrite every
3–5 years.** The reasoning matters more than the number, because two different
clocks are running and the slower one is the one people worry about.

- **Magnetic decay is the *slow* clock.** Remanence on a shelved platter is good
  for well over a decade at room temperature. No manufacturer publishes an
  archival retention spec for HDDs — anyone quoting one is quoting a guess. It is
  temperature-sensitive: a hot attic ages the magnetisation far faster than a
  cupboard.
- **Mechanics are the *fast* clock, and they are what actually kills shelved
  drives.** Lubricant migrates off the spindle bearing and the head-slider air
  bearing; the head can stick to the ramp or the platter (stiction); elastomer
  parts and the spindle grease stiffen. The common failure of a long-shelved
  drive is not corrupted files — it is a drive that will not spin up, or that
  spins up and dies within hours. This mode gets worse with idle time regardless
  of how cool and dry the storage is.
- **Reading does not refresh anything.** A read-only verify pass proves the data
  is still there and exercises the mechanism, but it does not rewrite a single
  magnetic domain. Only a *write* refreshes. To actually renew the recording,
  copy the contents off and back, or run a non-destructive read-write pass
  (`badblocks -n`, on a drive you have another copy of).

Concrete protocol for a shelved drive:

- **Every 6–12 months:** power it up, `smartctl -a` (watch POH, realloc, pending),
  and a full-surface read (`dd if=… of=/dev/null bs=1M conv=noerror,sync`) — the
  same sweep as §4. Failures found this way are recoverable *because another copy
  still exists*; failures found when you need the drive are not.
- **Every 3–5 years:** rewrite it, or migrate the data to a newer disk. Treat the
  drive as consumable and the data as the asset.
- **Storage conditions:** cool, dry, stable temperature, antistatic bag, no
  vibration, on a shelf rather than a garage or attic. Temperature *cycling* and
  humidity do more damage than a steady warm room.
- **Label the drive physically** with contents, date shelved and last-verified
  date. An unlabelled shelved drive becomes an unknown-provenance drive within a
  year, and then nobody dares wipe it or trust it.

**And the rule that outranks all of the above: a shelved drive is not a backup.**
It is one copy, unverified, unmonitored, and its failure is discovered only at the
moment it is needed. The 320G on the shelf is a *convenience* — a deferral of the
decision about what its 177G contains — not protection. Anything that matters
needs the 3-2-1 arrangement independently of what is on the shelf.
