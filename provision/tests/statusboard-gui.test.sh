#!/usr/bin/env bash
# provision/tests/statusboard-gui.test.sh — the physical-display kiosk.
#
# provision/statusboard/statusboard-gui.sh replaces the Linux VT on latitude's
# screen with cage + foot, because a psf console font cannot draw the board's
# U+2581..U+2588 chart ramp and the ASCII fallback reads as repeated characters
# (2026-07-29).
#
# Nothing here needs a compositor, a seat, or root: every decision the installer
# makes is factored into a pure function that renders text, and this suite asserts
# on that text. The two invariants worth having a test for at all are the ones
# whose absence is unrecoverable FROM THE BOX — cage's -s (without it a compositor
# owning tty1 swallows Ctrl-Alt-F2 and the only console is unreachable) and the
# hook's refusal to exec (with exec, a cage that fails ends the session, respawns
# the getty, and spins). Both have already been paid for once in this repo's
# history by a console that could only be fixed over SSH.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUI="$REPO/provision/statusboard/statusboard-gui.sh"
BOARD_SH="$REPO/provision/statusboard/statusboard.sh"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }
line() { if printf '%s\n' "$1" | grep -qxF -- "$2"; then pass "$3"; else fail "$3 (no whole line '$2')"; fi; }

[ -f "$GUI" ] || { echo "FAIL: $GUI missing" >&2; exit 1; }

bash -n "$GUI"; eq "$?" '0' 'syntax is valid'

# shellcheck source=provision/statusboard/statusboard-gui.sh
STATUSBOARD_GUI_LIB_ONLY=1 source "$GUI"

# ── sbg_missing_deps ──────────────────────────────────────────────────────────
eq "$(sbg_missing_deps bash sed)" '' 'missing_deps: nothing missing when all present'
has "$(sbg_missing_deps bash sbg-definitely-not-a-command)" 'sbg-definitely-not-a-command' \
  'missing_deps: names an absent command'
hasnt "$(sbg_missing_deps bash sbg-definitely-not-a-command)" 'bash' \
  'missing_deps: does not name a present one'
# All of them, not just the first: a box missing both cage and foot should be told
# once, not made to re-run the installer per package.
eq "$(sbg_missing_deps sbg-nope-a sbg-nope-b)" 'sbg-nope-a sbg-nope-b' \
  'missing_deps: reports every absent command'

# ── sbg_font_has_ramp ─────────────────────────────────────────────────────────
sbg_font_has_ramp ''; eq "$?" '1' 'font_has_ramp: empty family is not a match'
if command -v fc-list >/dev/null 2>&1; then
  sbg_font_has_ramp 'Sbg No Such Font At All'
  eq "$?" '1' 'font_has_ramp: a font that is not installed is not a match'
  # Whole-field matching: fc-list prints comma-joined family aliases, so a
  # substring match would let "JetBrains Mono" be satisfied by a stylistic variant
  # like "JetBrains Mono Thin" whose coverage was never checked.
  grep -q 'grep -qxF' "$GUI"; eq "$?" '0' 'font_has_ramp: matches a whole family field'
  grep -q "tr ',' " "$GUI"; eq "$?" '0' 'font_has_ramp: splits comma-joined aliases first'
else
  printf '  SKIP font_has_ramp live queries (no fc-list on this host)\n'
fi
# Coverage is queried, never assumed from the name — the VT path degraded precisely
# because a plausibly-named font lacked the glyphs.
grep -q ':charset=' "$GUI"; eq "$?" '0' 'font_has_ramp: asks fontconfig by charset'

# ── sbg_board_argv / sbg_session_argv ────────────────────────────────────────
BOARD_ARGV="$(sbg_board_argv /tmp/board.sh 2 20 120)"
line "$BOARD_ARGV" 'bash' 'board_argv: runs the board through bash'
line "$BOARD_ARGV" '/tmp/board.sh' 'board_argv: passes the board path through'
line "$BOARD_ARGV" '2' 'board_argv: forwards the interval value'
line "$BOARD_ARGV" '20' 'board_argv: forwards the probe value'
line "$BOARD_ARGV" '120' 'board_argv: forwards the cell duration'
eq "$(printf '%s\n' "$BOARD_ARGV" | grep -c .)" '8' 'board_argv: one argument per line'

SESSION_ARGV="$(sbg_session_argv /opt/gui.sh)"
line "$SESSION_ARGV" '--session' 'session_argv: re-enters the script in session mode'
line "$SESSION_ARGV" '/opt/gui.sh' 'session_argv: re-enters THIS script, by path'
eq "$(printf '%s\n' "$SESSION_ARGV" | grep -c .)" '3' 'session_argv: one argument per line'

# ── sbg_kiosk_argv ────────────────────────────────────────────────────────────
# The inner command is now an argument rather than baked in: the kiosk runs
# `--session` (which builds the tmux layout from inside foot, where the row count
# finally exists), while a box without tmux or btop runs the board directly. Both
# compositions have to survive the one-argument-per-line contract, so both are
# asserted — the font family contains a space, and a caller that re-split a flat
# string would hand foot "Mono:size=20" as a command.
ARGV="$(sbg_kiosk_argv 'JetBrains Mono' 20 bash /tmp/board.sh --interval 1 --probe 10 --cell 60)"
line "$ARGV" 'cage' 'kiosk: cage is the compositor'
line "$ARGV" 'foot' 'kiosk: foot is the terminal'
line "$ARGV" 'bash' 'kiosk: the board is run through bash'
line "$ARGV" '/tmp/board.sh' 'kiosk: passes the board path through'
line "$ARGV" 'JetBrains Mono:size=20' 'kiosk: font family and size reach foot as one argument'
line "$ARGV" '--interval' 'kiosk: forwards --interval'
line "$ARGV" '1' 'kiosk: forwards the interval value'
line "$ARGV" '--probe' 'kiosk: forwards --probe'
line "$ARGV" '10' 'kiosk: forwards the probe value'
line "$ARGV" '--' 'kiosk: separates cage options from the application'

# THE escape hatch. A compositor holding tty1 without -s means Ctrl-Alt-F2 does
# nothing, and the console on a box whose console is its only screen becomes
# reachable only over the network. Assert the flag, and assert it as a whole
# argument so a future `-sd` merge or a rename cannot satisfy it accidentally.
line "$ARGV" '-s' 'kiosk: cage -s keeps VT switching (Ctrl-Alt-F2 escape hatch)'
line "$ARGV" '-H' 'kiosk: foot -H holds the window so a crashed board leaves its error visible'

# The OTHER half of that escape hatch, and the half that fails silently: cage asks
# logind's Seat.SwitchTo, which is polkit-gated, and a minimal Debian ships no
# polkit — so logind denies it to everyone but root and the keys do nothing.
# Measured on latitude 2026-07-29 (cage logged "Could not switch session:
# Permission denied" on every press). --check must FAIL on this, not mention it.
GUI_SRC="$(cat "$GUI")"
has "$GUI_SRC" 'sbg_have_polkit' 'check: probes for a polkit authority'
CHECK_BODY="$(awk '/^sbg_check\(\)/,/^}/' "$GUI")"
has "$CHECK_BODY" 'sbg_have_polkit' 'check: the polkit probe runs inside sbg_check'
# Anchored `fi`, not a bare /fi/ — the branch's own "fix:" hint contains those two
# letters and an unanchored range would end one line early, right before the rc=1.
polkit_rc="$(printf '%s\n' "$CHECK_BODY" | awk '/if sbg_have_polkit/,/^ *fi$/' | grep -c 'rc=1')"
eq "$polkit_rc" '1' 'check: a missing polkit makes --check fail, not warn'
# Presence, never polkit's own verdict: polkit answers per CALLER session, so asking
# from an SSH shell would report "denied" on a healthy box.
hasnt "$CHECK_BODY" 'pkcheck --action' 'check: does not ask polkit to decide for the wrong session'

# Taking tty1 from the text board leaves that unit FAILED (it holds the VT with
# Conflicts=getty@tty1), and the kiosk would then report "units 1 failed" forever —
# a permanent false alarm on the display whose job is to make that line mean
# something. Observed on latitude 2026-07-29.
has "$GUI_SRC" 'systemctl reset-failed "$TEXT_SERVICE"' 'install: clears the text board failed state'
dis_at="$(grep -n 'systemctl disable --now "\$TEXT_SERVICE"' "$GUI" | head -1 | cut -d: -f1)"
rst_at="$(grep -n 'systemctl reset-failed "\$TEXT_SERVICE"' "$GUI" | head -1 | cut -d: -f1)"
[ -n "$dis_at" ] && [ -n "$rst_at" ] && [ "$rst_at" -gt "$dis_at" ] \
  && pass 'install: resets the failed state AFTER disabling, never before' \
  || fail 'install: reset-failed must follow the disable'

# One argument per line is the contract: the font family contains a space, so a
# caller that re-split a flat string would pass "Mono:size=20" as a command.
eq "$(printf '%s\n' "$ARGV" | grep -c .)" '21' 'kiosk: argv is one argument per line'
line "$ARGV" '--cell' 'kiosk: forwards --cell'
line "$ARGV" '60' 'kiosk: forwards the cell duration'

# The composition the kiosk actually uses.
KIOSK_SESSION_ARGV="$(sbg_kiosk_argv 'JetBrains Mono' 16 bash /opt/gui.sh --session)"
line "$KIOSK_SESSION_ARGV" '--session' 'kiosk: composes with the session command'
eq "$(printf '%s\n' "$KIOSK_SESSION_ARGV" | grep -c .)" '16' \
  'kiosk: argv is one argument per line with the session command too'
# An inner command is mandatory. Without the guard, `-e` would be emitted with
# nothing after it and foot would open an interactive shell on the wall display.
sbg_kiosk_argv 'JetBrains Mono' 16 >/dev/null 2>&1
eq "$?" '1' 'kiosk: refuses to build an argv with no command to run'

# ── sbg_pty_size ──────────────────────────────────────────────────────────────
# The size the split is computed from. It must come from the KERNEL, not terminfo:
# tput answers from the terminfo entry (nominal 24x80) and fails outright when TERM
# is unset or `dumb`, so the first deploy measured 24 rows on a 36-row display and
# dropped the strip with nothing logged (2026-07-29).
grep -q 'stty size' "$GUI"; eq "$?" '0' 'pty_size: asks the kernel via stty'
PTY_BODY="$(awk '/^sbg_pty_size\(\)/,/^}/' "$GUI")"
stty_at="$(printf '%s\n' "$PTY_BODY" | grep -n 'stty size' | head -1 | cut -d: -f1)"
tput_at="$(printf '%s\n' "$PTY_BODY" | grep -n 'tput lines' | head -1 | cut -d: -f1)"
[ -n "$stty_at" ] && [ -n "$tput_at" ] && [ "$stty_at" -lt "$tput_at" ] \
  && pass 'pty_size: stty first, tput only as a fallback' \
  || fail "pty_size: stty($stty_at) must be tried before tput($tput_at)"
# Two numbers, always, whatever the terminal does — the caller feeds them straight
# into arithmetic under `set -u`.
SZ="$(sbg_pty_size < /dev/null)"
eq "$(printf '%s\n' "$SZ" | wc -w | tr -d ' ')" '2' 'pty_size: always yields two fields'
case "$SZ" in
  *[!0-9\ ]*) fail "pty_size: both fields are numeric (got '$SZ')" ;;
  *) pass 'pty_size: both fields are numeric even with no tty at all' ;;
esac

# ── sbg_settle_size ───────────────────────────────────────────────────────────
# Reading the kernel was necessary but not sufficient. foot creates the pty at a
# default 80x24 and resizes it only after the compositor configures its surface,
# which is AFTER it has exec'd its child — so on latitude the honest kernel answer
# was 80x24 for a 146x36 display, and the split was dropped for lack of rows
# (2026-07-29). The size has to be waited for, not read.
SETTLE_BODY="$(awk '/^sbg_settle_size\(\)/,/^}/' "$GUI")"
has "$SETTLE_BODY" 'WINCH' 'settle_size: waits for the resize signal, not a fixed guess'
has "$SETTLE_BODY" 'trap - WINCH' 'settle_size: puts the handler back when done'
# The signal is the fast path; the loop bound is the guarantee. A terminal that
# never resizes must still leave with the right answer, just later.
has "$SETTLE_BODY" 'tries' 'settle_size: is bounded, so a terminal that never signals still returns'
# Two agreeing samples, because a compositor may configure more than once and a
# size caught mid-sequence is as wrong as one caught before it.
has "$SETTLE_BODY" '[ "$cur" = "$prev" ]' 'settle_size: requires the size to stop moving'
# Fast when there is nothing to wait for: no tty, so stty fails and both loops fall
# straight through to the terminfo fallback.
SETTLED="$(sbg_settle_size 2 0.01 < /dev/null)"
eq "$(printf '%s\n' "$SETTLED" | wc -w | tr -d ' ')" '2' 'settle_size: still yields two fields with no tty'
case "$SETTLED" in
  *[!0-9\ ]*) fail "settle_size: both fields numeric (got '$SETTLED')" ;;
  *) pass 'settle_size: both fields are numeric' ;;
esac

# ── sbg_split_rows ────────────────────────────────────────────────────────────
# The row arithmetic for the btop strip. Both bounds are measured, not guessed:
# btop refuses to draw a cpu-only box below 8 rows, and the board needs 25 rows of
# content (measured on latitude 2026-07-29), so 26 leaves one spare for a mount
# appearing rather than clipping `units all ok` — the alarm line.
eq "$(sbg_split_rows 36 8)" '8' 'split_rows: the kiosk geometry fits the requested strip'
eq "$(sbg_split_rows 36 8 26 8)" '8' 'split_rows: explicit minimums agree'
# One row goes to the pane border tmux draws between them, so 36 rows is 35 of
# content. A strip that would push the board under its minimum gets trimmed…
eq "$(sbg_split_rows 36 20 26 8)" '9' 'split_rows: trims the strip rather than the board'
eq "$(sbg_split_rows 40 30 26 8)" '13' 'split_rows: trims to exactly what is left above the board'
# …and dropped outright once trimming would take it below what btop will draw. A
# "Terminal size too small" box on the wall is worse than no strip at all.
eq "$(sbg_split_rows 36 30 30 8)" '0' 'split_rows: drops the strip when the board needs almost everything'
eq "$(sbg_split_rows 30 8 26 8)" '0' 'split_rows: drops the strip on a short display'
eq "$(sbg_split_rows 24 8)" '0' 'split_rows: an 80x24 terminal gets the board alone'
eq "$(sbg_split_rows 36 4 26 8)" '0' 'split_rows: refuses a strip smaller than btop will accept'
# Never a crash and never a wrong split from junk input.
eq "$(sbg_split_rows '' 8)" '0' 'split_rows: empty total is no split'
eq "$(sbg_split_rows abc 8)" '0' 'split_rows: non-numeric total is no split'
eq "$(sbg_split_rows 36 '')" '0' 'split_rows: empty request is no split'
eq "$(sbg_split_rows 0 8)" '0' 'split_rows: a zero-row terminal is no split'
eq "$(sbg_split_rows 1 8)" '0' 'split_rows: one row is all border, no split'

# ── sbg_tmux_conf_text ────────────────────────────────────────────────────────
TCONF="$(sbg_tmux_conf_text tmux-256color)"
line "$TCONF" 'set -g default-terminal "tmux-256color"' 'tmux conf: uses the terminfo entry it is given'
has "$(sbg_tmux_conf_text screen-256color)" 'default-terminal "screen-256color"' \
  'tmux conf: the terminfo entry is a parameter, not a constant'
# tmux forwards COLORTERM but will not pass 24-bit escapes through without this,
# which is why the board asks #{client_termfeatures} instead of trusting COLORTERM.
# Without the line the charts silently drop to the 16-colour thresholds.
has "$TCONF" 'terminal-features' 'tmux conf: declares terminal features'
has "$TCONF" 'RGB' 'tmux conf: declares RGB so the chart gradient survives tmux'
has "$TCONF" 'foot' 'tmux conf: scopes the RGB feature to foot, the kiosk terminal'
# `set -as`, not `set -g`: terminal-features is a list, and replacing it wholesale
# would drop the defaults tmux ships for every other terminal.
has "$TCONF" 'set -as terminal-features' 'tmux conf: appends to terminal-features rather than replacing it'
# tmux 3.5a defaults window-size to `latest`, so attaching from an 80x24 ssh window
# would reflow the PHYSICAL display to 80x24 and kill the chart column.
line "$TCONF" 'set -g window-size manual' 'tmux conf: pins the window size against a small ssh attach'
# Restores what foot -H used to do alone. With tmux between them, a board that dies
# no longer ends foot's child — btop holds the server up and -H never fires.
line "$TCONF" 'set -g remain-on-exit on' 'tmux conf: a dead pane keeps its error on screen'
# The board already paints a hostname and a clock on row one.
line "$TCONF" 'set -g status off' 'tmux conf: no status bar to repeat the board header'

# ── sbg_btop_conf_text ────────────────────────────────────────────────────────
BCONF="$(sbg_btop_conf_text cpu)"
# btop has no --config flag, so the boxes can only be chosen through a file.
line "$BCONF" 'shown_boxes = "cpu"' 'btop conf: shows only the boxes it is given'
has "$(sbg_btop_conf_text 'cpu mem')" 'shown_boxes = "cpu mem"' \
  'btop conf: the box list is a parameter'
has "$BCONF" 'truecolor = True' 'btop conf: keeps 24-bit colour'
has "$BCONF" 'theme_background = False' 'btop conf: sits on foot background instead of its own slab'
# btop REWRITES its config on exit, so this must never be the user's own file —
# the kiosk would then be changing what plain `btop` does in an interactive shell.
has "$GUI_SRC" 'XDG_CONFIG_HOME=' 'btop conf: handed to btop through a private XDG_CONFIG_HOME'
hasnt "$GUI_SRC" '$HOME/.config/btop' 'btop conf: never writes the user own btop config'

# ── sbg_dropin_text ───────────────────────────────────────────────────────────
DROPIN="$(sbg_dropin_text me)"
has "$DROPIN" '[Service]' 'dropin: is a [Service] override'
has "$DROPIN" '--autologin me' 'dropin: autologs the named user in'
has "$DROPIN" '--noclear' 'dropin: does not clear the screen first'
has "$DROPIN" 'agetty' 'dropin: still runs agetty'
# The empty reset is not cosmetic: ExecStart is list-typed, so a drop-in without it
# APPENDS, and systemd would run two agettys on one VT.
line "$DROPIN" 'ExecStart=' 'dropin: resets ExecStart before setting it'
eq "$(printf '%s\n' "$DROPIN" | grep -c '^ExecStart=')" '2' \
  'dropin: exactly one reset plus one replacement'
has "$(sbg_dropin_text someone)" '--autologin someone' 'dropin: honours the user argument'

# No --login-options. Supplying -o hands the /bin/login argv to the caller, which
# stops agetty from adding the `-f <user>` that --autologin exists to add. Debian's
# stock `-o '-p -- \u'` therefore produces a HUNG `/bin/login -p --` with no user
# — the exact symptom of the first install attempt on latitude (2026-07-29).
hasnt "$DROPIN" '-o ' 'dropin: passes no --login-options (it would cancel the -f the autologin needs)'
hasnt "$DROPIN" '--login-options' 'dropin: nor the long form'
hasnt "$DROPIN" '\u' 'dropin: no \u substitution to get wrong'

# ── sbg_hook_text ─────────────────────────────────────────────────────────────
HOOK="$(sbg_hook_text /opt/gui.sh /dev/tty1)"
has "$HOOK" '/dev/tty1' 'hook: guards on the physical console'
has "$HOOK" 'WAYLAND_DISPLAY' 'hook: does not nest inside an existing compositor'
has "$HOOK" 'DISPLAY' 'hook: nor inside an X session'
has "$HOOK" '/opt/gui.sh' 'hook: invokes the launcher it was given'
has "$HOOK" 'tty 2>/dev/null' 'hook: reads the real tty rather than trusting an env var'

# No exec, and no bare return/exit either. /etc/profile sources this file, so an
# `exit` in the guard's false branch would kill every login shell on the box —
# including SSH. The guard is written as a positive `if` for exactly that reason.
hasnt "$HOOK" 'exec ' 'hook: does not exec (a failing cage would respawn-loop the getty)'
hasnt "$HOOK" 'exit 0' 'hook: never exits — /etc/profile sources it into every login shell'
has "$HOOK" 'if [' 'hook: guards with a positive conditional instead'
# The SSH path must be unaffected, since ~/.bashrc already auto-attaches tmux there.
eq "$(printf '%s\n' "$HOOK" | grep -c 'tty 2>/dev/null')" '1' 'hook: exactly one tty check'

# ── Installer shape ───────────────────────────────────────────────────────────
SRC="$(cat "$GUI")"
has "$SRC" 'sbg_check || ' 'install: verifies prerequisites BEFORE mutating anything'
has "$SRC" 'pgrep -u "$RUN_USER" -x cage' 'install: proves cage actually started'
has "$SRC" 'systemctl disable --now "$TEXT_SERVICE"' \
  'install: releases tty1 from the text board (it Conflicts= the getty)'
has "$SRC" 'rm -f "$PROFILE_HOOK" "$DROPIN"' 'install: rolls both artifacts back on failure'
has "$SRC" 'WAS_TEXT' 'install: remembers whether the text board was enabled, to restore it'
has "$SRC" 'need root' 'install: refuses to run unprivileged'

# The kiosk's own diagnostics. A compositor on tty1 means no /dev/vcs1, so the
# screen cannot be dumped over SSH any more and cage's stderr would be visible only
# to someone sitting at the box.
has "$SRC" 'STATUSBOARD_GUI_LOG' 'run: mirrors stderr to a log readable over SSH'
has "$SRC" 'tee -a "$LOG" >&2' 'run: keeps stderr on the screen as well as in the log'
has "$SRC" ': > "$LOG"' 'run: truncates per start rather than growing forever'

# Verify-then-commit ordering, the lesson from statusboard.sh's --install: the
# rollback must come from a check on the RUNNING state, not from an exit code that
# a systemctl restart hands back before the child has had time to fail.
gui_line() { grep -n "$1" "$GUI" | head -1 | cut -d: -f1; }
CHECK_AT="$(gui_line 'sbg_check || ')"
WRITE_AT="$(gui_line 'sbg_dropin_text "\$RUN_USER" >')"
PROVE_AT="$(gui_line 'pgrep -u "\$RUN_USER" -x cage')"
ROLL_AT="$(gui_line 'rolling back')"
if [ "$CHECK_AT" -lt "$WRITE_AT" ] && [ "$WRITE_AT" -lt "$PROVE_AT" ] && [ "$PROVE_AT" -lt "$ROLL_AT" ]; then
  pass 'install: order is check, write, prove, roll back'
else
  fail "install: order is check($CHECK_AT) write($WRITE_AT) prove($PROVE_AT) rollback($ROLL_AT)"
fi

# --uninstall must undo exactly what --install created and nothing more. It
# deliberately does NOT re-enable the text board: the user may not want it back,
# and the message says how.
has "$SRC" 'removed the kiosk' 'uninstall: reports what it removed'
has "$SRC" 'rmdir "$DROPIN_DIR"' 'uninstall: cleans up the drop-in directory'

# ── The claim that no board code changes ──────────────────────────────────────
# statusboard-gui.sh's whole premise is that the board picks the block ramp by
# itself under foot, because stdout is a pts and no /dev/ttyN matches. Assert the
# selection rather than trusting the prose: if a future refactor inverts the
# default, the kiosk silently goes back to repeated ASCII.
if [ -f "$BOARD_SH" ]; then
  RAMP="$(STATUSBOARD_LIB_ONLY=1 bash -c 'p="$1"; set --; source "$p"; SB_IS_VT=0; sb_ramp_name' _ "$BOARD_SH")"
  eq "$RAMP" 'height' 'board: a non-VT stdout selects the block ramp (what foot gives us)'
  RAMP="$(STATUSBOARD_LIB_ONLY=1 bash -c 'p="$1"; set --; source "$p"; SB_IS_VT=1; sb_ramp_name' _ "$BOARD_SH")"
  eq "$RAMP" 'ascii' 'board: a VT still degrades to ASCII (tty2..tty6 keep working)'
  GLYPHS="$(STATUSBOARD_LIB_ONLY=1 bash -c 'p="$1"; set --; source "$p"; SB_IS_VT=0; sb_ramp' _ "$BOARD_SH")"
  has "$GLYPHS" '█' 'board: the block ramp really is U+2581..U+2588'
  # The range this suite and the installer both name must be the range the board
  # draws, or the font check validates glyphs nobody uses.
  has "$GLYPHS" '▁' 'board: and starts at U+2581'
  eq "$RAMP_LO" '2581' 'installer: checks the low end of the ramp the board draws'
  eq "$RAMP_HI" '2588' 'installer: checks the high end too'
else
  printf '  SKIP board cross-checks (%s missing)\n' "$BOARD_SH"
fi

# ── The session mode's failure modes ──────────────────────────────────────────
# tmux sits UPSTREAM of the board in cage -> foot -> tmux -> board, which inverts
# the usual calculus: a missing or broken layer here is a BLACK SCREEN, not a
# missing pane. Every path out of the split has to end at the board.
SESSION_BODY="$(awk '/^if \[ "\$MODE" = session \]/,/^fi$/' "$GUI")"
has "$SESSION_BODY" 'exec "${BOARD_CMD[@]}"' 'session: falls back to the board alone'
# One for no-room/no-deps, one for mkdir, one for a tmux that will not start.
eq "$(printf '%s\n' "$SESSION_BODY" | grep -c 'exec "${BOARD_CMD\[@\]}"')" '3' \
  'session: every failure path ends at the board, not at a black screen'
has "$SESSION_BODY" 'sbg_split_rows' 'session: sizes the strip against the real row count'
has "$SESSION_BODY" 'sbg_settle_size' 'session: waits for the pty size before sizing the split'
# Every fallback here is invisible on screen — stderr goes to the pty and the board
# paints over it within a second — so the decision is written down instead. Without
# this, "the strip is missing" and "the strip measured 24 rows" look identical.
has "$SESSION_BODY" 'sbg_note' 'session: records why the strip is or is not there'
has "$SESSION_BODY" 'sbg_note "pty ' 'session: records the size it measured'
# One note per way out, so no path is silent.
note_paths="$(printf '%s\n' "$SESSION_BODY" | grep -c "sbg_note .strip off")"
[ "$note_paths" -ge 5 ] && pass 'session: every strip-off path says which one it was' \
  || fail "session: only $note_paths of the strip-off paths are recorded"
has "$SRC" 'why the strip is or is not there' 'install: says where that record lives'
# has-session before new-session: an existing session means FOOT restarted, and the
# board's chart history lives in that running process and nowhere else.
has "$SESSION_BODY" 'has-session' 'session: re-attaches instead of rebuilding, preserving chart history'
has "$SESSION_BODY" 'resize-window' 'session: sets the geometry itself, since window-size is manual'
# Its own socket. `-f` is honoured only when a server STARTS, so sharing the default
# socket with a running session would silently discard the kiosk config — and a
# `kill-server` in that session would take the display with it.
has "$SESSION_BODY" '-L "$TMUX_SOCKET"' 'session: runs on its own tmux socket, not the user server'
# %q, because tmux joins a multi-word command back into one string and re-splits it.
has "$SESSION_BODY" "printf '%q " 'session: quotes the command tmux will re-split'
# Killing cage leaves a DETACHED tmux server running the board on an invisible pty,
# and on reinstall the new foot would re-attach to a session running the old board.
has "$SRC" 'sbg_kill_tmux' 'install: kills the kiosk tmux server, not just cage'
KILL_AT="$(gui_line 'sbg_kill_tmux "\$RUN_USER" "\$TMUX_SOCKET"' | head -1)"
GETTY_AT="$(gui_line 'systemctl restart "\$GETTY_UNIT"' | head -1)"
[ -n "$KILL_AT" ] && [ -n "$GETTY_AT" ] && [ "$KILL_AT" -lt "$GETTY_AT" ] \
  && pass 'install: kills the stale session BEFORE restarting the getty' \
  || fail "install: kill($KILL_AT) must precede the getty restart($GETTY_AT)"

# ── Help ──────────────────────────────────────────────────────────────────────
OUT="$(bash "$GUI" --help 2>&1)"; eq "$?" '0' 'help: exits 0'
has "$OUT" '--install' 'help: documents --install'
has "$OUT" '--uninstall' 'help: documents --uninstall'
has "$OUT" '--check' 'help: documents --check'
OUT="$(bash "$GUI" --nonsense 2>&1)"; eq "$?" '2' 'args: an unknown flag exits 2'

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
