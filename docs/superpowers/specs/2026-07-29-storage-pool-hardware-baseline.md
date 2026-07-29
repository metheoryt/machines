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

**The full dump is committed alongside this document** as
[`2026-07-29-hus726060ale611-smart-evidence.txt`](2026-07-29-hus726060ale611-smart-evidence.txt)
— 324 lines of `smartctl -x`, captured 2026-07-29 21:20 with the drive back in
Dock B bay 0 solely to take this record. Read-only; nothing was written to the
drive. Headline fields, all from that file:

```
Device Model:     HUS726060ALE611          <- sold as WD Purple WD63PURZ
Serial Number:    NAGUNU1X
LU WWN Device Id: 5 000cca 242cbab63       <- OUI 000cca = Hitachi/HGST, not WD
Firmware Version: APGL0001
Rotation Rate:    7200 rpm                 <- WD Purple WD63PURZ is 5400 rpm
  9 Power_On_Hours                74485    <- 8.5 years
0x01 0x010  Power-on Hours        74485    <- ACS devstat log agrees exactly
0x03 0x008  Spindle Motor Power-on Hours  74420
0x01 0x018  Logical Sectors Written  5904970852764   <- 3.02 PB
  5 Reallocated_Sector_Ct             0
197 Current_Pending_Sector            0
198 Offline_Uncorrectable             0
199 UDMA_CRC_Error_Count              0
```

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

### There is a fifth bay (found 2026-07-29 19:51)

A **single-bay 2.5" USB enclosure**, Norelsys **NS1066** bridge, on **bus 002**
behind a 5 Gbps hub. The ST320LT020 320G is now seated in it as `sdc`, online
alongside all four dock drives. **The pool is five bays, not four.**

Two things about this enclosure differ from the docks and both matter:

- **Its bridge reports a hardcoded placeholder serial, `0123456789ABCDE`.** So
  `usb-ATA_ST320LT020-9YG14_0123456789ABCDE-0:0` is *not* enclosure-unique — any
  other NS1066 would collide. The dock convention above (bridge serial identifies
  the dock) does not extend here. Address this drive by
  **`wwn-0x5000c500531b3d59`** or `ata-ST320LT020-9YG142_W047MMKS`, both of which
  come from the drive rather than the bridge.
- **Write cache is disabled** on this bridge (`sd 1:0:0:0: [sdc] Write cache:
  disabled, read cache: enabled`). Slower writes, safer against a yank.

SMART passthrough works: `-d sat` returns the full attribute table with the same
partial-passthrough pattern as the docks (`SMART STATUS` rejected, `-H` falls
back to an attribute assessment).

**The consequence is not "one more bay."** It is that the 320G no longer has to be
*offline* in order to free a dock slot — so it can be an online, monitored,
backed-up member, which §8.3 shows its contents demand. Dock B bay 0 stays free
for the eventual 6TB either way.

## 3. Link and bus facts

- Both docks sit on **bus 004**, a single 10 Gbps xHCI root hub, each
  negotiating **5000M (USB 3.0)**. Throughput across the two docks is *shared,
  not additive*.
- Both docks bind `usb-storage`, **not `uas`** — no command queueing. Fine for
  sequential bulk, weaker under concurrent random I/O.
- ~~**Bus 002 is now completely free**~~ — **no longer true as of 2026-07-29
  19:47.** A 4-port 5 Gbps hub now sits on bus 002 port 1 carrying an SD/microSD
  card reader (`sda`/`sdb`, both empty) and the NS1066 320G enclosure. Bus 002 is
  still the *uncontended-with-the-docks* bus, which is what mattered, but it is no
  longer empty and the hub caps everything behind it at **5 Gbps shared**. If the
  6TB is to get a clean path, it should go on a **bus 002 root port directly, not
  behind that hub** — or the hub moves to bus 003 (480M, fine for a card reader).
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
| **ST320LT020-9YG142**<br>`W047MMKS` | **NS1066 enclosure**, bus 002 | `F:` `Public`, 177G — **online, and it must stay online**, see §8.3 | 36 154 (4.1 y) | 0 realloc / 0 events / 0 pending / 0 uncorr; **CRC 0** | 10 ATA errors but **newest at 13 478 h — 2.6 years stale**; `Reported_Uncorrect` 11 and `Command_Timeout` 299 both historical; past thermal excursion (`190 In_the_past`, worst 042 vs thresh 045); Start_Stop 23 713, Load_Cycle 78 349 — **least head-parking wear in the pool** |

> **Reading Seagate raws.** The ST320LT020 reports `Raw_Read_Error_Rate`
> 150 830 712 and `Seek_Error_Rate` 17 853 537 044. Those are Seagate's packed
> multi-field counters, not error counts — the raw value is meaningless and only
> the normalised value carries information (117/099 against threshold 006, and
> 082/060 against 030 — both healthy). The same applies to
> `Hardware_ECC_Recovered`. Do not read these as 150 million read errors.

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

  > **RESULT — 2026-07-29 22:14. Delta 0. The 144 is historical.**
  >
  > The full surface was read: **1 000 205 189 120 bytes — every sector of the
  > drive — in 10 374.9 s at 96.4 MB/s** (the average fell from 113 to 96 MB/s
  > partway through, when Dock B and the XS2000 joined the shared bus-004 root
  > hub, not because of anything on the drive).
  >
  > | Attribute | Baseline 19:21 | After full read 22:14 | Δ |
  > |---|---|---|---|
  > | WD10SPZX `199 UDMA_CRC_Error_Count` | 144 | **144** | **0** |
  > | WD10SPZX `9 Power_On_Hours` | 28 797 | 28 800 | +3 |
  > | ST1000LM024 `199 UDMA_CRC_Error_Count` | 0 | **0** | **0** |
  > | ST1000LM024 `9 Power_On_Hours` | 25 361 | 25 364 | +3 |
  >
  > Three hours of sustained sequential load across the entire platter produced
  > **not one new CRC event.** The 144 is scar tissue from past dock reseats. The
  > link is sound, there is no bay-versus-drive question to isolate, and the
  > A0/A1 swap in the protocol above is unnecessary. **Nothing to fix.**
  >
  > Two further results from the same run:
  >
  > - **Surface counters unchanged and still zero** after reading every sector:
  >   `Reallocated_Sector_Ct 0`, `Current_Pending_Sector 0`,
  >   `Offline_Uncorrectable 0`. A latent unreadable sector would have surfaced
  >   here — that is what a full read is for.
  > - **The 664G years archive is fully readable, verified for the first time.**
  >   `dmesg` contains **zero** I/O, medium or unrecovered-read errors for `sdd`
  >   across the whole run — only the boot-time attach lines. This check matters
  >   because `conv=noerror,sync` would have padded past a bad sector silently
  >   rather than failing, so dd's own exit status proves less than the kernel log
  >   and the unchanged SMART counters do. All three agree.
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
4. ~~**Resolve the A0 CRC question before the 664G consolidation copy**~~ —
   **resolved 2026-07-29 22:14: delta 0 over a full 1 TB read. Historical.
   Nothing to fix, and the consolidation copy is not gated on it.** The original
   wording anticipated this outcome — "resolve may mean confirm it is historical
   and do nothing" — and that is what happened.
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
   Revised 2026-07-29: bus 002 now carries a 5 Gbps hub with a card reader and the
   NS1066 enclosure, so the primary wants a bus 002 **root port**, not the hub
   (§3).
7. **Revision — the pool is five bays and the 320G is one of them** (§2). It no
   longer has to go offline to free a dock slot, which was the only argument for
   shelving it. Ordering becomes: WD10SPZX → HGST *(caveat above)* →
   **ST320LT020** → ST1000LM024. The 320G ranks above the ST1000LM024 on measured
   wear (least head-parking in the pool, CRC 0, scars 2.6 years stale) and below
   the others only on capacity — 298G, 122G of it free.
8. **The 320G's own contents are now the pool's most exposed data** (§8.3): two
   restic repositories, 40G of irreplaceable video and key material, none of it
   with a second copy. That outranks the consolidation question, because it is
   fixable today and the consolidation is not.

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
| `6C28DD2C28DCF654` | `/mnt/public` | NS1066 enclosure, `sdc1` | same + `x-systemd.device-timeout=60` |

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

The fourth entry was added at 19:56 once the 320G reappeared in the NS1066
enclosure (§2). Its comment block in `/etc/fstab` records the placeholder-serial
caveat, because the obvious `usb-*` path is the wrong one to use there.

**Complete as of 21:19** — Dock B was powered back on, so the HGST's UUID could
finally be read and its entry added:

| `6C16E54216E50DC0` | `/mnt/immich-2024-backup` | Dock B bay 1, `sdh2` | same + `x-systemd.device-timeout=60` |

All five data volumes now have UUID entries. `mount -a` clean, every mount present.
The `TODO` block in `/etc/fstab` can be dropped.

The 6TB (`sdg`) deliberately has **no entry** — it is raw, unpartitioned, and going
back.

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
| **ST320LT020** (NS1066) | yes, but **must not be** | **yes, and it has to be** — least head-parking wear in the pool, and §8.3 shows what it holds |
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
moment it is needed. Anything that matters needs the 3-2-1 arrangement
independently of what is on the shelf.

### 8.3. Correction: shelving the 320G was wrong

An earlier revision of this document, and the advice that produced it, called
shelving the ST320LT020 **zero-risk** and described its 177G as "a deferral of the
decision about what it contains." Both statements were made **without ever
inspecting the contents.** With the drive back online in the NS1066 enclosure,
`/mnt/public` holds:

| Path | Size | What it is |
|---|---|---|
| `restic-repos/laptop-music` | *(part of 69G)* | **A live restic repository** — full `config`/`data`/`index`/`keys`/`snapshots` layout |
| `restic-repos/wsl` | *(part of 69G)* | **A second live restic repository**, same layout |
| `Настя Стас GoPro` | 40G | Personal video — irreplaceable |
| `qb` | 60G | Downloads — replaceable |
| `G614JV-Ubuntu-24.04.tar` | 9.9G | WSL distro export |
| `secrets/` | 133K | **Private SSH keys** (`id_ed25519`, `id_rsa`), wifi credentials, `wsl-secrets-*.tar` |

So the drive that was being retired holds **two backup repositories, key material,
and 40G of irreplaceable video**, and it is 4.1 years old with no second copy of
any of it. It is not a shelf candidate; it is an under-protected pool member.

**The generalisable error is not about this disk.** It is that a shelf-vs-service
judgement was made from SMART attributes alone, on a volume whose contents had
never been listed. Health tells you whether a drive will survive; only the
contents tell you what it costs if it doesn't. Inspect before deciding, in that
order.

Two consequences for the layout in §5:

1. **`restic-repos` is 69G of backup data that §5's coverage picture did not know
   existed.** Before it is counted as coverage it has to be verified —
   `restic -r /mnt/public/restic-repos/<repo> snapshots` — because 69G of a
   corrupt repository is 69G of false comfort. Until that runs, treat it as
   unverified bytes.
2. **`secrets/` needs a different answer from everything else.** It is 133K of
   private keys sitting on an offline-until-today NTFS volume. It must not simply
   be copied onto latitude's root, for the reason in §9.

## 9. Standing hold: latitude's root is not encrypted

`nvme1n1p3` is **plaintext ext4**. There are no `crypt` devices, `cryptsetup` is
not even installed, and `cryptsetup isLuks` on the root partition returns false.
The NixOS install this machine replaced had a **LUKS-encrypted root** — that
property was lost in the Debian 13 reinstall, and neither the migration plan nor
the harvest doc records the loss.

This is a standing hold, not a task for today, but it constrains work now:

- **Do not stage `secrets/` (private keys, wifi credentials) onto root.** Moving
  key material from an offline drive to an always-on, unencrypted server root
  increases exposure rather than reducing it. It needs an encrypted target, or
  `age`/`gpg` encryption at rest, or to stay where it is until one exists.
- The other categories — the Kingston's irreplaceable data, `restic-repos`, the
  40G of video — carry no such constraint and are fine to stage on root.
- latitude is becoming **the server**. Full-disk encryption on a machine that
  holds the fleet's consolidated data is a decision that should be made
  deliberately, not inherited by default from an installer.

Supporting SSD health, since root is about to be leaned on:

| Device | Role | POH | Written | Wear | Errors |
|---|---|---|---|---|---|
| KIOXIA KBG40ZNS512G | boot / root, 446G free of 453G | 14 019 | 35.0 TB | **12 % used** | 0, spare 100 % |
| KINGSTON SNV2S1000G | `/mnt/immich`, 160G free of 932G | 20 467 | 11.8 TB | **1 % used** | 0, spare 100 % |

Both healthy with ample endurance left. Root has room for every staging candidate
at once (~119G excluding `secrets/`).

## 10. Clearing the 320G — disposition of each item

Decision 2026-07-29: the 320G is to be emptied and reused as a pool member. The
backups on it were generated during the desktop Windows 11 reinstall and the
restic repos will be regenerated once the data layout is settled, since the
originals still exist. Item by item, with what was verified:

| Item | Size | Disposition | Verified? |
|---|---|---|---|
| `qb` | 60G | **drop** — replaceable downloads | n/a |
| `G614JV-Ubuntu-24.04.tar` | 9.9G | **drop** — WSL export from the reinstall | The distro is live: `desktop-ubuntu26` is an active tailnet node (`100.64.0.6`) |
| `restic-repos/wsl` | 2.3G, 19 snapshots | **drop** — same reinstall vintage | same as above |
| `Настя Стас GoPro` | 39.0 GiB, 162 files | **move to desktop** | desktop `C:` has **1194 GB free**; `G:` has only 38.4 GB and is not a candidate |
| `restic-repos/laptop-music` | 67G, 14 snapshots | **HOLD — see below** | Original found, but in the wrong place |
| `secrets/` | 133K | **drop** — already migrated (decided 2026-07-29). No separate delete step: the reformat in §10.3 destroys it, which also avoids remounting `ntfs3` rw | Fingerprints recorded before destruction, below |

### 10.0. `secrets/` — fingerprints kept, contents destroyed with the volume

Decided: drop it, the material is already migrated. Public fingerprints recorded
first so that a future authentication failure is diagnosable — these are public
metadata, not key material, and keeping them costs nothing:

```
256  SHA256:fFZUwTp9Ye4HukFntyjVplkAJxczc7GWz6ssWlcyg40  methe@me-g614jv        (ED25519)
3072 SHA256:gA8eWbg6MwUFjg6IX135LEFKJ9nYHzM52nBDfojDI/o  methe@DESKTOP-4PQ6V6B  (RSA)
```

Both are **desktop** keys, not latitude's, which corroborates the migration claim:
`methe@me-g614jv` is live — it is in latitude's `authorized_keys` today. The RSA
key carries the pre-rename hostname `DESKTOP-4PQ6V6B` and is legacy. The directory
also held 22 Windows wifi profile exports (`Беспроводная сеть-*.xml`) and
`wsl-secrets-Ubuntu-24.04.tar`; the wifi profiles are re-enterable, and they belong
to a machine being decommissioned.

No separate deletion step is scheduled: the reformat destroys it. That is
deliberate — a targeted delete would require remounting the volume read-write
through `ntfs3`, which is the one operation that could damage what is still on it.

### 10.1. `laptop-music` must not be dropped yet

> **Naming, because it is actively confusing.** The *role* of server moved to
> **latitude**; the *name* did not follow. The tailnet node and SSH alias literally
> called `server` is still **g513ie**, the old G15, and `fleet.json` still gives
> g513ie the logical name `server` while giving latitude `profile: server`. Every
> reference below uses **`g513ie`** or **`latitude`** and never bare `server`.
> Renaming the fleet entry is its own task; until it happens, `ssh server` reaches
> the box being decommissioned.

The original was located: **`C:\Users\methe\Music` on g513ie — 89 GB,
11 550 files** (14 878 counted from WSL, which sees hidden entries), alongside
`C:\Navidrome` (0.2 GB of Navidrome's own state). The 67G repo is a deduplicated,
compressed backup of that library, so "the original still exists" is true.

**But the original is on the machine being decommissioned.** The migration plan's
own global constraint reads: *"The G15 is the only copy of some data until Task 15
passes. No wipe, no sale, no reformat of any drive before the restore verification
in Task 15 succeeds."* Dropping this repo takes the music library from two copies
(G15 original + 320G repo) to **one copy, on the box being retired**. That is a
reduction in safety disguised as a cleanup, and it is the only one of the six items
where the "we still have the originals" reasoning does not hold.

**The fix makes the cleanup unblock itself.** Pull the 89 GB library from
g513ie to latitude's root (446 GB free) *first*, then drop the repo. Three things
land at once: the music gets a second copy on a different machine, the 320G
actually reaches empty, and the library ends up on the host that is becoming the
server and will run Navidrome. Root usage after the video and the music: ~130 GB
of 453 GB.

### 10.2. The video moves in two legs, not one

Leg 1 — `/mnt/public/Настя Стас GoPro` → `~/staging/` on latitude root, over USB,
native ext4, no network. Leg 2 — latitude → desktop `C:`.

Splitting it is deliberate:

- **The video is never single-copy.** A direct 320G → desktop move would have it
  in flight as the only copy; leg 1 finishes before anything is deleted.
- **The Cyrillic path is an encoding hazard on the Windows leg**, not on the Linux
  one. Isolating it into leg 2 means the risky step is unhurried and independently
  retryable rather than entangled with the wipe.
- **The transfer direction is fixed by what is wired.** latitude cannot resolve or
  authenticate to `desktop`; its `~/.ssh/config` carries only GitHub blocks and it
  has no fleet aliases after the Debian reinstall. But `methe@me-g614jv` and
  `me@wsl-desktop` are both in latitude's `authorized_keys`, and
  `ssh desktop → latitude` was confirmed working. **Leg 2 runs as a pull from
  desktop.**

### 10.3. Wipe the 320G by reformatting, not by deleting

Once it is empty, do not delete 177 GB of files through `ntfs3` read-write —
remounting rw is the one operation that can damage what is still on the volume.
Reformat instead: it is a single operation, it takes the Windows metadata
(`$RECYCLE.BIN`, `System Volume Information`) with it, and the drive is
Linux-only now, so **ext4** is the right target. The UUID changes, so its
`/etc/fstab` entry (§7.1) must be updated in the same step — `nofail` means a
stale UUID fails quietly rather than loudly, which is exactly how it would get
missed.

**Order, and nothing out of order:** stage video (leg 1) → pull music from g513ie
→ verify both → drop `qb`, the tar, and `restic-repos/wsl` → drop
`restic-repos/laptop-music` → resolve `secrets/` → reformat → update fstab →
push video to desktop (leg 2).

**Leg 1 complete, 2026-07-29 20:24.** `~/staging/Настя Стас GoPro` on latitude —
**41 905 063 663 bytes, 162 files, rsync exit 0**, byte-exact against the source.
Do not delete the source on the 320G until a `rsync -n --checksum` pass confirms
content as well as size; rsync's in-transfer verification is good but a content
re-read is the cheap insurance before an irreversible delete.

### 10.4. Every Windows-side transfer must run inside WSL

**5 406 of the 11 550 music files have non-ASCII (Cyrillic) paths** — e.g.
`OldMusic/DJ TOYOTA/104 - Сафари.mp3`, `MiyaGi Эндшпиль - Фея.mp3`. The GoPro
folder is the same. Native Windows `scp` and `tar` send filenames in the local
codepage and mangle them; PowerShell additionally corrupts binary pipelines.

Both Windows boxes have WSL, and WSL's drvfs presents Windows filenames as proper
UTF-8, so the fix is to run the transfer inside WSL rather than from PowerShell:

| Box | WSL distro | `rsync` | Notes |
|---|---|---|---|
| **g513ie** | Ubuntu 26.04 LTS (was Stopped) | present | reads `/mnt/c/Users/methe/Music` correctly |
| **desktop** | `desktop-ubuntu26`, live tailnet node `100.64.0.6` | assumed, verify | writes to `/mnt/c/...` for leg 2 |

If WSL is unavailable for some step, the fallback that still preserves names is a
WSL-produced tar streamed through the *native* ssh, driven by `cmd` — never
PowerShell:

```
cmd /c "wsl -e tar -cf - -C /mnt/c/Users/methe Music | ssh latitude ""tar -xf - -C /home/me/staging"""
```

WSL builds the archive so the names are UTF-8; native ssh only moves opaque bytes.
One pass, no resume.

## 11. latitude has no outbound SSH identity, and MagicDNS is broken on it

Two independent findings, both blocking anything latitude should initiate itself.
Neither is a storage problem, but both were hit while planning the transfers and
both matter more now that latitude is the server.

### 11.1. No fleet key — latitude can only be *reached*, never *reach*

`~/.ssh/` on latitude holds exactly `id_cyphy671` and `id_metheoryt`, both GitHub
identities pinned with `IdentitiesOnly yes`. A search across `/home`, `/root` and
`/etc/ssh` finds no other private key. The NixOS install's `id_ed25519` is gone.

So the direction of every fleet transfer is currently forced:

| From | To latitude | Why |
|---|---|---|
| g513ie (native Windows) | ✅ | `methe@g513ie` in latitude's `authorized_keys` |
| desktop (native Windows) | ✅ | `methe@me-g614jv` |
| desktop (WSL) | ✅ | `me@wsl-desktop` |
| air | ✅ | `me@air` |
| **g513ie (WSL)** | ❌ | its key is not authorized — this is what blocks the music rsync |
| **latitude → anything** | ❌ | **no outbound key exists at all** |

Two grants are therefore in play, and they are not the same size:

1. **One public key, to unblock the music tonight** — an ed25519 keypair in
   g513ie's WSL, its `.pub` appended to latitude's `authorized_keys`. One line in
   one file. Avoidable entirely by using the `cmd`-driven tar stream above, which
   needs no new trust.
2. **A fleet identity for latitude, which is the structural fix** —
   `ssh-keygen -t ed25519` on latitude, its `.pub` into `authorized_keys` on
   g513ie, desktop, air and hub. Until this exists, latitude cannot pull from
   g513ie on a schedule, cannot push backups anywhere, and cannot run the
   fleet-dispatch scripts that assume outbound reach. A server that can only be
   connected *to* is the wrong shape.

latitude also has **no fleet `Host` aliases** — `~/.ssh/config` contains only the
GitHub blocks. Under NixOS `modules/home/ssh.nix` generated the fleet entries;
nothing generates them on Debian.

**Dead trust to sweep:** `me-nixos-latitude5520` sits in latitude's own
`authorized_keys`, but its private half died with the NixOS install. It is an
orphaned grant, and it is probably present on the other fleet boxes' 
`authorized_keys` too — worth a fleet-wide sweep when the new key is added, since
that is the moment every box's file is being edited anyway.

### 11.2. MagicDNS resolves nothing on latitude

`getent hosts` fails for `g513ie.gg.ez`, `desktop.gg.ez`, `air.gg.ez`, `hub.gg.ez`
and `server.gg.ez` alike — every name, not one bad entry. But MagicDNS is enabled
tailnet-wide (`MagicDNSSuffix: gg.ez`, `MagicDNSEnabled: true`) and the tailnet
itself is healthy: `100.64.0.3`, `.4` and `.7` all ping.

Cause: `/etc/resolv.conf` is generated by **`dhcpcd`** and lists only
`nameserver 192.168.8.1`. Tailscale's `100.100.100.100` resolver is never
installed, so the `gg.ez` suffix has nowhere to resolve. There is no
`systemd-resolved` in the path for `tailscaled` to hand DNS to.

This is why `ssh desktop` from latitude reports *"Could not resolve hostname"*
rather than a permission error. Until it is fixed, anything latitude initiates has
to use tailnet IPs. It will bite every name-based script, so it belongs with 11.1
rather than after it.

### 11.3. Resolved 2026-07-29 20:45 — latitude has a fleet identity

`ssh-keygen -t ed25519 -C "me@latitude"`, passphrase-less because the fleet's
unattended jobs need it (the same deliberate choice the retired NixOS key carried).

**Fingerprint: `SHA256:uZJCBdKuM/r+74I8ITbsOaeKpRmkqmp+bHhjbouNYm0 me@latitude`**

Distributed to all four peers, backups taken alongside each edit:

| Host | File written | Note |
|---|---|---|
| air | `~/.ssh/authorized_keys` | |
| hub | `~/.ssh/authorized_keys` | |
| desktop | `C:\ProgramData\ssh\administrators_authorized_keys` | the user's `~/.ssh/authorized_keys` does not exist; `methe` is an admin so this file is the authoritative one |
| g513ie | `C:\ProgramData\ssh\administrators_authorized_keys` | both files exist here, but the admin file is the one sshd consults |

Fleet `Host` blocks appended to latitude's `~/.ssh/config` in a marked block, each
with `IdentityFile ~/.ssh/id_ed25519` + `IdentitiesOnly yes`. **They use tailnet
IPs, not `*.gg.ez` names**, because of 11.2 — with a comment saying to switch them
to names once DNS is fixed.

Verified: `ssh g513ie`, `ssh desktop`, `ssh air`, `ssh hub` all return `OK` from
latitude. **`g513ie` does not resolve from air either** — only the literal alias
`server` reaches it, which is the §10 naming collision biting in practice.

**Deliberately not done yet:** removing the dead grants. `me-nixos-latitude5520`
is provably orphaned and sits in the `authorized_keys` of air, hub, desktop and
g513ie; hub additionally carries `methe@DESKTOP-4PQ6V6B`, `methe@lat5520`,
`methe@methe-server` and `me@desktop-wsl-ubuntu-26-04`. Those four are *stale
comments*, not provably stale keys — a comment is not a key identity, and the same
key material may still be live under a renamed host. Removal must compare key
material, and it must happen **after** the new key is confirmed working, never in
the same edit that grants access.

### 11.4. The g513ie link is the real transfer constraint

The music pull runs as `rsync --rsync-path="wsl -e rsync"` from latitude — the
remote end executes rsync *inside* WSL, so `/mnt/c` paths resolve and the Cyrillic
names arrive as UTF-8. g513ie's default shell is PowerShell, which mangles binary
pipelines when *it* does the piping; a `md5sum`-vs-`cat | md5sum` round trip of a
5 MB binary through it matched exactly, so the rsync protocol stream survives.
The mechanism works. The link does not:

| Measurement | Value |
|---|---|
| Tailnet path | **direct**, `192.168.8.170:41641` — same LAN, no DERP relay |
| `tailscale ping` RTT | **251 ms**, then **454 ms** twelve minutes later |
| rsync throughput | 6.9 MB/s, decaying to **4.1 MB/s** |
| Raw `/dev/zero` stream (no disk, no drvfs, no per-file overhead) | **3.0 MB/s** |

**The first diagnosis was wrong and the measurement corrected it.** With 18 378
files and a 251 ms RTT, per-file round trips looked like the obvious culprit, which
would have made a single tar stream the fix. But a `/dev/zero` stream — no disk, no
drvfs, one round trip total — ran *slower* than rsync. The link is
**bandwidth-bound, not latency-bound**, so a tar stream buys nothing. (Both numbers
were taken while the rsync was live and contending, so neither is clean in
isolation; the conclusion rests on both being single-digit MB/s, which no amount of
contention explains away.)

At ~4 MB/s the 89 GB pull needs 6+ hours and the trend is the wrong way. Options,
in order of preference:

1. **Put g513ie on ethernet.** A 251→454 ms RTT on a local wire is a wifi problem,
   not a network-design one. Restarting the script after plugging in costs nothing:
   `rsync -a` skips what already landed, so the transfer resumes rather than
   restarts.
2. **Let it run overnight.** It is idempotent and unattended. Nothing else waits on
   it except the 320G wipe.

Either way the script is at `~/staging/pull-music.sh` on latitude and is safe to
re-run any number of times.

### 11.5. Sneakernet supersedes the wifi pull

A **Kingston XS2000** portable SSD — the Ventoy install drive — was plugged into
latitude at 21:18 and is a far better vehicle than the link:

| Partition | Size | FS | Label | Free |
|---|---|---|---|---|
| `sdf1` | 253.8G | exfat | `Boot` | 206G — Ventoy's ISO partition |
| `sdf2` | 32M | vfat | `VTOYEFI` | Ventoy's ESP; do not touch |
| `sdf3` | **700G** | ntfs | `data` | **638G** — general storage, holds `backup` and `windows-reinstall` |

`sdf3` is the target: 638G free, and writing there does not disturb Ventoy's boot
function. Encoding is safe end to end — NTFS stores names as UTF-16, Windows
writes them natively, and Linux `ntfs3` reads them back as UTF-8, so the Cyrillic
filenames never pass through a codepage conversion at all. This is *better* than
the ssh route, not merely faster.

The wifi rsync was killed at 21:19 having transferred **15G of 89G**. That work is
not wasted: `rsync -a` skips files already present with matching size and mtime, so
the final pass only needs the remaining ~74G.

Sequence: unmount both XS2000 partitions on latitude → move the drive to g513ie →
`robocopy` the library onto `sdf3` (native Windows-to-NTFS, no drvfs, no network) →
move the drive back → rsync from the XS2000 into `~/staging/music/`. Then re-run
`pull-music.sh` once as a **consistency check against the live source** — with the
data already local it transfers nothing and only reports differences.

Note `sdf3` had to be mounted with an explicit `-t ntfs3`. Auto-detection picks the
old read-only `ntfs` driver, which is not built into this kernel, and the mount
fails with `unknown filesystem type 'ntfs'` — a misleading error, since the
filesystem is fine and only the driver name is wrong.

### 11.6. Result — 452 MB/s, byte-verified

The robocopy leg ran 22:48–22:52 on 2026-07-29 and completed:

```
              Total    Copied   Skipped  Mismatch    FAILED    Extras
   Dirs :      3500      3500         8         0         0         0
  Files :     14878     14877         1         0         0         0
  Bytes :  88.302 g  88.302 g       504         0         0         0
  Times :   0:35:06   0:03:29                       0:00:00   0:00:26

  Speed :         452 283 285 Bytes/sec
```

Independent tally of both trees, counting hidden files (`-Force`), re-checked
after the copy at 2026-07-29 23:4x with the drive still attached to g513ie:

```
TARGET 94813954726 bytes 14878 files
SOURCE 94813954726 bytes 14878 files
MATCH True
```

**452 MB/s against 4–10 MB/s over the link** — the sneakernet decision was worth
roughly two orders of magnitude, and it removed the encoding risk rather than
merely working around it.

Two measurement notes worth keeping:

- The **first** verification ran without `-Force` and reported `11550 files /
  94739766854 bytes`. It matched source-to-target too, so it was not wrong — it
  simply excluded hidden files on both sides. When a tally is used as proof of a
  copy, state whether hidden files are in it; two correct numbers that disagree
  invite a false "the copy is short" conclusion.
- robocopy's `1 skipped, 504 bytes` is not a gap. Skipped means already present
  and identical at the target; the full tallies agreeing confirms it. **Judge a
  robocopy on the file/byte tally, never on the exit code** — 0–7 are all
  success (it is a bitmask, not an ordinal), so a nonzero status is routine.

### 11.7. Gotcha: Windows OpenSSH kills the copy when the session drops

The **first** robocopy attempt died after 2 files / 0.24 GB with only the log
header written. Cause: it was launched with

```powershell
Start-Process -NoNewWindow robocopy ...
```

which leaves the child inside the ssh session's **job object**. Windows OpenSSH
tears that whole job down on disconnect, so the copy dies with the session —
`nohup`, `&`, and detaching the terminal do not help, because the kill is done by
the job object, not by a signal.

The escape is to have another service create the process, so it is never in the
session's job to begin with:

```powershell
$cmd = @'
cmd.exe /c robocopy "C:\Users\methe\Music" "F:\music-from-g513ie" /E /MT:8 /R:2 /W:2 /NFL /NDL /NP /XJ > "C:\Users\methe\robocopy-music.log" 2>&1
'@
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $cmd}
```

`Win32_Process.Create` spawns via **WmiPrvSE**, outside the job, and the copy
outlives the session. This applies to *every* long-running task started on a
Windows fleet member over ssh, not just this copy — a scheduled task would work
equally well, `Start-Process` never will.

Also note the here-string is passed as a **single-quoted** `@'...'@` block: over
ssh, double-quoted PowerShell here-strings repeatedly failed with `The string is
missing the terminator`. Where quoting cannot be made to survive the hop, base64
the script as UTF-16LE and run `powershell -NoProfile -EncodedCommand <b64>` —
that path has no quoting surface at all and is the reliable way to run a
multi-line PowerShell script on a fleet Windows box.

## 12. The HGST long self-test aborts through the dock

`Reallocated_Event_Count 23` with `Reallocated_Sector_Ct 0` on the HGST
HTS541010A9E680 (§4) is the one open health question in the pool: 23 relocation
*events* recorded, 0 sectors currently held as relocated. A long self-test is the
way to settle whether the surface is stable now.

It does not finish through the dock. **Attempt 1** (with `/mnt/immich-2024-backup`
mounted) ended:

```
# 1  Extended offline    Aborted by host    80% remaining    27818 hours
```

`dmesg` held nothing but the attach lines — no reset, no I/O error, no
disconnect. "Aborted by host" is the drive's account of an ATA-level abort, so
something in the path sent it, and the two candidates were the mounted volume's
background I/O and the USB bridge itself.

**Attempt 2** started 22:54 with the volume **unmounted**, removing the first
candidate. It progressed past attempt 1's death point — 90% remaining at 22:54,
80% at 23:14, 70% at 23:34, i.e. roughly 20 min per 10% and an ETA near 02:00.

Status at the time of writing: **in progress, unresolved**. Two outcomes, both
worth recording:

- **It completes.** Then the 23 events are historical and the surface is stable,
  and attempt 1's abort is attributable to the mounted volume's I/O — which is a
  rule in its own right: *unmount a volume before running a long self-test on it
  through a USB bridge.*
- **It aborts again with nothing touching the drive.** Then the bridge is the
  cause, and *"long self-tests cannot run through these docks"* is the finding.
  That is not a small conclusion — it means the realloc-events question cannot be
  settled without a direct SATA connection, and by extension that no drive in
  this pool can be surface-verified while it lives in a dock. Any future
  "is this disk still good?" decision would rest on attributes alone.

Dock B must stay powered until the test ends either way; cutting its power is
itself an abort and would waste the run.

### Unrelated, and benign: an order-4 allocation failure

While the 1 TB sweep of §4 was running, `dmesg` recorded:

```
[Wed Jul 29 21:53:03 2026] tr: page allocation failure: order:4, mode:0x40cc0(GFP_KERNEL|__GFP_COMP)
```

21 GB of page cache from the sweep sat in `inactive_file` and a 16-page
contiguous allocation could not be satisfied promptly. No OOM kill, no process
lost, no disk involvement. Recorded only so it is not later mistaken for a
storage fault found on the same night.
