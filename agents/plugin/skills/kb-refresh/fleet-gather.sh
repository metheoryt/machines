#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are copied back (via tar).
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

local_host_id() {
  # Map a live `hostname` to its fleet detect.hostname; passthrough if unknown.
  local json="${1:-$FLEET_JSON}" live="$2" id=""
  if [ -f "$json" ]; then
    id="$(jq -r --arg h "$live" '
      .machines | to_entries[]
      | select((.value.detect.hostname // "") == $h)
      | .value.detect.hostname' "$json" 2>/dev/null | head -1)"
  fi
  [ -n "$id" ] && printf '%s\n' "$id" || printf '%s\n' "$live"
}

remote_distill_script() {
  # Static run-script executed on a remote via `bash -s -- <hostid> <nroots>
  # <root>... <match>...`. All dynamic values arrive as positional args; the
  # only expansion is a leading ~ → remote $HOME (distill.py does NOT expanduser
  # an explicit --projects-root).
  cat <<'EOS'
set -euo pipefail
host="$1"; shift
nroots="$1"; shift
roots=(); for _ in $(seq 1 "$nroots"); do roots+=("$1"); shift; done
margs=(); for m in "$@"; do margs+=(--match "$m"); done
mkdir -p ~/.cache/kb-digests
for root in "${roots[@]}"; do
  root="${root/#\~/$HOME}"
  python3 ~/.cache/distill.py --projects-root "$root" \
    --out ~/.cache/kb-digests --state ~/.cache/kb-harvest-state.json \
    --host "$host" "${margs[@]}"
done
EOS
}

detect_hosts() {
  # fleet.json workstations that also have a Host entry in the ssh config.
  # Emits the full fleet_hosts tuple (alias<TAB>platform<TAB>hostname<TAB>user)
  # so main has platform/identity/user without a second jq pass.
  local json="${1:-$FLEET_JSON}" cfg="${2:-$HOME/.ssh/config}"
  [ -f "$cfg" ] || return 0
  local alias rest
  while IFS=$'\t' read -r alias rest; do
    [ -n "$alias" ] || continue
    if grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b${alias}\b" "$cfg"; then
      printf '%s\t%s\n' "$alias" "$rest"
    fi
  done < <(fleet_hosts "$json")
}

# Usage: fleet-gather.sh --out DIR --state FILE --match SUBSTR [--match SUBSTR ...]
main() {
  command -v jq >/dev/null 2>&1 || { echo "fleet-gather: jq required" >&2; return 3; }

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

  local self_id; self_id="$(local_host_id "$FLEET_JSON" "$(hostname)")"

  echo "[local] distilling as '$self_id'…" >&2
  python3 "$SKILL_DIR/distill.py" --projects-root "$HOME/.claude/projects" \
    --out "$out" --state "$state" --host "$self_id" "${match_args[@]}"

  local alias platform hostid user
  while IFS=$'\t' read -r alias platform hostid user; do
    # Self-exclusion: compare the remote's resolved identity to ours. The probe
    # MUST be bash-wrapped — a bare `ssh $h hostname` runs in PowerShell and
    # returns the native Windows name.
    local remote_live
    remote_live="$(ssh -n "$alias" bash -lc 'hostname' 2>/dev/null || true)"
    if [ -n "$remote_live" ] && \
       [ "$(local_host_id "$FLEET_JSON" "$remote_live")" = "$self_id" ]; then
      echo "[$alias] is this box, skipping self" >&2
      continue
    fi

    # Reachability + cache dir (bash-wrapped; PowerShell mkdir has no -p).
    if ! ssh -n "$alias" bash -lc 'mkdir -p ~/.cache/kb-digests' 2>/dev/null; then
      echo "[$alias] skipped (unreachable)" >&2
      continue
    fi

    # Push the distiller (drop the deployed-symlink dependency) + seed the
    # git-tracked watermark, both via cat (rsync fails on Windows).
    if ! ssh "$alias" bash -lc 'cat > ~/.cache/distill.py' < "$SKILL_DIR/distill.py"; then
      echo "[$alias] distiller push failed" >&2
      continue
    fi
    ssh "$alias" bash -lc 'cat > ~/.cache/kb-harvest-state.json' < "$state" \
      || echo "[$alias] state seed failed (remote falls back to its own cache)" >&2

    # Distill every root for this platform (Windows: profile + WSL; unix: home).
    local roots=(); mapfile -t roots < <(roots_for_platform "$platform" "$user")
    echo "[$alias] distilling in-place as '$hostid' (${#roots[@]} root(s))…" >&2
    if ! remote_distill_script | \
         ssh "$alias" bash -s -- "$hostid" "${#roots[@]}" "${roots[@]}" "${matches[@]}"; then
      echo "[$alias] remote distill failed" >&2
      continue
    fi

    # Merge the remote's advanced watermark back (only its `sessions`).
    local tmp_state; tmp_state="$(mktemp)"
    if ssh -n "$alias" bash -lc 'cat ~/.cache/kb-harvest-state.json' > "$tmp_state" 2>/dev/null; then
      python3 "$SKILL_DIR/distill.py" --merge-from "$tmp_state" --state "$state" >/dev/null \
        || echo "[$alias] state merge-back failed" >&2
    fi
    rm -f "$tmp_state"

    # Pull digests via tar (rsync fails on Windows). Exclude manifest.tsv — the
    # local manifest accumulates and a plain copy would clobber it.
    echo "[$alias] pulling digests…" >&2
    ssh -n "$alias" bash -lc 'cd ~/.cache/kb-digests 2>/dev/null && tar cf - --exclude=manifest.tsv . 2>/dev/null' \
      | tar xf - -C "$out" 2>/dev/null \
      || echo "[$alias] digest pull failed" >&2
  done < <(detect_hosts "$FLEET_JSON")
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
