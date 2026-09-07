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

# ── Pure decisions (unit-tested by provision/orca-serve.test.sh) ──────────────
# These sit above the LIB_ONLY hook so the two guards they drive can be tested
# without downloading a 200 MB AppImage.

# WSL detection reads /proc/version, NEVER $WSL_DISTRO_NAME: sshd does not set
# that variable and this script is normally run over ssh. Same rule as
# tier_docker, for the same reason — guessing wrong in that direction installs a
# daemon on a box that should not have one.
orca_is_wsl() {   # [path-to-proc-version]
  grep -qi microsoft "${1:-/proc/version}" 2>/dev/null
}

# The CLI wrapper's NAME. `orca` collides with GNOME's screen reader
# (/usr/bin/orca, Ubuntu package `orca`, present on every desktop install) and
# ~/.local/bin sits AHEAD of /usr/bin in a login PATH — so on a desktop box this
# wrapper silently shadows an accessibility tool. On WSL there is no desktop, the
# name was free, and it went unnoticed until g15 became a native Ubuntu box on
# 2026-09-07. Orca's own CliInstaller names its shim `orca-ide` for exactly this
# reason and says so in a comment; we step aside rather than take the name.
orca_cli_name() {   # [root-prefix-for-tests]
  local r="${1:-}"
  if [ -e "$r/usr/bin/orca" ] || [ -e "$r/bin/orca" ]; then
    printf 'orca-cli\n'
  else
    printf 'orca\n'
  fi
}

# Whether to install the boot-durable `orca serve` unit. This script's premise is
# that Orca's GUI cannot run here, so a headless serve is the only way to reach
# the box. On a native Linux desktop that premise is FALSE and the unit is
# actively harmful: Electron allows one instance per userData dir
# (~/.config/orca), so a running serve makes the GUI exit with "Another Orca
# instance is already running for this userData profile". g15 did exactly that on
# 2026-09-07 — its Windows→Ubuntu reinstall brought the WSL-era unit back,
# enabled, and the desktop app could not open until it was disabled. With a
# window open, the window itself serves the port a client pairs to, so the unit
# buys nothing there.
# Exit 2 means the caller passed a value this function does not understand.
orca_want_autostart() {   # <auto|1|0> [path-to-proc-version]
  case "$1" in
    1|yes|true) return 0 ;;
    0|no|false) return 1 ;;
    auto)       orca_is_wsl "${2:-/proc/version}" ;;
    *)          return 2 ;;
  esac
}

# Allow sourcing just the functions (for tests) without running main.
[ "${ORCA_SERVE_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

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
# The cache is keyed by the RESOLVED tag, never by the string "latest". Until
# 2026-09-07 the file was named orca-${ORCA_VERSION:-latest}.AppImage, so with
# the default VER the name never changed, `[ -f "$AI" ]` was a permanent cache
# hit, and NO re-run of this script ever upgraded Orca — g15-wsl sat on 1.4.192
# while upstream was at 1.4.197. The extract gate was worse: it keyed on
# squashfs-root/AppRun merely existing, so even an explicit ORCA_VERSION=x.y.z
# downloaded the new AppImage and then skipped unpacking it.
ORCA_DIR="$HOME/.local/opt/orca"; mkdir -p "$ORCA_DIR"
APPDIR="$ORCA_DIR/squashfs-root"

# The only truthful record of what is EXTRACTED is the AppImage's own desktop
# entry. Compare tags with the leading v stripped from both sides: upstream says
# v1.4.197 and this file says 1.4.192, so a raw comparison is either never equal
# (re-downloads 200+ MB every run) or never unequal (never upgrades).
_installed_ver() {
  sed -n 's/^X-AppImage-Version=v\{0,1\}//p' "$APPDIR/orca-ide.desktop" 2>/dev/null | head -1
}

REQ="${ORCA_VERSION:-latest}"
if [ "$REQ" = latest ]; then
  VER="$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest 2>/dev/null \
         | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$VER" ]; then
    # Rate-limited or offline. Stay on what is installed rather than guessing —
    # never re-download blind, and never leave the box without a runtime.
    VER="$(_installed_ver)"
    [ -n "$VER" ] || die "could not resolve the latest Orca release and none is installed."
    warn "GitHub release lookup failed — staying on the installed $VER"
  fi
else
  VER="${REQ#v}"
fi
URL="https://github.com/stablyai/orca/releases/download/v${VER}/orca-linux.AppImage"
AI="$ORCA_DIR/orca-${VER}.AppImage"
INSTALLED="$(_installed_ver)"
ok "Orca target $VER (installed: ${INSTALLED:-none})"

if [ "$INSTALLED" = "$VER" ] && [ -x "$APPDIR/AppRun" ]; then
  ok "Orca $VER already extracted — nothing to download or unpack"
else
  if [ -f "$AI" ]; then
    ok "AppImage present: $AI"
  else
    info "Downloading Orca AppImage ($VER)…"
    # Download to .part first: a truncated AppImage left at the final name would
    # be a cache hit forever, which is the bug this whole block exists to fix.
    curl -fsSL "$URL" -o "$AI.part" || { rm -f "$AI.part"; die "AppImage download failed: $URL"; }
    mv "$AI.part" "$AI"
  fi
  chmod +x "$AI"

  # The live orca-serve.service execs a binary INSIDE squashfs-root, so the tree
  # cannot be swapped under it — stop it first. Which manager owns the unit is
  # decided further down (WSL's user@UID often has no bus), so probe both.
  SERVE_CTL=""
  if systemctl --user is-active --quiet orca-serve.service 2>/dev/null; then
    SERVE_CTL="systemctl --user"
  elif systemctl is-active --quiet orca-serve.service 2>/dev/null; then
    SERVE_CTL="$SUDO systemctl"
  fi
  if [ -n "$SERVE_CTL" ]; then
    info "Stopping orca-serve for the upgrade…"
    $SERVE_CTL stop orca-serve.service || true
  fi

  info "Extracting CLI (--appimage-extract)…"
  # MOVE the old tree aside, never rm: if the new release moved cli/index.js the
  # `die` below fires and this is the only way back to a working runtime.
  OLD=""
  if [ -e "$APPDIR" ]; then
    OLD="$APPDIR.prev-${INSTALLED:-unknown}"
    rm -rf "$OLD"; mv "$APPDIR" "$OLD"
  fi
  if ( cd "$ORCA_DIR" && "$AI" --appimage-extract >/dev/null 2>&1 ); then
    [ -n "$OLD" ] && ok "previous tree kept at $OLD (rm -rf it once $VER is proven)"
  else
    if [ -n "$OLD" ]; then rm -rf "$APPDIR"; mv "$OLD" "$APPDIR"; warn "restored the previous Orca tree"; fi
    die "--appimage-extract failed."
  fi
fi

# ── Expose the orca CLI on PATH ───────────────────────────────────────────────
# Orca ships NO standalone `orca` binary on Linux — the only `orca`-named files
# in the AppImage are per-OS launcher SCRIPTS (darwin/win32). The real CLI is a
# JS entrypoint (…/out/cli/index.js inside app.asar.unpacked) run THROUGH the
# bundled Electron binary in Node mode (ELECTRON_RUN_AS_NODE=1) — the launcher
# model VS Code and Orca's own darwin/win wrappers use. In Node mode it needs no
# X display, so `serve` runs truly headless (no xvfb). We write that wrapper.
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
CLI_NAME="$(orca_cli_name)"
CLI_PATH="$HOME/.local/bin/$CLI_NAME"
[ "$CLI_NAME" = orca ] || warn "/usr/bin/orca exists (GNOME screen reader) — installing the CLI as \`$CLI_NAME\` so it is not shadowed"
rm -f "$CLI_PATH"   # may be a stale symlink — remove before `>` so we never write through it
cat > "$CLI_PATH" <<EOF
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
chmod +x "$CLI_PATH"
ok "orca CLI → ~/.local/bin/$CLI_NAME (Electron node-mode wrapper → $CLIJS)"

# ── Verify the CLI runs headlessly ────────────────────────────────────────────
# Node mode needs no display — no xvfb path. NEED_XVFB stays 0 for the serve
# wrapper below (kept so a future display-bound subcommand could reintroduce it).
NEED_XVFB=0
if "$CLI_PATH" --help >/dev/null 2>&1; then
  ok "orca CLI works headlessly"
else
  warn "$CLI_NAME --help failed. Debug:  ELECTRON_RUN_AS_NODE=1 \"$ELECTRON\" \"$CLIJS\" --help"
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
# Serve needs an X display: Electron's browser panes abort with "Missing X server
# or \$DISPLAY" and take the whole runtime down. Orca starts its own Xvfb on :99
# when DISPLAY is unset — but under WSLg /tmp/.X11-unix is a READ-ONLY tmpfs, so
# Xvfb cannot bind its socket there and never becomes ready. WSLg already serves
# :0 on that same tmpfs, so hand it to serve instead of fighting for :99.
# On a cold distro start the unit can beat WSLg to its socket; without the wait
# the first attempt gets no display and Restart=on-failure has to clean up after
# it (NRestarts=1 on a measured wsl --terminate cycle).
# Guarded on WSL: off WSL /tmp/.X11-unix is a normal writable dir, so Orca's own
# Xvfb on :99 comes up fine and this 30-second wait would be a pointless stall
# on a box that has no WSLg to wait for.
if [ -z "\${DISPLAY:-}" ] && grep -qi microsoft /proc/version 2>/dev/null; then
  for _ in \$(seq 1 30); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done
  [ -S /tmp/.X11-unix/X0 ] && export DISPLAY=:0
fi
# Serve prints the banner and the PAIRING URL on stdout, and Electron flushes a
# non-tty stdout only at exit — so under systemd the journal shows nothing until
# the process dies, and the documented "read the pairing URL from the journal"
# never works. Give it a pty when stdout is not one; script -e still returns the
# child's exit status, so Restart=on-failure keeps working. (No backticks in this
# heredoc: it is unquoted, so they would run as a command substitution HERE.)
if [ -t 1 ]; then
  exec ${RUN_PREFIX}$CLI_NAME serve --port 6768 --pairing-address "\$addr"
fi
exec script -qefc "${RUN_PREFIX}$CLI_NAME serve --port 6768 --pairing-address \$addr" /dev/null
EOF
chmod +x "$SERVE"
ok "serve wrapper → ~/.local/bin/orca-serve-start"

# ── Autostart: WSL only, unless asked ─────────────────────────────────────────
# See orca_want_autostart above for WHY a native desktop must not get this unit
# (Electron's one-instance-per-userData-dir rule makes a running serve lock the
# GUI out). ORCA_SERVE_AUTOSTART=1 forces it anyway — for a headless Linux box
# with no session to open a window in, which is a real case and the only reason
# this is an override rather than a hard refusal.
ORCA_SERVE_AUTOSTART="${ORCA_SERVE_AUTOSTART:-auto}"
orca_want_autostart "$ORCA_SERVE_AUTOSTART"
case $? in
  0) WANT_UNIT=1 ;;
  1) WANT_UNIT=0 ;;
  *) die "ORCA_SERVE_AUTOSTART must be auto, 1 or 0 (got '$ORCA_SERVE_AUTOSTART')" ;;
esac

if [ "$WANT_UNIT" = 0 ]; then
  JOURNAL="(no autostart unit on this box — run: $CLI_NAME serve --port 6768)"
  ok "not a WSL distro — skipping the orca-serve autostart unit"
  warn "no desktop session on this box? force it: ORCA_SERVE_AUTOSTART=1 bash $0"
else
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
fi   # end of the WANT_UNIT gate


# ── Next steps ────────────────────────────────────────────────────────────────
HEADLINE="Orca server ready on this distro."
[ "$WANT_UNIT" = 0 ] && HEADLINE="Orca installed. No headless server here — the desktop app is the runtime."
cat <<EOF

${HEADLINE}
  • Pairing URL (SECRET — do not commit):  ${JOURNAL}
  • Reach it at:  ${TSIP}:6768   (or <node>.gg.ez:6768 with MagicDNS)
  • Pair a client:  $CLI_NAME environment add --name <distro> --pairing-code '<orca://pair?…>'
EOF
