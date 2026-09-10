#!/usr/bin/env bash
# Make Docker on latitude survive a reboot with its media drive attached.
#   ./install-docker-ordering.sh        show what would change
#   ./install-docker-ordering.sh -go    apply (edits fstab, writes daemon.json,
#                                       freezes mountpoints, restarts dockerd if
#                                       daemon.json changed -- bounces immich)
#   ./install-docker-ordering.sh -off   revert all three changes
#
# THE BUG THIS FIXES, from the 2026-08-03 reboot that broke Jellyfin playback
# and Seerr's library sync at once. Boot timeline that day:
#
#   20:02:21  boot
#   20:02:25  /mnt/immich up          (internal nvme - fast)
#   20:02:28  docker up               <- containers start HERE
#   20:02:56  /mnt/servarr up         <- USB enclosure, 28s too late
#
# Docker started first, so every container binding ${DATA_ROOT} resolved
# /mnt/servarr/ServarrMedia/{movies,tv,xxx} against the still-EMPTY mountpoint
# and helpfully created those dirs on the root filesystem. The drive then
# mounted over the top, hiding them. Result: jellyfin, qbittorrent, radarr,
# sonarr, bazarr and whisparr all saw an empty /data for a full day while the
# host showed a healthy, fully-populated /mnt/servarr. Jellyfin's DB still
# listed every episode, so the library looked fine and playback 404'd:
#
#   ffmpeg: Error opening input: No such file or directory
#   DirectoryNotFoundException: /data/tv/.../S02E01...mkv
#
# The SAME race broke DNS. Tailscale rewrites /etc/resolv.conf shortly after
# tailscaled comes up; containers that start before that snapshot whatever was
# there (a 127.0.0.53 stub), and Docker records "NO EXTERNAL NAMESERVERS
# DEFINED". Seerr then failed every 5 minutes on
#
#   Sync interrupted: getaddrinfo EAI_AGAIN raw.githubusercontent.com
#
# and aborted the whole Jellyfin scan on that one download, so Seerr connected
# but listed no media. The *arrs additionally tripped "All indexers unavailable
# for more than 6 hours" -- fallout, not a separate fault.
#
# Both halves are ONE root cause: containers starting before the host was ready.
# Two independent guards, because the two resources become ready at different
# times and neither implies the other. A third was added 2026-09-08 after the
# same race recurred on a different disk -- see GUARD 3.
#
# GUARD 1 - fstab ordering, not a hard dependency. `x-systemd.before=` makes the
# mount unit order itself before docker.service, so Docker waits for the mount
# ATTEMPT to settle. `nofail` stays: a dead drive delays boot by the existing
# x-systemd.device-timeout=60 and Docker still starts. The stricter option -
# RequiresMountsFor= in a docker.service drop-in - was rejected on purpose: it
# would take immich down whenever the USB enclosure fails to enumerate, and that
# enclosure is the fleet's flaky one.
#
# GUARD 2 - pin Docker's DNS, so resolv.conf timing stops mattering at all.
# 100.100.100.100 FIRST is load-bearing: it is Tailscale's resolver, and it is
# what makes MagicDNS (*.gg.ez) resolve INSIDE containers. 1.1.1.1 is the
# fallback for when Tailscale is down. Quad100 is reachable from the docker
# bridge - verified from a container on servarr_default before this was written.
#
# GUARD 3 - make the silent failure impossible, not merely unlikely. Ordering
# NARROWS the race window; it cannot close it. A dock that is powered off has no
# window at all, it simply never arrives, and Docker's own behaviour does the
# rest: a missing bind source is CREATED, so the container comes up healthy on an
# empty directory and nothing anywhere reports an error.
#
# So take the mkdir away. `chattr +i` on the mountpoint dir UNDERNEATH the mount
# makes Docker's auto-create fail with EPERM and the container refuse to start.
# While the disk is mounted that immutable inode is shadowed and every write goes
# to the real filesystem, so it costs nothing in the happy path. What it buys is
# a stopped container you can see in `docker ps`, instead of an empty library you
# cannot see anywhere.
#
# Reaching the underlying dir needs a second view of the root filesystem
# (`mount --bind /`), because the mount hides it. No unmount, no container stop.
#
# THE ASSUMPTION THE WHOLE GUARD RESTS ON, AND IT IS MEASURED, NOT RECALLED:
# mount() does not write to the target inode, so a filesystem CAN still be
# mounted over an immutable directory. If that were false this guard would leave
# every disk unmounted at boot AND every container refusing to start -- a
# whole-box outage traded for a one-service one. Measured on latitude
# 2026-09-08, and the check is four lines if it ever needs re-measuring:
#
#   sudo mkdir -p /tmp/g3/{target,src} && sudo touch /tmp/g3/src/canary
#   sudo chattr +i /tmp/g3/target
#   sudo mount --bind /tmp/g3/src /tmp/g3/target && ls /tmp/g3/target   # -> canary
#   sudo umount /tmp/g3/target; sudo chattr -i /tmp/g3/target; rm -rf /tmp/g3
#
# The live consequence, same day: `lsattr -d /mnt/immich-2024` shows NO `i` while
# the disk is mounted. That is not the bit having been lost -- it is lsattr
# reading sde2's root dir, with the frozen root-fs inode correctly shadowed
# underneath. Check the bit through $ROOTVIEW, never at the mountpoint path.
#
# THE RECURRENCE THAT FORCED THIS, 2026-09-08. Same race, different disk. Boot
# timeline of 2026-09-03:
#
#   18:44:24  boot
#   18:45:02  docker up               <- containers start HERE
#   (later)   /mnt/immich-2024 up     <- USB dock, too late again
#
# immich_server's 19 archive binds (${LOCATION_1970}..${LOCATION_2024}) resolved
# against the empty mountpoint, Docker created them on the root filesystem, and
# sde2 mounted over the top. For five days every 2007-2024 photo download
# returned
#
#   ERROR [Api:LoggingRepository] Unable to send file: Error: ENOENT:
#   no such file or directory, access '/data/library/admin/2023/.../IMG_1842.JPG'
#
# while the host showed a healthy, fully-populated /mnt/immich-2024 and the
# container reported (healthy). Immich's own IntegrityService logged ~20,400
# missing files at 03:05 daily and nobody was reading it. Guard 1 would have
# prevented it -- immich-2024 was excluded from MOUNTS on a premise nobody
# re-checked. Guard 3 exists because "nobody re-checked" is not a fault you can
# fix by being more careful next time.
#
# Applying guard 2 needs a dockerd restart: the `dns` key is read at daemon
# start, and SIGHUP does not cover it. That bounces immich and its postgres.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

FSTAB=/etc/fstab
DAEMON_JSON=/etc/docker/daemon.json
OPT='x-systemd.before=docker.service'
# Only the mounts Docker actually binds -- DERIVED FROM THE LIVE BINDS, not from
# memory. The command that produces this list, run on latitude 2026-09-08:
#
#   for c in $(docker ps -a --format '{{.Names}}'); do
#     docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$c"
#   done | cut -d: -f1 | grep ^/mnt/ | cut -d/ -f1-3 | sort -u
#
# It says: immich_server binds 19 year-dirs under /mnt/immich-2024, restic-server
# binds /mnt/wd8/restic-rest, the servarr stack binds /mnt/wd8/ServarrMedia, and
# immich binds /mnt/immich. Both of the last two moved onto /mnt/wd8 on
# 2026-09-10 — media first, then the repositories.
#
# THIS LIST WAS WRONG UNTIL 2026-09-08, AND THAT IS WHY THE BUG RECURRED. It read
# `(/mnt/immich /mnt/servarr)` under a comment asserting that "immich-2024 /
# immich-mirror / spare320 / xs belong to the rsync timers" and that ordering
# Docker behind them "would hand that dock a veto over immich". Both halves were
# false:
#
#   - immich-2024 and spare320 are bound by CONTAINERS, not merely rsync'd. The
#     archive mounts have been in immich's compose.yml since the migration; the
#     comment described the disks' other job and mistook it for their only one.
#   - There is no veto to hand out. `nofail` is on every one of these lines, so
#     an absent disk costs x-systemd.device-timeout=60 and Docker starts anyway
#     -- which is exactly what the GUARD 1 paragraph above already argued. The
#     exclusion contradicted its own stated rationale and nobody noticed.
#
# Re-derive this list from live binds before trusting it. A disk's membership
# here is a fact about what Docker binds today, not about what the disk is for.
#
# immich-mirror and xs stay out on a CHECKED premise: no container binds either
# (mirror is rsync-only, written by mirror-refresh.sh; xs is archive-mirror.sh's
# removable target and is marked `transient` in the statusboard disk map).
# /mnt/wd8 is listed BEFORE any container binds it, and that is deliberate —
# the one exception to "derive this list from live binds". migrate-servarr-wd8.sh
# refuses to cut over until this entry exists and `-go` has run, because the
# window it protects is the very first `compose up` against the new disk: that
# is precisely when the mountpoint is unfrozen, unordered, and empty. Adding it
# afterwards would mean guarding every start except the one that has never been
# tested. It is inert until the disk exists: fstab_patch skips a mountpoint with
# no fstab line, and guard3 skips a path with no directory.
#
# /mnt/spare320 is the mirror image of that exception: since 2026-09-10 no
# container binds it, and by the live-binds rule it should be gone. It stays for
# the burn-in window, because it still holds the ONLY other copy of the two
# restic repositories that moved to /mnt/wd8. Freezing a mountpoint nothing binds
# costs nothing and keeps a stray bind from quietly writing to the fallback copy.
# It leaves this list when the disk leaves the box, not before.
#
# /mnt/servarr LEFT this list on 2026-09-10, and that departure is what guard3's
# retirement scan exists for. Its media copy was proven redundant — files,
# inodes, real and apparent bytes and hardlink GROUPS all matched /mnt/wd8, and
# qBittorrent had already rechecked every torrent against the new disk — so the
# HGST was emptied and remounted as /mnt/immich-2024-backup, the second copy of
# the closed 1970-2024 archive, which no container binds either.
#
# Deleting a name from this array used to be a silent one-way door: guard3_apply
# only ever froze what was LISTED, so a retired mountpoint kept its `chattr +i`
# forever with nothing in the repo saying so, and the only documented revert
# (`-off`) also strips the DNS pin and restarts dockerd — bouncing immich and
# postgres to unfreeze one directory. `add` now unfreezes any frozen /mnt/* dir
# that is NOT in this list, so retiring a mountpoint is the same single action as
# adding one: edit the array, run the script.
MOUNTS=(/mnt/immich /mnt/immich-2024 /mnt/spare320 /mnt/wd8)
DNS_JSON='{"dns": ["100.100.100.100", "1.1.1.1"]}'

MODE=show
case "${1:-}" in
  -go)  MODE=go ;;
  -off) MODE=off ;;
  ""|-n) MODE=show ;;
  *) echo "usage: $0 [-n|-go|-off]"; exit 2 ;;
esac

say(){ echo "[docker-ordering] $*"; }

# --- fstab -------------------------------------------------------------------
# Rewritten in python, not sed: fstab is boot-critical and field-positional, and
# a regex that eats the wrong column here costs a rescue boot. `findmnt --verify`
# gates the swap-in, so a malformed file is never left in place.
# Writes the candidate to $2 and prints the changed mountpoints on stderr.
# python writes the file itself: routing it through $(...) silently ate the
# trailing newline on /etc/fstab, which the dry run caught as a phantom diff on
# the last entry. Never round-trip a boot-critical file through a subshell.
fstab_patch() {
  local action="$1" outfile="$2"
  python3 - "$FSTAB" "$action" "$OPT" "$outfile" "${MOUNTS[@]}" <<'PY'
import sys
path, action, opt, outfile, *targets = sys.argv[1:]
out, changed = [], []
for line in open(path).read().splitlines(keepends=True):
    s = line.strip()
    f = s.split()
    if s.startswith('#') or len(f) < 4 or f[1] not in targets:
        out.append(line); continue
    opts = [o for o in f[3].split(',') if o]
    if action == 'add':
        if opt in opts:
            out.append(line); continue
        opts.append(opt)
    else:
        if opt not in opts:
            out.append(line); continue
        opts = [o for o in opts if o != opt]
    f[3] = ','.join(opts)
    nl = '\n' if line.endswith('\n') else ''
    # Re-pad to keep the file readable; column alignment is cosmetic only.
    out.append('%-42s  %-22s  %-6s  %s  %s %s%s'
               % (f[0], f[1], f[2], f[3], f[4], f[5], nl) if len(f) >= 6
               else '  '.join(f) + nl)
    changed.append(f[1])
with open(outfile, 'w') as fh:
    fh.write(''.join(out))
sys.stderr.write(' '.join(changed))
PY
}

fstab_apply() {
  local action="$1" tmp changed
  tmp=$(mktemp)
  fstab_patch "$action" "$tmp" 2>"$tmp.err" || { say "FATAL fstab rewrite failed"; rm -f "$tmp" "$tmp.err"; return 1; }
  changed=$(cat "$tmp.err"); rm -f "$tmp.err"
  if [ -z "$changed" ]; then
    say "fstab already correct ($action)"; rm -f "$tmp"; return 0
  fi
  if [ "$MODE" = show ]; then
    say "would $action '$OPT' on:$changed"
    diff -u "$FSTAB" "$tmp" | sed 's/^/    /'
    rm -f "$tmp"; return 0
  fi
  # Verify the CANDIDATE before it becomes /etc/fstab, not after.
  if ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
    say "FATAL candidate fstab failed 'findmnt --verify' - not installing"
    findmnt --verify --tab-file "$tmp" 2>&1 | sed 's/^/    /'
    rm -f "$tmp"; return 1
  fi
  sudo cp -a "$FSTAB" "$FSTAB.bak.$(date +%Y%m%d%H%M%S)"
  sudo install -m644 "$tmp" "$FSTAB" && say "fstab: ${action}ed '$OPT' on:$changed"
  rm -f "$tmp"
}

# --- daemon.json -------------------------------------------------------------
# Merge rather than clobber. There is no daemon.json on latitude today, but a
# future one may carry unrelated keys, and silently dropping a log-driver or
# storage-driver setting is exactly the kind of thing that shows up three
# reboots later.
RESTART_NEEDED=0

daemon_json_apply() {
  local action="$1" tmp
  tmp=$(mktemp)
  python3 - "$DAEMON_JSON" "$action" "$DNS_JSON" >"$tmp" <<'PY'
import json, os, sys
path, action, dns_json = sys.argv[1:4]
cur = {}
if os.path.exists(path):
    with open(path) as fh:
        body = fh.read().strip()
    if body:
        cur = json.loads(body)
want = json.loads(dns_json)
if action == 'add':
    cur.update(want)
else:
    for k in want:
        cur.pop(k, None)
print(json.dumps(cur, indent=2))
PY
  if [ $? -ne 0 ]; then say "FATAL $DAEMON_JSON is not valid JSON - fix by hand"; rm -f "$tmp"; return 1; fi
  if [ -f "$DAEMON_JSON" ] && cmp -s "$DAEMON_JSON" "$tmp"; then
    say "daemon.json already correct ($action)"; rm -f "$tmp"; return 0
  fi
  if [ "$MODE" = show ]; then
    say "would $action dns pin in $DAEMON_JSON"
    diff -u "$DAEMON_JSON" "$tmp" 2>/dev/null | sed 's/^/    /' || sed 's/^/    /' "$tmp"
    rm -f "$tmp"; return 0
  fi
  [ -f "$DAEMON_JSON" ] && sudo cp -a "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%Y%m%d%H%M%S)"
  sudo mkdir -p "$(dirname "$DAEMON_JSON")"
  sudo install -m644 "$tmp" "$DAEMON_JSON" && say "daemon.json: dns pin ${action}ed"
  rm -f "$tmp"
  # The `dns` key is read only at daemon start; SIGHUP does not cover it.
  RESTART_NEEDED=1
}


# --- guard 3: immutable mountpoints ------------------------------------------
# The rationale is in the header. Mechanics only from here.
#
# Everything operates on $ROOTVIEW$m -- the dir as it exists on the ROOT
# filesystem -- never on $m, which is whatever is mounted there right now.
ROOTVIEW=/mnt/rootview

rootview_open() {
  sudo mkdir -p "$ROOTVIEW" || return 1
  mountpoint -q "$ROOTVIEW" && return 0
  sudo mount --bind / "$ROOTVIEW"
}
rootview_close() { mountpoint -q "$ROOTVIEW" && sudo umount "$ROOTVIEW"; return 0; }

is_frozen() { sudo lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q i; }

# Split the mounts into those whose ghost tree is safe to delete (empty dirs
# only) and those that are not.
#
# NEVER DELETE BLINDLY. A container that started against a ghost may have
# WRITTEN into it -- qbittorrent downloading into /mnt/servarr/ServarrMedia is
# the obvious way this stops being cosmetic and becomes data loss. Empty dirs go;
# a single non-empty regular file anywhere in the tree stops the script and is
# reported for a human to move.
#
# 2026-09-08, the only file the fleet had: a 0-byte
# /mnt/spare320/restic-rest/.htpasswd, auto-created during the 2026-08-27 race.
# The populated 136-byte original was safe on sdc1 the whole time. That is the
# failure restic-hub-selfcheck.sh's "one .htpasswd" check exists to catch, and
# it is why this function reports rather than assumes.
ghost_scan() {
  local m under
  GHOSTS=(); KEEPERS=()
  for m in "${MOUNTS[@]}"; do
    under="$ROOTVIEW$m"
    [ -d "$under" ] || continue
    [ -n "$(sudo ls -A "$under" 2>/dev/null)" ] || continue
    if sudo find "$under" -type f ! -empty -print -quit 2>/dev/null | grep -q .; then
      KEEPERS+=("$m")
    else
      GHOSTS+=("$m")
    fi
  done
}

guard3_apply() {
  local action="$1" m under
  rootview_open || { say "FATAL cannot bind-mount / at $ROOTVIEW"; return 1; }

  if [ "$action" = remove ]; then
    for m in "${MOUNTS[@]}"; do
      under="$ROOTVIEW$m"
      [ -d "$under" ] || continue
      is_frozen "$under" || { say "guard3: $m already mutable"; continue; }
      if [ "$MODE" = show ]; then say "would unfreeze (chattr -i) $m"; continue; fi
      sudo chattr -i "$under" && say "guard3: unfroze $m"
    done
    rootview_close
    return 0
  fi

  ghost_scan
  # Clear the debris BEFORE freezing. Freezing first would preserve the ghost
  # tree under an immutable parent -- and a ghost dir is itself writable, so
  # Docker's mkdir would still succeed one level down and the guard would be
  # decorative.
  if [ "${#KEEPERS[@]}" -gt 0 ]; then
    say "FATAL ghost trees under ${KEEPERS[*]} hold NON-EMPTY files."
    say "      Something wrote real data while the disk was absent. Move it by"
    say "      hand, then re-run; this script will not delete it for you."
    for m in "${KEEPERS[@]}"; do
      sudo find "$ROOTVIEW$m" -type f ! -empty -printf '        %10s  %p\n' 2>/dev/null | head -20
    done
    rootview_close
    return 1
  fi

  for m in "${GHOSTS[@]}"; do
    if [ "$MODE" = show ]; then
      say "would delete ghost tree under $m (empty dirs only):"
      sudo find "$ROOTVIEW$m" -mindepth 1 2>/dev/null | sed "s|$ROOTVIEW||; s|^|        |" | head -25
      continue
    fi
    is_frozen "$ROOTVIEW$m" && sudo chattr -i "$ROOTVIEW$m"
    sudo find "$ROOTVIEW$m" -mindepth 1 -delete 2>/dev/null
    say "guard3: cleared ghost tree under $m"
  done

  # RETIREMENT -- the direction this guard was missing. A path deleted from
  # MOUNTS keeps its immutable bit unless something takes it off, and nothing
  # did, so "removed from the array" and "still frozen on disk" could disagree
  # indefinitely. Scoped to /mnt/* one level deep: the guard set never holds
  # anything else, and a blind fleet-wide `chattr -i` is not this script's to
  # own. $ROOTVIEW itself lands in this glob and is skipped by is_frozen.
  for under in "$ROOTVIEW"/mnt/*; do
    [ -d "$under" ] || continue
    m=${under#"$ROOTVIEW"}
    case " ${MOUNTS[*]} " in *" $m "*) continue ;; esac
    is_frozen "$under" || continue
    if [ "$MODE" = show ]; then say "would RETIRE (chattr -i) $m - no longer in MOUNTS"; continue; fi
    sudo chattr -i "$under" && say "guard3: retired $m - unfrozen, no longer in MOUNTS"
  done

  for m in "${MOUNTS[@]}"; do
    under="$ROOTVIEW$m"
    if [ ! -d "$under" ]; then say "guard3: $m has no underlying dir (?)"; continue; fi
    if is_frozen "$under"; then say "guard3: $m already frozen"; continue; fi
    if [ "$MODE" = show ]; then say "would freeze (chattr +i) $m"; continue; fi
    sudo chattr +i "$under" && say "guard3: froze $m"
  done

  rootview_close
}

# Prove the guard, do not trust the bit. An immutable flag that does not actually
# stop Docker's mkdir is worth nothing, and the bind sources are up to three
# levels below the frozen dir (jellyfin binds /mnt/wd8/ServarrMedia/movies),
# so "the top-level dir is enough" is an assumption that has to be measured.
guard3_verify() {
  local m under probe rc
  rootview_open || return 1
  for m in "${MOUNTS[@]}"; do
    under="$ROOTVIEW$m"
    probe="$under/.guard3probe/deep/deeper"
    sudo mkdir -p "$probe" 2>/dev/null; rc=$?
    if [ $rc -ne 0 ]; then
      say "verified: mkdir under $m refused (EPERM) - Docker cannot ghost this mount"
    else
      say "WARNING: mkdir under $m SUCCEEDED - guard 3 is not effective here"
      sudo rm -rf "$under/.guard3probe"
    fi
  done
  rootview_close
}

# --- run ---------------------------------------------------------------------
ACTION=add; [ "$MODE" = off ] && ACTION=remove

fstab_apply "$ACTION" || exit 1
if [ "$MODE" != show ]; then
  sudo systemctl daemon-reload
  # Prove the ordering edge actually exists rather than trusting the option
  # spelling. systemd silently ignores an x-systemd.* it does not understand.
  for m in "${MOUNTS[@]}"; do
    unit=$(systemd-escape -p --suffix=mount "$m")
    if [ "$ACTION" = add ]; then
      systemctl show "$unit" -p Before --value | tr ' ' '\n' | grep -qx docker.service \
        && say "verified: $unit Before=docker.service" \
        || say "WARNING: $unit has no Before=docker.service - check systemd version supports x-systemd.before="
    fi
  done
fi

daemon_json_apply "$ACTION" || exit 1
guard3_apply "$ACTION" || exit 1

if [ "$MODE" = show ]; then
  say "(dry run - pass -go to apply)"
  exit 0
fi

if [ "$RESTART_NEEDED" -eq 1 ]; then
  say "restarting dockerd to pick up the dns pin (immich + postgres bounce)"
  sudo systemctl restart docker
  sleep 10
fi

say "--- state ---"
[ "$ACTION" = add ] && guard3_verify
# --fstab, not the live table: x-systemd.* are generator directives, not kernel
# mount options, so `findmnt /mnt/wd8` shows only "rw,noatime" and looks like
# the edit did not land. The Before= check above is the real verification.
for m in "${MOUNTS[@]}"; do findmnt --fstab -o TARGET,OPTIONS "$m" 2>/dev/null; done
say "container DNS check:"
for c in jellyseerr jellyfin immich_server; do
  printf '  %-16s ' "$c"
  docker exec "$c" getent hosts image.tmdb.org >/dev/null 2>&1 && echo OK || echo FAIL
done
say "container media check:"
docker exec jellyfin sh -c 'printf "  /data/tv=%s /data/movies=%s\n" "$(ls /data/tv|wc -l)" "$(ls /data/movies|wc -l)"' 2>/dev/null
