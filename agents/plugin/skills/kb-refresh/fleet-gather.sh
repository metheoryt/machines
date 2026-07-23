#!/usr/bin/env bash
# fleet-gather.sh — gather + in-place distill transcripts across the fleet.
# Raw transcripts never leave their machine; only digests are copied back (via tar).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fleet.json (repo root) is the machine manifest; four levels up from the skill dir.
FLEET_JSON="${FLEET_JSON:-$SKILL_DIR/../../../../fleet.json}"

# shellcheck source=../lib/fleet-dispatch.sh
. "$SKILL_DIR/../lib/fleet-dispatch.sh"

# Headscale MagicDNS suffix for reaching discovered WSL hosts by nickname.
MAGICDNS_SUFFIX="${MAGICDNS_SUFFIX:-gg.ez}"

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
  # Projects root to distill on the remote. Every platform harvests the box's
  # own Claude profile at ~/.claude/projects; the remote distiller expands ~ to
  # $HOME, which on Windows (via Git Bash, per fd_run) is
  # /c/Users/<user>/.claude/projects — the Windows-native profile. Self-declared
  # WSL distros are separate fleet hosts harvested directly (via fd_wsl_hosts),
  # so there is no /mnt/c cross-mount root here (it does not exist under Git
  # Bash and would fail the set -e remote distill).
  printf '~/.claude/projects\n'
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
PY=python3
python3 -c '' >/dev/null 2>&1 || PY=python
for root in "${roots[@]}"; do
  root="${root/#\~/$HOME}"
  "$PY" ~/.cache/distill.py --projects-root "$root" \
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

# harvest_host <alias> <platform> <hostid> <user> <out> <state> <match...> —
# reachability probe, distiller push, watermark seed, in-place distill,
# watermark merge-back, digest pull for ONE remote box. Dispatch goes through
# fd_run/fd_probe (agents/plugin/skills/lib/fleet-dispatch.sh) so a `windows`
# platform reaches the Windows-native clone via Git Bash instead of landing in
# the WSL default-distro bash. Used for both a fleet.json member (main's
# member loop) and a discovered WSL guest (harvested as a plain `linux`
# platform target, same push/distill/pull).
#
# Every failure path below is `continue`-shaped: it logs and returns 0 rather
# than letting a bad host abort the whole gather (the script runs
# `set -euo pipefail`). Two sites push BOTH a fixed remote command AND a file's
# content over the same fd_run stdin (`cat > dest` + payload) — this relies on
# bash reading script input a line at a time from a non-seekable stream so the
# trailing payload bytes still reach the spawned `cat`; verified for a bare
# script (Task 4) but NOT yet for script+payload through the Windows Git-Bash
# hop (deferred to Task 10 Step 5 live verification).
harvest_host() {
  local alias="$1" platform="$2" hostid="$3" user="$4" out="$5" state="$6"
  shift 6
  local -a matches=("$@")

  if ! printf 'mkdir -p ~/.cache/kb-digests' | fd_run "$alias" "$platform" >/dev/null 2>&1; then
    echo "[$alias] skipped (unreachable)" >&2
    return 0
  fi

  # Push the distiller (drop the deployed-symlink dependency) + seed the
  # git-tracked watermark, both via `cat > dest` (rsync fails on Windows).
  if ! { printf 'cat > ~/.cache/distill.py\n'; cat "$SKILL_DIR/distill.py"; } \
       | fd_run "$alias" "$platform"; then
    echo "[$alias] distiller push failed" >&2
    return 0
  fi
  { printf 'cat > ~/.cache/kb-harvest-state.json\n'; cat "$state"; } \
    | fd_run "$alias" "$platform" \
    || echo "[$alias] state seed failed (remote falls back to its own cache)" >&2

  # Distill every root for this platform (Windows: profile + WSL; unix: home).
  local roots=(); mapfile -t roots < <(roots_for_platform "$platform" "$user")
  echo "[$alias] distilling in-place as '$hostid' (${#roots[@]} root(s))…" >&2
  if ! remote_distill_script \
       | fd_run "$alias" "$platform" "$hostid" "${#roots[@]}" "${roots[@]}" "${matches[@]}"; then
    echo "[$alias] remote distill failed" >&2
    return 0
  fi

  # Merge the remote's advanced watermark back (only its `sessions`).
  local tmp_state; tmp_state="$(mktemp)"
  if printf 'cat ~/.cache/kb-harvest-state.json' | fd_run "$alias" "$platform" > "$tmp_state" 2>/dev/null; then
    python3 "$SKILL_DIR/distill.py" --merge-from "$tmp_state" --state "$state" >/dev/null \
      || echo "[$alias] state merge-back failed" >&2
  fi
  rm -f "$tmp_state"

  # Pull digests via tar (rsync fails on Windows). Exclude manifest.tsv — the
  # local manifest accumulates and a plain copy would clobber it.
  echo "[$alias] pulling digests…" >&2
  printf 'cd ~/.cache/kb-digests 2>/dev/null && tar cf - --exclude=manifest.tsv . 2>/dev/null' \
    | fd_run "$alias" "$platform" \
    | tar xf - -C "$out" 2>/dev/null \
    || echo "[$alias] digest pull failed" >&2
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
    # goes through fd_run so a `windows` member dispatches via Git Bash instead
    # of landing in PowerShell (which would report the native Windows name, not
    # `hostname`'s bash-side answer) — see fleet-dispatch.sh for the mechanics.
    local remote_live
    remote_live="$(printf 'hostname' | fd_run "$alias" "$platform" 2>/dev/null || true)"
    if [ -n "$remote_live" ] && \
       [ "$(local_host_id "$FLEET_JSON" "$remote_live")" = "$self_id" ]; then
      echo "[$alias] is this box, skipping self" >&2
      continue
    fi

    harvest_host "$alias" "$platform" "$hostid" "$user" "$out" "$state" "${matches[@]}"

    # WSL guests of a windows member: each self-declared (fleet.local.json
    # `.self.fleet == true`) distro is harvested as a plain `linux` platform
    # target over its tailnet nickname, reusing the same harvest_host body.
    # (No self-exclusion here per Task 10 brief — a WSL nickname and this box's
    # fleet detect.hostname live in different namespaces, so a comparison would
    # never meaningfully fire; mirror fleet-pull.sh's exact check instead if
    # that ever becomes a real topology.) Note: if the windows member above was
    # unreachable, this still issues its own probe (wsl.exe -l -q) against the
    # same dead box — a wasted timeout, not a correctness issue.
    if [ "$platform" = windows ]; then
      local nick wsl_hostid
      while IFS= read -r nick; do
        [ -n "$nick" ] || continue
        wsl_hostid="$(local_host_id "$FLEET_JSON" "$nick")"
        harvest_host "$nick${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}" linux "$wsl_hostid" "" \
          "$out" "$state" "${matches[@]}"
      done < <(fd_wsl_hosts "$alias" "$platform")
    fi
  done < <(detect_hosts "$FLEET_JSON")
}

if [ "${KB_GATHER_NO_MAIN:-0}" != "1" ]; then
  main "$@"
fi
