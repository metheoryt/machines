#!/usr/bin/env bash
# provision/tests/wsl-fixes.test.sh — unit tests for the WSL-only fixes:
# the wslopen asset and the binfmt watchdog renderers. No sudo, no network,
# no real WSL distro — the installer is sourced in WSL_FIXES_LIB_ONLY mode.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

# ── the wslopen asset ─────────────────────────────────────────────────────────
ASSET="$REPO/provision/assets/wslopen"

[ -f "$ASSET" ] && pass "wslopen asset exists" || die "wslopen asset missing at $ASSET"
bash -n "$ASSET" 2>/dev/null && pass "wslopen parses" || die "wslopen has a syntax error"

# It must base64/UTF-16LE encode the command: plain string interpolation lets
# cmd/PowerShell mangle & ? = in an OAuth callback URL, which is exactly the
# case this exists for.
grep -q 'iconv -f UTF-8 -t UTF-16LE' "$ASSET" && pass "wslopen encodes UTF-16LE" \
  || die "wslopen must pipe through iconv UTF-16LE"
grep -qE '\$powershell".*-EncodedCommand "\$encoded"' "$ASSET" && pass "wslopen uses -EncodedCommand" \
  || die "wslopen must invoke \$powershell with -EncodedCommand \"\$encoded\" (not merely mention the word)"

# URL schemes must pass through untouched; only real paths get wslpath'd.
grep -q 'http://\* | https://\*' "$ASSET" && pass "wslopen passes URLs through" \
  || die "wslopen must not wslpath a URL"

# ── the installer's pure helpers ──────────────────────────────────────────────
export WSL_FIXES_LIB_ONLY=1
# shellcheck source=/dev/null
source "$REPO/provision/wsl-fixes.sh"

# wsl_fixes_needs_reregister: 0 (act) when the binfmt entry is absent.
tmp="$(mktemp -d)"
wsl_fixes_needs_reregister "$tmp/absent" && pass "needs_reregister: absent → act" \
  || die "needs_reregister must return 0 when the entry is missing"
printf 'enabled\ninterpreter /init\n' > "$tmp/present"
wsl_fixes_needs_reregister "$tmp/present" && die "needs_reregister must return 1 when present" \
  || pass "needs_reregister: present → no action"
rm -rf "$tmp"

# Both symlink names are required: tools shell out to one or the other.
names="$(wsl_fixes_symlink_names | sort | tr '\n' ' ')"
eq "$names" "wslview xdg-open " "symlink names are xdg-open and wslview"

# The watchdog service must recover via the VERIFIED action and nothing else.
svc="$(wsl_fixes_watchdog_service)"
case "$svc" in
  *"systemctl restart systemd-binfmt"*) pass "watchdog restarts systemd-binfmt" ;;
  *) die "watchdog service must recover with: systemctl restart systemd-binfmt" ;;
esac
case "$svc" in
  *"Type=oneshot"*) pass "watchdog service is oneshot" ;;
  *) die "watchdog service must be Type=oneshot" ;;
esac

# It must be GATED on the binfmt entry actually being absent — without this,
# the "restart systemd-binfmt" action above fires unconditionally every 60s.
case "$svc" in
  *"ConditionPathExists=!$WSL_FIXES_BINFMT_PATH"*) pass "watchdog is gated on ConditionPathExists=!<path>" ;;
  *) die "watchdog service must set ConditionPathExists=!$WSL_FIXES_BINFMT_PATH" ;;
esac

# It must NOT reintroduce the inert binfmt.d conf approach.
case "$svc" in
  *"binfmt.d"*) die "watchdog must not write a binfmt.d conf — it is inert" ;;
  *) pass "watchdog avoids the inert binfmt.d conf" ;;
esac

tmr="$(wsl_fixes_watchdog_timer)"
case "$tmr" in
  *"OnBootSec="*) pass "timer fires at boot" ;;
  *) die "timer must set OnBootSec=" ;;
esac
case "$tmr" in
  *"OnUnitActiveSec="*) pass "timer repeats" ;;
  *) die "timer must set OnUnitActiveSec=" ;;
esac
case "$tmr" in
  *"WantedBy=timers.target"*) pass "timer is enable-able" ;;
  *) die "timer must have WantedBy=timers.target" ;;
esac

exit "$fail"
