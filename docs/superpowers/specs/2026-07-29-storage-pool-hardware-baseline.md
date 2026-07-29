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
| **WDC WD10SPZX-21Z10T0**<br>`WD-WX91E575272W` | A0 | `E:` years archive `admin`, **664G, only online copy** | 28 796 (3.3 y) | 0 realloc / 0 events / 0 pending / 0 uncorr — **cleanest surface in the pool** | **UDMA_CRC 144 and still accruing** (worst 199 vs value 200); Start_Stop 91 599; Load_Cycle 122 818 |
| **HGST HTS541010A9E680**<br>`670200210032` bay 1 | B1 | `H:` restic `immich-media-2024`, 650G; designated off-site copy | 27 816 (3.2 y) | 0 pending / 0 uncorr, **23 realloc events** (0 sectors) | **Load_Cycle 639 701 — past the ~600k typical rating**; Start_Stop 116 800; Power_Cycle 14 413; CRC 18 |
| **ST1000LM024 HN-M101MBB**<br>`S2U5J9ECA34541` | A1 | `G:` restic `immich-media` + `immich-postgres`, 159G | 25 361 (2.9 y) | 0 realloc / 0 pending / 0 uncorr; CRC 0 | **Multi_Zone_Error_Rate normalised 001/100** (raw 83 172); **max-ever temp 63 °C**; Samsung M8-derived family with a weak field record |
| **ST320LT020-9YG142**<br>`W047MMKS` | *(removed)* | `F:` `Public`, 177G — retired, shelved | 36 153 (4.1 y) | 0 realloc / 0 pending / 0 uncorr | 10 ATA errors but **newest at 13 478 h — 2.6 years stale**; `Reported_Uncorrect` 11 and `Command_Timeout` 299 both historical; past thermal excursion (`190 In_the_past`) |

### What that table changes

- **The drive being retired is healthier today than one being kept.** The 320G's
  scars are all 2.6 years old with a clean surface since; the ST1000LM024 carries
  a live `Multi_Zone_Error_Rate` at the bottom of its normalised scale and has
  seen 63 °C.
- **The years archive's only online copy sits behind a marginal link.** 144 CRC
  errors, still climbing, on the drive holding 664G of irreplaceable `admin`
  data — which is exactly the data about to be read end-to-end during
  consolidation. CRC errors are detected and retried rather than silent, but they
  mark a link that can drop mid-copy.
  **Diagnostic available:** its dock-mate in bay A1 shows CRC 0 on the same dock
  and cable, so swapping the two drives between bays A0/A1 isolates it — if the
  count follows the drive it is the drive's connector, if it stays with the bay
  it is the bay.
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
4. **Fix the A0 link before the 664G consolidation copy**, not after.
5. **`/etc/fstab` has no data-disk entries at all** — root, ESP and swap only.
   Every `/mnt/*` mount is currently transient, so a reboot brings latitude up
   with empty mount points and any service pointed at nothing. UUID-based entries
   with `nofail` are a prerequisite before services come up, independent of the
   layout choice.
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
