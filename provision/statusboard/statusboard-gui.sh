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
CELL="${STATUSBOARD_GUI_CELL:-60}"

# ── the btop strip, and why tmux is under it ──────────────────────────────────
#
# The board answers "is anything wrong". btop answers "what is this machine doing
# right now" — per-core load, per-core temperature, CPU frequency, none of which
# the board carries (it has load average only, and no thermals at all).
#
# It has to be a STACK. Not side-by-side, not rotating pages. btop computes its
# own minimum terminal size from the boxes it is showing and refuses to draw below
# it; measured on this box (2026-07-29):
#
#   cpu               draws in 8 rows
#   mem               needs 36x10
#   cpu mem           needs 60x18
#   cpu mem net proc  needs 80x24   (the default, and why 80x24 is the number
#                                    everyone remembers as "btop's minimum")
#
# The board needs 25 rows and the full width for its charts. At the kiosk's
# measured 146x36 that leaves exactly one geometry that fits: board on top, a
# cpu-only btop strip beneath. Rotating full-screen windows would fit anything at
# all, and is worse for a wall display — the thing you looked up for is on the
# other page half the time.
#
# tmux earns its place twice. It is the only splitter available (foot has no
# panes), and it makes the physical display READABLE OVER SSH: under cage there is
# no /dev/vcs1 to dump, so until now the only remote view of that screen was the
# stderr tee in --run mode. `tmux -L board attach` is the screen itself.
BTOP="${STATUSBOARD_GUI_BTOP:-1}"
BTOP_ROWS="${STATUSBOARD_GUI_BTOP_ROWS:-8}"
BTOP_BOXES="${STATUSBOARD_GUI_BTOP_BOXES:-cpu}"
# Both minimums are measured, not guessed. 26 is the board's 25 rows of content
# plus one spare, so gaining a mount does not clip `units all ok` — the alarm
# line, and the worst line on the board to lose silently.
BOARD_MIN_ROWS="${STATUSBOARD_GUI_BOARD_MIN_ROWS:-26}"
BTOP_MIN_ROWS=8
# Its OWN tmux server. `-f` is read only when a server STARTS, so sharing the
# default socket with an already-running session would silently discard this
# config — and `tmux kill-server` in that session would take the display with it.
TMUX_SOCKET="${STATUSBOARD_GUI_TMUX_SOCKET:-board}"
TMUX_SESSION="${STATUSBOARD_GUI_TMUX_SESSION:-board}"
# Generated configs. Per-user and volatile on purpose: they are rewritten on every
# start, so they can never drift from the script that produced them.
KIOSK_STATE="${STATUSBOARD_GUI_STATE:-${XDG_RUNTIME_DIR:-/var/tmp}/statusboard-kiosk}"

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
    # Not for humans: this is how the kiosk re-enters itself from inside foot,
    # where the pty size is finally knowable and the split can be sized to it.
    --session) MODE=session; shift ;;
    --no-btop) BTOP=0; shift ;;
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

# sbg_board_argv <board> <interval> <probe> <cell>: the board itself, one argument
# per line so a caller can compose it into a larger argv without re-splitting.
sbg_board_argv() {
  printf '%s\n' bash "${1:-}" --interval "${2:-1}" --probe "${3:-10}" --cell "${4:-60}"
}

# sbg_session_argv <self>: re-enter this script in --session mode. That is what
# builds the tmux layout, and it has to happen inside foot because the row count
# the split is sized against does not exist until then.
sbg_session_argv() {
  printf '%s\n' bash "${1:-}" --session
}

# sbg_kiosk_argv <font> <size> <cmd>...: the kiosk command line, one argument per
# line so a test can assert on it without re-splitting a string.
#
#   cage -s   VT switching stays enabled. This is the escape hatch: without it a
#             compositor owning tty1 swallows Ctrl-Alt-F2 and the only console on
#             the box is unreachable from the box.
#   cage -d   no client-side decorations — a title bar on a kiosk is wasted rows.
#   foot -H   hold the window open after the child exits, so a board that dies
#             leaves its error on screen instead of a black rectangle. Note that
#             with tmux in the middle this no longer covers a dying BOARD — see
#             remain-on-exit in sbg_tmux_conf_text, which is what restores it.
sbg_kiosk_argv() {
  local font="${1:-}" size="${2:-16}"
  shift 2 2>/dev/null || true
  [ $# -gt 0 ] || return 1
  printf '%s\n' cage -s -d -- \
    foot -H -f "$font:size=$size" \
    -o main.pad=6x6 -o cursor.style=underline \
    -e "$@"
}

# sbg_pty_size: "<cols> <rows>" for the terminal on stdin.
#
# stty, not tput. tput answers from TERMINFO — it reports the entry's nominal size,
# or fails outright when TERM is unset or `dumb`, and either way it is not being
# asked about the window it is actually on. stty asks the kernel. The split is
# sized in rows and a wrong count here costs the strip SILENTLY, which is exactly
# what the first deploy did (2026-07-29): board full-screen, no strip, nothing
# anywhere saying why.
sbg_pty_size() {
  local sz rows cols
  sz="$(stty size 2>/dev/null)"
  rows="${sz%% *}"
  cols="${sz##* }"
  case "$rows" in '' | *[!0-9]*) rows=0 ;; esac
  case "$cols" in '' | *[!0-9]*) cols=0 ;; esac
  if [ "$rows" -eq 0 ] || [ "$cols" -eq 0 ]; then
    rows="$(tput lines 2>/dev/null)"
    cols="$(tput cols 2>/dev/null)"
    case "$rows" in '' | *[!0-9]*) rows=24 ;; esac
    case "$cols" in '' | *[!0-9]*) cols=80 ;; esac
  fi
  printf '%s %s' "$cols" "$rows"
}

# sbg_settle_size [tries] [delay]: the pty size once it has stopped changing.
#
# The size read in this script's first milliseconds is a LIE. foot creates the pty
# at a default 80x24 and resizes it only once the compositor has configured its
# surface — which happens after it has already exec'd its child. Measured on
# latitude 2026-07-29: `stty size` returned 80x24 on a 146x36 display, so the split
# arithmetic concluded there was no room for the board plus btop and dropped the
# strip. Reading the kernel instead of terminfo was necessary but not sufficient;
# the kernel was telling the truth about a pty that had not been resized yet.
#
# The WINCH trap is the fast path — the kernel signals the foreground group on
# TIOCSWINSZ, so this usually returns within one delay of foot's first configure.
# The timeout is the GUARANTEE: a terminal that never resizes (or never signals)
# still leaves with a correct answer, just later. The second loop exists because a
# compositor may configure more than once, and a size caught mid-sequence is as
# wrong as a size caught before it.
sbg_settle_size() {
  local tries="${1:-20}" delay="${2:-0.1}" i prev cur
  SBG_WINCH=0
  trap 'SBG_WINCH=1' WINCH
  for ((i = 0; i < tries; i++)); do
    [ "$SBG_WINCH" = 1 ] && break
    sleep "$delay"
  done
  trap - WINCH
  prev="$(sbg_pty_size)"
  for ((i = 0; i < tries; i++)); do
    sleep "$delay"
    cur="$(sbg_pty_size)"
    [ "$cur" = "$prev" ] && { printf '%s' "$cur"; return; }
    prev="$cur"
  done
  printf '%s' "$prev"
}

# sbg_split_rows <total> <want> [min_board] [min_btop]: how many rows the btop strip
# actually gets, or 0 meaning "do not split at all".
#
# The board is the reason the display exists, so it wins every conflict: the strip
# is trimmed to whatever is left above min_board, and DROPPED rather than shrunk
# past the point where btop would refuse to draw — a "Terminal size too small" box
# on the wall is worse than no strip.
sbg_split_rows() {
  local total="${1:-0}" want="${2:-0}" minb="${3:-${BOARD_MIN_ROWS:-26}}" \
    mint="${4:-${BTOP_MIN_ROWS:-8}}" avail
  case "$total" in '' | *[!0-9]*) printf 0; return ;; esac
  case "$want" in '' | *[!0-9]*) printf 0; return ;; esac
  case "$minb" in '' | *[!0-9]*) minb=26 ;; esac
  case "$mint" in '' | *[!0-9]*) mint=8 ;; esac
  # One row is spent on the border tmux draws between the two panes.
  avail=$((total - 1))
  [ "$avail" -gt 0 ] || { printf 0; return; }
  [ $((avail - want)) -ge "$minb" ] || want=$((avail - minb))
  [ "$want" -ge "$mint" ] || { printf 0; return; }
  printf '%s' "$want"
}

# sbg_tmux_term: which terminfo entry to hand tmux.
#
# `default-terminal "tmux-256color"` makes tmux REFUSE TO START when that entry is
# absent ("missing or unsuitable terminal") — and here that would mean a black
# screen rather than a degraded one, because tmux is upstream of the board. The
# entry ships in ncurses-term, which the status-board tier installs; this exists so
# a box that somehow lacks it loses colour depth instead of the display.
sbg_tmux_term() {
  if infocmp tmux-256color >/dev/null 2>&1; then
    printf 'tmux-256color'
  else
    printf 'screen-256color'
  fi
}

# sbg_tmux_conf_text [term]: the kiosk's tmux config. Every line is load-bearing.
#
#   terminal-features ,foot*:RGB
#           tmux forwards COLORTERM but will not pass 24-bit escapes through
#           without this — which is exactly why the board asks tmux directly via
#           #{client_termfeatures} instead of trusting COLORTERM. Omit it and the
#           charts silently drop to the 16-colour thresholds inside the kiosk.
#   status off
#           the board already paints a hostname and a clock on its first row. A
#           status bar would cost a row to repeat them.
#   NOT window-size
#           it belongs here and cannot go here. tmux 3.5a defaults it to `latest`,
#           so attaching from an 80x24 SSH window reflows the PHYSICAL display to
#           80x24 and kills the chart column — but `set -g window-size manual` in a
#           config read at server start CRASHES the server: measured on latitude
#           2026-07-29, `tmux -f <conf> new-session -d` reports "server exited
#           unexpectedly" and the server log ends mid-spawn_window with zero
#           sessions. --session therefore sets it as a command, after the first
#           session exists, where it is harmless and does the same job.
#   remain-on-exit on
#           restores what `foot -H` used to do by itself. With tmux in between, a
#           board that dies no longer ends foot's child: btop holds the server up,
#           -H never fires, and the failure would be invisible on the very display
#           whose job is to report failures.
sbg_tmux_conf_text() {
  local term="${1:-tmux-256color}"
  cat <<CONF
# Generated by statusboard-gui.sh — rewritten on every start. Do not edit.
set -g default-terminal "$term"
set -as terminal-features ",foot*:RGB"
set -g status off
set -g remain-on-exit on
set -g mouse off
set -g escape-time 0
set -g history-limit 500
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=colour238"
CONF
}

# sbg_btop_conf_text <boxes>: btop's config for the strip.
#
# btop has no --config flag, so choosing its boxes means a config file and a
# private XDG_CONFIG_HOME pointed at it. Private because btop REWRITES its config
# on exit: sharing the user's would let the kiosk quietly change what plain `btop`
# does in an interactive shell.
sbg_btop_conf_text() {
  local boxes="${1:-cpu}"
  cat <<CONF
# Generated by statusboard-gui.sh — rewritten on every start. Do not edit.
shown_boxes = "$boxes"
update_ms = 2000
# The strip sits on foot's background rather than painting a slab of its own.
theme_background = False
truecolor = True
vim_keys = False
CONF
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

  # tmux and btop are the LAYOUT, not the board. A missing one costs the strip; it
  # must never cost the display, so neither is a hard failure — --session falls
  # back to the board alone, full screen, exactly as it ran before the strip
  # existed.
  if [ "$BTOP" != 1 ]; then
    printf 'strip      off (STATUSBOARD_GUI_BTOP=0) — board alone, full screen\n'
  else
    missing="$(sbg_missing_deps tmux btop)"
    if [ -n "$missing" ]; then
      printf 'strip      missing %s — will fall back to the board alone, full screen\n' "$missing"
      printf '           fix: sudo apt install -y tmux btop\n'
    else
      printf 'strip      ok (tmux, btop) — %s rows of [%s] under the board\n' \
        "$BTOP_ROWS" "$BTOP_BOXES"
      printf '           board keeps the rest, at least %s rows; below that the strip is dropped\n' \
        "$BOARD_MIN_ROWS"
    fi
  fi

  local -a inner=()
  mapfile -t inner < <(sbg_session_argv "$SELF")
  printf 'kiosk      %s\n' "$(sbg_kiosk_argv "$FONT" "$FONTSIZE" "${inner[@]}" | tr '\n' ' ')"
  printf 'cadence    interval %ss, probe %ss, cell %ss\n' "$INTERVAL" "$PROBE" "$CELL"
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

  # Killing cage is not enough. The kiosk's tmux server is DETACHED from its
  # client, so losing foot leaves the board and btop running forever on an
  # invisible pty — and on --install it would also mean the freshly restarted foot
  # re-attaches to a session still running the OLD board. As root the socket has to
  # be reached as the user who owns it; /tmp/tmux-0 is not /tmp/tmux-1000.
  sbg_kill_tmux() {
    local user="${1:-me}" sock="${2:-board}"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$user" -- tmux -L "$sock" kill-server 2>/dev/null
    else
      su -s /bin/sh -c "tmux -L '$sock' kill-server" "$user" 2>/dev/null
    fi
    return 0
  }

  if [ "$MODE" = uninstall ]; then
    rm -f "$PROFILE_HOOK" "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null
    systemctl daemon-reload
    sbg_kill_tmux "$RUN_USER" "$TMUX_SOCKET"
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
  # Before the getty restarts, so the new foot builds a fresh session instead of
  # re-attaching to one running the board from before this install.
  sbg_kill_tmux "$RUN_USER" "$TMUX_SOCKET"

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

  printf 'kiosk is up on %s: cage -> foot -> tmux -> statusboard.sh + btop\n' "$GUI_TTY"
  printf 'font %s at %spt; charts use the real U+%s..U+%s ramp now\n' \
    "$FONT" "$FONTSIZE" "$RAMP_LO" "$RAMP_HI"
  printf 'Ctrl-Alt-F2 still reaches a console login (cage -s).\n'
  printf 'to see that screen over ssh: tmux -L %s attach -t %s\n' "$TMUX_SOCKET" "$TMUX_SESSION"
  printf 'why the strip is or is not there: cat %s.session\n' "${KIOSK_STATE%/}"
  printf 'to undo: sudo bash %s --uninstall\n' "$SELF"
  exit 0
fi

# ── session ───────────────────────────────────────────────────────────────────
# Runs INSIDE foot. This is the first point in the chain where the terminal's real
# row count exists, and the split has to be sized against real rows rather than a
# guess — get it wrong by one and the board's bottom line, the one that says
# whether any unit failed, is the line that falls off.

if [ "$MODE" = session ]; then
  [ -f "$BOARD" ] || { printf 'no board at %s\n' "$BOARD" >&2; exit 1; }
  SESS_RAW="$(sbg_pty_size)"
  read -r SESS_COLS SESS_ROWS <<< "$(sbg_settle_size)"

  mapfile -t BOARD_CMD < <(sbg_board_argv "$BOARD" "$INTERVAL" "$PROBE" "$CELL")

  # Every fallback below is silent by construction: this mode's stderr goes to the
  # pty, and the board then paints over it within a second. So the decision gets
  # WRITTEN DOWN. Cheap, and it is the difference between "the strip is missing"
  # and "the strip is missing because it measured 24 rows".
  SESS_NOTE="${KIOSK_STATE%/}.session"
  sbg_note() { printf '%s\n' "$*" >> "$SESS_NOTE" 2>/dev/null || true; }
  : > "$SESS_NOTE" 2>/dev/null
  # Both numbers, because the gap between them is the whole story if this ever goes
  # wrong again: "raw 80x24, settled 146x36" says foot resized late and we waited.
  sbg_note "pty ${SESS_COLS}x${SESS_ROWS} (raw at exec ${SESS_RAW// /x})"

  STRIP=0
  MISSING="$(sbg_missing_deps tmux btop)"
  if [ "$BTOP" != 1 ]; then
    sbg_note 'strip off: STATUSBOARD_GUI_BTOP is not 1'
  elif [ -n "$MISSING" ]; then
    sbg_note "strip off: missing $MISSING"
  else
    STRIP="$(sbg_split_rows "$SESS_ROWS" "$BTOP_ROWS")"
    [ "$STRIP" -gt 0 ] ||
      sbg_note "strip off: ${SESS_ROWS} rows cannot hold ${BOARD_MIN_ROWS} for the board plus ${BTOP_MIN_ROWS} for btop"
  fi
  # No tmux, no btop, or no room for a strip that btop would agree to draw: the
  # board takes the whole terminal, exactly as it did before any of this existed.
  # The board is the point; the strip is a bonus, and a bonus must not be able to
  # break the thing it decorates.
  [ "$STRIP" -gt 0 ] || exec "${BOARD_CMD[@]}"
  sbg_note "strip ${STRIP} rows of [${BTOP_BOXES}], board keeps $((SESS_ROWS - STRIP - 1))"

  mkdir -p "$KIOSK_STATE/btop" || {
    sbg_note "strip off: cannot create $KIOSK_STATE"
    exec "${BOARD_CMD[@]}"
  }
  sbg_tmux_conf_text "$(sbg_tmux_term)" > "$KIOSK_STATE/tmux.conf"
  sbg_btop_conf_text "$BTOP_BOXES" > "$KIOSK_STATE/btop/btop.conf"

  TM=(tmux -L "$TMUX_SOCKET" -f "$KIOSK_STATE/tmux.conf")
  # %q, not bare words: tmux joins a multi-word command back into one string and
  # re-splits it itself, so anything with a space in it needs to survive that.
  BOARD_LINE="$(printf '%q ' "${BOARD_CMD[@]}")"
  BTOP_LINE="$(printf '%q ' env "XDG_CONFIG_HOME=$KIOSK_STATE" btop)"

  # An existing session means FOOT restarted, not that the box did. Re-attaching
  # keeps the board's chart history, which lives in the running process and nowhere
  # else — otherwise a compositor hiccup throws away hours of it.
  #
  # But existence is not liveness, and conflating them wedges the display. The
  # remain-on-exit that keeps a crashed board's error on screen also means a dead
  # board leaves a DEAD PANE rather than an ended session: has-session says yes
  # forever, `foot -H` cannot help because tmux is still alive, and the getty will
  # not respawn anything because the session is there. Restarting the box would not
  # even fix it. Verified on latitude 2026-07-29 (a killed pane reports
  # #{pane_dead}=1 indefinitely while has-session still succeeds). So: ask about the
  # BOARD PANE, and rebuild from scratch when it is a corpse.
  REUSE=0
  if "${TM[@]}" has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if [ "$("${TM[@]}" display -p -t "$TMUX_SESSION:0.0" '#{pane_dead}' 2>/dev/null)" = 1 ]; then
      # The rebuild is about to discard the one thing that dead pane was holding: the
      # error the board died with. `-S -` and not the default range, because it lands
      # in the scrollback — a dying pane scrolls, so a default capture comes back
      # blank and looks like there was never anything to read (2026-07-29).
      {
        printf 'board pane died with status %s\n' \
          "$("${TM[@]}" display -p -t "$TMUX_SESSION:0.0" '#{pane_dead_status}' 2>/dev/null)"
        "${TM[@]}" capture-pane -p -S - -t "$TMUX_SESSION:0.0" 2>/dev/null |
          grep -v '^[[:space:]]*$' | tail -25
      } > "${KIOSK_STATE%/}.crash" 2>/dev/null
      sbg_note "session existed but its board pane was dead — rebuilding"
      sbg_note "  what it died of: ${KIOSK_STATE%/}.crash"
      "${TM[@]}" kill-session -t "$TMUX_SESSION" 2>/dev/null
    else
      REUSE=1
      sbg_note 'reusing the running session — chart history preserved'
      # If only the STRIP died, bring it back. A btop that fell over should cost the
      # strip until the next kiosk restart, not permanently.
      if [ "$("${TM[@]}" display -p -t "$TMUX_SESSION:0.1" '#{pane_dead}' 2>/dev/null)" = 1 ]; then
        "${TM[@]}" respawn-pane -k -t "$TMUX_SESSION:0.1" "$BTOP_LINE" 2>>"$SESS_NOTE" &&
          sbg_note 'strip pane was dead — respawned it'
      fi
    fi
  fi

  if [ "$REUSE" = 0 ]; then
    # tmux is UPSTREAM of the board here, so a tmux that will not start is a black
    # screen, not a missing strip. Never let that be the outcome.
    if ! "${TM[@]}" new-session -d -s "$TMUX_SESSION" \
      -x "$SESS_COLS" -y "$SESS_ROWS" "$BOARD_LINE" 2>>"$SESS_NOTE"; then
      sbg_note 'strip off: tmux would not start a session'
      exec "${BOARD_CMD[@]}"
    fi
    # Now, and not in the config file: read at server start this option crashes
    # tmux 3.5a outright (see sbg_tmux_conf_text). Set here it pins the geometry, so
    # attaching from a small SSH window can no longer reflow the physical display.
    "${TM[@]}" set -g window-size manual 2>>"$SESS_NOTE" ||
      sbg_note 'window-size stayed automatic; a small ssh attach can reflow the display'
    "${TM[@]}" split-window -t "$TMUX_SESSION" -v -l "$STRIP" "$BTOP_LINE" 2>>"$SESS_NOTE" ||
      sbg_note 'split failed; the board has the whole session'
    # Focus back on the board. btop quits on `q`; the board reads no input at all,
    # so it is the safe place for a stray keypress at the physical keyboard to land.
    "${TM[@]}" select-pane -t "$TMUX_SESSION:0.0" 2>/dev/null
  fi
  # window-size is manual, so this is the only thing that ever sets the geometry —
  # which is the point: a later `tmux attach` from a small SSH window cannot reflow
  # the physical display out from under itself.
  "${TM[@]}" resize-window -t "$TMUX_SESSION" -x "$SESS_COLS" -y "$SESS_ROWS" 2>/dev/null
  exec "${TM[@]}" attach -t "$TMUX_SESSION"
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

mapfile -t INNER < <(sbg_session_argv "$SELF")
mapfile -t KIOSK < <(sbg_kiosk_argv "$FONT" "$FONTSIZE" "${INNER[@]}")
exec "${KIOSK[@]}"
