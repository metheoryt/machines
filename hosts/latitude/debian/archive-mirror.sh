#!/usr/bin/env bash
# Mirror the closed 1970-2024 immich archive onto its second drive.
#   ./archive-mirror.sh          dry run (default: prints what would change)
#   ./archive-mirror.sh -go      actually copy
#   ./archive-mirror.sh -verify  compare the two trees, copy nothing
#
# WHY THIS EXISTS. Until 2026-08-01 /mnt/immich-2024/admin held EXACTLY ONE COPY
# of the 1970-2024 photo archive - 663 GiB, 20456 files, 2156 dirs. /mnt/immich
# has mirror-refresh.sh looking after it; this tree had nothing at all. The drive
# originally earmarked for the job is still named in the commented-out
# '/mnt/immich-2024-backup' line in /etc/fstab (HGST HTS541010A9E680) - it was
# consumed as /mnt/servarr during the migration, and the old restic repos on the
# Windows G:/H: drives went in the same reshuffle. Hence the target here is the
# only drive left with room: the Kingston XS2000 at /mnt/xs.
#
# TARGET IS exfat, AND THAT IS FINE - checked, not assumed (2026-08-01):
#   no hardlinks in the tree (nlink>1 count is 0), so losing -H costs nothing
#   uniform me:me ownership, so losing -o/-g costs one chown on restore
#   0 filenames with " * : < > ? | \ or a trailing space/dot (exfat rejects those)
#   longest path component 95 chars, well under exfat's 255
#   4 files over 4 GiB, largest 11.6 GB - exfat's ceiling is far above that;
#     the 4 GiB limit people remember is FAT32's, not exfat's
# Re-run those checks before pointing this at a different tree. Do NOT add -a:
# it implies -pgo, and every run would then fail to set perms exfat cannot store.
#
# 37 GiB of slack (663 into 700) is thin in general but fine here: 1970-2024 is a
# CLOSED set. New photos land on /mnt/immich, not here. If this tree ever starts
# growing again, the slack assumption dies with it.
#
# THE SOURCE DOCK IS THE FLAKY ONE, not the target. sdc (immich-2024) and sdd
# (immich-mirror) are the two bays of the dock on usb4/4-2, which logged 24
# 'usb 4-2: reset' events in the 24h before this script was written - clustered
# under load, which is exactly what a 663 GiB sustained read is. The target
# (usb2/2-2) is a separate controller, so there is no bandwidth contention, but
# expect the source to drop mid-run. Hence: --partial-dir, and a retry loop that
# re-mounts before trying again (nofail only applies at boot; after a bus drop a
# mount needs an explicit `mount`).
#
# --partial-dir, NOT --append-verify. A source-side drop leaves a truncated file
# at the destination; --partial-dir parks it under .rsync-partial/ so it is never
# mistaken for a complete file, and rsync uses it as the delta basis next run.
# --append-verify assumes the destination is a strict prefix of the source, which
# a torn write does not guarantee.
#
# GUARDS ARE BY UUID. Every /dev/sdX letter reshuffles across a reboot here (five
# bus-powered USB drives plus a card reader race to enumerate) and one enclosure
# reports a fake serial, so a letter or a serial is not an identity.
#
# --delete is OFF, same reasoning as mirror-refresh.sh: a deletion in the immich
# UI must not propagate to the only other copy.
#
# Do not run this at the same time as mirror-refresh.sh - both read from drives in
# the same dock, and contention is what provokes the resets.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

SRC=/mnt/immich-2024/admin
DST=/mnt/xs/immich-2024-archive
SRC_MNT=/mnt/immich-2024;  SRC_UUID=63c1de22-0607-40bc-aa35-168bf78927fb
DST_MNT=/mnt/xs;           DST_UUID=FBED-BCAA
MAX_ATTEMPTS=12
say(){ echo "[$(date +%F_%H:%M:%S)] $*"; }

MODE=dry
case "${1:-}" in
  -go)     MODE=go ;;
  -verify) MODE=verify ;;
  ""|-n)   MODE=dry ;;
  *) echo "usage: $0 [-n|-go|-verify]"; exit 2 ;;
esac

# --- identity guards -------------------------------------------------------
check_mount(){  # $1 mountpoint  $2 expected uuid
  [ "$(findmnt -no UUID "$1" 2>/dev/null)" = "$2" ]
}
remount(){      # $1 mountpoint  $2 expected uuid
  say "  $1 missing or wrong device - remounting"
  sudo umount "$1" 2>/dev/null
  sudo mount "$1" 2>/dev/null
  check_mount "$1" "$2"
}
for pair in "$SRC_MNT:$SRC_UUID" "$DST_MNT:$DST_UUID"; do
  m=${pair%:*}; u=${pair#*:}
  check_mount "$m" "$u" || remount "$m" "$u" || { say "FATAL $m is not the expected filesystem (want UUID=$u, got '$(findmnt -no UUID "$m" 2>/dev/null)')"; exit 1; }
done
[ -d "$SRC" ] || { say "FATAL source $SRC does not exist"; exit 1; }
say "mounts verified by UUID"

# --- measurement -----------------------------------------------------------
src_bytes=$(sudo du -sb "$SRC" 2>/dev/null | cut -f1)
dst_avail=$(df -B1 --output=avail "$DST_MNT" | tail -1 | tr -d ' ')
dst_bytes=$(sudo du -sb "$DST" 2>/dev/null | cut -f1); dst_bytes=${dst_bytes:-0}
gib(){ awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1073741824}'; }
say "source $(gib "$src_bytes")  |  already at target $(gib "$dst_bytes")  |  target free $(gib "$dst_avail")"

need=$(( src_bytes - dst_bytes ))
if [ "$need" -gt 0 ] && [ "$need" -gt "$dst_avail" ]; then
  say "FATAL need $(gib "$need") more but only $(gib "$dst_avail") free on $DST_MNT"
  exit 1
fi

# --- verify-only -----------------------------------------------------------
if [ "$MODE" = verify ]; then
  say "=== counts ==="
  sf=$(sudo find "$SRC" -type f 2>/dev/null | wc -l); df_=$(find "$DST" -type f -not -path '*/.rsync-partial/*' 2>/dev/null | wc -l)
  sd=$(sudo find "$SRC" -type d 2>/dev/null | wc -l); dd=$(find "$DST" -type d -not -name '.rsync-partial' 2>/dev/null | wc -l)
  echo "  files: src=$sf dst=$df_    dirs: src=$sd dst=$dd    bytes: src=$src_bytes dst=$dst_bytes"
  [ "$sf" = "$df_" ] && [ "$src_bytes" = "$dst_bytes" ] && say "MATCH" || say "MISMATCH - re-run with -go"
  say "=== content sample (25 random files, md5) ==="
  bad=0
  while IFS= read -r rel; do
    a=$(sudo md5sum "$SRC/$rel" 2>/dev/null | cut -d' ' -f1)
    b=$(md5sum "$DST/$rel" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$b" ]; then echo "  MISSING $rel"; bad=$((bad+1))
    elif [ "$a" != "$b" ]; then echo "  DIFFER  $rel"; bad=$((bad+1)); fi
  done < <(sudo find "$SRC" -type f -printf '%P\n' 2>/dev/null | shuf -n 25)
  [ "$bad" = 0 ] && say "sample clean" || say "$bad of 25 sampled files bad"
  exit 0
fi

# --- copy ------------------------------------------------------------------
DRY=-n; [ "$MODE" = go ] && DRY=""
FLAGS=(-rlt --no-perms --no-owner --no-group --modify-window=1
       --partial --partial-dir=.rsync-partial
       --human-readable --info=stats2
       --exclude=/lost+found/ --exclude=.rsync-partial/)
[ "$MODE" = go ] && FLAGS+=(--info=progress2)

mkdir -p "$DST" 2>/dev/null || sudo mkdir -p "$DST"

rc=1
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  say "rsync attempt $attempt/$MAX_ATTEMPTS"
  sudo rsync "${FLAGS[@]}" $DRY "$SRC/" "$DST/"; rc=$?
  case "$rc" in
    0)  say "rsync clean"; break ;;
    24) say "rsync exit 24 (source files vanished mid-run) - benign, treating as done"; rc=0; break ;;
    *)  say "rsync exit $rc - checking the bus" ;;
  esac
  [ "$MODE" = dry ] && break
  sudo journalctl -k --since "-10 min" 2>/dev/null | grep -aE "usb [0-9.-]+: (reset|USB disconnect)" | tail -3
  check_mount "$SRC_MNT" "$SRC_UUID" || remount "$SRC_MNT" "$SRC_UUID"
  check_mount "$DST_MNT" "$DST_UUID" || remount "$DST_MNT" "$DST_UUID"
  sleep 30
done

if [ "$MODE" = dry ]; then
  say "(dry run - pass -go to apply, -verify to compare)"
  exit 0
fi
[ "$rc" = 0 ] || { say "FAILED after $MAX_ATTEMPTS attempts (last rc=$rc) - re-run, it resumes"; exit "$rc"; }

# --- post-copy verification ------------------------------------------------
say "=== verifying ==="
sf=$(sudo find "$SRC" -type f 2>/dev/null | wc -l)
df_=$(find "$DST" -type f -not -path '*/.rsync-partial/*' 2>/dev/null | wc -l)
sb=$(sudo du -sb "$SRC" | cut -f1); db=$(sudo du -sb "$DST" | cut -f1)
echo "  files: src=$sf dst=$df_"
echo "  bytes: src=$sb dst=$db"
leftover=$(find "$DST" -type d -name .rsync-partial 2>/dev/null | wc -l)
[ "$leftover" = 0 ] || echo "  WARNING $leftover .rsync-partial dirs remain - the run was incomplete"
if [ "$sf" = "$df_" ] && [ "$sb" = "$db" ] && [ "$leftover" = 0 ]; then
  say "ARCHIVE MIRROR OK - $SRC now has a second copy at $DST"
else
  say "ARCHIVE MIRROR INCOMPLETE - re-run; it resumes from .rsync-partial"
  exit 1
fi
