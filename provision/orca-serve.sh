#!/usr/bin/env bash
# provision/orca-serve.sh — install Orca and autostart a headless `orca serve`
# runtime in THIS WSL2 distro, reachable over the tailnet (run
# provision/tailscale-wsl.sh FIRST). The Orca desktop/mobile client pairs to it
# and drives repos/terminals/agents that live natively on the distro's Linux
# filesystem — not across the slow \\wsl.localhost 9P boundary.
#
# Orca ships on Linux only as a GUI AppImage; the `orca` CLI (which `serve`
# needs) is bundled inside. We extract it headlessly with --appimage-extract
# (no FUSE, no root) and symlink the CLI onto PATH.
#
# Idempotent; safe to re-run. Serve autostarts via a systemd *user* unit +
# linger, mirroring provision/linux.sh's git-autofetch pattern.
#
# Usage (inside the distro, AFTER tailscale-wsl.sh):
#   bash ~/machines/provision/orca-serve.sh
#   ORCA_VERSION=1.2.3 bash ~/machines/provision/orca-serve.sh   # pin a version
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

have tailscale || die "tailscale not found — run provision/tailscale-wsl.sh first."
TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$TSIP" ] || die "no tailnet IPv4 — run provision/tailscale-wsl.sh first."
ok "tailnet IP: $TSIP"

# ── Electron runtime deps (best-effort; names vary across releases) ───────────
# _apt_try installs the FIRST existing package name from its args; warns if none.
_apt_try() {
  local p
  for p in "$@"; do
    if $SUDO apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
      ok "dep $p"; return 0
    fi
  done
  warn "none of [$*] installed — orca may hit a missing .so"
}
info "Installing Electron runtime libs…"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq || warn "apt-get update failed — dep install may be stale"
_apt_try libnss3
_apt_try libgbm1
_apt_try libgtk-3-0t64 libgtk-3-0
_apt_try libasound2t64 libasound2
_apt_try libatk-bridge2.0-0t64 libatk-bridge2.0-0
_apt_try libatk1.0-0t64 libatk1.0-0
_apt_try libcups2t64 libcups2
_apt_try libxshmfence1
_apt_try libdrm2
_apt_try libxkbcommon0
_apt_try libxcomposite1
_apt_try libxdamage1
_apt_try libxrandr2
_apt_try libxfixes3
_apt_try libpango-1.0-0
_apt_try xvfb   # fallback virtual display for headless Electron

# ── Download + extract the AppImage (headless, no FUSE) ───────────────────────
ORCA_DIR="$HOME/.local/opt/orca"; mkdir -p "$ORCA_DIR"
VER="${ORCA_VERSION:-latest}"
if [ "$VER" = latest ]; then
  URL="https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage"
else
  URL="https://github.com/stablyai/orca/releases/download/v${VER}/orca-linux.AppImage"
fi
AI="$ORCA_DIR/orca-${VER}.AppImage"
if [ -f "$AI" ]; then
  ok "AppImage present: $AI"
else
  info "Downloading Orca AppImage ($VER)…"
  curl -fsSL "$URL" -o "$AI" || die "AppImage download failed: $URL"
fi
chmod +x "$AI"

info "Extracting CLI (--appimage-extract)…"
rm -rf "$ORCA_DIR/squashfs-root"
( cd "$ORCA_DIR" && "$AI" --appimage-extract >/dev/null 2>&1 ) || die "--appimage-extract failed."

# ── Expose the orca CLI on PATH ───────────────────────────────────────────────
CLI="$(find "$ORCA_DIR/squashfs-root" -type f -name orca 2>/dev/null | head -1)"
if [ -n "$CLI" ]; then
  chmod +x "$CLI"
  ln -sf "$CLI" "$HOME/.local/bin/orca"
  ok "orca CLI → ~/.local/bin/orca ($CLI)"
else
  APPRUN="$ORCA_DIR/squashfs-root/AppRun"
  [ -x "$APPRUN" ] || die "no 'orca' binary and no AppRun in squashfs-root — cannot expose a CLI."
  cat > "$HOME/.local/bin/orca" <<EOF
#!/usr/bin/env bash
exec "$APPRUN" "\$@"
EOF
  chmod +x "$HOME/.local/bin/orca"
  ok "orca CLI wrapper → ~/.local/bin/orca (AppRun)"
fi

# ── Verify the CLI runs headlessly (xvfb fallback) ────────────────────────────
NEED_XVFB=0
if orca --help >/dev/null 2>&1; then
  ok "orca CLI works headlessly"
elif have xvfb-run && xvfb-run -a orca --help >/dev/null 2>&1; then
  NEED_XVFB=1
  warn "orca needs a virtual display — serve will run under xvfb-run"
else
  warn "orca --help failed. Check libs:  ldd \"$CLI\" | grep 'not found'  — or run once under WSLg."
fi

# ── Serve wrapper (computes pairing address fresh at each start) ──────────────
SERVE="$HOME/.local/bin/orca-serve-start"
RUN_PREFIX=""
[ "$NEED_XVFB" = 1 ] && RUN_PREFIX="xvfb-run -a "
cat > "$SERVE" <<EOF
#!/usr/bin/env bash
# orca-serve-start — launch the headless Orca runtime bound to this node's
# current tailnet IP. Written by provision/orca-serve.sh.
set -u
export PATH="\$HOME/.local/bin:\$PATH"
addr="\$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "\$addr" ] || { echo "orca-serve-start: no tailnet IPv4 (is tailscaled up?)" >&2; exit 1; }
exec ${RUN_PREFIX}orca serve --port 6768 --pairing-address "\$addr"
EOF
chmod +x "$SERVE"
ok "serve wrapper → ~/.local/bin/orca-serve-start"

# ── Autostart via systemd user unit + linger ──────────────────────────────────
if systemctl --user show-environment >/dev/null 2>&1; then
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
  cat > "$UD/orca-serve.service" <<'UNIT'
[Unit]
Description=Orca headless runtime server (tailnet, port 6768)
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/orca-serve-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  if systemctl --user enable --now orca-serve.service >/dev/null 2>&1; then
    $SUDO loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
    ok "orca-serve.service enabled (autostart + linger)"
  else
    warn "could not enable orca-serve.service — start manually: orca-serve-start"
  fi
else
  warn "no systemd user manager — start manually: orca-serve-start (or under tmux/nohup). Enable systemd in /etc/wsl.conf for autostart."
fi

# ── Next steps ────────────────────────────────────────────────────────────────
cat <<EOF

Orca server ready on this distro.
  • Pairing URL (SECRET — do not commit):  journalctl --user -u orca-serve -f
  • Reach it at:  ${TSIP}:6768   (or <node>.fleet.mesh:6768 with MagicDNS)
  • Pair a client:  orca environment add --name $(uname -n) --pairing-code '<orca://pair?…>'
EOF
