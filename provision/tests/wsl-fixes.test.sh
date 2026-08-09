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

# wsl-fixes.sh defines its own die() that calls `exit 1`, clobbering the one
# above. Left alone, the FIRST failing assertion after this point kills the run
# and every later assertion silently goes unreported. Restore the helpers.
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

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

# ── the native docker CLI ─────────────────────────────────────────────────────
# Docker Desktop injects /usr/bin/docker and the cli-plugins as symlinks into
# /mnt/wsl/docker-desktop/cli-tools, a VM-wide tmpfs it repopulates every boot.
# On 2026-08-01 that repopulation half-failed: the socket, the bind-mounts and
# the symlink were all wired, cli-tools was left empty, and `docker` vanished
# from a distro whose integration toggle still read ON. A headless work distro
# nobody opens would not notice. These packages give each distro a CLI that
# does not depend on that tmpfs.

pkgs="$(wsl_fixes_docker_packages | sort | tr '\n' ' ')"
eq "$pkgs" "docker-buildx-plugin docker-ce-cli docker-compose-plugin " \
  "docker packages are the CLI plus compose and buildx"

# The daemon must NEVER be installed: dockerd belongs to Docker Desktop, and a
# second one would fight it for /var/run/docker.sock.
case "$(wsl_fixes_docker_packages)" in
  *docker-ce-cli*) : ;;
  *) die "docker packages must include docker-ce-cli" ;;
esac
case " $pkgs " in
  *" docker-ce "*|*" docker.io "*|*" containerd"*)
    die "docker packages must not install a daemon (docker-ce / docker.io / containerd)" ;;
  *) pass "docker packages install no daemon" ;;
esac

# The apt source must be pinned to this distro's own codename and signed by the
# keyring we install — an unsigned or wrong-suite line silently breaks apt.
line="$(wsl_fixes_docker_repo_line amd64 resolute)"
case "$line" in
  *"arch=amd64"*)   pass "repo line pins the architecture" ;;
  *) die "repo line must pin arch=: $line" ;;
esac
case "$line" in
  *"signed-by=$WSL_FIXES_DOCKER_KEYRING"*) pass "repo line is signed-by the installed keyring" ;;
  *) die "repo line must be signed-by=$WSL_FIXES_DOCKER_KEYRING: $line" ;;
esac
case "$line" in
  *"https://download.docker.com/linux/ubuntu resolute stable"*)
    pass "repo line targets the distro codename on the stable channel" ;;
  *) die "repo line must be '<url> <codename> stable': $line" ;;
esac

# Docker Desktop owns /usr/bin/docker and recreates it as a symlink on every
# boot. dpkg-divert moves the package's binary out of its way so both survive;
# /usr/local/bin precedes /usr/bin on PATH, so the diverted one wins.
eq "$WSL_FIXES_DOCKER_DIVERT" "/usr/bin/docker.native" \
  "the package binary is diverted clear of Docker Desktop's symlink"
case "$WSL_FIXES_DOCKER_SHIM" in
  /usr/local/bin/*) pass "shim sits on a PATH entry ahead of /usr/bin" ;;
  *) die "shim must live under /usr/local/bin, got $WSL_FIXES_DOCKER_SHIM" ;;
esac

# needs_install keys off the DIVERTED path, not `command -v docker` — Docker
# Desktop's symlink makes `command -v docker` succeed even while dangling,
# which is precisely the state this fix exists to survive.
tmp="$(mktemp -d)"
wsl_fixes_docker_needs_install "$tmp/absent" && pass "docker needs_install: absent → act" \
  || die "docker needs_install must return 0 when the diverted binary is missing"
printf '#!/bin/sh\n' > "$tmp/present"; chmod +x "$tmp/present"
wsl_fixes_docker_needs_install "$tmp/present" && die "docker needs_install must return 1 when present" \
  || pass "docker needs_install: present → no action"
# A dangling symlink is the observed failure mode, and must count as absent.
ln -s "$tmp/nowhere" "$tmp/dangling"
wsl_fixes_docker_needs_install "$tmp/dangling" && pass "docker needs_install: dangling symlink → act" \
  || die "a dangling symlink must count as absent"
rm -rf "$tmp"

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

# The poll interval IS the worst-case outage: interop is dead from the moment it
# is unregistered until the next tick. A 60s interval was sized for a rare
# failure. Measured 2026-08-01 with a second distro in play: seven unregisters
# in 25 minutes, roughly one per interaction with desktop-pure. Anything above
# ~15s makes routine `wsl.exe`/`cmd.exe` calls fail for most of a minute.
secs() { case "$1" in *min) echo $(( ${1%min} * 60 ));; *s) echo "${1%s}";; *) echo "$1";; esac; }
iv="$(printf '%s\n' "$tmr" | sed -n 's/^OnUnitActiveSec=//p')"
[ -n "$iv" ] && [ "$(secs "$iv")" -le 15 ] && pass "timer polls at least every 15s (got $iv)" \
  || die "OnUnitActiveSec must be <= 15s — it is the worst-case interop outage (got '${iv:-unset}')"

bs="$(printf '%s\n' "$tmr" | sed -n 's/^OnBootSec=//p')"
[ -n "$bs" ] && [ "$(secs "$bs")" -le 15 ] && pass "first check happens within 15s of boot (got $bs)" \
  || die "OnBootSec must be <= 15s — interop can already be dead at boot (got '${bs:-unset}')"

# AccuracySec lets systemd defer a tick by up to that much, so it adds straight
# onto the outage window. Keep it small enough not to undo the interval above.
ac="$(printf '%s\n' "$tmr" | sed -n 's/^AccuracySec=//p')"
[ -n "$ac" ] && [ "$(secs "$ac")" -le 5 ] && pass "accuracy does not inflate the window (got $ac)" \
  || die "AccuracySec must be <= 5s — it adds to the outage window (got '${ac:-unset}')"

# ── the memory guard ──────────────────────────────────────────────────────────
# 2026-08-09: the VM wedged after anon memory hit ~15.8 GB of the 16 GB cap AND
# swap reached zero, at which point an order-6 GFP_KERNEL allocation failed
# inside vmbus_alloc_ring <- hvs_probe and killed the vsock transport the WSL
# relay needs. No OOM killer fired — a kernel high-order allocation fails
# gracefully — so the distro went unreachable with nothing killed and nothing
# logged in userspace.

sc="$(wsl_fixes_memory_sysctl)"

# The default is 45056 KB (44 MB) and that is what failed. The number matters
# less than it being far above the default, because what it really buys is
# high-order blocks in the buddy allocator, not free bytes.
mf="$(printf '%s\n' "$sc" | sed -n 's/^vm.min_free_kbytes = //p')"
[ -n "$mf" ] && [ "$mf" -ge 262144 ] && pass "min_free_kbytes reserves >= 256 MB (got $mf)" \
  || die "vm.min_free_kbytes must be >= 262144 — 45056 is the default that failed (got '${mf:-unset}')"

# Default 10 = 0.1% of the zone, i.e. reclaim starts at the cliff edge. At the
# failure the log read `free:33960kB min:34060kB` — free was already BELOW min.
ws="$(printf '%s\n' "$sc" | sed -n 's/^vm.watermark_scale_factor = //p')"
[ -n "$ws" ] && [ "$ws" -gt 10 ] && pass "reclaim starts before the cliff (got $ws)" \
  || die "vm.watermark_scale_factor must exceed the default 10 (got '${ws:-unset}')"

ea="$(wsl_fixes_earlyoom_args)"

# BOTH thresholds are required. -m alone fires under ordinary page-cache
# pressure and kills for no reason; -s alone fires only once swap is gone, which
# is already too late to matter.
case "$ea" in
  *"-m "*) pass "earlyoom keys on available memory" ;;
  *) die "earlyoom args must set -m: $ea" ;;
esac
case "$ea" in
  *"-s "*) pass "earlyoom keys on free swap" ;;
  *) die "earlyoom args must set -s — memory alone fires far too early: $ea" ;;
esac

# Killing PID 1 or the container runtime converts a recoverable memory event
# into a broken distro; sshd/tailscaled are how a wedged box is reached at all.
case "$ea" in
  *"--avoid"*) pass "earlyoom protects the processes recovery depends on" ;;
  *) die "earlyoom args must set --avoid: $ea" ;;
esac
for critical in systemd init dockerd sshd; do
  case "$ea" in
    *"$critical"*) pass "earlyoom avoids $critical" ;;
    *) die "earlyoom --avoid must cover $critical: $ea" ;;
  esac
done

# The whole point is that something in userspace dies before the kernel does.
# If nothing is preferred, earlyoom picks by heuristic and may well take a shell
# instead of the multi-GB job that caused the pressure.
case "$ea" in
  *"--prefer"*python3*) pass "earlyoom prefers the long-running hogs" ;;
  *) die "earlyoom --prefer must name python3 — a killed sync is re-drivable, a wedged VM is not: $ea" ;;
esac

# earlyoom matches /proc/<pid>/comm, which contains no path. A pattern written
# with slashes (the shape used for path matching elsewhere) silently matches
# nothing, and a --prefer that matches nothing is indistinguishable from absent.
case "$ea" in
  */*) die "earlyoom patterns must not contain '/' — comm carries no path: $ea" ;;
  *) pass "earlyoom patterns match comm, not paths" ;;
esac

# The defaults file is sourced by the unit, so the args must land in the
# variable the package actually reads.
ed="$(wsl_fixes_earlyoom_defaults)"
case "$ed" in
  *"EARLYOOM_ARGS="*) pass "defaults file sets EARLYOOM_ARGS" ;;
  *) die "defaults file must set EARLYOOM_ARGS — the unit reads nothing else" ;;
esac

exit "$fail"
