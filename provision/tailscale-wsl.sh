#!/usr/bin/env bash
# provision/tailscale-wsl.sh — enroll THIS WSL2 distro as a distinct node on the
# fleet's Headscale tailnet (control https://cc.cyphy.kz), so a server running
# inside the distro (Orca, ssh, rustdesk) is reachable from other tailnet nodes
# at its OWN 100.64.x.y — independent of the Windows host's own Tailscale.
# Pairs with provision/orca-serve.sh.
#
# Model: one tailscaled PER distro (NOT host mirrored-networking), so N distros
# on one Windows host each get a distinct identity and Orca can use the default
# port 6768 everywhere. Inbound arrives via the VPS DERP relay (region 999)
# through WSL's default NAT — no port forwarding, no .wslconfig change.
#
# Idempotent; safe to re-run. Requires systemd in the distro (Ubuntu 24.04+/
# 26.04 default; else set [boot] systemd=true in /etc/wsl.conf and `wsl -t <d>`).
#
# Usage (inside the distro):
#   export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
#   bash ~/machines/provision/tailscale-wsl.sh
#   # optional custom node name:
#   ORCA_TS_HOSTNAME=devbox bash ~/machines/provision/tailscale-wsl.sh
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

LOGIN_SERVER="https://cc.cyphy.kz"

# DNS-label safe: lowercase, non [a-z0-9-] → '-', collapse repeats, trim edges.
ts_sanitize_hostname() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Allow sourcing just the function (for tests) without running main.
[ "${TS_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  warn "does not look like WSL — continuing anyway."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

# systemd is required for tailscaled as a service.
if ! systemctl show-environment >/dev/null 2>&1; then
  die "systemd not running in this distro. Add to /etc/wsl.conf:  [boot]\\nsystemd=true  then 'wsl -t $(uname -n)' and re-open."
fi

# ── Node hostname ─────────────────────────────────────────────────────────────
DEFAULT_NAME="wsl-$(ts_sanitize_hostname "${WSL_DISTRO_NAME:-$(uname -n)}")"
HOSTNAME_TS="${ORCA_TS_HOSTNAME:-$DEFAULT_NAME}"
info "Node hostname: $HOSTNAME_TS"

# ── Already enrolled? (idempotent) ────────────────────────────────────────────
if have tailscale && tailscale ip -4 2>/dev/null | grep -qE '^100\.'; then
  ok "already enrolled on the tailnet: $(tailscale ip -4 | head -1) ($HOSTNAME_TS.fleet.mesh)"
  exit 0
fi

# ── Install tailscale ─────────────────────────────────────────────────────────
if have tailscale; then
  ok "tailscale already installed"
else
  info "Installing tailscale…"
  curl -fsSL https://tailscale.com/install.sh | sh || die "tailscale install failed."
fi

# ── Start the daemon ──────────────────────────────────────────────────────────
$SUDO systemctl enable --now tailscaled || die "could not start tailscaled."

# ── /dev/net/tun sanity ───────────────────────────────────────────────────────
[ -e /dev/net/tun ] || warn "/dev/net/tun missing — inbound serving may need 'tailscaled --tun=userspace-networking'. Modern WSL2 kernels provide tun."

# ── Enroll ────────────────────────────────────────────────────────────────────
[ -n "${HEADSCALE_AUTHKEY:-}" ] || die "HEADSCALE_AUTHKEY not set. Export the reusable pre-auth key (headscale user 'fleet') and re-run."
info "Enrolling on $LOGIN_SERVER as $HOSTNAME_TS…"
$SUDO tailscale up \
  --login-server "$LOGIN_SERVER" \
  --authkey "$HEADSCALE_AUTHKEY" \
  --hostname "$HOSTNAME_TS" \
  || die "tailscale up failed."

# ── Verify ────────────────────────────────────────────────────────────────────
IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$IP" ] || die "enrolled but no tailnet IPv4 yet — check 'tailscale status'."
ok "node '$HOSTNAME_TS' up at $IP  (MagicDNS: ${HOSTNAME_TS}.fleet.mesh)"
printf '\nNext: bash %s\n' "$(dirname "$0")/orca-serve.sh"
