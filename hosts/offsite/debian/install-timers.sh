#!/usr/bin/env bash
# Install the village box's own health timers into systemd (system scope).
#   VAULT_UUID=<uuid> ./install-timers.sh        show what would change
#   VAULT_UUID=<uuid> ./install-timers.sh -go     install, enable, and start
#   ./install-timers.sh -off                      disable and remove them
#
# Modeled on hosts/latitude/debian/install-timers.sh. The units are COPIED, not
# symlinked, into /etc/systemd/system: systemd will happily follow a symlink
# there, but a symlink into a git work-tree means a `git pull` can change what
# root executes on a timer with no review step. The ExecStart lines still point
# into the checkout - that is deliberate and the same trust boundary the rest of
# the fleet's self-pull machinery already accepts - but the unit definition
# itself stays a deliberate copy.
#
# /etc/default/offsite carries VAULT_UUID for both units (EnvironmentFile=-, so
# a missing file is not fatal to the unit — it is fatal to offsite-selfcheck.sh
# itself, via VAULT_UUID:?). -go requires VAULT_UUID in the environment so the
# file this script writes is never a guess.
#
# EXIT CODES — four distinct failure modes, each its own code, chosen to not
# repeat a meaning install-rest-server.sh already gives a code ON THIS SAME
# HOST (0 success, 1 service failed to reach active, 2 not root, 3 htpasswd
# missing, 78 vault wrong UUID, 79 checksum unverifiable):
#   0  success
#   20 usage — an unrecognised flag
#   21 a required script (offsite-selfcheck.sh, offsite-verify.sh, or the
#      referenced restic-pack-verify.sh) is missing or not executable
#   22 a unit file is missing from systemd/
#   23 VAULT_UUID is unset for -go — a distinct precondition from all of the
#      above, so it gets its own code rather than folding into "usage"
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="$HERE/systemd"
UNIT_DST=/etc/systemd/system
DEFAULT_FILE=/etc/default/offsite
UNITS=(offsite-selfcheck.service offsite-selfcheck.timer offsite-verify.service offsite-verify.timer)
TIMERS=(offsite-selfcheck.timer offsite-verify.timer)

MODE=show
case "${1:-}" in
  -go)  MODE=go ;;
  -off) MODE=off ;;
  ""|-n) MODE=show ;;
  *) echo "usage: $0 [-n|-go|-off]"; exit 20 ;;
esac

say(){ echo "[install-timers] $*"; }

# The scripts the units call must exist, or we would enable a timer that fails
# every fire. Check before touching systemd, not after.
for s in offsite-selfcheck.sh offsite-verify.sh; do
  [ -x "$HERE/$s" ] || { say "FATAL $HERE/$s missing or not executable"; exit 21; }
done
[ -x /home/me/machines/hosts/latitude/debian/restic-pack-verify.sh ] ||
  { say "FATAL restic-pack-verify.sh missing or not executable (referenced, not copied)"; exit 21; }
for u in "${UNITS[@]}"; do
  [ -f "$UNIT_SRC/$u" ] || { say "FATAL $UNIT_SRC/$u missing"; exit 22; }
done

if [ "$MODE" = off ]; then
  for t in "${TIMERS[@]}"; do sudo systemctl disable --now "$t" 2>/dev/null && say "disabled $t"; done
  for u in "${UNITS[@]}"; do sudo rm -f "$UNIT_DST/$u" && say "removed $UNIT_DST/$u"; done
  sudo systemctl daemon-reload
  say "done"
  exit 0
fi

if [ "$MODE" = go ]; then
  # Distinct precondition, distinct exit (23) — a missing VAULT_UUID at
  # install time is not "not root" (install-rest-server.sh's 2), not "usage"
  # (this script's own 20), and not "unit file missing" (22).
  if [ -z "${VAULT_UUID:-}" ]; then
    say "FATAL set VAULT_UUID to the vault disk UUID"
    exit 23
  fi
  say "writing $DEFAULT_FILE"
  printf 'VAULT_UUID=%s\n' "$VAULT_UUID" | sudo tee "$DEFAULT_FILE" >/dev/null
  sudo chmod 644 "$DEFAULT_FILE"
fi

for u in "${UNITS[@]}"; do
  if [ -f "$UNIT_DST/$u" ] && cmp -s "$UNIT_SRC/$u" "$UNIT_DST/$u"; then
    say "unchanged  $u"
  elif [ "$MODE" = show ]; then
    say "would install  $u"
    diff -u "$UNIT_DST/$u" "$UNIT_SRC/$u" 2>/dev/null | sed 's/^/    /' | head -20
  else
    sudo install -m644 "$UNIT_SRC/$u" "$UNIT_DST/$u" && say "installed  $u"
  fi
done

if [ "$MODE" = show ]; then
  say "(dry run - pass -go to install; set VAULT_UUID first)"
  exit 0
fi

sudo systemctl daemon-reload
for t in "${TIMERS[@]}"; do
  sudo systemctl enable --now "$t" && say "enabled $t"
done

say "--- state ---"
systemctl list-timers --all "${TIMERS[@]}" --no-pager 2>/dev/null
