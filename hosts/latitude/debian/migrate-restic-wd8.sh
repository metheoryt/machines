#!/usr/bin/env bash
# Move BOTH restic repositories off the 320 G ST320LT020 (/mnt/spare320) and
# onto the WD 8 TB (/mnt/wd8).
#
#   ./migrate-restic-wd8.sh plan       what it would do + a source-side baseline
#   ./migrate-restic-wd8.sh sync       bulk copy, DETACHED, hub stays up
#   ./migrate-restic-wd8.sh status     progress / rate  (safe any time)
#   ./migrate-restic-wd8.sh verify     rsync dry-run + `restic check` on the copy
#   ./migrate-restic-wd8.sh cutover    stop writers, delta, verify, repoint, start
#   ./migrate-restic-wd8.sh rollback   point everything back at /mnt/spare320
#
# THE SOURCE IS NEVER DELETED BY THIS SCRIPT. Emptying spare320 is what lets it
# leave the dock, but that is a separate decision taken days later, by hand.
#
# WHAT MOVES, AND WHY BOTH.
#   /mnt/spare320/restic-rest  112 G  the fleet hub: g513ie + g614jv, served by
#                                     the restic-server container over REST
#   /mnt/spare320/restic       12 G   latitude's OWN repo, written by
#                                     resticprofile-backup@profile-latitude
# Moving only the hub would leave 12 G pinning a 293 G / 36k-hour drive in a
# dock bay, which is the opposite of the point.
#
# WHY TWO PASSES, as with the servarr move. Five scheduled writers touch these
# trees (latitude backup 04:30, g15 client 05:00, g16-wsl client 06:00,
# forget 07:30 and 09:30, selfcheck 09:03, weekly checks Sun 06:00/08:30/10:30).
# Pass 1 runs live; `cutover` stops every writer and runs a delta over what
# moved. The hub is down for the delta, not for the copy.
#
# WHAT VERIFIES THIS IS NOT rsync. A byte-identical tree is necessary and not
# sufficient — the property being preserved is "restic can still use it".
# `restic check` walks the index and every pack reference; run it on all three
# repositories at the new path before anything is repointed. The rsync dry-run
# stays because it is seconds and catches a truncated copy faster.
#
# TRAP — THE CONFIG IS THE REPO CHECKOUT, AND YOU DO NOT CONTROL WHEN IT LANDS.
# resticprofile runs with WorkingDirectory=/home/me/machines/backup/latitude and
# reads profiles.yaml straight out of the git work-tree, so repointing the
# repositories is a COMMIT. This script was written believing the commit could be
# held back until `cutover` pulled it. IT CANNOT: `fleet-selfpull.service` is a
# user timer that fast-forwards every fleet repo on its own. On 2026-09-10 it
# pulled the repointing commit at 16:44:52, twenty-five minutes before the bulk
# copy finished — a profiles.yaml naming /mnt/wd8 over a half-copied tree.
#
# Nothing broke, and not because of the design: no writer was scheduled before
# 04:30. The one guard that would have held is the profiles' `run-before`
# assertion, and it is only half a guard — it tests that the repo's `config`
# object exists, not that the repo is COMPLETE, so a `forget --prune` firing in
# that window would have run against a partial copy.
#
# So the writers are stopped by `sync`, at the start, and started again by
# `cutover` or `rollback`. They are daily jobs and the whole migration is under
# an hour; holding them for its duration costs nothing and closes the window
# instead of timing it. Do not move that back into cutover.
#
# TRAP — THE DOCKS LOSE POWER. Same hazard the servarr move carried: fstab is
# `nofail` with no automount, so a dropped mount stays down and `systemctl
# --failed` stays clean. Every phase re-checks both mounts before touching
# anything; the worker re-checks between retries.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# --- paths -------------------------------------------------------------------
SRC_MNT=/mnt/spare320
DST_MNT=/mnt/wd8
DST_UUID=726efd1f-7eb1-45d7-a09e-1e9467c6319f

SRC_REST="$SRC_MNT/restic-rest";  DST_REST="$DST_MNT/restic-rest"
SRC_LOCAL="$SRC_MNT/restic";      DST_LOCAL="$DST_MNT/restic"

REPO_DIR=/home/me/machines
PROFILES="$REPO_DIR/backup/latitude/profiles.yaml"
SELFCHECK="$REPO_DIR/hosts/latitude/debian/restic-hub-selfcheck.sh"
COMPOSE_DIR=/home/me/my/vps/homeserver/restic-server
ENV_FILE="$COMPOSE_DIR/.env"

STATE=/var/lib/restic-migrate
LOG_DIR=/var/log/restic-migrate
UNIT=restic-sync

# repo:relative-path:password-file — the three repositories, at whatever root
# is passed in. Kept in one place so `plan` and `verify` cannot check different
# sets.
REPOS=(
  "latitude:restic/latitude:$REPO_DIR/backup/latitude/pass.txt"
  "g614jv:restic-rest/g614jv:/home/me/.config/restic/g614jv.pass.txt"
  "g513ie:restic-rest/g513ie:/home/me/.config/restic/g513ie.pass.txt"
)

# Every scheduled writer. `cutover` stops all of them and starts them again.
TIMERS=(
  resticprofile-backup@profile-latitude.timer
  resticprofile-forget@profile-g614jv-maintenance.timer
  resticprofile-forget@profile-g513ie-maintenance.timer
  resticprofile-check@profile-latitude.timer
  resticprofile-check@profile-g614jv-maintenance.timer
  resticprofile-check@profile-g513ie-maintenance.timer
  restic-hub-selfcheck.timer
)

say(){ printf '[restic] %s\n' "$*"; }
die(){ printf '[restic] FATAL %s\n' "$*" >&2; exit 1; }

# --- guards ------------------------------------------------------------------

need_mounts(){
  local m
  for m in "$@"; do findmnt -M "$m" >/dev/null 2>&1 || return 1; done
  return 0
}

remount(){
  local m
  for m in "$@"; do
    findmnt -M "$m" >/dev/null 2>&1 && continue
    say "mount $m is gone — trying to start it"
    sudo systemctl start "$(systemd-escape -p --suffix=mount "$m")" 2>&1 | sed 's/^/     /'
  done
}

# The destination must be the 8 TB, not an empty directory standing in for it.
# Checking the filesystem UUID rather than "is something mounted" is the same
# assertion restic-hub-selfcheck.sh makes, and for the same reason.
need_dst(){
  local got
  need_mounts "$DST_MNT" || die "$DST_MNT is not mounted"
  got=$(findmnt -no UUID "$DST_MNT" 2>/dev/null)
  [ "$got" = "$DST_UUID" ] || die "$DST_MNT has UUID '${got}', want $DST_UUID"
}

restic_bin(){
  command -v restic 2>/dev/null && return 0
  [ -x /usr/local/bin/restic ] && { echo /usr/local/bin/restic; return 0; }
  die "restic binary not found"
}

# `restic check` each of the three repositories under $1 (a filesystem root).
# Structural check: index integrity plus every pack referenced by a snapshot.
# Not --read-data; that is the weekly scheduled job's business and it is hours.
check_repos(){
  local root="$1" rc=0 name rel pass repo bin
  bin=$(restic_bin) || return 1
  for entry in "${REPOS[@]}"; do
    IFS=: read -r name rel pass <<<"$entry"
    repo="$root/$rel"
    # `sudo test`, not `test`: the two hub repositories are drwx------ root:root
    # (the container writes as root), so an unprivileged -f is false on a
    # repository that is perfectly present. Reporting that as MISSING is how a
    # healthy repo gets "fixed".
    if ! sudo test -f "$repo/config"; then
      printf '    %-10s %s\n' "$name" "MISSING — no $repo/config"; rc=1; continue
    fi
    if sudo env RESTIC_PASSWORD_FILE="$pass" "$bin" -r "$repo" check --no-lock >/tmp/.rc.$$ 2>&1; then
      printf '    %-10s ok   (%s snapshots)\n' "$name" \
        "$(sudo env RESTIC_PASSWORD_FILE="$pass" "$bin" -r "$repo" snapshots --no-lock --json 2>/dev/null | grep -o '"id"' | wc -l)"
    else
      printf '    %-10s CHECK FAILED\n' "$name"; sed 's/^/        /' /tmp/.rc.$$; rc=1
    fi
    rm -f /tmp/.rc.$$
  done
  return "$rc"
}

# --- phases ------------------------------------------------------------------

phase_plan(){
  need_mounts "$SRC_MNT" || die "$SRC_MNT is not mounted"
  need_dst
  say "source  $SRC_MNT  $(findmnt -no SOURCE,SIZE,USED,AVAIL "$SRC_MNT")"
  say "target  $DST_MNT  $(findmnt -no SOURCE,SIZE,USED,AVAIL "$DST_MNT")"
  echo
  say "would copy:"
  sudo du -sh "$SRC_REST" "$SRC_LOCAL" 2>/dev/null | sed 's/^/     /'
  echo
  say "destination state:"
  for d in "$DST_REST" "$DST_LOCAL"; do
    if [ -e "$d" ]; then printf '     %s  EXISTS (%s)\n' "$d" "$(sudo du -sh "$d" 2>/dev/null | cut -f1)"
    else printf '     %s  absent — sync will create it\n' "$d"; fi
  done
  echo
  say "scheduled writers cutover will stop:"
  systemctl list-timers --all --no-pager --no-legend "${TIMERS[@]}" 2>/dev/null \
    | awk '{printf "     %-52s next %s %s\n", $NF, $1, $2}'
  echo
  say "SOURCE-SIDE BASELINE — a failure here is not caused by the copy:"
  check_repos "$SRC_MNT" || say "    baseline is NOT clean — fix that before migrating"
}

phase_sync(){
  need_mounts "$SRC_MNT" || die "$SRC_MNT is not mounted"
  need_dst
  sudo mkdir -p "$STATE" "$LOG_DIR" "$DST_REST" "$DST_LOCAL"
  if systemctl is-active --quiet "$UNIT"; then
    say "$UNIT is already running — use 'status'"; return 0
  fi
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  # Stopped HERE, not in cutover — see the config trap in the header. The window
  # being closed is "profiles.yaml already repointed, data not there yet", and
  # fleet-selfpull decides when that starts, not this script.
  say "stopping every scheduled writer for the duration of the migration"
  sudo systemctl stop "${TIMERS[@]}"
  say "starting detached copy as $UNIT (log: $LOG_DIR/rsync.log)"
  sudo systemd-run --unit="$UNIT" --collect --description="restic repos -> wd8" \
    "$(readlink -f "$0")" _worker
  say "watch it with: $(basename "$0") status"
}

phase_worker(){
  sudo mkdir -p "$LOG_DIR"
  : >"$STATE/started"; date -Is >"$STATE/started"
  local try rc pair src dst
  for pair in "$SRC_REST|$DST_REST" "$SRC_LOCAL|$DST_LOCAL"; do
    src=${pair%%|*}; dst=${pair##*|}
    try=0
    while :; do
      try=$((try+1))
      if ! need_mounts "$SRC_MNT" "$DST_MNT"; then
        remount "$SRC_MNT" "$DST_MNT"; sleep 30
        [ "$try" -lt 40 ] && continue || { echo "giving up: mounts never came back" >&2; exit 1; }
      fi
      rsync -aHAX --info=name,stats2 \
        --log-file="$LOG_DIR/rsync.log" "$src/" "$dst/"
      rc=$?
      # 24 = a file vanished mid-copy. On an append-only repo with the hub live
      # that is a forget/prune racing us, not damage; the delta pass settles it.
      [ "$rc" = 0 ] || [ "$rc" = 24 ] && break
      [ "$try" -ge 40 ] && { echo "rsync rc=$rc after $try tries" >&2; exit "$rc"; }
      sleep 30
    done
  done
  date -Is >"$STATE/finished"
  echo "bulk copy finished cleanly ($(cat "$STATE/finished"))" | tee -a "$LOG_DIR/rsync.log"
}

phase_status(){
  local state src_b dst_b
  state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
  say "unit    $state"
  [ -f "$STATE/started" ]  && say "started $(cat "$STATE/started")"
  [ -f "$STATE/finished" ] && say "ENDED   $(cat "$STATE/finished")"
  src_b=$(sudo du -sb "$SRC_REST" "$SRC_LOCAL" 2>/dev/null | awk '{s+=$1} END{print s+0}')
  dst_b=$(sudo du -sb "$DST_REST" "$DST_LOCAL" 2>/dev/null | awk '{s+=$1} END{print s+0}')
  [ "$src_b" -gt 0 ] && say "copied  $(( dst_b * 100 / src_b ))%  ($(numfmt --to=iec "$dst_b") of $(numfmt --to=iec "$src_b"))"
  # A migration abandoned between `sync` and `cutover` leaves every backup job
  # switched off, and nothing else in the fleet would say so — `systemctl
  # --failed` is clean for a timer that is merely stopped. Report it here.
  local down
  down=$(systemctl is-active "${TIMERS[@]}" 2>/dev/null | grep -c inactive)
  [ "$down" = 0 ] && say "timers  all ${#TIMERS[@]} running" \
                  || say "timers  $down of ${#TIMERS[@]} STOPPED — cutover or rollback starts them again"
  tail -3 "$LOG_DIR/rsync.log" 2>/dev/null | sed 's/^/     /'
}

phase_verify(){
  need_mounts "$SRC_MNT" || die "$SRC_MNT is not mounted"
  need_dst
  local rc=0 out
  say "1/2 structural (rsync dry-run, both trees)…"
  for pair in "$SRC_REST|$DST_REST" "$SRC_LOCAL|$DST_LOCAL"; do
    out=$(sudo rsync -aHAXni --delete "${pair%%|*}/" "${pair##*|}/" 2>&1)
    if [ -z "$out" ]; then printf '     %-28s identical\n' "$(basename "${pair%%|*}")"
    else
      printf '     %-28s DIFFERS — %s entries, first 10:\n' "$(basename "${pair%%|*}")" "$(printf '%s\n' "$out" | wc -l)"
      printf '%s\n' "$out" | head -10 | sed 's/^/        /'; rc=1
    fi
  done
  echo
  say "2/2 restic check on the COPY — the property that actually matters:"
  check_repos "$DST_MNT" || rc=1
  echo
  [ "$rc" = 0 ] && say "VERIFY PASS" || say "VERIFY FAILED — do not cut over"
  return "$rc"
}

phase_cutover(){
  need_mounts "$SRC_MNT" || die "$SRC_MNT is not mounted"
  need_dst

  # `sync` already stopped these; repeat it so `cutover` is safe on its own for
  # a run that skipped the bulk pass.
  say "confirming every scheduled writer is stopped"
  sudo systemctl stop "${TIMERS[@]}"
  say "stopping the REST hub"
  ( cd "$COMPOSE_DIR" && docker compose down ) || die "compose down failed"

  say "delta pass (all writers down)…"
  for pair in "$SRC_REST|$DST_REST" "$SRC_LOCAL|$DST_LOCAL"; do
    sudo rsync -aHAX --delete --info=stats2 "${pair%%|*}/" "${pair##*|}/" \
      || { phase_restart; die "delta rsync failed — nothing was repointed"; }
  done
  sudo chown --reference="$SRC_REST"  "$DST_REST"
  sudo chown --reference="$SRC_LOCAL" "$DST_LOCAL"
  sudo chmod --reference="$SRC_REST"  "$DST_REST"
  sudo chmod --reference="$SRC_LOCAL" "$DST_LOCAL"

  phase_verify || { phase_restart; die "verify failed — nothing was repointed, hub restarted on the OLD path"; }

  # The config lives in the git work-tree resticprofile reads. Pull it now, and
  # refuse to continue unless the pull actually moved every path.
  say "pulling the config change"
  git -C "$REPO_DIR" pull --ff-only 2>&1 | sed 's/^/     /' || { phase_restart; die "git pull failed"; }
  local stale
  stale=$(grep -c "$SRC_MNT/restic" "$PROFILES" "$SELFCHECK" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
  [ "$stale" = 0 ] || { phase_restart; die "$stale reference(s) to $SRC_MNT/restic remain in profiles.yaml / selfcheck — push the config change first"; }
  grep -q "$DST_MNT/restic" "$PROFILES" || { phase_restart; die "profiles.yaml does not name $DST_MNT — push the config change first"; }

  say "pointing RESTIC_DATA_PATH at $DST_REST"
  cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
  sed -i "s|^RESTIC_DATA_PATH=.*|RESTIC_DATA_PATH=$DST_REST|" "$ENV_FILE"

  phase_restart

  say "smoke — the hub's own self-check against the new path:"
  sudo "$SELFCHECK" 2>&1 | sed 's/^/     /' || say "     selfcheck reported a problem — read it before trusting this"
  echo
  say "done. Both repositories on $SRC_MNT are UNTOUCHED — leave them a few days."
  say "Emptying spare320 is what frees the dock bay; that is a separate decision."
}

phase_restart(){
  say "starting the REST hub"
  ( cd "$COMPOSE_DIR" && docker compose up -d ) 2>&1 | tail -3 | sed 's/^/     /'
  say "starting the timers"
  sudo systemctl start "${TIMERS[@]}"
}

phase_rollback(){
  say "pointing RESTIC_DATA_PATH back at $SRC_REST"
  sed -i "s|^RESTIC_DATA_PATH=.*|RESTIC_DATA_PATH=$SRC_REST|" "$ENV_FILE"
  say "revert the profiles.yaml / selfcheck commit by hand, then:"
  say "  git -C $REPO_DIR pull --ff-only"
  phase_restart
}

case "${1:-}" in
  plan)     phase_plan ;;
  sync)     phase_sync ;;
  _worker)  phase_worker ;;
  status)   phase_status ;;
  verify)   phase_verify ;;
  cutover)  phase_cutover ;;
  rollback) phase_rollback ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ; exit 2 ;;
esac
