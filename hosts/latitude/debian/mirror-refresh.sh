#!/usr/bin/env bash
# Refresh /mnt/immich-mirror from /mnt/immich.
#   ./mirror-refresh.sh -n     dry run (default: prints what would change)
#   ./mirror-refresh.sh -go    actually copy
#
# DELIBERATE EXCLUSIONS (decided 2026-07-31 - do not "fix" these):
#   ImmichMedia/postgres        live PGDATA. An rsync of a running postgres data dir
#                               yields a torn copy that LOOKS like a backup and is
#                               unrestorable. The real DB backup is var-backups/immich-db.
#
# The Media/{movies,torrents,tv,xxx} excludes are GONE (2026-08-01) because the
# tree itself is gone: the servarr payload moved off /mnt/immich (to the HGST in
# 2026-08, and on to /mnt/wd8/ServarrMedia on 2026-09-10 — do not chase the sd
# letter, that is what the label is for) and the orphaned /mnt/immich/Media copy
# was deleted after verifying the
# survivor matched on file count, apparent bytes, hardlink count and a content
# sample. Nothing here excludes it any more because there is nothing to exclude.
# That payload is still deliberately UNBACKED-UP - it is seeded, re-acquirable
# torrent data, and this script only ever mirrors /mnt/immich. Do not "fix" that
# by adding /mnt/wd8 to the source list.
#
# ServarrConfig IS mirrored on purpose - jellyfin + *arr configs are not
# re-derivable. (It used to live at Media/config; it is /mnt/immich/ServarrConfig
# now, still under $S and still unexcluded, so it keeps being copied.)
#
# -H IS MANDATORY. Without it the immich library expands past what fits.
#
# --delete is OFF. A photo deleted in the immich UI must not propagate to the backup,
# and the mirror holds dest-only trees the source does not have: staging/ (the only
# second copy of the GoPro video) and var-backups/. If you ever add --delete, also add
# --filter="protect /staging/" --filter="protect /var-backups/" and a --backup-dir.
#
# NOTE: the mirror still holds its own copy of the old Media/ tree from before the
# move. Deleting it there is a separate decision - --delete is off, so this script
# will never remove it for you.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
S=/mnt/immich; D=/mnt/immich-mirror
DRY=-n; [ "${1:-}" = "-go" ] && DRY=""
# MOUNT IDENTITY IS CHECKED BY UUID, AND THIS IS THE ONLY GUARD THERE IS.
# /mnt/immich-mirror is deliberately NOT in install-docker-ordering.sh's MOUNTS
# - nothing in docker binds it, and that array is derived from live binds - so
# its mountpoint dir is not chattr +i and nothing turns a missing destination
# into EPERM. Without this check an unmounted mirror means half a terabyte
# written onto the root filesystem. The test used to be `findmnt -no SOURCE`,
# which only proves SOMETHING is mounted there; on a box where every sd letter
# reshuffles and one enclosure reports a fake serial, "right mountpoint, wrong
# disk" is reachable, so the check is by UUID like archive-mirror.sh's.
#
# A MISSING MOUNT IS REMOUNTED ONCE; A WRONG ONE IS NEVER TOUCHED. nofail only
# applies at boot, so after a bus drop the mount needs an explicit `mount` -
# not doing that is what cost 90 minutes of unnoticed mirror downtime on
# 2026-09-10. But unlike archive-mirror.sh this does NOT umount first: docker
# binds $S, and unmounting a live bind to "repair" an identity mismatch is a
# worse failure than refusing to run. Wrong UUID means FATAL, hands off.
S_UUID=d0dd3972-d279-4b57-8ab4-35d17f37b955   # nvme0n1p1 - INTERNAL, not a dock
D_UUID=a7d7b61e-94b1-4673-af71-81152061199f   # the mirror disk, NS1066 enclosure
# 78 = "a mount is not what it should be", distinct from rsync's own codes and
# from the unit's flock conflict code (75), so ExecMainStatus alone says which
# of the three happened. Changing either means changing the other; see the unit.
E_MOUNT=78
for pair in "$S:$S_UUID" "$D:$D_UUID"; do
  m=${pair%:*}; u=${pair#*:}
  got=$(findmnt -no UUID "$m" 2>/dev/null || true)
  if [ -z "$got" ]; then
    echo "WARN $m not mounted - remounting once"
    sudo mount "$m" 2>/dev/null || true
    got=$(findmnt -no UUID "$m" 2>/dev/null || true)
  fi
  # findmnt lists EVERY mount at a target, so a stacked mountpoint comes back as
  # several UUIDs and never equals $u - it fails closed, which is right: a
  # backup destination with something mounted over it is not a state to write
  # into. Reachable here for real, not just in a test: after a bus drop the
  # remount can land on top of a mount the kernel has not torn down. Say so,
  # and flatten the value so the message stays one line.
  case $got in
    *"$u"*) [ "$got" = "$u" ] || { echo "FATAL $m has STACKED mounts (top layer is not the disk): $(echo $got)"; exit "$E_MOUNT"; } ;;
  esac
  [ "$got" = "$u" ] || {
    echo "FATAL $m is not the expected filesystem (want UUID=$u, got '$(echo ${got:-nothing mounted})')"
    exit "$E_MOUNT"; }
done
echo "mounts verified by UUID"
EX=(--exclude=/ImmichMedia/postgres/ --exclude=/lost+found/)
# EXIT STATUS IS LOAD-BEARING NOW - this runs under a systemd timer.
#
# It used to end with `[ -n "$DRY" ] && echo ...`, which is FALSE under -go and
# was the last command, so a fully successful `mirror-refresh.sh -go` always
# exited 1. Invisible when typed by hand; under the timer every nightly run
# reported Failed, which is worse than no alert because it teaches you to ignore
# the one that matters. Neither rsync's status was checked either, so real
# failures were equally unreported. Found 2026-08-01 by starting the unit instead
# of trusting a hand-run.
rc=0
echo "=== library + config ==="
rsync -aHAX $DRY --info=stats2 "${EX[@]}" "$S/" "$D/" || rc=$?
echo "=== current DB dumps ==="
rsync -a $DRY --info=stats2 /var/backups/immich-db "$D/var-backups/" || rc=$?
if [ -n "$DRY" ]; then echo "(dry run - pass -go to apply)"; fi
# 24 = "some files vanished before they could be transferred". Expected against a
# live immich library and not a failure; anything else is.
[ "$rc" = 24 ] && rc=0
exit "$rc"
