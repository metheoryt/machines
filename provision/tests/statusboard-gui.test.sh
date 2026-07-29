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

# ── sbg_kiosk_argv ────────────────────────────────────────────────────────────
ARGV="$(sbg_kiosk_argv /tmp/board.sh 'JetBrains Mono' 20 1 10 60)"
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

# ── Help ──────────────────────────────────────────────────────────────────────
OUT="$(bash "$GUI" --help 2>&1)"; eq "$?" '0' 'help: exits 0'
has "$OUT" '--install' 'help: documents --install'
has "$OUT" '--uninstall' 'help: documents --uninstall'
has "$OUT" '--check' 'help: documents --check'
OUT="$(bash "$GUI" --nonsense 2>&1)"; eq "$?" '2' 'args: an unknown flag exits 2'

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
