#!/usr/bin/env bash
# Unit tests for the provision/linux.sh tier driver + provision/lib/tiers.sh.
# No root, no network: exercises profile resolution and the dry-run tier list.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../linux.sh"
TIERS="$HERE/../lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qE "$2" && die "$3" || pass "$3"; }

plan() { MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE="$1" bash "$DRIVER" 2>&1; }

ws="$(plan workstation)"
hub="$(plan hub)"

# Profile banner names the resolution source.
has "$ws" 'profile: workstation \(from MACHINES_PROFILE\)' "banner reports env-var source"

# Both profiles start with apt_min and include the CORE agent-config tier.
has "$ws"  '^tier_apt_min$'       "workstation runs tier_apt_min"
has "$hub" '^tier_apt_min$'       "hub runs tier_apt_min"
has "$ws"  '^tier_agents_config$' "workstation runs tier_agents_config"
has "$hub" '^tier_agents_config$' "hub runs tier_agents_config"
eq "$(printf '%s\n' "$hub" | grep -c '^tier_apt_min$')" "1" "hub runs tier_apt_min exactly once"

# workstation keeps today's full set, in today's order.
eq "$(printf '%s\n' "$ws" | grep '^tier_' | tr '\n' ' ')" \
   "tier_apt_min tier_apt_dev tier_agents_config tier_git_base tier_gortex tier_agent_clis claude codex tier_shell_init tier_autofetch tier_ssh_accounts tier_selfpull tier_ssh_trust " \
   "workstation tier list and order"

# hub is lean: no dev apt layer, no gortex, no codex.
hasnt "$hub" '^tier_apt_dev$' "hub omits tier_apt_dev"
hasnt "$hub" '^tier_gortex$'  "hub omits tier_gortex"
hasnt "$hub" 'codex'          "hub omits the codex CLI"

# HAZARD GUARD: ssh_accounts would overwrite hub's ~/.ssh/config with
# IdentitiesOnly on an unregistered key and kill its only GitHub auth.
hasnt "$hub" '^tier_ssh_accounts$' "hub NEVER runs tier_ssh_accounts"

# hub pins fleet-selfpull to ~/machines so ~/vps never auto-pulls.
has "$hub" '^tier_selfpull %h/machines$' "hub pins FLEET_ROOTS to %h/machines"
has "$ws"  '^tier_selfpull$'             "workstation leaves FLEET_ROOTS default"
has "$hub" '^tier_shell_init --no-fish$' "hub skips the fish config"

# Resolution precedence 2 and 3: no env override, so the driver must read
# fleet.json by OS hostname, and fall back to workstation for an unknown box.
# Stub `hostname` on PATH (keep the real binaries the driver needs).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
stub_host() { printf '#!/bin/sh\necho %s\n' "$1" > "$tmp/bin/hostname"; chmod +x "$tmp/bin/hostname"; }
plan_host() { stub_host "$1"; MACHINES_TIERS_DRY_RUN=1 PATH="$tmp/bin:$PATH" bash "$DRIVER" 2>&1; }

has "$(plan_host 27608)" 'profile: hub \(from fleet.json\)' "hostname 27608 resolves to hub via fleet.json"
has "$(plan_host wsl-scratch)" 'profile: workstation \(default\)' "unknown hostname defaults to workstation"

# Library sources inert.
out="$(TIERS_LIB_ONLY=1 bash -c 'source "$1"; declare -F tier_apt_min >/dev/null && echo LOADED' _ "$TIERS")"
eq "$out" "LOADED" "TIERS_LIB_ONLY sources without side effects"

# The generated fleet-selfpull unit MUST carry KillMode=process: the pull fires
# post-merge, which backgrounds converge.sh inside this unit's cgroup, and the
# default control-group kill reaps it ~3s later when the oneshot finishes —
# Trigger B then pulls forever and never applies anything.
grep -q 'KillMode=process' "$TIERS" \
  && pass "fleet-selfpull unit sets KillMode=process" \
  || die "fleet-selfpull unit sets KillMode=process"

# Every fleet.json machine must already have a committed per-host memory stub:
# agents/bootstrap.sh seeds a MISSING one inside the repo, which leaves the tree
# dirty and permanently disables fleet-selfpull's clean-tree gate on that box.
for h in $(jq -r '.machines[].detect.hostname' "$HERE/../../fleet.json"); do
  [ -f "$HERE/../../agents/hosts/$h.md" ] \
    && pass "host memory stub committed for $h" \
    || die "host memory stub committed for $h"
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
