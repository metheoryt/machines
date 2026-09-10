#!/usr/bin/env bash
# Mirror the closed 1970-2024 immich archive onto its second drive.
#   ./archive-mirror.sh          dry run (default: prints what would change)
#   ./archive-mirror.sh -go      actually copy
#   ./archive-mirror.sh -verify  compare the two trees, copy nothing
#
# WHY THIS EXISTS. Until 2026-08-01 /mnt/immich-2024/admin held EXACTLY ONE COPY
# of the 1970-2024 photo archive - 663 GiB, 20456 files, 2156 dirs. /mnt/immich
# has mirror-refresh.sh looking after it; this tree had nothing at all.
#
# THE TARGET IS THE DRIVE THIS JOB WAS ALWAYS MEANT TO HAVE, arrived at the long
# way round. The HGST HTS541010A9E680 was earmarked as /mnt/immich-2024-backup
# from the start, got consumed as /mnt/servarr during the 2026-07 migration, and
# came back on 2026-09-10 when ServarrMedia moved to the WD 8 TB and its copy
# here was proven redundant. In between, the target was the Kingston XS2000 at
# /mnt/xs - a removable stick that then left the box, taking the archive's only
# second copy with it and leaving this tree single-copy again for a week.
#
# THE 8 TB IS NOT THE TARGET, AND THE REASON IS THE DOCK, NOT THE ROOM. /mnt/wd8
# has 6.4 T free and looked like the obvious destination. It sits in the SAME
# Ugreen dock as the source: usb4/4-2 bay 1 is immich-2024, bay 2 is wd8, one
# 5 Gbit link shared between them. A 663 GiB sustained read and write down one
# link, on the dock that logged 24 resets in a day under load, is the worst pair
# available. The HGST is on usb4/4-1 - a different root port, its own 5 Gbit
# link. Same controller, but the controller is 10 Gbit and never the constraint.
# Measure the topology before choosing a bay: `udevadm info -q path -n sdX`.
#
# TARGET IS ext4 NOW, WHICH RETIRES A WHOLE PARAGRAPH OF CONCESSIONS. The XS2000
# was exfat, so this script ran with -rlt --no-perms --no-owner --no-group and a
# --modify-window=1, and a restore from it would have needed a chown. ext4 on
# both ends means plain -aHAX: perms, owners, hardlinks and xattrs all survive,
# and the copy is a restore rather than a payload needing repair. The exfat
# survey that used to live here (no hardlinks, uniform me:me, no illegal
# filenames, 4 files over 4 GiB against a ceiling far above FAT32's remembered
# limit) is now only of historical interest - but re-run something like it if
# this is ever pointed at a non-POSIX filesystem again.
#
# ROOM IS NO LONGER THIN. The XS2000 gave 37 GiB of slack on 663-into-700, which
# was defensible only because 1970-2024 is a CLOSED set - new photos land on
# /mnt/immich, not here. The HGST offers 921 G against 663, so the slack
# assumption is no longer load-bearing. The closed-set fact still is: if this
# tree ever starts growing, revisit both.
#
# THE SOURCE DOCK IS THE FLAKY ONE, not the target, and that has not changed
# with the move. immich-2024 shares usb4/4-2 with wd8; that dock logged 24
# 'usb 4-2: reset' events in the 24h before this script was written, clustered
# under load - which is exactly what a 663 GiB sustained read is. Expect the
# source to drop mid-run. Hence: --partial-dir, and a retry loop that re-mounts
# before trying again (nofail only applies at boot; after a bus drop a mount
# needs an explicit `mount`). Do not identify a drive by /dev/sdX in any of
# this: every letter reshuffles across a reboot here and one enclosure reports a
# fake serial, so the guards below are by UUID.
#
# --partial-dir, NOT --append-verify. A source-side drop leaves a truncated file
# at the destination; --partial-dir parks it under .rsync-partial/ so it is never
# mistaken for a complete file, and rsync uses it as the delta basis next run.
# --append-verify assumes the destination is a strict prefix of the source, which
# a torn write does not guarantee.
#
# --delete is OFF, same reasoning as mirror-refresh.sh: a deletion in the immich
# UI must not propagate to the only other copy.
#
# IT NO LONGER CLASHES WITH mirror-refresh.sh. That warning was real when both
# jobs touched drives in one dock; after 2026-09-10 they share nothing at all -
# mirror-refresh reads the internal nvme and writes usb3/3-2.4, this reads
# usb4/4-2 and writes usb4/4-1. Re-check that before adding a third job.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

SRC=/mnt/immich-2024/admin
DST=/mnt/immich-2024-backup/immich-2024-archive
SRC_MNT=/mnt/immich-2024;        SRC_UUID=63c1de22-0607-40bc-aa35-168bf78927fb
DST_MNT=/mnt/immich-2024-backup; DST_UUID=fd0b0662-d574-40f5-930d-de8dc0fc5082
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
  # SUDO ON BOTH SIDES. It read the source with sudo and the destination without,
  # which is the same asymmetry that made a hub self-check report healthy restic
  # repos as MISSING: a bare `find` under a directory it cannot traverse
  # undercounts silently and prints MISMATCH on a good copy. A hand-run -verify
  # is the only caller that hits this - the unit runs as root - which is exactly
  # why it survived.
  sf=$(sudo find "$SRC" -type f 2>/dev/null | wc -l)
  df_=$(sudo find "$DST" -type f -not -path '*/.rsync-partial/*' 2>/dev/null | wc -l)
  sd=$(sudo find "$SRC" -type d 2>/dev/null | wc -l)
  dd=$(sudo find "$DST" -type d -not -name '.rsync-partial' 2>/dev/null | wc -l)
  # File bytes, not du: see the gate at the bottom of this script for why the
  # directory allocation of the two trees is expected to differ.
  sfb=$(sudo find "$SRC" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  dfb=$(sudo find "$DST" -type f -not -path '*/.rsync-partial/*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  echo "  files: src=$sf dst=$df_    dirs: src=$sd dst=$dd"
  echo "  file bytes: src=$sfb dst=$dfb    (du -sb: src=$src_bytes dst=$dst_bytes, dirs included)"
  [ "$sf" = "$df_" ] && [ "$sfb" = "$dfb" ] && say "MATCH" || say "MISMATCH - re-run with -go"
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
FLAGS=(-aHAX
       --partial --partial-dir=.rsync-partial
       --human-readable --info=stats2
       --exclude=/lost+found/ --exclude=.rsync-partial/)
# progress2 ONLY on a terminal. It repaints one line with \r, which is what you
# want when watching and useless in a file: under the first nohup'd run it wrote
# 124 KB in the first minute and left a log no one can read. stats2 above already
# prints the summary that matters to a log, and systemd captures stdout, so a
# timer-driven run must not set this.
[ "$MODE" = go ] && [ -t 1 ] && FLAGS+=(--info=progress2)

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
# THE GATE IS FILES, NOT `du`. It used to require exact `du -sb` equality
# between the two trees, and that is not a property a good copy has: du sums
# directory st_size too, and a directory that has grown and had entries deleted
# does not allocate like a freshly created copy of it. Measured mid-run on
# 2026-09-10: 2156 source dirs summed to 9,011,200 bytes while the fresh copies
# averaged ~20 bytes each SMALLER. So the old gate would have printed
# ARCHIVE MIRROR INCOMPLETE after two and a half hours of a perfectly good copy,
# and the obvious response - re-run it - would have found nothing to fix and
# said INCOMPLETE again. It was inherited from the exfat target, where it was
# wrong for a different reason.
#
# What is compared instead: the number of regular files, and the sum of their
# sizes. Directories are excluded from both. `du` is still PRINTED, because the
# difference between the two numbers is exactly the thing this comment is about
# and a reader deserves to see it rather than be told.
#
# NO LINK-GROUP AXIS, on a checked premise: this tree has 0 files with nlink>1
# (measured 2026-09-10, and the 2026-08-01 survey said the same). -aHAX carries
# -H so the property is preserved if that ever changes, and the assertion below
# fails loudly if it does - which is the point at which this gate needs the
# grouping axis that migrate-servarr-wd8.sh has.
fcount(){ sudo find "$1" -type f -not -path '*/.rsync-partial/*' 2>/dev/null | wc -l; }
fbytes(){ sudo find "$1" -type f -not -path '*/.rsync-partial/*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
flinked(){ sudo find "$1" -type f -links +1 -not -path '*/.rsync-partial/*' 2>/dev/null | wc -l; }

sf=$(fcount "$SRC");  df_=$(fcount "$DST")
sb=$(fbytes "$SRC");  db=$(fbytes "$DST")
sl=$(flinked "$SRC"); dl=$(flinked "$DST")
sdu=$(sudo du -sb "$SRC" | cut -f1); ddu=$(sudo du -sb "$DST" | cut -f1)
printf '  files       src=%-14s dst=%-14s %s\n' "$sf" "$df_" "$([ "$sf" = "$df_" ] && echo ok || echo MISMATCH)"
printf '  file bytes  src=%-14s dst=%-14s %s\n' "$sb" "$db" "$([ "$sb" = "$db" ] && echo ok || echo MISMATCH)"
printf '  hardlinked  src=%-14s dst=%-14s %s\n' "$sl" "$dl" "$([ "$sl" = "$dl" ] && echo ok || echo MISMATCH)"
printf '  du -sb      src=%-14s dst=%-14s (informational - directory allocation differs)\n' "$sdu" "$ddu"
leftover=$(sudo find "$DST" -type d -name .rsync-partial 2>/dev/null | wc -l)
[ "$leftover" = 0 ] || echo "  WARNING $leftover .rsync-partial dirs remain - the run was incomplete"
if [ "$sl" != 0 ]; then
  say "NOTE the source now has $sl hardlinked files where it had none."
  say "     Counts and byte sums cannot see link GROUPING - add that axis before"
  say "     trusting this gate again (see migrate-servarr-wd8.sh phase_verify)."
fi
if [ "$sf" = "$df_" ] && [ "$sb" = "$db" ] && [ "$sl" = "$dl" ] && [ "$leftover" = 0 ]; then
  say "ARCHIVE MIRROR OK - $SRC now has a second copy at $DST"
else
  say "ARCHIVE MIRROR INCOMPLETE - re-run; it resumes from .rsync-partial"
  exit 1
fi
