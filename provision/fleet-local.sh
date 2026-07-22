#!/usr/bin/env bash
# provision/fleet-local.sh — write this host's gitignored self-declaration to
# <repo>/fleet.local.json so the Windows parent's `wsl -l` discovery can find it
# and /ship reaches it by tailnet nickname. WSL distros never go in fleet.json.
# Idempotent: rewrites only the `self` block, preserving other top-level keys.
set -u
have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "fleet-local: jq required" >&2; exit 3; }

nickname=""; platform="linux"; repo="$HOME/machines"
while [ $# -gt 0 ]; do
  case "$1" in
    --nickname) nickname="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --repo)     repo="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$nickname" ] || { echo "fleet-local: --nickname required" >&2; exit 2; }

f="$repo/fleet.local.json"
base='{}'
[ -f "$f" ] && base="$(cat "$f")"
printf '%s' "$base" | jq \
  --arg n "$nickname" --arg p "$platform" \
  '.self = {nickname:$n, fleet:true, platform:$p}' > "$f.tmp" \
  && mv "$f.tmp" "$f"
echo "wrote $f (self.nickname=$nickname, fleet=true, platform=$platform)"
