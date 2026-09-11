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
# It also installs Orca on a NATIVE Linux desktop (mode `desktop`), where the
# shape is deliberately the opposite — see orca_install_mode below for why an
# unpacked tree can never self-update.
#
# Idempotent; safe to re-run. Serve autostarts via a systemd *user* unit +
# linger, mirroring provision/linux.sh's git-autofetch pattern.
#
# Usage (inside the distro, AFTER tailscale-wsl.sh):
#   bash ~/machines/provision/orca-serve.sh
#   ORCA_VERSION=1.2.3 bash ~/machines/provision/orca-serve.sh   # pin a version
#   ORCA_INSTALL_MODE=desktop bash ~/machines/provision/orca-serve.sh
#                                        # force the GUI shape (auto: not WSL)
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

# Which install SHAPE this box gets. The two are not variants of one install:
#
#   serve   — unpack the AppImage (--appimage-extract) and run the bundled CLI
#             out of squashfs-root. No FUSE, no display, and a path that never
#             moves, which is what a headless `orca serve` under systemd needs.
#   desktop — keep the AppImage whole and launch THAT. Orca's in-app updater is
#             electron-updater, whose AppImage install path is gated on
#             $APPIMAGE — a variable only the real AppImage runtime sets. Launch
#             an unpacked tree and every check ends in "[autoUpdater] APPIMAGE
#             env is not defined, current application is not an AppImage": it
#             still asks GitHub, it just can never install what it finds. g15 sat
#             on 1.4.197 that way while the rest of the fleet ran 1.4.200, with
#             no visible error anywhere (2026-09-12).
#
# Exit 2 means the caller passed a value this function does not understand.
orca_install_mode() {   # <auto|desktop|serve> [path-to-proc-version]
  case "$1" in
    desktop) printf 'desktop\n' ;;
    serve)   printf 'serve\n' ;;
    auto)    if orca_is_wsl "${2:-/proc/version}"; then printf 'serve\n'; else printf 'desktop\n'; fi ;;
    *)       return 2 ;;
  esac
}

# What the AppImage on disk is CALLED — load-bearing, and for opposite reasons in
# the two modes.
#
# desktop: the file must carry the release asset's own basename. When
#   electron-updater installs an AppImage it writes the downloaded asset under
#   ITS name and unlinks the file it replaced whenever the running basename
#   carries a version triplet and differs. So orca-1.4.200.AppImage would
#   self-update exactly once and delete the very path the .desktop entry execs —
#   a launcher that breaks at the NEXT release, not at install time.
# serve: nothing ever rewrites that file, and a name that never varies is the
#   cache key that never missed — the 2026-09-07 bug where `orca-latest.AppImage`
#   made nine days of upgrade runs green no-ops. Key it by the resolved tag.
orca_appimage_name() {   # <desktop|serve> <version>
  case "$1" in
    desktop) printf 'orca-linux.AppImage\n' ;;
    serve)   printf 'orca-%s.AppImage\n' "$2" ;;
    *)       return 2 ;;
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

ORCA_INSTALL_MODE="${ORCA_INSTALL_MODE:-auto}"
MODE="$(orca_install_mode "$ORCA_INSTALL_MODE")" \
  || die "ORCA_INSTALL_MODE must be auto, desktop or serve (got '$ORCA_INSTALL_MODE')"

# Resolved HERE rather than next to the unit install, because a forced serve unit
# also decides the install shape: the unit execs the CLI wrapper, which exists
# only in the unpacked layout. ORCA_SERVE_AUTOSTART=1 on a native box is the
# headless-Linux case orca_want_autostart documents — it must still get `serve`.
ORCA_SERVE_AUTOSTART="${ORCA_SERVE_AUTOSTART:-auto}"
orca_want_autostart "$ORCA_SERVE_AUTOSTART"
case $? in
  0) WANT_UNIT=1 ;;
  1) WANT_UNIT=0 ;;
  *) die "ORCA_SERVE_AUTOSTART must be auto, 1 or 0 (got '$ORCA_SERVE_AUTOSTART')" ;;
esac
if [ "$WANT_UNIT" = 1 ] && [ "$MODE" = desktop ]; then
  MODE=serve
  warn "ORCA_SERVE_AUTOSTART=$ORCA_SERVE_AUTOSTART forces the serve layout (the unit needs the unpacked CLI)"
fi
ok "install mode: $MODE"

# Only the serve path needs the tailnet: it exists to be reached from ANOTHER
# box. A desktop install is a local GUI and must not be refused on a box that
# has no tailscale.
TSIP=""
if [ "$MODE" = serve ]; then
  have tailscale || die "tailscale not found — run provision/tailscale-wsl.sh first."
  TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TSIP" ] || die "no tailnet IPv4 — run provision/tailscale-wsl.sh first."
  ok "tailnet IP: $TSIP"
fi

# ── Electron runtime deps (best-effort; names vary across releases) ───────────
# _apt_try installs the FIRST existing package name from its args; warns if none.
_apt_try() {
  local p
  for p in "$@"; do
    # Ask dpkg before reaching for sudo. A desktop box already has every Electron
    # dep, and on a box with no NOPASSWD sudo (g15) the install silently fails —
    # so without this the run prints "none of [libnss3] installed" sixteen times
    # about libraries that are all present.
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed'; then
      ok "dep $p (present)"; return 0
    fi
    _apt_update_once
    if $SUDO apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
      ok "dep $p"; return 0
    fi
  done
  warn "none of [$*] installed — orca may hit a missing .so"
}
info "Installing Electron runtime libs…"
export DEBIAN_FRONTEND=noninteractive
# Refreshed lazily, on the first dep that actually needs installing: a box where
# everything is already present (any desktop) would otherwise pay for an apt
# refresh — and warn about it failing — to install nothing.
APT_UPDATED=0
_apt_update_once() {
  [ "$APT_UPDATED" = 1 ] && return 0
  APT_UPDATED=1
  $SUDO apt-get update -qq || warn "apt-get update failed — dep install may be stale"
}
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
# xvfb is the serve path's fallback display for headless Electron; a desktop box
# has a real session and does not need it.
[ "$MODE" = serve ] && _apt_try xvfb
if [ "$MODE" = desktop ]; then
  # An AppImage mounts ITSELF with FUSE at every launch, so the desktop mode has
  # a dependency the serve mode does not. Ubuntu 26.04 ships fuse3 and no
  # libfuse2, and Orca's runtime is happy with it (measured on g15 2026-09-12) —
  # so only install when the box has neither, and warn rather than die: the
  # AppImage still runs with --appimage-extract-and-run without any of them.
  if have fusermount3 || have fusermount; then ok "FUSE present"; else _apt_try fuse3 libfuse2t64 libfuse2; fi
fi

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

# The desktop mode unpacks nothing, so there is no orca-ide.desktop to read —
# and it must not keep its own note of the version either, because the APP
# rewrites that AppImage when it self-updates and any sidecar would go stale the
# first time it worked. Ask the file itself: `--appimage-extract <entry>` unpacks
# a single entry (3 ms, no FUSE, no mount), cheap enough to do on every run.
_appimage_ver() {   # <path-to-appimage>
  [ -x "$1" ] || return 0
  local t; t="$(mktemp -d)"
  ( cd "$t" && "$1" --appimage-extract orca-ide.desktop >/dev/null 2>&1 )
  sed -n 's/^X-AppImage-Version=v\{0,1\}//p' "$t/squashfs-root/orca-ide.desktop" 2>/dev/null | head -1
  rm -rf "$t"
}

_current_ver() {
  if [ "$MODE" = desktop ]; then _appimage_ver "$ORCA_DIR/$(orca_appimage_name desktop '')"
  else _installed_ver; fi
}

REQ="${ORCA_VERSION:-latest}"
if [ "$REQ" = latest ]; then
  VER="$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest 2>/dev/null \
         | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$VER" ]; then
    # Rate-limited or offline. Stay on what is installed rather than guessing —
    # never re-download blind, and never leave the box without a runtime.
    VER="$(_current_ver)"
    [ -n "$VER" ] || die "could not resolve the latest Orca release and none is installed."
    warn "GitHub release lookup failed — staying on the installed $VER"
  fi
else
  VER="${REQ#v}"
fi
URL="https://github.com/stablyai/orca/releases/download/v${VER}/orca-linux.AppImage"
AI="$ORCA_DIR/$(orca_appimage_name "$MODE" "$VER")"
INSTALLED="$(_current_ver)"
ok "Orca target $VER (installed: ${INSTALLED:-none})"

if [ "$INSTALLED" = "$VER" ] && { [ "$MODE" = desktop ] || [ -x "$APPDIR/AppRun" ]; }; then
  ok "Orca $VER already installed — nothing to download"
else
  if [ -f "$AI" ] && [ "$MODE" != desktop ]; then
    # Safe only because the serve name carries the resolved tag. In desktop mode
    # the name is constant by design, so "the file exists" says nothing about
    # WHICH version it is — INSTALLED above already read that from the file.
    ok "AppImage present: $AI"
  else
    info "Downloading Orca AppImage ($VER)…"
    # Download to .part first: a truncated AppImage left at the final name would
    # be a cache hit forever, which is the bug this whole block exists to fix.
    curl -fsSL "$URL" -o "$AI.part" || { rm -f "$AI.part"; die "AppImage download failed: $URL"; }
    mv "$AI.part" "$AI"
  fi
  chmod +x "$AI"

  if [ "$MODE" = desktop ]; then
    # Nothing to unpack: the AppImage IS the install. A running Orca keeps the
    # old inode mounted, so the swap is safe — it just does not take effect
    # until the app is quit and relaunched.
    pgrep -f 'orca-ide( |$)' >/dev/null 2>&1 \
      && warn "Orca is running — quit and relaunch it to pick up $VER"
    ok "AppImage in place: $AI"
  else

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
  fi   # end of the desktop/serve split inside the install block
fi

# ── Desktop: the launcher, and then we are done ───────────────────────────────
# Exec must name the AppImage ITSELF, never an extracted AppRun — see
# orca_install_mode: $APPIMAGE is what the in-app updater is gated on, and only
# the AppImage runtime sets it. Orca rewrites this entry with the same shape when
# it integrates itself at first launch, so writing it here only matters on a box
# that has never opened Orca — which is every fresh one.
if [ "$MODE" = desktop ]; then
  APPS="$HOME/.local/share/applications"; mkdir -p "$APPS"
  ICONDIR="$HOME/.local/share/icons/hicolor/512x512/apps"; mkdir -p "$ICONDIR"
  # Extract the icon by its REAL path, not the AppImage root's `orca-ide.png` —
  # that one is a symlink into usr/share/icons, so extracting it alone yields a
  # dangling link and the copy fails with ENOENT (caught by the smoke run of
  # this branch, 2026-09-12).
  ICONSRC='usr/share/icons/hicolor/512x512/apps/orca-ide.png'
  if [ ! -f "$ICONDIR/orca-ide.png" ]; then
    ICONTMP="$(mktemp -d)"
    if ( cd "$ICONTMP" && "$AI" --appimage-extract "$ICONSRC" >/dev/null 2>&1 ) \
       && cp "$ICONTMP/squashfs-root/$ICONSRC" "$ICONDIR/orca-ide.png" 2>/dev/null; then
      ok "icon → $ICONDIR/orca-ide.png"
    else
      warn "could not extract the app icon — the launcher entry will show a generic one"
    fi
    rm -rf "$ICONTMP"
  fi

  DESKTOP_FILE="$APPS/orca-ide.desktop"
  rm -f "$DESKTOP_FILE"   # never write THROUGH a symlink (same rule as $CLI_PATH)
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Orca
Exec=$AI %U
Terminal=false
Type=Application
Icon=orca-ide
StartupWMClass=orca
X-AppImage-Version=$VER
Comment=Next-gen IDE for parallel agentic development
MimeType=text/markdown;x-scheme-handler/orca;
Categories=Utility;
EOF
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
  ok "launcher → $DESKTOP_FILE"

  # No CLI wrapper here on purpose. Ours points into squashfs-root, which this
  # mode does not create; Orca writes its own shim at first launch
  # (~/.config/orca/linux-orca-cli-shim/orca) and that one is AppImage-aware —
  # its generator reads $APPIMAGE/$APPDIR precisely because a mount path changes
  # every launch. It is named orca-ide there for the same reason orca_cli_name
  # steps aside: /usr/bin/orca is GNOME's screen reader.
  if [ -d "$APPDIR" ]; then
    warn "an unpacked tree from a previous serve-mode install is still at $APPDIR"
    warn "  it is what an existing CLI shim points at — rm -rf it only after the AppImage launch is proven"
  fi

  cat <<EOF

Orca $VER installed as a self-updating AppImage.
  • Launch it from the app menu, or:  $AI
  • It updates itself from here on — the check is \$APPIMAGE-gated, which an
    unpacked install can never satisfy.
  • No headless serve on this box; the window itself is the runtime.
EOF
  exit 0
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
# WANT_UNIT was decided up with the install mode; see there.
if [ "$WANT_UNIT" = 0 ]; then
  JOURNAL="(no autostart unit on this box — run: $CLI_NAME serve --port 6768)"
  ok "autostart not wanted here — skipping the orca-serve unit"
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
