#!/usr/bin/env bash
# Install latitude's backup and mirror timers into systemd (system scope).
#   ./install-timers.sh        show what would change
#   ./install-timers.sh -go    install, enable, and start the timers
#   ./install-timers.sh -off   disable and remove them
#
# WHY SYSTEM SCOPE, when fleet-selfpull / dotfiles-sync / git-autofetch are all
# systemd-USER timers on this box: those act on $HOME and need no privilege.
# These mirror whole filesystems - rsync -aHAX has to preserve ownership, and
# immich writes its pg_dumpall output root:root 644, which a non-root job can
# read but not reproduce. Wrong scope here produces a mirror that silently
# differs from the source in ownership.
#
# The units are copied, not symlinked, into /etc/systemd/system. systemd will
# happily follow a symlink there, but a symlink into a git work-tree means a
# `git pull` can change what root executes on a timer with no review step. The
# ExecStart still points into the checkout - that is deliberate and is the same
# trust boundary the rest of the fleet's self-pull machinery already accepts -
# but the unit definition itself stays a deliberate copy.
set -uo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="$HERE/systemd"
UNIT_DST=/etc/systemd/system
UNITS=(mirror-refresh.service mirror-refresh.timer archive-mirror.service archive-mirror.timer
       restic-hub-selfcheck.service restic-hub-selfcheck.timer)
TIMERS=(mirror-refresh.timer archive-mirror.timer restic-hub-selfcheck.timer)

MODE=show
case "${1:-}" in
  -go)  MODE=go ;;
  -off) MODE=off ;;
  ""|-n) MODE=show ;;
  *) echo "usage: $0 [-n|-go|-off]"; exit 2 ;;
esac

say(){ echo "[install-timers] $*"; }

# The scripts the units call must exist, or we would enable a timer that fails
# every fire. Check before touching systemd, not after.
for s in mirror-refresh.sh archive-mirror.sh restic-hub-selfcheck.sh; do
  [ -x "$HERE/$s" ] || { say "FATAL $HERE/$s missing or not executable"; exit 1; }
done
for u in "${UNITS[@]}"; do
  [ -f "$UNIT_SRC/$u" ] || { say "FATAL $UNIT_SRC/$u missing"; exit 1; }
done

if [ "$MODE" = off ]; then
  for t in "${TIMERS[@]}"; do sudo systemctl disable --now "$t" 2>/dev/null && say "disabled $t"; done
  for u in "${UNITS[@]}"; do sudo rm -f "$UNIT_DST/$u" && say "removed $UNIT_DST/$u"; done
  sudo systemctl daemon-reload
  say "done"
  exit 0
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
  say "(dry run - pass -go to install)"
  exit 0
fi

sudo systemctl daemon-reload
for t in "${TIMERS[@]}"; do
  sudo systemctl enable --now "$t" && say "enabled $t"
done

say "--- state ---"
systemctl list-timers --all "${TIMERS[@]}" --no-pager 2>/dev/null
