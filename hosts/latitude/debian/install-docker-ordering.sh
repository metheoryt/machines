#!/usr/bin/env bash
# Make Docker on latitude survive a reboot with its media drive attached.
#   ./install-docker-ordering.sh        show what would change
#   ./install-docker-ordering.sh -go    apply (edits fstab, writes daemon.json,
#                                       restarts dockerd -- bounces immich)
#   ./install-docker-ordering.sh -off   revert both changes
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
# times and neither implies the other.
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
# Applying guard 2 needs a dockerd restart: the `dns` key is read at daemon
# start, and SIGHUP does not cover it. That bounces immich and its postgres.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

FSTAB=/etc/fstab
DAEMON_JSON=/etc/docker/daemon.json
OPT='x-systemd.before=docker.service'
# Only the mounts Docker actually binds. Deliberately NOT every /mnt entry:
# immich-2024 / immich-mirror / spare320 / xs belong to the rsync timers, and
# immich-2024+immich-mirror sit on the enclosure that logged 24 USB resets in a
# day. Ordering Docker behind those would hand that dock a veto over immich.
MOUNTS=(/mnt/immich /mnt/servarr)
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
# --fstab, not the live table: x-systemd.* are generator directives, not kernel
# mount options, so `findmnt /mnt/servarr` shows only "rw,noatime" and looks like
# the edit did not land. The Before= check above is the real verification.
for m in "${MOUNTS[@]}"; do findmnt --fstab -o TARGET,OPTIONS "$m" 2>/dev/null; done
say "container DNS check:"
for c in jellyseerr jellyfin immich_server; do
  printf '  %-16s ' "$c"
  docker exec "$c" getent hosts image.tmdb.org >/dev/null 2>&1 && echo OK || echo FAIL
done
say "container media check:"
docker exec jellyfin sh -c 'printf "  /data/tv=%s /data/movies=%s\n" "$(ls /data/tv|wc -l)" "$(ls /data/movies|wc -l)"' 2>/dev/null
