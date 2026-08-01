#!/usr/bin/env bash
# Run SMART extended (long) self-tests on latitude's USB-docked drives and
# report health, self-test log, the four reallocation/CRC attributes, and any
# USB bus faults that happened during the run.
#
#   ./smart-long.sh                 # the two docked spinners below
#   ./smart-long.sh /dev/disk/by-id/usb-...-0:0 [more...]
#
# Worth running periodically: these are bus-powered 2.5" drives with high
# power-on hours, and a long test is the only thing that reads every sector.
# Budget ~3-4h (WDC ~186 min, HGST ~224 min) — the tests run INSIDE the drives
# in parallel, so there is no host IO contention and you can leave it detached.
#
# Always address a drive by its /dev/disk/by-id/usb-* path, never /dev/sdX:
# latitude has five bus-powered USB drives plus a card reader and the sdX
# letters reshuffle on every boot.
#
# UDMA_CRC_Error_Count rising, or bus faults in the journal, indicates the CABLE
# or DOCK rather than the platter — reseat before condemning a disk.
#
# (Originally chained after the one-shot overnight.sh migration job and blocked
# on its log; that dependency is gone. It stands alone now.)
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
say(){ echo "[$(date +%F_%H:%M:%S)] $*"; }

DEFAULT_DRIVES=(
  /dev/disk/by-id/usb-WDC_WD10_SPZX-21Z10T0_6702002103E1-0:0
  /dev/disk/by-id/usb-HGST_HTS_541010A9E680_670200210032-0:0
)
if [ "$#" -gt 0 ]; then DRIVES=("$@"); else DRIVES=("${DEFAULT_DRIVES[@]}"); fi

command -v smartctl >/dev/null || { say "FATAL smartctl not found (apt install smartmontools)"; exit 1; }
for d in "${DRIVES[@]}"; do
  [ -e "$d" ] || { say "FATAL $d not present — check the dock is powered and the drive spun up"; exit 1; }
done
say "targets: $(for d in "${DRIVES[@]}"; do basename "$d"; done | tr '\n' ' ')"

for d in "${DRIVES[@]}"; do
  say "starting extended self-test on $(basename "$d")"
  sudo smartctl -t long "$d" 2>&1 | grep -aiE "Testing has begun|Please wait|error" | head -2
done

say "polling every 10 min"
for i in $(seq 1 60); do
  sleep 600
  done_count=0
  for d in "${DRIVES[@]}"; do
    s=$(sudo smartctl -c "$d" 2>/dev/null | grep -a "Self-test routine in progress" || true)
    [ -z "$s" ] && done_count=$((done_count+1))
  done
  say "poll $i: $done_count/${#DRIVES[@]} finished"
  [ "$done_count" = "${#DRIVES[@]}" ] && break
done

for d in "${DRIVES[@]}"; do
  say "=== $(basename "$d") result ==="
  sudo smartctl -H "$d" 2>/dev/null | grep -ai "overall-health"
  sudo smartctl -l selftest "$d" 2>/dev/null | head -8
  sudo smartctl -A "$d" 2>/dev/null | grep -aiE "Reallocated_Sector|Current_Pending|Offline_Uncorrect|UDMA_CRC"
done
say "=== bus faults during self-tests ==="
sudo journalctl -k --since "-6h" | grep -acE "usb [0-9.-]+: (reset|USB disconnect)" || echo 0
say "SMART LONG DONE"
