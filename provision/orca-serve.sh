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

# Skip re-extract if already unpacked — the live orca-serve.service execs through a
# symlink INTO squashfs-root, so a blind rm -rf would clobber the running server on
# a re-run. rm -rf ~/.local/opt/orca/squashfs-root to force a re-extract/upgrade.
if [ -x "$ORCA_DIR/squashfs-root/AppRun" ]; then
  ok "Orca already extracted (rm -rf $ORCA_DIR/squashfs-root to re-extract/upgrade)"
else
  info "Extracting CLI (--appimage-extract)…"
  rm -rf "$ORCA_DIR/squashfs-root"
  ( cd "$ORCA_DIR" && "$AI" --appimage-extract >/dev/null 2>&1 ) || die "--appimage-extract failed."
fi

# ── Expose the orca CLI on PATH ───────────────────────────────────────────────
# Orca ships NO standalone `orca` binary on Linux — the only `orca`-named files
# in the AppImage are per-OS launcher SCRIPTS (darwin/win32). The real CLI is a
# JS entrypoint (…/out/cli/index.js inside app.asar.unpacked) run THROUGH the
# bundled Electron binary in Node mode (ELECTRON_RUN_AS_NODE=1) — the launcher
# model VS Code and Orca's own darwin/win wrappers use. In Node mode it needs no
# X display, so `serve` runs truly headless (no xvfb). We write that wrapper.
APPDIR="$ORCA_DIR/squashfs-root"
CLIJS="$(find "$APPDIR/resources" -type f -path '*/cli/index.js' 2>/dev/null | head -1)"
[ -n "$CLIJS" ] || die "Orca CLI entrypoint (…/cli/index.js) not found under $APPDIR/resources — Orca's layout may have changed."
ELECTRON="$APPDIR/orca-ide"
if [ ! -x "$ELECTRON" ]; then
  # Fall back to whatever binary AppRun launches: BIN="$APPDIR/<name>".
  # shellcheck disable=SC2016  # the literal $APPDIR is matched in AppRun, not expanded
  binname="$(sed -n 's/^BIN="\$APPDIR\/\(.*\)"$/\1/p' "$APPDIR/AppRun" 2>/dev/null | head -1)"
  [ -n "$binname" ] && ELECTRON="$APPDIR/$binname"
fi
[ -x "$ELECTRON" ] || die "Orca Electron binary not found (tried $APPDIR/orca-ide and AppRun's BIN=) — cannot expose a CLI."
rm -f "$HOME/.local/bin/orca"   # may be a stale symlink — remove before `>` so we never write through it
cat > "$HOME/.local/bin/orca" <<EOF
#!/usr/bin/env bash
# orca — run Orca's bundled CLI through its Electron binary in Node mode (no X
# display needed). Generated by provision/orca-serve.sh; mirrors Orca's own
# darwin/win launchers, incl. remapping NODE_OPTIONS so the CLI's own Node args
# win. Re-run orca-serve.sh to regenerate after an Orca upgrade.
set -u
export ORCA_NODE_OPTIONS="\${NODE_OPTIONS-}"
export ORCA_NODE_REPL_EXTERNAL_MODULE="\${NODE_REPL_EXTERNAL_MODULE-}"
unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE
exec env ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLIJS" "\$@"
EOF
chmod +x "$HOME/.local/bin/orca"
ok "orca CLI → ~/.local/bin/orca (Electron node-mode wrapper → $CLIJS)"

# ── Verify the CLI runs headlessly ────────────────────────────────────────────
# Node mode needs no display — no xvfb path. NEED_XVFB stays 0 for the serve
# wrapper below (kept so a future display-bound subcommand could reintroduce it).
NEED_XVFB=0
if orca --help >/dev/null 2>&1; then
  ok "orca CLI works headlessly"
else
  warn "orca --help failed. Debug:  ELECTRON_RUN_AS_NODE=1 \"$ELECTRON\" \"$CLIJS\" --help"
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

# ── Autostart: systemd user unit (+linger), else a system unit ────────────────
# Preferred: a user unit + linger (mirrors linux.sh's git-autofetch). But WSL's
# per-user manager (user@UID) frequently fails to start ("Failed to spawn
# executor: Device or resource busy" → result 'resources'), leaving no --user
# bus. Fall back to a SYSTEM unit running serve as this user — boot-durable +
# auto-restart, no linger needed (the system manager is healthy there, same as
# tailscaled / tailscale-autoconnect).
JOURNAL="journalctl -u orca-serve -f"   # overwritten to --user form on that path
if systemctl --user show-environment >/dev/null 2>&1; then
  UD="$HOME/.config/systemd/user"; mkdir -p "$UD"
  cat > "$UD/orca-serve.service" <<'UNIT'
[Unit]
Description=Orca headless runtime server (tailnet, port 6768)
# Retry forever so a missing Electron lib self-heals once installed (no start-limit).
StartLimitIntervalSec=0

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
    JOURNAL="journalctl --user -u orca-serve -f"
    ok "orca-serve.service enabled (user unit + linger)"
  else
    warn "could not enable the user orca-serve.service — start manually: orca-serve-start"
  fi
elif [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; then
  # No usable --user manager (typical in WSL). Install a SYSTEM unit instead.
  SVC_USER="$(id -un)"
  # A stale hand-started serve would hold :6768 and block the unit's bind.
  pkill -f 'out/cli/index.js serve' 2>/dev/null || true
  $SUDO tee /etc/systemd/system/orca-serve.service >/dev/null <<UNIT
[Unit]
Description=Orca headless runtime server (tailnet, port 6768)
After=tailscaled.service network-online.target
Wants=network-online.target
# Retry forever so a missing Electron lib self-heals once installed.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SVC_USER
ExecStart=$HOME/.local/bin/orca-serve-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  if $SUDO systemctl enable --now orca-serve.service >/dev/null 2>&1; then
    ok "orca-serve.service enabled (system unit, User=$SVC_USER — no user manager needed)"
  else
    warn "could not enable the system orca-serve.service — start manually: orca-serve-start"
  fi
else
  warn "no systemd user manager and not root — start manually: orca-serve-start (or under tmux/nohup)."
  JOURNAL="(run orca-serve-start in the foreground to see the pairing URL)"
fi

# ── Next steps ────────────────────────────────────────────────────────────────
cat <<EOF

Orca server ready on this distro.
  • Pairing URL (SECRET — do not commit):  ${JOURNAL}
  • Reach it at:  ${TSIP}:6768   (or <node>.fleet.mesh:6768 with MagicDNS)
  • Pair a client:  orca environment add --name <distro> --pairing-code '<orca://pair?…>'
EOF
