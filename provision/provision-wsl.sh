#!/usr/bin/env bash
# provision/provision-wsl.sh — half-provision THIS WSL distro as a self-declaring,
# ephemeral fleet host (NOT a fleet.json member). Run from inside the distro:
#   bash ~/machines/provision/provision-wsl.sh <nickname> [--no-tailscale]
#
# Chain (spec 2026-07-21, extended by spec 2026-08-01):
#   1. tailscale-wsl.sh --hostname <nickname>   enroll on the tailnet
#   2. ssh-wsl.sh                                fleet SSH client+server identity
#   3. linux.sh                                  software + timers + inbound trust
#   4. fleet-local.sh --nickname <nickname>      write the self-declaration
#   5. wsl-fixes.sh                              wslopen + binfmt watchdog
#
# --no-tailscale skips step 1. WSL2 distros share ONE network namespace (proven
# 2026-08-01: identical /proc/self/ns/net inodes, cross-visible listener tables),
# so only ONE distro per Windows host can run tailscaled and own tailscale0.
# Every distro after the first is provisioned with --no-tailscale and reached
# through its Windows parent instead — see fleet-dispatch.sh.
#
# The nickname is the fleet.local.json nickname and the dispatch key. For the
# ONE distro that owns the tailnet node it is also the tailnet node name; for
# every other distro it is not, because there is no second node.
set -u
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# provision_wsl_steps <no-tailscale> — ordered step script names, one per line.
provision_wsl_steps() {
  [ "${1:-0}" = 1 ] || printf 'tailscale-wsl.sh\n'
  printf 'ssh-wsl.sh\n'
  printf 'linux.sh\n'
  printf 'fleet-local.sh\n'
  printf 'wsl-fixes.sh\n'
}

provision_wsl_main() {
  local nick="" no_tailscale=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-tailscale) no_tailscale=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)  [ -n "$nick" ] && die "unexpected argument: $1"; nick="$1"; shift ;;
    esac
  done
  [ -n "$nick" ] || die "usage: provision-wsl.sh <nickname> [--no-tailscale]"

  local steps total i=0 step
  mapfile -t steps < <(provision_wsl_steps "$no_tailscale")
  total="${#steps[@]}"

  for step in "${steps[@]}"; do
    i=$((i + 1))
    info "$i/$total ${step}…"
    case "$step" in
      tailscale-wsl.sh) bash "$REPO/provision/$step" --hostname "$nick" ;;
      fleet-local.sh)
        if [ "$no_tailscale" = 1 ]; then
          bash "$REPO/provision/$step" --nickname "$nick" \
               --platform linux --dispatch parent --repo "$REPO"
        else
          bash "$REPO/provision/$step" --nickname "$nick" \
               --platform linux --repo "$REPO"
        fi ;;
      *)                bash "$REPO/provision/$step" ;;
    esac || die "$step failed"
  done

  printf '\n\033[1mProvisioned WSL host '\''%s'\''.\033[0m It self-declares fleet:true.\n' "$nick"
  if [ "$no_tailscale" = 1 ]; then
    printf 'No tailnet node of its own — reached through its Windows parent.\n'
  else
    printf 'Reachable at %s.gg.ez.\n' "$nick"
  fi
}

[ -n "${PROVISION_WSL_LIB_ONLY:-}" ] || provision_wsl_main "$@"
