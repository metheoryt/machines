#!/usr/bin/env bash
# provision/wsl-fixes.sh — WSL-only fixes that a distro rebuild must keep.
# Run from inside the distro; idempotent; safe to re-run to backfill an
# existing distro.
#
# NOT part of linux.sh: that script is shared with the Debian VPS `hub`, which
# has no WSL and no interop.
#
# Four fixes:
#
#   1. wslopen (+ xdg-open / wslview symlinks) — Ubuntu 26.04 dropped wslu, so
#      nothing opens a browser from inside the distro. Without it
#      `claude auth login --claudeai` falls back to a URL nobody sees and hangs
#      for the full 180s LOGIN_TIMEOUT_MS.
#
#   2. A binfmt watchdog. WSL interop is lost at runtime whenever ANOTHER distro
#      in the same WSL2 utility VM is shut down GRACEFULLY: binfmt_misc is shared
#      VM-wide, each distro's /init registers WSLInterop at boot, and a graceful
#      systemd shutdown unregisters it for every distro at once. Reproduced
#      2026-08-01 with `wsl -d <other> -u root -- systemctl poweroff`. An abrupt
#      `wsl --terminate` does NOT trigger it (no systemd shutdown runs), which is
#      why an earlier terminate-then-restart test wrongly cleared this — the
#      restart re-registered the handler before the check. The obvious fix — dropping
#      `:WSLInterop:M::MZ::/init:PF` into /usr/lib/binfmt.d/ — is INERT: WSL's
#      own systemd-binfmt ExecStartPost unregisters and re-registers *after*
#      binfmt.d is applied, which is why the live flags always read `P` and
#      never the conf's `PF`. The verified recovery is
#      `systemctl restart systemd-binfmt`, so the watchdog does exactly that.
#
#   3. A native docker CLI. Docker Desktop's WSL integration symlinks
#      /usr/bin/docker and every cli-plugin into /mnt/wsl/docker-desktop/
#      cli-tools — a VM-wide tmpfs it repopulates on every boot. Observed
#      2026-08-01: that repopulation half-completed. The socket, the
#      bind-mounts and the symlink were all wired; cli-tools was left empty;
#      `docker` was gone from a distro whose integration toggle still read ON.
#      Toggling it off and on in the UI repaired it. A headless work distro
#      nobody opens would not have noticed. So each distro gets its own CLI
#      from Docker's apt repo, independent of that tmpfs. Docker Desktop keeps
#      /usr/bin/docker, dpkg-divert puts the package's binary at
#      /usr/bin/docker.native, and /usr/local/bin/docker points at the latter —
#      /usr/local/bin precedes /usr/bin on PATH, so the durable one wins while
#      both survive. Only the CLI and its plugins are installed: dockerd stays
#      Docker Desktop's, and a second daemon would fight it for the socket.
#
#   4. A memory guard: kernel reserves + earlyoom. On 2026-08-09 the VM wedged
#      with `Wsl/Service/0x8007274c` after anonymous memory reached ~15.8 GB of
#      the 16 GB cap AND swap hit `Free swap = 0kB`. Page cache collapsed to
#      ~28 MB, and the next order-6 (256 KB contiguous) GFP_KERNEL allocation
#      failed inside `vmbus_alloc_ring <- hvs_probe` — the Hyper-V vsock
#      transport the WSL relay rides on. The distro did not crash; it silently
#      became unreachable, and no OOM killer fired, because a kernel high-order
#      allocation fails gracefully rather than invoking the killer. Two parts:
#
#        vm.min_free_kbytes 44 MB -> 256 MB. Not about the megabytes: it is what
#        keeps the buddy allocator holding HIGH-ORDER blocks. At the failure the
#        free lists read `0*512kB 2*1024kB 0*2048kB 0*4096kB` and
#        `free:33960kB min:34060kB` — free had fallen BELOW the watermark, with
#        nothing held back. vm.watermark_scale_factor 10 -> 150 starts reclaim
#        at 1.5% of the zone instead of 0.1%, i.e. before the cliff.
#
#        earlyoom, which does NOT prevent exhaustion — it changes the failure
#        mode from "VM unreachable, lose the session, wsl --shutdown" to "a
#        process died". That is the whole point, and it is why this is the
#        load-bearing half.
#
#      Kernel-global, not per-distro: WSL2 runs one kernel for the whole utility
#      VM, so these settings also cover the docker-desktop distro, which we do
#      not provision. That is a benefit here, but it does mean a SECOND
#      provisioned distro would run a second earlyoom against the same memory
#      and could double-kill on one pressure event. Only one Ubuntu distro is
#      provisioned as of 2026-08-09; revisit this if that changes.
#
#      NOT covered here, because this script runs inside the distro: the
#      host-side `.wslconfig` (autoMemoryReclaim=disabled, swap=16GB). That
#      lives in hosts/desktop/windows/windows-reinstall-runbook.md. Full
#      diagnosis: qaz-code/docs/known-issues/sync-wsl-freeze.md.
# NOTE: This file is currently sourced only by provision/tests/wsl-fixes.test.sh
# (with WSL_FIXES_LIB_ONLY=1). The `set -e` would leak into any other shell
# that sources it, so this is a sourcing caveat, not a standalone-script safety.
set -euo pipefail

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

WSL_FIXES_BINFMT_PATH="${WSL_FIXES_BINFMT_PATH:-/proc/sys/fs/binfmt_misc/WSLInterop}"
WSL_FIXES_UNIT_DIR="${WSL_FIXES_UNIT_DIR:-/etc/systemd/system}"
WSL_FIXES_BIN_DIR="${WSL_FIXES_BIN_DIR:-$HOME/.local/bin}"
WSL_FIXES_DOCKER_KEYRING="${WSL_FIXES_DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
WSL_FIXES_DOCKER_LIST="${WSL_FIXES_DOCKER_LIST:-/etc/apt/sources.list.d/docker.list}"
WSL_FIXES_DOCKER_DIVERT="${WSL_FIXES_DOCKER_DIVERT:-/usr/bin/docker.native}"
WSL_FIXES_DOCKER_SHIM="${WSL_FIXES_DOCKER_SHIM:-/usr/local/bin/docker}"
WSL_FIXES_SYSCTL_CONF="${WSL_FIXES_SYSCTL_CONF:-/etc/sysctl.d/99-wsl-memory.conf}"
WSL_FIXES_EARLYOOM_DEFAULTS="${WSL_FIXES_EARLYOOM_DEFAULTS:-/etc/default/earlyoom}"
WSL_FIXES_MIN_FREE_KB="${WSL_FIXES_MIN_FREE_KB:-262144}"
WSL_FIXES_WATERMARK_SCALE="${WSL_FIXES_WATERMARK_SCALE:-150}"

# ── pure helpers (unit-tested) ────────────────────────────────────────────────

# 0 = registration missing, watchdog should act. 1 = present, nothing to do.
wsl_fixes_needs_reregister() {
  [ ! -e "${1:-$WSL_FIXES_BINFMT_PATH}" ]
}

wsl_fixes_symlink_names() {
  printf 'xdg-open\n'
  printf 'wslview\n'
}

wsl_fixes_watchdog_service() {
  cat <<EOF
[Unit]
Description=Re-register WSL interop binfmt handler when it disappears
ConditionPathExists=!$WSL_FIXES_BINFMT_PATH

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart systemd-binfmt
EOF
}

wsl_fixes_watchdog_timer() {
  cat <<'EOF'
[Unit]
Description=Periodically check the WSL interop binfmt handler

[Timer]
OnBootSec=10s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

wsl_fixes_docker_packages() {
  printf 'docker-ce-cli\n'
  printf 'docker-compose-plugin\n'
  printf 'docker-buildx-plugin\n'
}

wsl_fixes_docker_repo_line() {
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable' \
    "$1" "$WSL_FIXES_DOCKER_KEYRING" "$2"
}

# 0 = the diverted binary is missing or dangling, install it. Deliberately NOT
# `command -v docker`: Docker Desktop's symlink keeps that succeeding even when
# its target has evaporated, which is the exact state this fix exists to survive.
wsl_fixes_docker_needs_install() {
  [ ! -x "${1:-$WSL_FIXES_DOCKER_DIVERT}" ]
}

wsl_fixes_memory_sysctl() {
  cat <<EOF
# Written by provision/wsl-fixes.sh. See the header for the 2026-08-09 freeze.
# Keep the buddy allocator holding high-order blocks: the allocation that took
# the VM down needed order-6 (256 KB contiguous) and the free lists had none.
vm.min_free_kbytes = $WSL_FIXES_MIN_FREE_KB

# Begin reclaim at ~1.5% of the zone instead of the 0.1% default, so the kernel
# has room to work before userspace has eaten everything.
vm.watermark_scale_factor = $WSL_FIXES_WATERMARK_SCALE
EOF
}

# earlyoom matches these against /proc/<pid>/comm, which carries no path and is
# truncated to 15 chars — hence bare anchored names rather than path patterns.
#
# --avoid: killing PID 1 or the container runtime turns a recoverable memory
# event into a broken distro. sshd and tailscaled are how a wedged box is
# reached at all.
# --prefer: the long-lived memory hogs. A killed sync is re-drivable from
# upstream by design; a wedged VM is not.
wsl_fixes_earlyoom_args() {
  printf -- '-m 8 -s 8 -r 60 --avoid %s --prefer %s' \
    "'^(systemd|init|dockerd|containerd|sshd|tailscaled)\$'" \
    "'^(python3|gortex|node|twg)\$'"
}

wsl_fixes_earlyoom_defaults() {
  cat <<EOF
# Written by provision/wsl-fixes.sh. See the header for the 2026-08-09 freeze.
# Both thresholds must be crossed before earlyoom acts: the freeze needed RAM at
# the cap AND swap at zero. Keying on memory alone would kill under ordinary
# page-cache pressure; keying on swap alone would fire far too late.
EARLYOOM_ARGS="$(wsl_fixes_earlyoom_args)"
EOF
}

# ── installers (need the filesystem; not unit-tested) ─────────────────────────

wsl_fixes_install_wslopen() {
  local repo asset dest name
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  asset="$repo/provision/assets/wslopen"
  [ -f "$asset" ] || die "missing asset: $asset"

  mkdir -p "$WSL_FIXES_BIN_DIR"
  dest="$WSL_FIXES_BIN_DIR/wslopen"
  install -m 0755 "$asset" "$dest"
  ok "installed $dest"

  while IFS= read -r name; do
    ln -sfn wslopen "$WSL_FIXES_BIN_DIR/$name"
    ok "linked $WSL_FIXES_BIN_DIR/$name -> wslopen"
  done < <(wsl_fixes_symlink_names)
}

wsl_fixes_install_watchdog() {
  local svc="$WSL_FIXES_UNIT_DIR/wsl-binfmt-watchdog.service"
  local tmr="$WSL_FIXES_UNIT_DIR/wsl-binfmt-watchdog.timer"

  wsl_fixes_watchdog_service | sudo tee "$svc" >/dev/null || die "cannot write $svc"
  wsl_fixes_watchdog_timer   | sudo tee "$tmr" >/dev/null || die "cannot write $tmr"
  sudo systemctl daemon-reload
  sudo systemctl enable --now wsl-binfmt-watchdog.timer
  ok "wsl-binfmt-watchdog.timer enabled"

  # The old, inert fix. Remove it so nobody trusts it later.
  if [ -f /usr/lib/binfmt.d/WSLInterop.conf ]; then
    sudo rm -f /usr/lib/binfmt.d/WSLInterop.conf
    ok "removed inert /usr/lib/binfmt.d/WSLInterop.conf"
  fi
}

wsl_fixes_install_docker_cli() {
  command -v apt-get >/dev/null 2>&1 || { warn "no apt-get — skipping the docker CLI"; return 0; }

  local arch codename want pkgs
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  [ -n "$codename" ] || die "cannot read VERSION_CODENAME — no apt suite to target"

  if [ ! -s "$WSL_FIXES_DOCKER_KEYRING" ]; then
    sudo install -m 0755 -d "$(dirname "$WSL_FIXES_DOCKER_KEYRING")"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo tee "$WSL_FIXES_DOCKER_KEYRING" >/dev/null || die "cannot fetch the docker apt key"
    sudo chmod a+r "$WSL_FIXES_DOCKER_KEYRING"
    ok "installed $WSL_FIXES_DOCKER_KEYRING"
  fi

  want="$(wsl_fixes_docker_repo_line "$arch" "$codename")"
  if [ "$(cat "$WSL_FIXES_DOCKER_LIST" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" | sudo tee "$WSL_FIXES_DOCKER_LIST" >/dev/null
    ok "wrote $WSL_FIXES_DOCKER_LIST ($codename)"
  fi

  # No --rename: Docker Desktop's existing symlink stays where it is, and only
  # the package's own binary is redirected. Must be registered before apt runs.
  if ! dpkg-divert --list /usr/bin/docker 2>/dev/null | grep -q .; then
    sudo dpkg-divert --divert "$WSL_FIXES_DOCKER_DIVERT" /usr/bin/docker >/dev/null
    ok "diverted the packaged /usr/bin/docker to $WSL_FIXES_DOCKER_DIVERT"
  fi

  if wsl_fixes_docker_needs_install; then
    pkgs="$(wsl_fixes_docker_packages | tr '\n' ' ')"
    sudo apt-get update -qq
    # shellcheck disable=SC2086
    sudo apt-get install -y $pkgs || die "docker CLI install failed"
  fi

  if [ -x "$WSL_FIXES_DOCKER_DIVERT" ]; then
    sudo ln -sfn "$WSL_FIXES_DOCKER_DIVERT" "$WSL_FIXES_DOCKER_SHIM"
    ok "linked $WSL_FIXES_DOCKER_SHIM -> $WSL_FIXES_DOCKER_DIVERT"
  else
    warn "$WSL_FIXES_DOCKER_DIVERT still missing after install — leaving Docker Desktop's symlink alone"
  fi
}

wsl_fixes_install_memory_guard() {
  wsl_fixes_memory_sysctl | sudo tee "$WSL_FIXES_SYSCTL_CONF" >/dev/null \
    || die "cannot write $WSL_FIXES_SYSCTL_CONF"
  sudo sysctl --system >/dev/null
  ok "min_free_kbytes=$(sysctl -n vm.min_free_kbytes) watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor)"

  if ! command -v apt-get >/dev/null 2>&1; then
    warn "no apt-get — skipping earlyoom, the guard is only half installed"
    return 0
  fi
  if ! command -v earlyoom >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq earlyoom || die "earlyoom install failed"
  fi

  wsl_fixes_earlyoom_defaults | sudo tee "$WSL_FIXES_EARLYOOM_DEFAULTS" >/dev/null \
    || die "cannot write $WSL_FIXES_EARLYOOM_DEFAULTS"
  # enable --now is a no-op on an already-enabled unit, so restart to pick the
  # defaults file up on a re-run.
  sudo systemctl enable --now earlyoom >/dev/null 2>&1 || true
  sudo systemctl restart earlyoom
  sudo systemctl is-active --quiet earlyoom \
    && ok "earlyoom active" \
    || die "earlyoom failed to start — check 'systemctl status earlyoom'"
}

wsl_fixes_main() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || warn "WSL_DISTRO_NAME unset — is this really a WSL distro?"
  info "installing wslopen…"
  wsl_fixes_install_wslopen
  info "installing binfmt watchdog…"
  wsl_fixes_install_watchdog
  info "installing the native docker CLI…"
  wsl_fixes_install_docker_cli
  info "installing the memory guard…"
  wsl_fixes_install_memory_guard
}

[ -n "${WSL_FIXES_LIB_ONLY:-}" ] || wsl_fixes_main "$@"
