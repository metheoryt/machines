#!/usr/bin/env bash
# Move ServarrMedia from the 931 G HGST (/mnt/servarr) onto the WD 8 TB.
#
#   ./migrate-servarr-wd8.sh plan       what it would do, changes nothing
#   ./migrate-servarr-wd8.sh prepare    partition + mkfs + fstab + mount /mnt/wd8
#   ./migrate-servarr-wd8.sh sync       bulk copy, DETACHED, services stay up
#   ./migrate-servarr-wd8.sh status     progress / rate / ETA  (safe any time)
#   ./migrate-servarr-wd8.sh verify     prove the copy, hardlinks included
#   ./migrate-servarr-wd8.sh cutover    stop stack, delta, verify, swap, start
#   ./migrate-servarr-wd8.sh rollback   point the stack back at /mnt/servarr
#
# THE SOURCE IS NEVER DELETED BY THIS SCRIPT, at any phase. Reclaiming the HGST
# is a separate, manual decision made days later — that disk is the intended
# home for the archive's second copy, which is currently single-copy since the
# XS2000 came out.
#
# WHY TWO PASSES. qBittorrent writes into the tree continuously, so a single
# copy taken with the stack up is stale before it lands. Pass 1 runs live and
# moves ~all of it in a couple of hours; `cutover` then stops the stack and runs
# a delta that touches only what moved since. Downtime is the delta, not the
# copy.
#
# TRAP 1 — HARDLINKS, AND THIS ONE IS MEASURED, NOT ASSUMED. The *arr setup
# hardlinks completed torrents into the library so qBittorrent can keep seeding
# the same bytes Radarr "imported". On 2026-09-10 the tree was 736,552,035,464
# real bytes against 895,785,548,563 apparent — 148 GiB, ~20%, exists only as
# links. `rsync -H` is therefore not an optimisation, it is the difference
# between a working copy and a 834 GiB pile that breaks every seeding torrent.
# `verify` checks the link GROUPING, not just the aggregate saving: two trees
# can save the same total while linking the wrong files to each other.
#
# TRAP 2 — THE DOCKS LOSE POWER, ~8 TIMES IN FIVE WEEKS. Both UGREEN docks drop
# within one second of each other and re-enumerate ~25 s later; the AC adapter
# never goes off-line, so it is a mains dip too short for the laptop's brick and
# too long for a 12 V dock PSU. A 2.5-hour rsync will eat one sooner or later.
# Two consequences the code has to carry:
#   - The mount does NOT come back on its own. fstab is `nofail` with no
#     automount, so systemd stops the unit and leaves it `inactive dead` —
#     `systemctl --failed` stays clean (incident 2026-08-23). The worker
#     re-starts the mount units itself and resumes.
#   - Writing to an absent /mnt/wd8 would fill the ROOT filesystem. Every phase
#     re-checks both mounts with findmnt before touching anything, and the
#     worker re-checks between retries — not only at start.
#
# TRAP 3 — DO NOT RESOLVE THE DISK BY /dev/sdX. Letters reshuffle across every
# reboot here, and this script calls mkfs. The dock's own by-id name is shared
# between its two bays (`usb-..._6702002103E1-0:0` and `-0:1`), so that is not
# an identity either. The WWN is: burned into the drive, unique, and recorded at
# acceptance. All three of WWN, model+serial and byte-exact size must agree or
# the script aborts rather than picking.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# --- identity of the target disk (from the 2026-09-08 acceptance run) ---------
WWN=wwn-0x50014ee216c6bf75
EXPECT_SERIAL=WD-RD2RRPWH
EXPECT_MODEL='WDC WD80EAAZ-22BXBB0'
EXPECT_BYTES=8001563222016

# --- paths -------------------------------------------------------------------
DST_MNT=/mnt/wd8
SRC_MNT=/mnt/servarr
SRC="$SRC_MNT/ServarrMedia"
DST="$DST_MNT/ServarrMedia"
LABEL=wd8

COMPOSE_DIR=/home/me/my/vps/homeserver/servarr
ENV_FILE="$COMPOSE_DIR/.env"
ORDERING=/home/me/machines/hosts/latitude/debian/install-docker-ordering.sh

STATE=/var/lib/wd8-migrate
LOG_DIR=/var/log/wd8-migrate
UNIT=wd8-sync

say(){ printf '[wd8] %s\n' "$*"; }
die(){ printf '[wd8] FATAL %s\n' "$*" >&2; exit 1; }

# --- guards ------------------------------------------------------------------

# Both mounts live, or nothing happens. This is the guard that keeps a dock
# power drop from turning into an rsync that fills /.
need_mounts(){
  local m
  for m in "$@"; do
    findmnt -M "$m" >/dev/null 2>&1 || return 1
  done
  return 0
}

# Try to bring a dropped mount back the way the 2026-08-23 recovery did.
# Only ever starts a unit that is already declared in fstab.
remount(){
  local m
  for m in "$@"; do
    findmnt -M "$m" >/dev/null 2>&1 && continue
    say "mount $m is gone — trying to start it"
    sudo systemctl start "$(systemd-escape -p --suffix=mount "$m")" 2>&1 | sed 's/^/     /'
  done
}

# Resolve the 8 TB, or refuse. Ambiguity aborts; this is a mkfs target.
resolve_disk(){
  local dev info serial model bytes
  dev=$(readlink -f "/dev/disk/by-id/$WWN" 2>/dev/null) \
    || die "cannot resolve /dev/disk/by-id/$WWN — is the dock powered?"
  [ -b "$dev" ] || die "/dev/disk/by-id/$WWN does not point at a block device"

  info=$(sudo smartctl -i "$dev" 2>/dev/null)
  serial=$(printf '%s\n' "$info" | awk -F': *' '/^Serial Number/{print $2}')
  model=$(printf '%s\n' "$info"  | awk -F': *' '/^Device Model/{print $2}')
  bytes=$(sudo blockdev --getsize64 "$dev" 2>/dev/null)

  [ "$serial" = "$EXPECT_SERIAL" ] || die "serial mismatch on $dev: got '${serial}', want '$EXPECT_SERIAL'"
  [ "$model"  = "$EXPECT_MODEL"  ] || die "model mismatch on $dev: got '${model}', want '$EXPECT_MODEL'"
  [ "$bytes"  = "$EXPECT_BYTES"  ] || die "size mismatch on $dev: got ${bytes}, want $EXPECT_BYTES"

  printf '%s\n' "$dev"
}

# --- phases ------------------------------------------------------------------

phase_plan(){
  local dev
  dev=$(resolve_disk) || exit 1
  say "target disk : $dev  ($EXPECT_MODEL $EXPECT_SERIAL, $WWN)"
  say "partitions  : $(lsblk -no NAME,SIZE,FSTYPE "$dev" | tail -n +2 | tr '\n' ' ' | sed 's/  */ /g')"
  say "source      : $SRC"
  sudo du -sb --si "$SRC" 2>/dev/null | sed 's/^/     real     /'
  sudo du -sb --si --count-links "$SRC" 2>/dev/null | sed 's/^/     apparent /'
  say "files       : $(sudo find "$SRC" -type f | wc -l)"
  say "fstab line it would add:"
  printf '     UUID=<new>  %s  ext4  defaults,noatime,nofail,x-systemd.device-timeout=60  0 2\n' "$DST_MNT"
  say "MOUNTS in install-docker-ordering.sh contains $DST_MNT: $(grep -q "MOUNTS=.*$DST_MNT" "$ORDERING" && echo yes || echo 'NO — cutover will refuse')"
  say "(nothing was changed)"
}

phase_prepare(){
  local dev part uuid
  dev=$(resolve_disk) || exit 1

  if findmnt -M "$DST_MNT" >/dev/null 2>&1; then
    say "$DST_MNT already mounted — prepare is a no-op"
    return 0
  fi

  # Refuse to reformat a disk that already carries a filesystem with anything on
  # it. An empty partition table from a previous prepare run is fine to reuse.
  if lsblk -no FSTYPE "$dev" | grep -q .; then
    die "$dev already has a filesystem. Refusing to mkfs. Inspect it by hand:
       sudo lsblk -f $dev"
  fi

  say "writing GPT + one partition on $dev"
  printf 'label: gpt\n,,L\n' | sudo sfdisk "$dev" >/dev/null || die "sfdisk failed"
  sudo udevadm settle
  part="${dev}1"
  [ -b "$part" ] || die "expected $part to appear after partitioning"

  # -m 1, not -m 0. The default 5% reserve would be 365 G here, which is worth
  # reclaiming, but 0% is not the way: the reserve is also what keeps ext4 from
  # fragmenting badly as the filesystem fills, and this disk holds an actively
  # growing torrent target. 1% is 73 G against 5.7 T that stays free anyway.
  say "mkfs.ext4 on $part (label $LABEL, 1% reserve)"
  sudo mkfs.ext4 -q -m 1 -L "$LABEL" "$part" || die "mkfs failed"

  uuid=$(sudo blkid -s UUID -o value "$part") || die "cannot read UUID of $part"
  say "UUID=$uuid"

  if grep -q "[[:space:]]$DST_MNT[[:space:]]" /etc/fstab; then
    say "fstab already has a $DST_MNT line — leaving it alone"
  else
    sudo cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    printf 'UUID=%-36s  %-18s  ext4  defaults,noatime,nofail,x-systemd.device-timeout=60  0 2\n' \
      "$uuid" "$DST_MNT" | sudo tee -a /etc/fstab >/dev/null
    findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 \
      || die "the fstab I just wrote fails 'findmnt --verify' — restore the .bak"
    say "fstab: added $DST_MNT"
  fi
  # x-systemd.before=docker.service is deliberately NOT written here.
  # install-docker-ordering.sh owns that option for every mount Docker binds; it
  # adds it, verifies the Before= edge really exists, and freezes the mountpoint
  # in the same run. Writing it by hand here would give two owners for one line.

  sudo mkdir -p "$DST_MNT"
  sudo systemctl daemon-reload
  sudo systemctl start "$(systemd-escape -p --suffix=mount "$DST_MNT")" \
    || die "cannot mount $DST_MNT"
  need_mounts "$DST_MNT" || die "$DST_MNT still not mounted"

  sudo mkdir -p "$DST"
  sudo chown --reference="$SRC" "$DST"
  sudo chmod --reference="$SRC" "$DST"
  sudo mkdir -p "$STATE" "$LOG_DIR"
  say "ready: $(findmnt -no SOURCE,TARGET,SIZE,AVAIL "$DST_MNT")"
  say "next: $0 sync"
}

# The detached copy. Re-entrant: rerunning it resumes.
_worker(){
  local tries=0 rc
  sudo mkdir -p "$STATE" "$LOG_DIR"
  date +%s | sudo tee "$STATE/started" >/dev/null

  while :; do
    remount "$SRC_MNT" "$DST_MNT"
    if ! need_mounts "$SRC_MNT" "$DST_MNT"; then
      tries=$((tries + 1))
      [ "$tries" -gt 40 ] && { say "giving up: mounts absent after $tries tries"; return 1; }
      say "mounts not ready (try $tries/40) — waiting 30s"
      sleep 30
      continue
    fi

    say "rsync pass starting ($(date -Is))"
    ionice -c2 -n7 nice -n10 rsync -aHAX --delete \
      --partial-dir=.rsync-partial \
      --info=name,stats2 \
      --log-file="$LOG_DIR/rsync.log" \
      "$SRC/" "$DST/"
    rc=$?
    case "$rc" in
      0)  say "rsync completed cleanly ($(date -Is))"; return 0 ;;
      24) say "rsync rc=24 (files vanished mid-copy — normal with the stack up)"; return 0 ;;
      *)  tries=$((tries + 1))
          [ "$tries" -gt 40 ] && { say "giving up after $tries attempts (last rc=$rc)"; return "$rc"; }
          say "rsync rc=$rc — retry $tries/40 in 30s"
          sleep 30 ;;
    esac
  done
}

phase_sync(){
  need_mounts "$SRC_MNT" "$DST_MNT" || die "both $SRC_MNT and $DST_MNT must be mounted (run prepare?)"
  if systemctl is-active --quiet "$UNIT"; then
    say "$UNIT is already running — use '$0 status'"
    return 0
  fi
  sudo mkdir -p "$STATE" "$LOG_DIR"
  # Detached under systemd, for the same reason the badblocks run was: this
  # takes hours and must not die with the ssh session that started it.
  sudo systemd-run --unit="$UNIT" --collect \
    --description="Copy ServarrMedia to the WD 8 TB" \
    "$(readlink -f "$0")" _worker || die "systemd-run failed"
  say "started as $UNIT"
  say "watch:  journalctl -u $UNIT -f"
  say "or:     $0 status"
}

human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%s' "${1:-0}"; }

phase_status(){
  local total done_ pct start now elapsed rate eta
  printf '[wd8] unit    : %s\n' "$(systemctl is-active "$UNIT" 2>/dev/null || echo inactive)"
  need_mounts "$DST_MNT" || { say "$DST_MNT NOT MOUNTED"; return 1; }
  total=$(sudo du -sb "$SRC" 2>/dev/null | cut -f1)
  done_=$(sudo du -sb "$DST" 2>/dev/null | cut -f1)
  : "${total:=0}" "${done_:=0}"
  [ "$total" -gt 0 ] || die "cannot size $SRC"
  pct=$(( done_ * 100 / total ))
  printf '[wd8] copied  : %s of %s  (%s%%)\n' "$(human "$done_")" "$(human "$total")" "$pct"
  if [ -r "$STATE/started" ]; then
    start=$(cat "$STATE/started"); now=$(date +%s); elapsed=$(( now - start ))
    if [ "$elapsed" -gt 0 ] && [ "$done_" -gt 0 ]; then
      rate=$(( done_ / elapsed ))
      printf '[wd8] elapsed : %s   avg %s/s\n' "$(date -u -d @"$elapsed" +%H:%M:%S)" "$(human "$rate")"
      if [ "$rate" -gt 0 ] && [ "$done_" -lt "$total" ]; then
        eta=$(( (total - done_) / rate ))
        printf '[wd8] eta     : %s  (finish ~%s)\n' \
          "$(date -u -d @"$eta" +%H:%M:%S)" "$(date -d "+$eta seconds" +%H:%M)"
      fi
    fi
  fi
  printf '[wd8] last    : %s\n' "$(sudo tail -n1 "$LOG_DIR/rsync.log" 2>/dev/null | cut -c1-120)"
  printf '[wd8] free    : %s\n' "$(df -h --output=avail "$DST_MNT" | tail -1 | tr -d ' ')"
}

# Prove the copy. Three independent checks, because each misses what the others
# catch:
#   1. rsync dry-run  — structural: a missing or differing file anywhere.
#   2. byte totals    — real AND apparent; apparent alone would pass a copy with
#                       no hardlinks at all, real alone would pass a copy that
#                       linked the WRONG files together.
#   3. link groups    — the actual invariant: files sharing an inode on the
#                       source share an inode on the destination. 2076 files
#                       makes this a one-second check, so there is no reason to
#                       settle for the aggregate.
phase_verify(){
  need_mounts "$SRC_MNT" "$DST_MNT" || die "both mounts must be live to verify"
  local out fail=0

  say "1/3 structural (rsync dry-run)…"
  out=$(sudo rsync -aHAXni --delete "$SRC/" "$DST/" 2>&1)
  if [ -n "$out" ]; then
    fail=1
    say "    DIFFERS — $(printf '%s\n' "$out" | wc -l) entries, first 20:"
    printf '%s\n' "$out" | head -20 | sed 's/^/       /'
  else
    say "    identical"
  fi

  say "2/3/3 byte totals + hardlink groups…"
  sudo python3 - "$SRC" "$DST" <<'PY' || fail=1
import os, sys, collections

def scan(root):
    groups = collections.defaultdict(list)
    apparent = 0
    for dp, _dns, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            import stat as S
            if not S.S_ISREG(st.st_mode):
                continue
            rel = os.path.relpath(p, root)
            groups[st.st_ino].append(rel)
            apparent += st.st_size
    real = 0
    sizes = {}
    for ino, paths in groups.items():
        paths.sort()
        p = os.path.join(root, paths[0])
        sz = os.lstat(p).st_size
        sizes[ino] = sz
        real += sz
    # identity of the LINK STRUCTURE, independent of inode numbers
    canon = frozenset(tuple(v) for v in groups.values())
    return dict(files=sum(len(v) for v in groups.values()),
                inodes=len(groups), real=real, apparent=apparent, canon=canon)

src, dst = sys.argv[1], sys.argv[2]
a, b = scan(src), scan(dst)
ok = True
for k in ("files", "inodes", "real", "apparent"):
    same = a[k] == b[k]
    ok &= same
    print("    %-9s src=%-16d dst=%-16d %s" % (k, a[k], b[k], "ok" if same else "MISMATCH"))
if a["canon"] == b["canon"]:
    print("    linkgroup src and dst link exactly the same files together  ok")
else:
    ok = False
    only_a = a["canon"] - b["canon"]
    only_b = b["canon"] - a["canon"]
    print("    linkgroup MISMATCH: %d groups only on src, %d only on dst"
          % (len(only_a), len(only_b)))
    for g in list(only_a)[:5]:
        print("       src-only group:", " | ".join(g))
    for g in list(only_b)[:5]:
        print("       dst-only group:", " | ".join(g))
sys.exit(0 if ok else 1)
PY

  if [ "$fail" -eq 0 ]; then say "VERIFY PASS"; return 0; fi
  say "VERIFY FAILED — do not cut over"; return 1
}

stack(){ (cd "$COMPOSE_DIR" && docker compose "$@"); }

phase_cutover(){
  need_mounts "$SRC_MNT" "$DST_MNT" || die "both mounts must be live"
  grep -q "MOUNTS=.*$DST_MNT" "$ORDERING" \
    || die "$DST_MNT is not in MOUNTS in install-docker-ordering.sh.
       Add it and run '$ORDERING -go' FIRST. Starting the stack against an
       unfrozen, unordered mountpoint is exactly the bind race that cost five
       days on immich-2024."
  sudo lsattr -d /mnt/rootview"$DST_MNT" >/dev/null 2>&1 # informational only

  say "stopping the servarr stack"
  stack down || die "compose down failed"

  say "delta pass (stack down)…"
  sudo rsync -aHAX --delete --partial-dir=.rsync-partial \
    --info=name,stats2 --log-file="$LOG_DIR/rsync.log" "$SRC/" "$DST/"
  local rc=$?
  [ "$rc" -eq 0 ] || { say "delta rsync rc=$rc — restarting the stack on the OLD path"; stack up -d; die "delta failed"; }

  phase_verify || { say "restarting the stack on the OLD path"; stack up -d; die "verify failed"; }

  say "pointing DATA_ROOT at $DST"
  sudo cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  sudo sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$DST|" "$ENV_FILE"
  grep -q "^DATA_ROOT=$DST\$" "$ENV_FILE" || die "DATA_ROOT edit did not take"

  say "starting the stack"
  stack up -d || die "compose up failed"

  sleep 15
  say "smoke check — container-side paths are unchanged (/data/*), so a"
  say "non-zero count here means the bind resolved to the new disk correctly:"
  docker exec jellyfin sh -c 'printf "     /data/movies=%s  /data/tv=%s  /data/xxx=%s\n" \
    "$(ls /data/movies 2>/dev/null | wc -l)" "$(ls /data/tv 2>/dev/null | wc -l)" "$(ls /data/xxx 2>/dev/null | wc -l)"'
  docker exec qbittorrent sh -c 'printf "     qb /data/torrents=%s\n" "$(ls /data/torrents 2>/dev/null | wc -l)"'
  say "done. The old copy on $SRC is UNTOUCHED — leave it a few days."
  say "Check qBittorrent has no errored torrents before reclaiming the HGST."
}

phase_rollback(){
  say "pointing DATA_ROOT back at $SRC"
  sudo sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$SRC|" "$ENV_FILE"
  grep -q "^DATA_ROOT=$SRC\$" "$ENV_FILE" || die "rollback edit did not take"
  stack down && stack up -d
  say "back on the old disk; the 8 TB copy is left in place"
}

case "${1:-plan}" in
  plan)     phase_plan ;;
  prepare)  phase_prepare ;;
  sync)     phase_sync ;;
  _worker)  _worker ;;
  status)   phase_status ;;
  verify)   phase_verify ;;
  cutover)  phase_cutover ;;
  rollback) phase_rollback ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
