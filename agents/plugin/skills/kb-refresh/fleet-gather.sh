#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are rsynced back.
set -euo pipefail

FLEET_WORKSTATIONS=(latitude desktop server)   # 'hub' is the VPS, excluded
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_hosts() {
  # Echoes every fleet workstation alias present in ~/.ssh/config, one per
  # line. Does NOT exclude the current box — the OS hostname never matches
  # the SSH alias on this fleet (latitude5520≠latitude, g614jv≠desktop,
  # methe-server≠server), so that comparison never fired. Self-exclusion is
  # done at connect time in main() instead, via a live `ssh` hostname probe.
  local cfg="${HOME}/.ssh/config"
  [ -f "$cfg" ] || return 0
  local h
  for h in "${FLEET_WORKSTATIONS[@]}"; do
    if grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b${h}\b" "$cfg"; then
      echo "$h"
    fi
  done
}

# Usage: fleet-gather.sh --out DIR --state FILE --match SUBSTR [--match SUBSTR ...]
main() {
  local out="" state="" matches=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2;;
      --state) state="$2"; shift 2;;
      --match) matches+=("$2"); shift 2;;
      *) echo "unknown arg: $1" >&2; return 2;;
    esac
  done
  [ -n "$out" ] && [ -n "$state" ] && [ "${#matches[@]}" -gt 0 ] || {
    echo "required: --out --state --match" >&2; return 2; }

  local match_args=(); local m
  for m in "${matches[@]}"; do match_args+=(--match "$m"); done

  echo "[local] distilling…" >&2
  python3 "$SKILL_DIR/distill.py" --out "$out" --state "$state" \
    --host "$(hostname)" "${match_args[@]}"

  local h
  for h in $(detect_hosts); do
    # Self-exclusion moved here from detect_hosts: the OS hostname never
    # matches the SSH alias on this fleet, so we can only tell "this is me"
    # by actually connecting and comparing the remote hostname to our own.
    if [ "$(ssh "$h" hostname 2>/dev/null)" = "$(hostname)" ]; then
      echo "[$h] is this box, skipping self" >&2
      continue
    fi
    echo "[$h] distilling in-place…" >&2
    # Run the (synced) distiller on the remote box; force bash — remote shell is fish.
    # The cyphy plugin is deployed as a skills-directory symlink
    # ~/.claude/skills/cyphy -> …/agents/plugin, so distill.py lives under
    # ~/.claude/skills/cyphy/skills/kb-refresh/ on every fleet box.
    rc=0
    ssh "$h" bash -lc "'python3 ~/.claude/skills/cyphy/skills/kb-refresh/distill.py \
      --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json --host $h ${match_args[*]}'" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 255 ]; then
        echo "[$h] skipped (unreachable)" >&2
      else
        echo "[$h] remote distill failed (exit $rc)" >&2
      fi
      continue
    fi
    echo "[$h] pulling digests…" >&2
    rsync -az "$h:.cache/kb-digests/" "$out/" || echo "[$h] rsync failed" >&2
  done
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
