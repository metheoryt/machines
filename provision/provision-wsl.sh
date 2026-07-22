#!/usr/bin/env bash
# provision/provision-wsl.sh — half-provision THIS WSL distro as a self-declaring,
# ephemeral fleet host (NOT a fleet.json member). Run from inside the distro:
#   bash ~/machines/provision/provision-wsl.sh <nickname>
#
# Chain (spec 2026-07-21 / plan 2026-07-22):
#   1. tailscale-wsl.sh --hostname <nickname>   enroll on the tailnet
#   2. ssh-wsl.sh                                fleet SSH client+server identity
#   3. linux.sh                                  software + timers + inbound trust
#   4. fleet-local.sh --nickname <nickname>      write the self-declaration
#
# The nickname is BOTH the tailnet node name (so <nickname>.gg.ez resolves) and
# the fleet.local.json nickname the Windows parent's `wsl -l` discovery reports.
set -u
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NICK="${1:-}"
[ -n "$NICK" ] || die "usage: provision-wsl.sh <nickname>   (tailnet node name = fleet nickname)"

info "1/4 tailnet enroll as '$NICK'…"
bash "$REPO/provision/tailscale-wsl.sh" --hostname "$NICK" || die "tailscale-wsl.sh failed"

info "2/4 fleet SSH identity (client + server)…"
bash "$REPO/provision/ssh-wsl.sh" || die "ssh-wsl.sh failed"

info "3/4 software + timers + inbound trust…"
bash "$REPO/provision/linux.sh" || die "linux.sh failed"

info "4/4 self-declaration → fleet.local.json…"
bash "$REPO/provision/fleet-local.sh" --nickname "$NICK" --platform linux --repo "$REPO" \
  || die "fleet-local.sh failed"

printf '\n\033[1mProvisioned WSL host '\''%s'\''.\033[0m It self-declares fleet:true and is reachable at %s.gg.ez.\n' "$NICK" "$NICK"
printf 'A /ship from any box will now discover and pull this distro.\n'
