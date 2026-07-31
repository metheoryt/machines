#!/usr/bin/env bash
# provision/tests/provision-wsl.test.sh — the chain order and the
# --no-tailscale gate. Sources in LIB_ONLY mode; runs no step.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

export PROVISION_WSL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$REPO/provision/provision-wsl.sh"

# Default chain: tailnet enroll first, fixes last.
full="$(provision_wsl_steps 0 | tr '\n' ' ')"
eq "$full" "tailscale-wsl.sh ssh-wsl.sh linux.sh fleet-local.sh wsl-fixes.sh " \
  "default chain order"

# --no-tailscale drops ONLY the enroll step. WSL2 distros share one network
# namespace, so a second tailscaled cannot create a second tailscale0.
none="$(provision_wsl_steps 1 | tr '\n' ' ')"
eq "$none" "ssh-wsl.sh linux.sh fleet-local.sh wsl-fixes.sh " \
  "--no-tailscale drops only the enroll step"

case "$none" in
  *tailscale-wsl.sh*) die "--no-tailscale must not run tailscale-wsl.sh" ;;
  *) pass "--no-tailscale really skips tailscale-wsl.sh" ;;
esac

# Every named step must exist on disk — a typo here is a silent no-op at runtime.
for s in $full; do
  [ -f "$REPO/provision/$s" ] && pass "step exists: $s" || die "missing step script: $s"
done

# The header lie must be gone: tailscale-wsl.sh claimed one tailscaled PER
# distro with "no port juggling". Distros share a netns; that is false.
if grep -q 'one tailscaled PER distro' "$REPO/provision/tailscale-wsl.sh"; then
  die "tailscale-wsl.sh still claims one tailscaled per distro"
else
  pass "tailscale-wsl.sh header corrected"
fi

exit "$fail"
