#!/usr/bin/env bash
# hosts/g15/ubuntu/install-compose-override.sh — place qaz-code's host-local
# compose override on g15.
#
# COPIES rather than symlinks, for the same reason
# hosts/latitude/debian/install-timers.sh does: a `git pull` here must not
# change what a 186 GB database mounts without somebody looking at the diff.
#
# g15 ONLY. The file names `/data/qaz-code/pgdata`, a bind path that exists on
# this box and nowhere else, so running it against another checkout of qaz-code
# would point that box's DB at a directory it does not have.
#
# It also writes qaz-code's `.git/info/exclude` line if missing. That exclude is
# MACHINE-LOCAL — it is not in the repo and a fresh clone does not inherit it,
# so without this step the copy shows up as an untracked file in `git status`
# and `fleet-selfpull` refuses the tree as dirty, silently and forever
# (roadmap P6). Being ignored is what keeps the pull working, not tidiness.
set -euo pipefail

TARGET_REPO="${1:-$HOME/my/qaz-code}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compose.override.yml"
DST="$TARGET_REPO/compose.override.yml"

[ -d "$TARGET_REPO/.git" ] || { echo "not a git checkout: $TARGET_REPO" >&2; exit 1; }
[ -d /data/qaz-code/pgdata ] || {
  echo "/data/qaz-code/pgdata does not exist — this file is g15-only, refusing" >&2
  exit 1
}

if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "compose.override.yml already current"
else
  # rm before > : $DST could be a symlink, and a redirect writes through one,
  # truncating its target. That is how Orca's own orca-ide shim was destroyed on
  # this box on 2026-09-07.
  rm -f "$DST"
  cp "$SRC" "$DST"
  echo "wrote $DST"
fi

excl="$TARGET_REPO/.git/info/exclude"
if ! grep -qxF 'compose.override.yml' "$excl" 2>/dev/null; then
  mkdir -p "$(dirname "$excl")"
  printf 'compose.override.yml\n' >> "$excl"
  echo "added compose.override.yml to $excl"
else
  echo "exclude line already present"
fi
