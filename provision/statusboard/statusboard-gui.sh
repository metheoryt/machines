#!/usr/bin/env bash
# provision/statusboard/statusboard-gui.sh — run the status board inside a real
# terminal emulator on the physical display, instead of on a Linux VT.
#
# WHY THIS EXISTS
#
# statusboard.sh paints time-series charts with the eighth-block ramp
# U+2581..U+2588 — the same glyphs the user's own statusline uses. A Linux VT
# cannot draw them. A psf console font carries at most 512 glyphs, and the
# largest one available here (Uni3-TerminusBold32x16) ships only U+2588, U+2591
# and U+2592 out of that range, so the board's `sb_is_vt` path falls back to an
# ASCII ramp. That fallback is legible but repeats the same few characters, which
# is exactly what "some repeated chars on chart area" was (2026-07-29).
#
# The fix is not a better psf font — none of them have the coverage. It is to stop
# using a VT for the physical display and run a modern terminal emulator there:
#
#   cage (Wayland kiosk compositor) -> foot (terminal) -> statusboard.sh
#
# foot renders a TrueType font, so the ramp is exact, the font size is a number
# rather than a search for a psf file, and the board's OWN detection does the
# right thing with no code change: under foot, stdout is a /dev/pts/N, no
# /dev/ttyN matches statusboard.sh's `-ef /dev/stdout` probe, SB_IS_VT stays 0,
# and the block ramp is selected.
#
# WHY A LOGIN SESSION AND NOT A SYSTEM UNIT
#
# cage must hold a logind seat to become DRM master on /dev/dri/card0. A plain
# `User=me` system service has no session and no seat, so it cannot. Rather than
# recreate a session with PAMName=login (the greetd-kiosk pattern — it works, but
# every one of statusboard.service's hardening directives has to come back off,
# because cage and foot need a writable XDG_RUNTIME_DIR), this uses the thing
# that hands out seats for a living: an autologin getty.
#
#   getty@tty1 --autologin me  ->  login shell  ->  /etc/profile.d hook  ->  cage
#
# That also picks the better failure mode. The hook does NOT exec, so if cage
# dies you land on a bash prompt on tty1 with the error above it — diagnosable
# from the chair. The system-unit shape leaves a black screen and an unusable
# console, which this box has already been through twice.
#
# Usage:
#   bash statusboard-gui.sh              # run the kiosk in the foreground
#   bash statusboard-gui.sh --check      # verify prerequisites, change nothing
#   sudo bash statusboard-gui.sh --install
#   sudo bash statusboard-gui.sh --uninstall
#
# --install takes tty1 away from statusboard.service (the text board) and gives
# it to the autologin getty. Ctrl-Alt-F2 still reaches a console login from
# inside the kiosk, because cage is started with -s.
set -u

MODE=run
FONT="${STATUSBOARD_GUI_FONT:-JetBrains Mono}"
# Size is purely a readability call: nothing in the board is tuned to a fixed
# width, it re-reads the terminal size each frame. For scale, 20pt measured
# 119x29 on latitude's panel, so 16pt gives roughly a quarter more of each axis.
FONTSIZE="${STATUSBOARD_GUI_FONTSIZE:-16}"
INTERVAL="${STATUSBOARD_GUI_INTERVAL:-1}"
PROBE="${STATUSBOARD_GUI_PROBE:-10}"
# Seconds of samples per chart cell. Matches the board's own default; passed
# explicitly so `--check` shows every cadence the kiosk runs at in one line.
CELL="${STATUSBOARD_GUI_CELL:-300}"
GUI_TTY="${STATUSBOARD_GUI_TTY:-/dev/tty1}"
GETTY_UNIT="getty@$(basename "$GUI_TTY").service"
DROPIN_DIR="${STATUSBOARD_DROPIN_DIR:-/etc/systemd/system/$GETTY_UNIT.d}"
DROPIN="$DROPIN_DIR/statusboard-gui.conf"
# zz- so it runs after anything else in profile.d: this hook blocks for the life
# of the session, and a hook that never returns must not pre-empt the ones that
# set PATH or locale.
PROFILE_HOOK="${STATUSBOARD_PROFILE_HOOK:-/etc/profile.d/zz-statusboard-gui.sh}"
TEXT_SERVICE=statusboard.service
RAMP_LO=2581
RAMP_HI=2588

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --install) MODE=install; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --font) FONT="${2:-}"; shift 2 ;;
    --size) FONTSIZE="${2:-16}"; shift 2 ;;
    -h | --help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BOARD="$(dirname "$SELF")/statusboard.sh"

# ── Pure helpers (unit-tested) ────────────────────────────────────────────────

# sbg_missing_deps <cmd>...: the subset of its arguments that are not on PATH.
# Printed rather than returned so the caller can name all of them in one message
# instead of failing on the first.
sbg_missing_deps() {
  local c out=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || out="$out$c "
  done
  printf '%s' "${out% }"
}

# sbg_font_has_ramp <family>: does this font cover U+2581..U+2588?
#
# Asked by measured coverage, never by name. The whole reason the VT path degrades
# is a font that looked right and lacked the glyphs, and a TrueType font with a
# plausible name can miss the range just as easily. fontconfig can answer directly:
# a :charset= query matches only fonts covering EVERY listed codepoint, so an empty
# result is a definite no.
sbg_font_has_ramp() {
  local family="${1:-}" lo="${2:-$RAMP_LO}" hi="${3:-$RAMP_HI}"
  [ -n "$family" ] || return 1
  command -v fc-list >/dev/null 2>&1 || return 1
  fc-list ":charset=$lo-$hi" family 2>/dev/null |
    tr ',' '\n' | grep -qxF "$family"
}

# sbg_have_polkit: is a polkit authority installed at all?
#
# Asked by artefact rather than by dpkg so it holds on any distro, and it is a
# presence test rather than a decision test on purpose: polkit's own answer depends
# on the CALLER's session, so asking from an SSH shell (not on a seat, not active)
# would say "denied" on a perfectly healthy box. Whether cage itself is authorised
# is answerable with `pkcheck --action-id org.freedesktop.login1.chvt --process
# $(pgrep -x cage)`, which needs the kiosk to already be running.
sbg_have_polkit() {
  command -v pkcheck >/dev/null 2>&1 && return 0
  [ -x /usr/lib/polkit-1/polkitd ] || [ -x /usr/libexec/polkit-1/polkitd ]
}

# sbg_kiosk_argv <board> <font> <size> <interval> <probe> <cell>: the kiosk command line,
# one argument per line so a test can assert on it without re-splitting a string.
#
#   cage -s   VT switching stays enabled. This is the escape hatch: without it a
#             compositor owning tty1 swallows Ctrl-Alt-F2 and the only console on
#             the box is unreachable from the box.
#   cage -d   no client-side decorations — a title bar on a kiosk is wasted rows.
#   foot -H   hold the window open after the child exits, so a board that dies
#             leaves its error on screen instead of a black rectangle.
sbg_kiosk_argv() {
  local board="${1:-}" font="${2:-}" size="${3:-16}" interval="${4:-1}" probe="${5:-10}" cell="${6:-300}"
  printf '%s\n' cage -s -d -- \
    foot -H -f "$font:size=$size" \
    -o main.pad=6x6 -o cursor.style=underline \
    -e bash "$board" --interval "$interval" --probe "$probe" --cell "$cell"
}

# sbg_dropin_text <user>: the getty drop-in that turns the login prompt into an
# autologin. The empty ExecStart= is required — a drop-in APPENDS to a list-typed
# directive, so without the reset systemd would run two agettys on one VT.
#
# Deliberately WITHOUT Debian's `-o '-p -- \u'`. --autologin normally adds
# `-f <user>` to the /bin/login command line itself, but supplying --login-options
# hands that argv to the caller, so agetty stops adding it — which is how the first
# install attempt produced a hung `/bin/login -p --` with no user and no autologin
# at all (2026-07-29). Dropping -o is the smaller surface and was verified to yield
# `-bash` as the target user; the environment -p would have preserved is one this
# VT has no interest in.
sbg_dropin_text() {
  local user="${1:-me}"
  cat <<CONF
# Installed by statusboard-gui.sh. Autologin is what earns the logind seat that
# cage needs to take DRM master; see the header of that script.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --autologin $user - \$TERM
CONF
}

# sbg_hook_text <self> <tty>: the /etc/profile.d hook.
#
# Every guard is load-bearing:
#   tty       only the physical console. /etc/profile is read by every login
#             shell, including `ssh -t latitude` and `su -l`, and starting a
#             compositor from one of those would fail noisily at best.
#   WAYLAND_DISPLAY / DISPLAY
#             already inside a compositor — do not nest.
#   -f board  the repo may not be checked out yet on a freshly imaged box.
#
# It runs the kiosk WITHOUT exec on purpose. exec would replace the login shell,
# so a cage that fails immediately would end the session, respawn the getty, and
# spin. Falling through to the prompt instead leaves the failure on screen and a
# shell under it.
sbg_hook_text() {
  local self="${1:-}" tty="${2:-/dev/tty1}"
  cat <<HOOK
# /etc/profile.d/$(basename "${PROFILE_HOOK}") — installed by statusboard-gui.sh.
# Starts the status board kiosk on the physical console. Do not edit; reinstall.
if [ -z "\${WAYLAND_DISPLAY:-}" ] && [ -z "\${DISPLAY:-}" ] &&
  [ "\$(tty 2>/dev/null)" = "$tty" ] && [ -f "$self" ]; then
  bash "$self"
fi
HOOK
}

[ "${STATUSBOARD_GUI_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── check ─────────────────────────────────────────────────────────────────────

sbg_check() {
  local rc=0 missing
  missing="$(sbg_missing_deps cage foot fc-list)"
  if [ -n "$missing" ]; then
    printf 'missing: %s\n' "$missing" >&2
    printf 'try: sudo apt install -y cage foot fontconfig foot-terminfo\n' >&2
    rc=1
  else
    printf 'deps       ok (cage, foot, fc-list)\n'
  fi

  if sbg_font_has_ramp "$FONT"; then
    printf 'font       ok (%s covers U+%s..U+%s)\n' "$FONT" "$RAMP_LO" "$RAMP_HI"
  else
    printf 'font       %s does not cover U+%s..U+%s — charts would degrade\n' \
      "$FONT" "$RAMP_LO" "$RAMP_HI" >&2
    printf '           try: sudo apt install -y fonts-jetbrains-mono fonts-dejavu-core\n' >&2
    rc=1
  fi

  if [ -e /dev/dri/card0 ]; then
    printf 'drm        ok (/dev/dri/card0)\n'
  else
    printf 'drm        no /dev/dri/card0 — cage has nothing to drive\n' >&2
    rc=1
  fi

  if [ -f "$BOARD" ]; then
    printf 'board      ok (%s)\n' "$BOARD"
  else
    printf 'board      missing: %s\n' "$BOARD" >&2
    rc=1
  fi

  # The escape hatch is TWO things, and the second one fails silently. cage -s makes
  # the compositor honour Ctrl-Alt-Fn, but the switch it then asks for goes through
  # logind's Seat.SwitchTo, which is polkit-gated — and a minimal Debian has no
  # polkit at all, in which case logind denies it to everyone but root. The keys do
  # nothing, cage logs "Could not switch session: Permission denied" where nobody
  # looks, and the only console on the box becomes network-only. That is worth a
  # hard failure rather than a note.
  if sbg_have_polkit; then
    printf 'vtswitch   ok (polkit present — Ctrl-Alt-F2..F7 can leave the kiosk)\n'
  else
    printf 'vtswitch   no polkit — Ctrl-Alt-Fn will be denied and the kiosk traps the console\n' >&2
    printf '           fix: sudo apt install -y polkitd\n' >&2
    rc=1
  fi

  printf 'kiosk      %s\n' "$(sbg_kiosk_argv "$BOARD" "$FONT" "$FONTSIZE" "$INTERVAL" "$PROBE" "$CELL" | tr '\n' ' ')"
  return "$rc"
}

if [ "$MODE" = check ]; then
  sbg_check
  exit $?
fi

# ── install / uninstall ───────────────────────────────────────────────────────

if [ "$MODE" = install ] || [ "$MODE" = uninstall ]; then
  [ "$(id -u)" = 0 ] || { printf 'need root for --%s\n' "$MODE" >&2; exit 1; }
  RUN_USER="${STATUSBOARD_USER:-${SUDO_USER:-me}}"

  if [ "$MODE" = uninstall ]; then
    rm -f "$PROFILE_HOOK" "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null
    systemctl daemon-reload
    pkill -u "$RUN_USER" -x cage 2>/dev/null
    systemctl restart "$GETTY_UNIT" 2>/dev/null
    printf 'removed the kiosk; %s is a normal login prompt again\n' "$GUI_TTY"
    printf 'to put the TEXT board back on %s: sudo bash %s --install\n' "$GUI_TTY" "$BOARD"
    exit 0
  fi

  sbg_check || { printf '\nrefusing to install with the above unmet.\n' >&2; exit 1; }

  # The text board holds tty1 with Conflicts=getty@tty1, so the getty cannot start
  # while it runs. Stop AND disable: leaving it enabled means the next boot has two
  # units racing for the same VT.
  WAS_TEXT=0
  if systemctl is-enabled --quiet "$TEXT_SERVICE" 2>/dev/null; then WAS_TEXT=1; fi
  systemctl disable --now "$TEXT_SERVICE" 2>/dev/null
  # And clear its failed state. The text board holds tty1 with Conflicts=getty@tty1,
  # so handing that VT to the getty leaves it FAILED — which the board then reports
  # forever as "units 1 failed", on the very display whose job is to make a failed
  # unit mean something. A permanent false alarm is worse than no alarm.
  systemctl reset-failed "$TEXT_SERVICE" 2>/dev/null

  mkdir -p "$DROPIN_DIR"
  sbg_dropin_text "$RUN_USER" > "$DROPIN"
  sbg_hook_text "$SELF" "$GUI_TTY" > "$PROFILE_HOOK"
  chmod 0644 "$DROPIN" "$PROFILE_HOOK"
  systemctl daemon-reload

  # Prove it before declaring success, and roll the whole thing back if cage never
  # appears — an installed-but-broken kiosk is a dead physical console, and this
  # box has no other screen.
  systemctl enable "$GETTY_UNIT" >/dev/null 2>&1
  systemctl restart "$GETTY_UNIT" 2>/dev/null
  ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -u "$RUN_USER" -x cage >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done

  if [ "$ok" = 0 ]; then
    printf 'cage never started — rolling back so the console stays usable:\n' >&2
    journalctl -u "$GETTY_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' >&2
    rm -f "$PROFILE_HOOK" "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null
    systemctl daemon-reload
    if [ "$WAS_TEXT" = 1 ]; then
      systemctl enable --now "$TEXT_SERVICE" 2>/dev/null
      printf '\nrestored %s on %s. Nothing else changed.\n' "$TEXT_SERVICE" "$GUI_TTY" >&2
    else
      systemctl restart "$GETTY_UNIT" 2>/dev/null
      printf '\nrestored the login prompt on %s. Nothing else changed.\n' "$GUI_TTY" >&2
    fi
    exit 1
  fi

  printf 'kiosk is up on %s: cage -> foot -> statusboard.sh\n' "$GUI_TTY"
  printf 'font %s at %spt; charts use the real U+%s..U+%s ramp now\n' \
    "$FONT" "$FONTSIZE" "$RAMP_LO" "$RAMP_HI"
  printf 'Ctrl-Alt-F2 still reaches a console login (cage -s).\n'
  printf 'to undo: sudo bash %s --uninstall\n' "$SELF"
  exit 0
fi

# ── run ───────────────────────────────────────────────────────────────────────
# The mode the profile.d hook invokes. Fails loudly rather than silently: the hook
# does not exec, so whatever is printed here stays on screen above a shell prompt.

# Once a compositor owns tty1 there is no /dev/vcs1 to dump, so the screen stops
# being readable over SSH — and the screen is where cage's errors go. Mirror stderr
# into a file so a failure is diagnosable from the network instead of needing
# someone in the chair. Truncated per start, not appended: one session's worth is
# what you want, and an append-only log on an unattended box has no rotation story.
LOG="${STATUSBOARD_GUI_LOG:-/var/tmp/statusboard-gui.log}"
if : > "$LOG" 2>/dev/null; then
  exec 2> >(tee -a "$LOG" >&2)
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  printf 'XDG_RUNTIME_DIR is unset — cage has nowhere for its Wayland socket.\n' >&2
  printf 'This mode expects a real logind session (an autologin getty provides one).\n' >&2
  exit 1
fi
[ -f "$BOARD" ] || { printf 'no board at %s\n' "$BOARD" >&2; exit 1; }

mapfile -t KIOSK < <(sbg_kiosk_argv "$BOARD" "$FONT" "$FONTSIZE" "$INTERVAL" "$PROBE" "$CELL")
exec "${KIOSK[@]}"
