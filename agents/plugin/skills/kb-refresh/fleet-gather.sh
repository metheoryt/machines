#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are rsynced back.
set -euo pipefail

FLEET_WORKSTATIONS=(latitude desktop server)   # 'hub' is the VPS, excluded
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_hosts() {
  local cfg="${HOME}/.ssh/config"
  [ -f "$cfg" ] || return 0
  local self; self="$(hostname 2>/dev/null || echo)"
  local h
  for h in "${FLEET_WORKSTATIONS[@]}"; do
    [ "$h" = "$self" ] && continue
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
    echo "[$h] distilling in-place…" >&2
    # Run the (synced) distiller on the remote box; force bash — remote shell is fish.
    ssh "$h" bash -lc "'python3 ~/.claude/plugins/cache/*/cyphy/*/skills/kb-refresh/distill.py \
      --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json --host $h ${match_args[*]}'" \
      || { echo "[$h] skipped (unreachable)" >&2; continue; }
    echo "[$h] pulling digests…" >&2
    rsync -az "$h:.cache/kb-digests/" "$out/" || echo "[$h] rsync failed" >&2
  done
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
