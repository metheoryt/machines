#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are rsynced back.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fleet.json (repo root) is the machine manifest; four levels up from the skill dir.
FLEET_JSON="${FLEET_JSON:-$SKILL_DIR/../../../../fleet.json}"

fleet_hosts() {
  # Emit one TSV row per non-hub workstation: alias<TAB>platform<TAB>hostname<TAB>user.
  # The hub is the only member with ssh.host set (it's the VPS) — exclude it.
  local json="${1:-$FLEET_JSON}"
  [ -f "$json" ] || return 0
  jq -r '
    .machines | to_entries[]
    | select(.value.ssh.host == null)
    | [ .key, (.value.platform // "unknown"),
        (.value.detect.hostname // ""), (.value.ssh.user // "") ]
    | @tsv
  ' "$json"
}

roots_for_platform() {
  # Projects roots to distill on the remote, in order. Windows boxes keep live
  # transcripts in the Windows profile AND (partially) in WSL — distill both.
  local platform="$1" user="$2"
  case "$platform" in
    windows)
      printf '/mnt/c/Users/%s/.claude/projects\n' "$user"
      printf '~/.claude/projects\n'
      ;;
    *)
      printf '~/.claude/projects\n'
      ;;
  esac
}

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
    # Seed the remote with the authoritative git-tracked watermark so it does not
    # re-distill sessions already harvested fleet-wide (read-once holds fleet-wide).
    ssh "$h" mkdir -p .cache 2>/dev/null || true
    rsync -az "$state" "$h:.cache/kb-harvest-state.json" 2>/dev/null \
      || echo "[$h] state push failed (remote falls back to its own cache)" >&2

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

    # Merge the remote's advanced watermark back into the git-tracked state.
    tmp_state="$(mktemp)"
    if rsync -az "$h:.cache/kb-harvest-state.json" "$tmp_state" 2>/dev/null; then
      python3 "$SKILL_DIR/distill.py" --merge-from "$tmp_state" --state "$state" >/dev/null \
        || echo "[$h] state merge-back failed" >&2
    fi
    rm -f "$tmp_state"

    echo "[$h] pulling digests…" >&2
    rsync -az "$h:.cache/kb-digests/" "$out/" || echo "[$h] rsync failed" >&2
  done
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
