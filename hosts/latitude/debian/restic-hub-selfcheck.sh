#!/usr/bin/env bash
# Verification for the restic REST hub latitude runs.
#
# MOVED HERE FROM `vps/homeserver/restic-server/selfcheck.sh` on 2026-08-29, with
# the backup system. The REST *server* stays in `vps` because it is a service;
# checking that latitude's backup hub is actually working is machine-backup work,
# which is what `machines` owns. It also sits with the rest of latitude's ops
# scripts and is installed by the `install-timers.sh` next to it -- one mechanism
# for this box's system timers, with the same copy-not-symlink review boundary.
#
# It exists because this service has now failed silently FOUR times: 29h on
# 2026-08-02, 3 days on 2026-08-04, and 2 days on 2026-08-27..29 -- every one of
# them a bind race, every one found by a manual audit rather than an alert.
#
# **On a timer since 2026-08-29** (15 min after boot, then daily at 09:00), so a
# failure now leaves a failed systemd unit, which `just health` already reports.
# That is deliberately the whole notification story: alerting proper is deferred
# (roadmap P0) and this is the cheapest thing that stops the silence.
#
# KNOWN FALSE POSITIVE: check 8 reads snapshot freshness, which is really a
# CLIENT liveness check. desktop-wsl is a laptop; a weekend off fails it with
# nothing wrong on the hub. Check 3 is the one that fires only on real hub
# breakage. The 26h threshold is left as it was found -- see it misfire before
# changing it.
#
# A non-interactive ssh PATH on Debian excludes /usr/sbin and /sbin, and this
# needs ss and findmnt.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

DRIVE_UUID="3a78fd88-deb0-4c1a-a576-14abd0631d57"
DATA="/mnt/spare320/restic-rest"
REPO="g614jv"
PORT=8001
CONTAINER="restic-server"
rc=0

check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok    %s (%s)\n' "$1" "$3"
  else
    printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    rc=1
  fi
}

# 1. The drive, by UUID. Every letter reshuffles across a reboot on this box, and
#    /mnt/spare320 is mounted `nofail` -- so an absent drive boots fine and
#    docker bind-mounts an EMPTY directory over it.
got_uuid="$(findmnt -no UUID /mnt/spare320 2>/dev/null)"
check "drive mounted by UUID" "$DRIVE_UUID" "${got_uuid:-absent}"

# 2. The repo's config object. With the drive absent a client would find no repo
#    and -- since append-only still permits creating a NEW config -- could start
#    a fresh one and report success. Client-side `initialize: false` closes it;
#    this makes it loud regardless.
#
#    NOTE: this reads the HOST path, so it is NOT the empty-bind-mount guard its
#    comment used to claim to be. Check 3 is.
[ -e "$DATA/$REPO/config" ] && s=present || s=MISSING
check "repo config present" "present" "$s"

# 3. THE empty-bind-mount guard: is the container looking at the same file the
#    host is? On 2026-08-27 restic-server started while /mnt/spare320 was
#    unmounted, so ${RESTIC_DATA_PATH}:/data bound the empty directory BENEATH
#    the mountpoint. It wrote a 0-byte .htpasswd there and kept serving it after
#    the drive came back: every client got 401 for two days while every
#    host-side check above stayed green.
#
#    Inode, not size -- size only says "a file of the same length", inode says
#    "the same file". This is the one check that fails on real hub breakage and
#    on nothing else; check 8 below cannot tell breakage from a sleeping client.
#
#    Recovery is `docker compose up -d --force-recreate`. NOT `docker restart`
#    and NOT `up -d`, both of which reuse the existing container's mount
#    configuration and leave it pinned to the shadowed directory.
host_ino="$(stat -c%i "$DATA/.htpasswd" 2>/dev/null || echo host-unreadable)"
cont_ino="$(docker exec "$CONTAINER" stat -c%i /data/.htpasswd 2>/dev/null || echo container-unreadable)"
check "container and host see one .htpasswd" "$host_ino" "$cont_ino"

# 4. A published port. The trap: a reused container comes back with
#    HostConfig.PortBindings intact and NetworkSettings.Ports EMPTY -- running,
#    logging "start server on [::]:8000", reachable by nobody. Recovery is
#    `up -d --force-recreate`, never `up -d` or `start`.
ports="$(docker inspect "$CONTAINER" --format '{{.NetworkSettings.Ports}}' 2>/dev/null)"
[ -n "$ports" ] && [ "$ports" != "map[]" ] && s=published || s="EMPTY(${ports:-no-container})"
check "port published" "published" "$s"

# 5. Something actually listening, on the wildcard address.
ss -lntp 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):$PORT|\[::\]:$PORT" && s=listening || s=NOT_LISTENING
check "listening on 0.0.0.0:$PORT" "listening" "$s"

# 6. Auth enforced. A 200 here would mean --no-auth crept back, and with a
#    wildcard bind that is every device on the LAN with delete rights.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/$REPO/config" 2>/dev/null)"
check "unauthenticated refused" "401" "$code"

# 7. Append-only and private-repos actually enabled, read from what the process
#    reported at startup. This script holds no credentials, so it CANNOT test
#    append-only behaviourally: an unauthenticated DELETE returns 401, which
#    proves auth and would keep passing green with --append-only removed. The
#    startup log is the honest credential-free assertion. The behavioural proof
#    is an authenticated DELETE of a nonexistent snapshot object returning 403
#    (403 comes before path resolution, repo.go:737) -- run at Task 8 Step 5 of
#    the plan, not here.
logs="$(docker logs "$CONTAINER" 2>&1)"
printf '%s' "$logs" | grep -q 'Append only mode enabled' && s=enabled || s=DISABLED
check "append-only enabled" "enabled" "$s"
printf '%s' "$logs" | grep -q 'Private repositories enabled' && s=enabled || s=DISABLED
check "private repos enabled" "enabled" "$s"
printf '%s' "$logs" | grep -q 'Authentication disabled' && s=DISABLED || s=enabled
check "authentication enabled" "enabled" "$s"

# 8. Freshness, which is the only assertion a lying exit status cannot fake. Read
#    from snapshot-file mtimes, so it needs no password and no cooperation from
#    the client: the box that failed cannot hide the failure.
newest="$(find "$DATA/$REPO/snapshots" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
if [ -z "$newest" ]; then
  printf 'FAIL  newest snapshot: none found\n'; rc=1
else
  age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
  if [ "$age_h" -le 26 ]; then
    printf 'ok    newest snapshot age (%sh, client is daily at 06:00)\n' "$age_h"
  else
    printf 'FAIL  newest snapshot age: %sh > 26h\n' "$age_h"; rc=1
  fi
fi

exit "$rc"
