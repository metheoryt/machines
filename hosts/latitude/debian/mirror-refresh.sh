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
# tree itself is gone: the servarr payload moved to /mnt/servarr/ServarrMedia
# (sdb2) and the orphaned /mnt/immich/Media copy was deleted after verifying the
# survivor matched on file count, apparent bytes, hardlink count and a content
# sample. Nothing here excludes it any more because there is nothing to exclude.
# That payload is still deliberately UNBACKED-UP - it is seeded, re-acquirable
# torrent data, and this script only ever mirrors /mnt/immich. Do not "fix" that
# by adding /mnt/servarr to the source list.
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
for m in "$S" "$D"; do findmnt -no SOURCE "$m" >/dev/null || { echo "FATAL $m not mounted"; exit 1; }; done
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
