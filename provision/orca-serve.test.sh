#!/usr/bin/env bash
# provision/orca-serve.test.sh — unit tests for the two guards in orca-serve.sh.
# No sudo, no network, no 200 MB AppImage: sources the script in
# ORCA_SERVE_LIB_ONLY mode so only the pure functions load and main never runs.
#
# BOTH guards were written after a live failure on g15 (2026-09-07), and both
# were mutation-tested by deleting them — the cases below fail when either is
# removed. That check is the point: a guard nothing would notice the absence of
# is not a guard, and this repo has already shipped one of those (the
# `declare -F` arm in roles/repos.sh, deleted the same day for that reason).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ORCA_SERVE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$here/orca-serve.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── orca_is_wsl: reads /proc/version, never $WSL_DISTRO_NAME ──────────────────
# The variable is deliberately set to a lie in both directions: sshd does not
# export it, so a script run over ssh sees it empty on a real distro, and a
# stray value in a login shell must not make a bare-metal box look like WSL.
printf '%s\n' 'Linux version 6.6.87.2-microsoft-standard-WSL2 (x@y) #1 SMP' > "$tmp/pv-wsl"
printf '%s\n' 'Linux version 7.0.0-31-generic (buildd@lcy02) #31-Ubuntu SMP' > "$tmp/pv-native"

WSL_DISTRO_NAME='' orca_is_wsl "$tmp/pv-wsl"    || fail 'is_wsl: WSL /proc/version not detected'
WSL_DISTRO_NAME='Ubuntu-26.04' orca_is_wsl "$tmp/pv-native" \
  && fail 'is_wsl: native box reported as WSL (did it read $WSL_DISTRO_NAME?)' || :
orca_is_wsl "$tmp/does-not-exist" && fail 'is_wsl: missing file must not be WSL' || :

# ── orca_cli_name: must not shadow GNOME's screen reader ──────────────────────
# ~/.local/bin sits AHEAD of /usr/bin in a login PATH, so a wrapper named `orca`
# on a desktop box silently takes over the accessibility tool's name.
mkdir -p "$tmp/desktop/usr/bin" "$tmp/desktop/bin" "$tmp/headless/usr/bin"
: > "$tmp/desktop/usr/bin/orca"
eq "$(orca_cli_name "$tmp/headless")" 'orca'     'cli_name: free name is taken'
eq "$(orca_cli_name "$tmp/desktop")"  'orca-cli' 'cli_name: steps aside for /usr/bin/orca'
# Ubuntu ships /bin as a symlink to /usr/bin, but a box where only /bin/orca
# exists must still be treated as claimed.
mkdir -p "$tmp/binonly/bin"; : > "$tmp/binonly/bin/orca"
eq "$(orca_cli_name "$tmp/binonly")"  'orca-cli' 'cli_name: /bin/orca also claims it'

# ── orca_want_autostart: explicit beats detection, junk is an error ───────────
want() { orca_want_autostart "$1" "$2" && echo yes || case $? in 1) echo no ;; *) echo err ;; esac; }

eq "$(want auto  "$tmp/pv-wsl")"    yes 'autostart: auto + WSL → install the unit'
eq "$(want auto  "$tmp/pv-native")" no  'autostart: auto + native → skip the unit'
eq "$(want 1     "$tmp/pv-native")" yes 'autostart: 1 forces it on a native box'
eq "$(want true  "$tmp/pv-native")" yes 'autostart: true is an alias of 1'
eq "$(want 0     "$tmp/pv-wsl")"    no  'autostart: 0 refuses it even on WSL'
eq "$(want no    "$tmp/pv-wsl")"    no  'autostart: no is an alias of 0'
eq "$(want maybe "$tmp/pv-wsl")"    err 'autostart: an unknown value is exit 2, not a default'

# ── orca_install_mode: the shape follows the box, not the caller's habit ──────
# desktop must NOT unpack the AppImage: electron-updater's install path is gated
# on $APPIMAGE, which only the AppImage runtime sets, so an unpacked Orca checks
# for updates forever and installs none (g15, 1.4.197 vs the fleet's 1.4.200).
mode() { orca_install_mode "$1" "$2" || echo err; }

eq "$(mode auto    "$tmp/pv-wsl")"    serve   'mode: auto + WSL → unpacked serve layout'
eq "$(mode auto    "$tmp/pv-native")" desktop 'mode: auto + native → whole AppImage'
eq "$(mode serve   "$tmp/pv-native")" serve   'mode: serve forced on a native box'
eq "$(mode desktop "$tmp/pv-wsl")"    desktop 'mode: desktop forced inside WSL'
eq "$(mode sideways "$tmp/pv-wsl")"   err     'mode: an unknown value is exit 2, not a default'

# ── orca_appimage_name: the basename is the whole bug, in both directions ─────
# desktop: electron-updater writes the release asset's own basename and unlinks
# the file it replaced when the running one carries a version triplet — so a
# version-named file self-updates once and deletes what the launcher execs.
# serve: a name that never varies is a cache that never misses (2026-09-07).
eq "$(orca_appimage_name desktop 1.4.200)" 'orca-linux.AppImage'  'name: desktop takes the asset basename'
eq "$(orca_appimage_name desktop '')"      'orca-linux.AppImage'  'name: desktop name does not depend on the version'
eq "$(orca_appimage_name serve   1.4.200)" 'orca-1.4.200.AppImage' 'name: serve keys the cache by the resolved tag'
orca_appimage_name bogus 1.2.3 >/dev/null 2>&1 && fail 'name: an unknown mode must be exit 2' || :

# ── The script must not write through a symlink ────────────────────────────────
# How the launcher got clobbered by hand on 2026-09-07: `cat > path` follows a
# symlink and truncates its TARGET. orca-serve.sh already guarded its own
# wrapper with `rm -f` before `>`; this asserts the guard stays, next to the one
# for the CLI wrapper's variable name so a rename cannot drop it.
grep -q 'rm -f "\$CLI_PATH"' "$here/orca-serve.sh" \
  || fail 'the rm -f before `cat > $CLI_PATH` is gone — a stale symlink would be written through'
grep -q 'CLI_NAME="\$(orca_cli_name)"' "$here/orca-serve.sh" \
  || fail 'the CLI wrapper no longer takes its name from orca_cli_name'

# ── The guards must still be WIRED IN, not merely defined ─────────────────────
# The function tests above pass whether or not main consults them, which is
# exactly how a dead guard survives a green suite.
grep -q 'orca_want_autostart "\$ORCA_SERVE_AUTOSTART"' "$here/orca-serve.sh" \
  || fail 'main no longer calls orca_want_autostart — the autostart gate is dead code'
grep -q 'if \[ "\$WANT_UNIT" = 0 \]; then' "$here/orca-serve.sh" \
  || fail 'the WANT_UNIT branch around the unit install is gone'

# The mode guards, same rule: defined-but-unconsulted is how a dead guard hides.
grep -q 'MODE="\$(orca_install_mode "\$ORCA_INSTALL_MODE")"' "$here/orca-serve.sh" \
  || fail 'main no longer calls orca_install_mode — the desktop/serve split is dead code'
grep -q 'AI="\$ORCA_DIR/\$(orca_appimage_name "\$MODE" "\$VER")"' "$here/orca-serve.sh" \
  || fail 'the AppImage path no longer comes from orca_appimage_name'
grep -q 'Exec=\$AI %U' "$here/orca-serve.sh" \
  || fail 'the .desktop entry no longer execs the AppImage itself — self-update breaks'
grep -q 'rm -f "\$DESKTOP_FILE"' "$here/orca-serve.sh" \
  || fail 'the rm -f before `cat > $DESKTOP_FILE` is gone — a stale symlink would be written through'
# A forced serve unit must drag the layout with it: the unit execs the CLI
# wrapper, which only the unpacked mode writes.
grep -q 'if \[ "\$WANT_UNIT" = 1 \] && \[ "\$MODE" = desktop \]; then' "$here/orca-serve.sh" \
  || fail 'ORCA_SERVE_AUTOSTART=1 no longer forces the serve layout — the unit would exec a missing wrapper'

echo "PASS: orca-serve.test.sh"
