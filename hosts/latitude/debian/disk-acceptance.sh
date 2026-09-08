#!/usr/bin/env bash
# disk-acceptance.sh — accept, or return, a newly bought disk.
#
#   ./disk-acceptance.sh identity /dev/disk/by-id/ata-WDC_WD80EAAZ-22BXBB0_RD2RRPWH \
#       --serial RD2RRPWH --model WD80EAAZ-22BXBB0 --wwn 50014EE216C6BF75
#   ./disk-acceptance.sh surface  <same by-id path> --serial <S> -go [--detach]
#   ./disk-acceptance.sh verdict  <same by-id path> --serial <S>
#
# TWO GATES ON TWO DIFFERENT CLOCKS, and that ordering is the whole design:
#
#   1. IDENTITY (5 minutes) decides KEEP or RETURN. It runs on the shop's
#      return-window clock, so it runs the hour the drive is unpacked — before
#      any burn-in, before anything is copied onto it.
#   2. SURFACE (~40 h) decides whether the drive may hold data. It runs on the
#      warranty clock, which is 2 years on the WD80EAAZ, so finishing it late
#      costs nothing but risk.
#
# The reason gate 1 exists at all: the last disk bought for this slot was not a
# dead drive, it was a FRAUD — a 2015 HGST Ultrastar HUS726060ALE611 with 74 502
# power-on hours and 3.02 PB written, wearing a WD Purple sticker and sold as
# new (docs/superpowers/specs/2026-07-30-6tb-return-claim-ru.md, and the raw
# SMART bundle beside it). A surface test would have PASSED that drive. Only the
# identity read caught it, and it is what made the claim provable.
#
# What this script cannot tell you, and nobody should later claim it did:
#   * CMR vs SMR. No SMART field reports it and a sequential write pass does not
#     discriminate device-managed SMR. It rests on the datasheet for the exact
#     part number printed by the identity phase — verify that against the
#     vendor's own CMR/SMR table, never from recall.
#   * Anything about the STICKER. Photograph the box label, the drive label and
#     the invoice serial BEFORE first power-on: the July fraud was a label that
#     disagreed with the platter, and a return claim needs both sides.
#
# THE INTERLOCK. The surface phase runs `badblocks -w`, which destroys whatever
# it is pointed at, and on this box /dev/sdX reshuffles on every boot (five USB
# devices plus a card reader race to enumerate). So it refuses to write unless
# ALL of these hold: the target is a /dev/disk/by-id/ata-* path, the caller
# passed --serial and it matches what the device reports, the device carries no
# partition table and no filesystem signature, nothing of it is mounted, and it
# appears nowhere in /etc/fstab. Pointed at /mnt/servarr's disk it exits 2.
#
# Docks: both Ugreen CM198 bays are JMicron JMS561U bridges on the usb-storage
# (BOT) driver. Measured 2026-09-08, on both docks: `-d sat` passes -i, -A AND
# 48-bit GP log reads (log directory 0x00 and SATA Phy 0x11 come back), so the
# DEVICE STATISTICS log — Head Flying Hours and Logical Sectors Written, the two
# counters the July claim leaned on — is reachable in principle. The four old
# 2.5" spindles answer "GP/SMART Log 0x04 not supported" because THEY predate
# ACS-3, not because the bridge ate it. `-d sat,12` is the one variant that
# genuinely cannot work (12-byte passthrough cannot carry a 48-bit command).
# The script still tries the variants in order and distinguishes the two cases
# in its verdict, because the fleet is three laptops and a VPS: there is no real
# SATA port anywhere to cross-check a drive that stays silent.
#
# badblocks notes that cost hours if you learn them the hard way:
#   * `-b 4096` is mandatory. The default 1024-byte block puts 8 TB at 7.8e9
#     blocks, past badblocks' 2^32 ceiling, and it aborts.
#   * `-c 4096` (16 MiB per pass) — the default 64-block buffer starves a USB
#     bridge and adds hours.
#   * It is NOT resumable. Run it detached (--detach puts it under systemd-run);
#     a dead ssh session takes the whole pass with it.
#   * A mid-run death is a BUS suspect first. Check `journalctl -k` for usb
#     reset/disconnect and attribute 199 before condemning the platter — dock B
#     dropped all four spindles for 3.5 minutes on 2026-08-23.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

EVIDENCE_ROOT=${EVIDENCE_ROOT:-/var/tmp/disk-acceptance}
# Capacity every "8 TB" drive reports, to the byte. A bridge that caps or
# misreports capacity shows up here and nowhere else.
BYTES_8TB=${EXPECT_BYTES:-8001563222016}
POH_NEW_MAX=${POH_NEW_MAX:-10}          # factory test time; above this it is used
CYCLES_NEW_MAX=${CYCLES_NEW_MAX:-50}
TIB=1099511627776

say(){ echo "[$(date +%F_%H:%M:%S)] $*"; }

# ── pure helpers (unit-tested by provision/tests/disk-acceptance.test.sh) ─────

# Leading integer of a SMART raw value: "0", "1234h+00m+00.000s", "0/0", "" -> 0.
smart_num(){ local v=${1:-}; v=${v%%[^0-9]*}; [ -n "$v" ] && printf '%s' "$v" || printf '0'; }

# RAW_VALUE (field 10) of an attribute ID in a `smartctl -A` dump.
smart_raw(){ awk -v id="$2" '$1==id {print $10; exit}' "$1" 2>/dev/null; }

smart_attr(){ smart_num "$(smart_raw "$1" "$2")"; }

# badblocks block count at a given block size, and the 2^32 ceiling.
bb_blocks(){ echo $(( ${1:-0} / ${2:-4096} )); }
bb_blocksize_ok(){ [ "$(bb_blocks "$1" "$2")" -lt 4294967296 ]; }

# Hours to write+read <bytes> at <MB/s> measured on the OUTER tracks. A CMR
# spindle falls to roughly half that rate at the inner tracks, so the honest
# projection is 1.4x the naive one -- the roadmap's "measure the first hour and
# extrapolate" under-promises without this factor.
eta_hours(){
  local bytes=$1 mbps=$2
  [ "${mbps%.*}" -gt 0 ] 2>/dev/null || { echo "?"; return; }
  awk -v b="$bytes" -v r="$mbps" 'BEGIN{printf "%.1f", (b/(r*1000000)/3600)*2*1.4}'
}

# NEW / USED / UNKNOWN from the two counters that cannot be reset by a reseller.
verdict_new(){
  local poh=$1 cycles=$2 lba_written=$3 sector=${4:-512}
  local written_tib
  written_tib=$(awk -v l="$lba_written" -v s="$sector" -v t="$TIB" 'BEGIN{printf "%.2f", l*s/t}')
  if [ "$poh" -gt "$POH_NEW_MAX" ] || [ "$cycles" -gt "$CYCLES_NEW_MAX" ]; then
    echo "USED poh=${poh}h cycles=${cycles} written=${written_tib}TiB"
  elif awk -v w="$written_tib" 'BEGIN{exit !(w>1)}'; then
    echo "USED written=${written_tib}TiB poh=${poh}h"
  elif [ "$poh" -eq 0 ] && [ "$cycles" -eq 0 ] && [ "$lba_written" -eq 0 ]; then
    echo "UNKNOWN all counters read zero — attributes may not be passing the bridge"
  else
    echo "NEW poh=${poh}h cycles=${cycles} written=${written_tib}TiB"
  fi
}

# PASS / FAIL / BUS from the surface pass. Numbers, not prose:
#   any bad block, or 5/197/198 above zero        -> FAIL, the platter
#   199 (UDMA_CRC) risen, or a usb reset in window -> BUS, reseat and re-run
verdict_surface(){
  local bad=$1 realloc=$2 pending=$3 offline=$4 crc_delta=$5 usb_faults=$6
  if [ "$bad" -gt 0 ] || [ "$realloc" -gt 0 ] || [ "$pending" -gt 0 ] || [ "$offline" -gt 0 ]; then
    echo "FAIL bad=${bad} realloc=${realloc} pending=${pending} offline=${offline}"
  elif [ "$crc_delta" -gt 0 ] || [ "$usb_faults" -gt 0 ]; then
    echo "BUS crc+${crc_delta} usb_faults=${usb_faults} — reseat cable/dock and re-run, do not condemn the drive"
  else
    echo "PASS no bad blocks, no reallocations, no bus faults"
  fi
}

# Every reason this target must not be written to. Empty output == safe.
# Kept pure (all state passed in) so the suite can drive every branch.
unsafe_reasons(){
  local path=$1 want_serial=$2 got_serial=$3 parttable=$4 fstype=$5 mounted=$6 in_fstab=$7
  case "$path" in
    /dev/disk/by-id/ata-*) ;;
    *) echo "target is not a /dev/disk/by-id/ata-* path (sdX letters reshuffle every boot)" ;;
  esac
  [ -n "$want_serial" ] || echo "--serial not given (it is what makes -go safe rather than theatrical)"
  [ -n "$want_serial" ] && [ "$want_serial" != "$got_serial" ] && \
    echo "serial mismatch: expected '$want_serial', device reports '$got_serial'"
  [ -n "$parttable" ] && echo "device carries a $parttable partition table"
  [ -n "$fstype" ] && echo "device carries a $fstype signature"
  [ -n "$mounted" ] && echo "device is mounted at $mounted"
  [ -n "$in_fstab" ] && echo "device appears in /etc/fstab as $in_fstab"
  return 0
}

# ── device probes ─────────────────────────────────────────────────────────────

sd_of(){ basename "$(readlink -f "$1")"; }

dev_serial(){ sudo smartctl -i -d sat "$1" 2>/dev/null | awk -F: '/Serial Number/{gsub(/ /,"",$2); print $2; exit}'; }

# Try the -d variants in order; echo the first that returns attributes.
smart_dtype(){
  local d
  for d in sat "sat,16" "sat,12" usbjmicron auto; do
    if sudo smartctl -A -d "$d" "$1" 2>/dev/null | grep -qa 'Power_On_Hours\|ID#'; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

usb_faults_since(){ sudo journalctl -k --since "$1" 2>/dev/null | grep -acE 'usb [0-9.-]+: (reset|USB disconnect|device descriptor read)' || true; }

# ── phases ───────────────────────────────────────────────────────────────────

phase_identity(){
  local dev=$1 want_serial=$2 want_model=$3 want_wwn=$4 sd bytes dtype ev
  sd=$(sd_of "$dev")
  ev="$EVIDENCE_ROOT/${want_serial:-$sd}"
  mkdir -p "$ev"

  say "identity phase — evidence -> $ev"
  {
    echo "# disk-acceptance identity, $(date -Is), host $(hostname)"
    echo "# by-id path: $dev -> /dev/$sd"
    echo
    echo "== 1. kernel SCSI inquiry (/sys/block) — no diagnostic tool involved"
    for f in vendor model rev; do printf '%s: %s\n' "$f" "$(cat "/sys/block/$sd/device/$f" 2>/dev/null)"; done
    printf 'size: %s bytes\n' "$(sudo blockdev --getsize64 "$dev" 2>/dev/null)"
    printf 'logical/physical sector: %s / %s\n' \
      "$(cat "/sys/block/$sd/queue/logical_block_size" 2>/dev/null)" \
      "$(cat "/sys/block/$sd/queue/physical_block_size" 2>/dev/null)"
    echo
    echo "== 2. udev (bridge + ATA identity, independent of smartctl)"
    udevadm info --query=property --name="$dev" 2>/dev/null | grep -E '^ID_(MODEL|SERIAL|SERIAL_SHORT|REVISION|WWN|BUS|VENDOR)=' || true
    ls -l /dev/disk/by-id/ 2>/dev/null | grep -F "$sd\$" || true
    echo
    echo "== 3. smartctl ATA IDENTIFY through the bridge"
    sudo smartctl -i -d sat "$dev" 2>&1
    echo
    echo "== 4. hdparm ATA IDENTIFY (a separate code path; may not pass the bridge)"
    sudo hdparm -I "$dev" 2>&1 | head -30
    echo
    echo "== 5. lsblk"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,TRAN,SERIAL,REV "$dev" 2>&1
  } > "$ev/identity.txt" 2>&1

  dtype=$(smart_dtype "$dev" || echo sat)
  say "SMART -d $dtype"
  sudo smartctl -A -d "$dtype" "$dev" > "$ev/smart-before.txt" 2>&1 || true
  sudo smartctl -H -c -l selftest -d "$dtype" "$dev" >> "$ev/smart-before.txt" 2>&1 || true
  sudo smartctl -x -d "$dtype" "$dev" > "$ev/smart-x-before.txt" 2>&1 || true
  sudo smartctl -l devstat -d "$dtype" "$dev" > "$ev/devstat-before.txt" 2>&1 || true
  printf '%s' "$dtype" > "$ev/dtype"

  local poh cycles lba sector realloc pending offline crc
  poh=$(smart_attr "$ev/smart-before.txt" 9)
  cycles=$(smart_attr "$ev/smart-before.txt" 12)
  lba=$(smart_attr "$ev/smart-before.txt" 241)
  sector=$(cat "/sys/block/$sd/queue/logical_block_size" 2>/dev/null || echo 512)
  realloc=$(smart_attr "$ev/smart-before.txt" 5)
  pending=$(smart_attr "$ev/smart-before.txt" 197)
  offline=$(smart_attr "$ev/smart-before.txt" 198)
  crc=$(smart_attr "$ev/smart-before.txt" 199)
  bytes=$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)

  echo
  echo "===================== IDENTITY GATE — keep or return ====================="
  printf 'model (kernel) : %s %s\n' "$(cat /sys/block/$sd/device/vendor 2>/dev/null)" "$(cat /sys/block/$sd/device/model 2>/dev/null)"
  printf 'model (ATA)    : %s\n' "$(grep -m1 'Device Model\|Model Number' "$ev/identity.txt" | cut -d: -f2- | xargs || true)"
  printf 'serial         : %s   (expected: %s)\n' "$(dev_serial "$dev")" "${want_serial:-<none given>}"
  printf 'WWN            : %s\n' "$(grep -m1 'LU WWN' "$ev/identity.txt" | cut -d: -f2- | xargs || true)"
  printf 'firmware       : %s\n' "$(grep -m1 'Firmware Version' "$ev/identity.txt" | cut -d: -f2- | xargs || true)"
  printf 'rotation       : %s\n' "$(grep -m1 'Rotation Rate' "$ev/identity.txt" | cut -d: -f2- | xargs || true)"
  printf 'capacity       : %s bytes (%s)\n' "$bytes" \
    "$([ "$bytes" = "$BYTES_8TB" ] && echo "matches the expected $BYTES_8TB exactly" || echo "EXPECTED $BYTES_8TB — a bridge capping or misreporting capacity shows up only here; set EXPECT_BYTES= to test a different unit")"
  printf 'sectors 5/197/198/199: %s / %s / %s / %s\n' "$realloc" "$pending" "$offline" "$crc"
  printf 'was it new     : %s\n' "$(verdict_new "$poh" "$cycles" "$lba" "$sector")"
  if [ -n "$want_model" ] && ! grep -qi "$want_model" "$ev/identity.txt"; then
    printf 'MODEL MISMATCH : nothing on the device reports %s — RETURN on this alone\n' "$want_model"
  fi
  if [ -n "$want_serial" ] && [ "$want_serial" != "$(dev_serial "$dev")" ]; then
    printf 'SERIAL MISMATCH: device disagrees with the invoice/sticker — RETURN on this alone\n'
  fi
  # The WWN is burned in at the factory and carries the maker's OUI, so it is the
  # one identifier a relabeller cannot touch: 50014EE2… is Western Digital's,
  # 5000CCA… is HGST's — and 5000CCA is exactly what the July 2026 substituted
  # drive reported while wearing a WD Purple sticker.
  if [ -n "$want_wwn" ]; then
    local got_wwn
    # Everything after the colon only: the words "LU WWN Device Id" are
    # themselves valid hex digits (d,e,c,e,d...) and prefixed the parsed value
    # with garbage until this was measured on a live drive, 2026-09-08.
    got_wwn=$(grep -m1 'LU WWN' "$ev/identity.txt" | sed 's/.*://' | tr -dc '0-9a-fA-F' | tr 'A-F' 'a-f')
    case "$got_wwn" in
      *"$(printf '%s' "$want_wwn" | tr -dc '0-9a-fA-F' | tr 'A-F' 'a-f')"*)
        echo 'WWN            : matches the sticker' ;;
      *) printf 'WWN MISMATCH   : sticker says %s, device reports %s — RETURN on this alone\n' "$want_wwn" "$got_wwn" ;;
    esac
    case "$got_wwn" in
      50014ee*) echo 'WWN OUI        : 0014ee = Western Digital' ;;
      5000cca*) echo 'WWN OUI        : 5000cca = HGST — NOT a WD-made platter. This is the July 2026 fraud signature.' ;;
      "" ) echo 'WWN OUI        : FINDING — no WWN read through the bridge' ;;
      *) printf 'WWN OUI        : %s — unknown maker OUI, look it up before accepting\n' "${got_wwn:0:7}" ;;
    esac
  fi
  if grep -qa 'Head Flying Hours\|Logical Sectors Written' "$ev/devstat-before.txt" 2>/dev/null; then
    echo 'devstat log    : readable — the two fraud-decisive counters are in devstat-before.txt'
  elif grep -qa 'not supported' "$ev/devstat-before.txt" 2>/dev/null; then
    echo 'devstat log    : FINDING — the DRIVE reports no Device Statistics log (GP 0x04). Measured 2026-09-08: the JMS561U bridge passes 48-bit GP log reads fine (log directory 0x00 and SATA Phy 0x11 both read through `-d sat`), so this is the drive, not the dock — and a 2025 ACS-3 drive that lacks devstat is itself worth a second look. Attributes 9/12/241 are then the only power-on evidence.'
  else
    echo 'devstat log    : FINDING — devstat did not read at all; see devstat-before.txt for which -d variant failed and how.'
  fi
  echo 'CMR            : not measurable here. Check the part number above against the vendor CMR/SMR table.'
  echo 'sticker        : not measurable here. Photograph box label + drive label + invoice serial now.'
  echo "eta for surface: ~$(eta_hours "${bytes:-0}" 150) h at an assumed 150 MB/s — replace with the measured rate after the first hour"
  echo "========================================================================="
}

phase_surface(){
  local dev=$1 want_serial=$2 go=$3 detach=$4 sd ev bytes reasons dtype
  sd=$(sd_of "$dev")
  ev="$EVIDENCE_ROOT/${want_serial:-$sd}"
  mkdir -p "$ev"

  local parttable fstype mounted in_fstab
  parttable=$(sudo blkid -p -s PTTYPE -o value "$dev" 2>/dev/null || true)
  fstype=$(sudo blkid -p -s TYPE -o value "$dev" 2>/dev/null || true)
  mounted=$(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null | tr -d ' \n' || true)
  in_fstab=$(grep -vE '^\s*#' /etc/fstab 2>/dev/null | grep -oE "(UUID=\S+|/dev/\S+)" | while read -r spec; do
      [ "$(readlink -f "${spec#UUID=}" 2>/dev/null)" = "$(readlink -f "$dev")" ] && echo "$spec"; done | head -1)
  # Any partition of the device counts, not just the whole-disk node.
  [ -z "$mounted" ] && mounted=$(lsblk -no MOUNTPOINTS "/dev/$sd" 2>/dev/null | tr -d ' \n' || true)

  reasons=$(unsafe_reasons "$dev" "$want_serial" "$(dev_serial "$dev")" "$parttable" "$fstype" "$mounted" "$in_fstab")
  if [ -n "$reasons" ]; then
    echo "REFUSING to write to $dev:"; printf '%s\n' "$reasons" | sed 's/^/  - /'
    exit 2
  fi

  bytes=$(sudo blockdev --getsize64 "$dev")
  bb_blocksize_ok "$bytes" 4096 || { say "FATAL $bytes bytes exceeds badblocks' 2^32 blocks even at -b 4096"; exit 1; }

  if [ "$go" != go ]; then
    say "DRY RUN — interlock passed, target is safe to destroy. Nothing written."
    say "would run: badblocks -b 4096 -c 4096 -w -t random -s -v -o $ev/badblocks.badlist $dev"
    say "budget ~$(eta_hours "$bytes" 150) h (write+read, inner-track factor applied). Add -go to start."
    return 0
  fi

  if [ "$detach" = yes ]; then
    say "re-executing under systemd-run as disk-accept-$sd (badblocks is not resumable; an ssh death would take it with it)"
    exec sudo systemd-run --unit="disk-accept-$sd" --collect --same-dir \
      --description="disk acceptance surface pass on $dev" \
      "$(readlink -f "$0")" surface "$dev" --serial "$want_serial" -go
  fi

  date -Is > "$ev/surface-started"
  say "surface pass on $dev ($bytes bytes) — one random-pattern write + verify read"
  say "watch: tail -f $ev/badblocks.log ; journalctl -fu disk-accept-$sd"
  sudo badblocks -b 4096 -c 4096 -w -t random -s -v -o "$ev/badblocks.badlist" "$dev" \
    > "$ev/badblocks.log" 2>&1
  local rc=$?
  date -Is > "$ev/surface-finished"
  say "badblocks exited $rc"
  dtype=$(cat "$ev/dtype" 2>/dev/null || echo sat)
  sudo smartctl -A -d "$dtype" "$dev" > "$ev/smart-after.txt" 2>&1 || true
  sudo smartctl -H -l selftest -d "$dtype" "$dev" >> "$ev/smart-after.txt" 2>&1 || true
  phase_verdict "$dev" "$want_serial"
  return $rc
}

phase_verdict(){
  local dev=$1 want_serial=$2 sd ev
  sd=$(sd_of "$dev"); ev="$EVIDENCE_ROOT/${want_serial:-$sd}"
  [ -f "$ev/smart-after.txt" ] || { say "no smart-after.txt in $ev — run the surface phase first"; exit 1; }

  local bad realloc pending offline crc_before crc_after started faults
  bad=$(grep -c . "$ev/badblocks.badlist" 2>/dev/null || echo 0)
  realloc=$(smart_attr "$ev/smart-after.txt" 5)
  pending=$(smart_attr "$ev/smart-after.txt" 197)
  offline=$(smart_attr "$ev/smart-after.txt" 198)
  crc_before=$(smart_attr "$ev/smart-before.txt" 199)
  crc_after=$(smart_attr "$ev/smart-after.txt" 199)
  started=$(cat "$ev/surface-started" 2>/dev/null || echo "-2 days")
  faults=$(usb_faults_since "$started")
  usb_faults_since "$started" > "$ev/usb-faults" 2>/dev/null || true

  echo
  echo "===================== SURFACE GATE — trust it with data ================="
  printf 'bad blocks         : %s (%s)\n' "$bad" "$ev/badblocks.badlist"
  printf 'attr 5/197/198     : %s / %s / %s\n' "$realloc" "$pending" "$offline"
  printf 'attr 199 UDMA_CRC  : %s -> %s\n' "$crc_before" "$crc_after"
  printf 'usb faults in run  : %s (journalctl -k since %s)\n' "$faults" "$started"
  printf 'window             : %s -> %s\n' "$started" "$(cat "$ev/surface-finished" 2>/dev/null || echo '(unfinished)')"
  printf 'VERDICT            : %s\n' "$(verdict_surface "$bad" "$realloc" "$pending" "$offline" "$((crc_after - crc_before))" "$faults")"
  echo "========================================================================="
}

usage(){ sed -n '3,5p' "$0"; exit 2; }

main(){
  local phase=${1:-} dev=${2:-} want_serial= want_model= want_wwn= go=dry detach=no
  case "$phase" in identity|surface|verdict) ;; *) usage ;; esac
  [ -n "$dev" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --serial) want_serial=${2:-}; shift 2 ;;
      --model)  want_model=${2:-}; shift 2 ;;
      --wwn)    want_wwn=${2:-}; shift 2 ;;
      -go)      go=go; shift ;;
      --detach) detach=yes; shift ;;
      *) echo "unknown argument: $1"; usage ;;
    esac
  done
  command -v smartctl >/dev/null || { say "FATAL smartctl not found (apt install smartmontools)"; exit 1; }
  [ -e "$dev" ] || { say "FATAL $dev not present — is the dock powered and the drive spun up?"; exit 1; }
  case "$phase" in
    identity) phase_identity "$dev" "$want_serial" "$want_model" "$want_wwn" ;;
    surface)  phase_surface  "$dev" "$want_serial" "$go" "$detach" ;;
    verdict)  phase_verdict  "$dev" "$want_serial" ;;
  esac
}

# Sourceable: the suite sources this file to drive the pure helpers above.
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
