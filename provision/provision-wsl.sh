#!/usr/bin/env bash
# provision/provision-wsl.sh — half-provision THIS WSL distro as a self-declaring,
# ephemeral fleet host (NOT a fleet.json member). Run from inside the distro:
#   bash ~/machines/provision/provision-wsl.sh <nickname> [--no-tailscale] \
#        [--parent <windows-fleet-alias>]
#
# Chain (spec 2026-07-21, extended by spec 2026-08-01):
#   1. tailscale-wsl.sh --hostname <nickname>   enroll on the tailnet
#   2. ssh-wsl.sh                                fleet SSH client+server identity
#   3. linux.sh                                  software + timers + inbound trust
#   4. fleet-local.sh --nickname <nickname>      write the self-declaration
#   5. wsl-fixes.sh                              wslopen + binfmt watchdog
#   6. backup-client.sh                          this distro's own restic schedule
#
# Step 6 is AFTER fleet-local.sh and that ordering is load-bearing: it resolves
# its identity from the fleet.local.json step 4 writes. A WSL distro cannot be
# identified any other way -- on desktop-wsl `hostname` is g614jv, which IS the
# Windows parent's detect.hostname, so detection would hand this distro the
# PARENT's backup profile. It is a no-op skip until backup/<nickname>/ exists.
#
# --no-tailscale skips step 1. WSL2 distros share ONE network namespace (proven
# 2026-08-01: identical /proc/self/ns/net inodes, cross-visible listener tables),
# so only ONE distro per Windows host can run tailscaled and own tailscale0.
# Every distro after the first is provisioned with --no-tailscale and reached
# through its Windows parent instead — see fleet-dispatch.sh.
#
# --parent <alias> names the Windows fleet member this distro runs on. It makes
# /ship reach THAT member through WSL interop instead of its tailnet node, which
# a distro on the same machine cannot hairpin to. Omitted, whatever the existing
# fleet.local.json declares is kept — so a re-provision never drops it.
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
  printf 'backup-client.sh\n'
}

provision_wsl_main() {
  local nick="" no_tailscale=0 parent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-tailscale) no_tailscale=1; shift ;;
      --parent) parent="${2:-}"; [ -n "$parent" ] || die "--parent needs a fleet alias"; shift 2 ;;
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
               --platform linux --dispatch parent --repo "$REPO" \
               ${parent:+--parent "$parent"}
        else
          bash "$REPO/provision/$step" --nickname "$nick" \
               --platform linux --repo "$REPO" \
               ${parent:+--parent "$parent"}
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
