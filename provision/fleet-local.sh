#!/usr/bin/env bash
# provision/fleet-local.sh — write this host's gitignored self-declaration to
# <repo>/fleet.local.json so the Windows parent's `wsl -l` discovery can find it
# and /ship reaches it by tailnet nickname. WSL distros never go in fleet.json.
# Idempotent: rewrites only the `self` block, preserving other top-level keys.
# `dispatch` selects how the fleet reaches this distro: `direct` (it owns the
# tailnet node, reachable at <nickname>.gg.ez) or `parent` (no node of its own —
# reached as `wsl.exe -d <distro>` through its Windows parent). WSL2 distros
# share one network namespace, so only one distro per host can be `direct`.
# `--parent <fleet-alias>` names the Windows member this distro runs on, so
# fleet-dispatch can reach that member through WSL interop instead of over the
# tailnet — a distro cannot ssh to its own host's node (hairpin: proven
# 2026-08-30, desktop answers latitude and times out from desktop-wsl). It must
# be declared, never inferred: `detect.hostname` is the WSL name on desktop
# (g614jv) and the native name on g15 (g513ie), so no hostname test is right
# for both. Omitting the flag preserves whatever the file already declares.
set -u
have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "fleet-local: jq required" >&2; exit 3; }

nickname=""; platform="linux"; repo="$HOME/machines"; dispatch="direct"; parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --nickname) nickname="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --dispatch) dispatch="$2"; shift 2 ;;
    --parent)   parent="$2"; shift 2 ;;
    --repo)     repo="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$nickname" ] || { echo "fleet-local: --nickname required" >&2; exit 2; }
case "$dispatch" in
  direct|parent) ;;
  *) echo "fleet-local: --dispatch must be 'direct' or 'parent', got '$dispatch'" >&2; exit 2 ;;
esac

f="$repo/fleet.local.json"
base='{}'
[ -f "$f" ] && base="$(cat "$f")"
printf '%s' "$base" | jq \
  --arg n "$nickname" --arg p "$platform" --arg d "$dispatch" --arg par "$parent" \
  '.self = ({nickname:$n, fleet:true, platform:$p, dispatch:$d}
            + (if $par != "" then {parent:$par}
               elif ((.self.parent // "") != "") then {parent:(.self.parent)}
               else {} end))' > "$f.tmp" \
  && mv "$f.tmp" "$f"
echo "wrote $f (self.nickname=$nickname, fleet=true, platform=$platform, dispatch=$dispatch${parent:+, parent=$parent})"
