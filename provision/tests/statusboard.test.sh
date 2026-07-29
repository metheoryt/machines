#!/usr/bin/env bash
# provision/tests/statusboard.test.sh — the console dashboard's pure helpers.
#
# No hardware, no /sys, no network: the script exposes every formatter as a
# function of its arguments and STATUSBOARD_LIB_ONLY=1 sources them without
# starting the render loop. That is what makes a battery meter testable on a mac.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }

export STATUSBOARD_LIB_ONLY=1
# shellcheck source=provision/statusboard/statusboard.sh
source "$REPO/provision/statusboard/statusboard.sh"

# ── sb_bar ────────────────────────────────────────────────────────────────────
# Glyphs follow the ramp, so the meter and the charts degrade together on a VT
# rather than one of them painting replacement boxes.
eq "$(sb_bar 0 10)"   '[░░░░░░░░░░]' 'bar: 0% is empty'
eq "$(sb_bar 100 10)" '[██████████]' 'bar: 100% is full'
eq "$(sb_bar 50 10)"  '[█████░░░░░]' 'bar: 50% is half'
eq "$(sb_bar 5 20)"   '[█░░░░░░░░░░░░░░░░░░░]' 'bar: 5% of 20 is one cell'
eq "$(STATUSBOARD_RAMP=ascii sb_bar 50 10)" '[#####.....]' 'bar: a VT gets the ASCII fill'
eq "$(STATUSBOARD_RAMP=ascii sb_bar 0 10)"  '[..........]' 'bar: ASCII empty is dots'
# A flaky EC reporting nonsense must not corrupt the frame width.
eq "$(sb_bar 255 10)" '[██████████]' 'bar: over-range clamps to full'
eq "$(sb_bar "" 10)"  '[░░░░░░░░░░]' 'bar: empty input is 0, not an error'
eq "$(sb_bar abc 10)" '[░░░░░░░░░░]' 'bar: non-numeric input is 0, not an error'
# Width must not depend on fill — 20 cells plus the two brackets. Counted in
# CHARACTERS, not bytes: the block glyphs are three bytes each.
eq "$(printf '%s' "$(sb_bar 37 20)" | wc -m | tr -d ' ')" '22' 'bar: width is stable regardless of fill'
eq "$(printf '%s' "$(sb_bar 99 20)" | wc -m | tr -d ' ')" '22' 'bar: width identical at high fill'
eq "$(printf '%s' "$(STATUSBOARD_RAMP=ascii sb_bar 99 20)" | wc -m | tr -d ' ')" '22' \
  'bar: the ASCII fill is the same width'

# ── sb_micro_to_unit ──────────────────────────────────────────────────────────
eq "$(sb_micro_to_unit 20000000 W)" '20.0W' 'micro: 20000000µ -> 20.0'
# 3300000 not 3250000: a .x5 boundary depends on the binary representation
# (printf gives 3.2 for 3.25), and a test that encodes a rounding tie teaches
# nothing about the formatter.
eq "$(sb_micro_to_unit 3300000 A)"  '3.3A'  'micro: rounds to one decimal'
eq "$(sb_micro_to_unit "" W)"       'n/a'   'micro: empty -> n/a'
eq "$(sb_micro_to_unit junk W)"     'n/a'   'micro: non-numeric -> n/a'

# ── charge-reporting ECs (sb_uwatts / sb_uwatthours) ──────────────────────────
# latitude's Dell EC exposes no power_now/energy_* at all, only charge_* plus
# current_now/voltage_now — so without these the battery row showed "Charging"
# with no wattage and no estimate. Fixtures are that box's real readings.
eq "$(sb_uwatts 2851000 16001000)" '45618851' 'uwatts: 2.851A x 16.001V -> ~45.6W in uW'
eq "$(sb_micro_to_unit "$(sb_uwatts 2851000 16001000)" W)" '45.6W' 'uwatts: composes into a readable W figure'
eq "$(sb_uwatts "" 16001000)"   '' 'uwatts: missing current -> empty, not 0'
eq "$(sb_uwatts 2851000 "")"    '' 'uwatts: missing voltage -> empty, not 0'
eq "$(sb_uwatthours 2594000 16001000)" '41506594' 'uwatthours: 2594mAh x 16.001V -> ~41.5Wh in uWh'
eq "$(sb_micro_to_unit "$(sb_uwatthours 2594000 16001000)" Wh)" '41.5Wh' 'uwatthours: matches the 39-42Wh design capacity'
eq "$(sb_uwatthours junk 16001000)" '' 'uwatthours: non-numeric -> empty'

# End to end: a charge-only EC must produce both a wattage and an estimate.
OUT="$(sb_battery_line 14 Charging "$(sb_uwatts 2851000 16001000)" \
  "$(sb_uwatthours 381000 16001000)" "$(sb_uwatthours 2594000 16001000)")"
has "$OUT" '45.6W'   'charge-only EC: battery row shows watts'
has "$OUT" 'to full' 'charge-only EC: battery row shows time-to-full'

# ── sb_secs_to_hm ─────────────────────────────────────────────────────────────
eq "$(sb_secs_to_hm 5400)"  '1h30m' 'secs: 5400 -> 1h30m'
eq "$(sb_secs_to_hm 59)"    '0h00m' 'secs: under a minute -> 0h00m'
eq "$(sb_secs_to_hm 86400)" '24h00m' 'secs: a day does not roll over to days'
eq "$(sb_secs_to_hm "")"    'n/a'   'secs: empty -> n/a'

# ── sb_pct_colour ─────────────────────────────────────────────────────────────
# Colour is suppressed when stdout is not a tty, which is the case here, so the
# thresholds are asserted through the battery line's text instead. What matters
# is that a bad percentage never returns an error.
sb_pct_colour 5 40 15 >/dev/null && pass 'pct_colour: low battery returns cleanly'
sb_pct_colour "" 40 15 >/dev/null && pass 'pct_colour: empty input returns cleanly'

# ── sb_status_glyph ───────────────────────────────────────────────────────────
has "$(sb_status_glyph up)"      'ok'   'glyph: up -> ok'
has "$(sb_status_glyph online)"  'ok'   'glyph: online -> ok'
has "$(sb_status_glyph down)"    'down' 'glyph: down -> down'
has "$(sb_status_glyph offline)" 'down' 'glyph: offline -> down'
has "$(sb_status_glyph warn)"    'warn' 'glyph: warn -> warn'
has "$(sb_status_glyph '')"      '?'    'glyph: unknown state -> ?'
has "$(sb_status_glyph banana)"  '?'    'glyph: unrecognised state -> ?, not empty'

# ── sb_battery_line ───────────────────────────────────────────────────────────
OUT="$(sb_battery_line 85 Charging 25000000 40000000 47000000)"
has "$OUT" '85%'      'battery: shows the percentage'
has "$OUT" 'Charging' 'battery: shows the status'
has "$OUT" '25.0W'    'battery: shows the draw in watts'
has "$OUT" 'to full'  'battery: charging shows time-to-full'

OUT="$(sb_battery_line 42 Discharging 15000000 20000000 47000000)"
has "$OUT" 'left'     'battery: discharging shows time-to-empty'
eq "$(printf '%s' "$OUT" | grep -c 'to full')" '0' 'battery: discharging does not show time-to-full'

# The condition that actually killed this box on 2026-07-29: a too-weak USB-C
# source, so the battery discharges while a supply is attached.
OUT="$(sb_battery_line 4 Discharging 18000000 2000000 47000000)"
has "$OUT" '4%'          'battery: critical percentage still renders'
has "$OUT" 'Discharging' 'battery: critical state shows Discharging'

# A desktop has no battery; the row must degrade, not vanish or error.
OUT="$(sb_battery_line "" "" "" "" "")"
has "$OUT" 'n/a' 'battery: absent battery renders n/a'

# A rate of 0 (idle EC) must not divide by zero.
OUT="$(sb_battery_line 85 Full 0 47000000 47000000)"
has "$OUT" '85%' 'battery: zero power_now still renders'
eq "$(printf '%s' "$OUT" | grep -c 'left')" '0' 'battery: zero rate gives no bogus estimate'

# ── Time charts ───────────────────────────────────────────────────────────────
# The chart column is the reason the frame is now laid out in two passes, so the
# padding maths is asserted as hard as the glyph maths: a one-cell error in either
# makes every row after it ragged.
export STATUSBOARD_RAMP=height   # pin the ramp; the default depends on the device

# sb_push: pure, oldest-out.
eq "$(sb_push '' 5)"            '5'       'push: first sample'
eq "$(sb_push '1,2,3' 4)"       '1,2,3,4' 'push: appends'
eq "$(sb_push '1,2,3' 4 3)"     '2,3,4'   'push: drops the oldest past the cap'
eq "$(sb_push '1,2,3' 4 1)"     '4'       'push: a cap of 1 keeps only the newest'
# A missing reading MUST become a placeholder, not an empty field: bash's read -a
# discards a trailing empty field, which would silently shorten the series and
# shift every later frame one cell sideways.
eq "$(sb_push '1,2' '')"        '1,2,-'   'push: a missing sample becomes -'
eq "$(sb_push "$(sb_push '1' '')" 3)" '1,-,3' 'push: a gap keeps its slot'

# sb_chart: newest at the right edge, fixed ceiling, stable width.
eq "$(sb_chart 8 100 '0,0,0,0,0,0,0,0')"           '▁▁▁▁▁▁▁▁' 'chart: zeroes are the lowest glyph, not blanks'
eq "$(sb_chart 8 100 '100,100,100,100,100,100,100,100')" '████████' 'chart: the ceiling is the top glyph'
eq "$(sb_chart 4 100 '1,2,3,4,97,98,99,100')"      '████'     'chart: only the newest cells are shown'
eq "$(sb_chart 4 100 '50,90')"                     '  ▅█'     'chart: a short series is right-aligned'
eq "$(sb_chart 4 100 '200,300,400,500')"           '████'     'chart: over-ceiling clamps, never overflows'
eq "$(sb_chart 4 100 '-,-,-,-')"                   '    '     'chart: missing samples are blanks'
eq "$(sb_chart 4 100 'x,x,x,x')"                   '××××'     'chart: an unreachable target is ×, not a gap'
eq "$(sb_chart 0 100 '1,2,3')"                     ''         'chart: zero width renders nothing'
eq "$(sb_chart junk 100 '1,2')"                    ''         'chart: non-numeric width renders nothing, not an error'
eq "$(sb_chart 4 0 '1,2,3,4')"                     '████'     'chart: a zero ceiling does not divide by zero'
# Width is the contract the layout depends on.
for series in '1' '1,2,3' '5,5,5,5,5,5,5,5,5,5,5,5'; do
  eq "$(printf '%s' "$(sb_chart 10 100 "$series")" | wc -m | tr -d ' ')" '10' \
    "chart: width is exactly 10 for series '$series'"
done
# The ASCII ramp is not a placeholder — it is what tty1 actually gets, because the
# console fonts on this box carry no partial blocks (measured 2026-07-29).
eq "$(STATUSBOARD_RAMP=ascii sb_chart 4 100 '0,33,66,100')" '.:+#' 'chart: ascii ramp spans the same range'
eq "$(STATUSBOARD_RAMP=ascii sb_chart 2 100 'x,x')"         'xx'   'chart: ascii ramp uses x for down'

# ── chart colour ──────────────────────────────────────────────────────────────
# Every assertion above ran with colour OFF and is byte-identical to the pre-colour
# board — that is the gate working, and it is why --once stays diffable. What follows
# turns colour ON explicitly, because otherwise none of the new code is covered.
ESC=$'\033'
count_sub() { # count_sub <string> <needle>
  local s="${1:-}" pat="${2:-}" n=0
  while [ "${s#*"$pat"}" != "$s" ]; do n=$((n + 1)); s="${s#*"$pat"}"; done
  printf '%s' "$n"
}

eq "$(sb_heat_color 0 8)" '' 'heat: no escape at all when colour is off'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 0 8)" "${ESC}[38;2;88;166;110m" 'heat: the floor is green'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8)" "${ESC}[38;2;200;70;70m" 'heat: the ceiling is red'
# A level past the top must clamp, not compute a colour outside the gradient.
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 99 8)" "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8)" \
  'heat: a level past the top clamps to the ceiling colour'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color junk 8)" "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 0 8)" \
  'heat: a non-numeric level is the floor, not an error'
# The gradient is only worth having if the levels are actually distinguishable.
HEATS=""
for i in 0 1 2 3 4 5 6 7; do
  HEATS="$HEATS$(STATUSBOARD_TRUECOLOR=1 sb_heat_color "$i" 8)"$'\n'
done
eq "$(printf '%s' "$HEATS" | sort -u | grep -c .)" '8' 'heat: eight levels are eight distinct colours'
# A 16-colour terminal keeps the thresholds rather than being fed 38;2 it may not parse.
eq "$(C_OK=${ESC}'[32m' STATUSBOARD_TRUECOLOR=0 sb_heat_color 0 8)" "${ESC}[32m" 'heat: no truecolor falls back to green'
eq "$(C_BAD=${ESC}'[31m' STATUSBOARD_TRUECOLOR=0 sb_heat_color 7 8)" "${ESC}[31m" 'heat: no truecolor falls back to red at the top'

# Run-length is a correctness property, not an optimisation: per-cell escapes cost
# ~19 bytes, which is tens of KB a frame on a wide display at a 1s interval.
FLAT="$(C_RST=${ESC}'[0m' STATUSBOARD_TRUECOLOR=1 sb_chart 8 100 '100,100,100,100,100,100,100,100')"
eq "$(count_sub "$FLAT" "${ESC}[38;2")" '1' 'chart: a run of equal samples emits one colour escape'
VARY="$(C_RST=${ESC}'[0m' STATUSBOARD_TRUECOLOR=1 sb_chart 3 100 '0,50,100')"
eq "$(count_sub "$VARY" "${ESC}[38;2")" '3' 'chart: each change of level emits its own escape'
# Colour must not leak past the chart into the rest of the frame.
eq "$(count_sub "$FLAT" "${ESC}[0m")" '1' 'chart: a coloured chart resets exactly once at the end'
# A gap carries no colour, so it has to close the run before it — otherwise the
# blank cell inherits a background-dependent tint.
GAP="$(C_RST=${ESC}'[0m' STATUSBOARD_TRUECOLOR=1 sb_chart 3 100 '100,-,100')"
eq "$(count_sub "$GAP" "${ESC}[0m")" '2' 'chart: a gap closes the colour run and the chart closes again'
# THE layout invariant: colour changes bytes, never cells. A chart one cell wider
# than the column it was measured for wraps the whole repainting frame.
eq "$(sb_vislen "$FLAT")" '8' 'chart: colour does not change the visible width'
eq "$(sb_vislen "$GAP")"  '3' 'chart: nor with a gap in it'
DOWN="$(C_BAD=${ESC}'[31m' C_RST=${ESC}'[0m' STATUSBOARD_TRUECOLOR=1 sb_chart 3 100 '100,x,100')"
has "$DOWN" "${ESC}[31m×" 'chart: a down sample is the alarm colour whatever surrounds it'
eq "$(sb_vislen "$DOWN")" '3' 'chart: a down sample keeps the width too'

# sb_vislen / sb_pad: the two-column layout is only aligned if colour is invisible
# to the width maths. Measuring with ${#s} instead leaves every coloured row short
# by the length of its escapes.
eq "$(sb_vislen 'abc')" '3' 'vislen: plain text'
eq "$(sb_vislen "$(printf '\033[32mabc\033[0m')")" '3' 'vislen: ANSI escapes do not count'
eq "$(sb_vislen '')" '0' 'vislen: empty'
eq "$(printf '%s' "$(sb_pad 'abc' 6)" | wc -c | tr -d ' ')" '6' 'pad: pads to the requested width'
eq "$(printf '%s' "$(sb_pad 'abcdefgh' 3)" | wc -c | tr -d ' ')" '8' 'pad: never truncates a row'
eq "$(sb_vislen "$(sb_pad "$(printf '\033[32mabc\033[0m')" 6)")" '6' 'pad: a coloured row pads to the same visible width'

# sb_chart_width: leaves the text column alone and gives up rather than drawing a
# chart too narrow to read.
eq "$(sb_chart_width 120 60)" '57' 'chart_width: cols minus text minus the gutter'
eq "$(sb_chart_width 80 70)"  '0'  'chart_width: no chart when under 8 cells would be left'
eq "$(sb_chart_width 0 60)"   '0'  'chart_width: no terminal width means no charts'
# The ceiling is in CELLS, so it is the cap divided by the fold factor. Comparing a
# cell count against a sample count would let a folded chart claim k times its depth.
eq "$(sb_chart_width 4000 60)" "$((SB_HIST_CAP / SB_K))" 'chart_width: capped at the history depth in cells'
eq "$(SB_K=1 SB_HIST_CAP=400 sb_chart_width 4000 60)" '400' 'chart_width: unfolded, the ceiling is the raw cap'
eq "$(SB_K=30 SB_HIST_CAP=6000 sb_chart_width 4000 60)" '200' 'chart_width: at k=30 a 6000-sample history is 200 cells'
# The depth must cover a full screen of folded cells, or a 5m chart silently shows
# a fraction of its width.
[ "$SB_HIST_CAP" -ge $((200 * SB_K)) ] \
  && pass 'cap: the history holds at least 200 cells at the configured fold' \
  || fail 'cap: the history is too shallow for the fold factor'
eq "$SB_CELL_SECS" "$((SB_K * PROBE))" 'cell: the displayed duration is derived from k, not from --cell'

# sb_trim: an uncharted row longer than the frame would wrap, and a wrapped row
# scrolls the entire repainting display.
eq "$(sb_trim 'abcdef' 10)" 'abcdef'  'trim: a short row is untouched'
eq "$(sb_trim 'abcdefghij' 5)" 'abcd>' 'trim: a long row is cut with a marker'
eq "$(sb_vislen "$(sb_trim "$(printf '\033[32mabcdefghij\033[0m')" 5)")" '5' \
  'trim: a coloured row trims to the visible width'
eq "$(sb_trim 'abc' 0)" 'abc' 'trim: a zero width is a no-op, not an empty row'

# sb_span: the same picture means different things at different probe rates, so the
# header has to say which.
# ── sb_fold ───────────────────────────────────────────────────────────────────
# The fold is what lets a cell be 5 minutes while the numbers stay 10 seconds old.
eq "$(sb_fold 1 '1,2,3')"   '1,2,3' 'fold: k=1 is the identity'
eq "$(sb_fold 0 '1,2,3')"   '1,2,3' 'fold: k=0 clamps to 1 rather than dividing by zero'
eq "$(sb_fold junk '1,2,3')" '1,2,3' 'fold: a non-numeric k clamps to 1'
eq "$(sb_fold 3 '')"        ''      'fold: an empty series folds to nothing'
eq "$(sb_fold 3 '1,2,3,4,5,6')" '3,6' 'fold: takes the max of each bucket'
# Buckets align from the NEWEST end, so the OLDEST one is the short one. Anchoring
# the other way would freeze the newest cell for a whole cell-width.
eq "$(sb_fold 3 '9,1,2,3,4,5,6')" '9,3,6' 'fold: the partial bucket is the oldest'
eq "$(sb_fold 3 '5')"       '5'     'fold: a series shorter than one bucket still renders'
# Max, not mean: a 5-minute cell that hides a spike is worse than one that alarms.
eq "$(sb_fold 5 '0,0,90,0,0')" '90' 'fold: a spike survives the fold'
# An outage inside the window must be visible as an outage.
eq "$(sb_fold 3 '1,x,2')"   'x'     'fold: any unreachable sample makes the cell unreachable'
eq "$(sb_fold 3 '-,-,-')"   '-'     'fold: an all-missing bucket stays a gap'
eq "$(sb_fold 3 '-,4,-')"   '4'     'fold: a partly-missing bucket uses what it has'
# Cell count, exactly: a fold that returns one cell too many or too few silently
# shifts every chart sideways.
eq "$(printf '%s' "$(sb_fold 10 "$(seq -s, 1 100)")" | tr ',' '\n' | grep -c .)" '10' \
  'fold: 100 samples at k=10 is exactly 10 cells'
eq "$(printf '%s' "$(sb_fold 10 "$(seq -s, 1 95)")" | tr ',' '\n' | grep -c .)" '10' \
  'fold: 95 samples at k=10 is 10 cells (the oldest is partial)'
# IFS must not leak out of the fold — a stray comma corrupts every later read -a.
sb_fold 3 '1,2,3' >/dev/null
eq "$(printf 'a b' | { read -r x y; printf '%s' "$y"; })" 'b' 'fold: does not leak IFS'

# ── sb_dur ────────────────────────────────────────────────────────────────────
eq "$(sb_dur 10)"   '10s'    'dur: seconds under a minute'
eq "$(sb_dur 300)"  '5m'     'dur: a whole number of minutes'
eq "$(sb_dur 90)"   '1m30s'  'dur: a ragged minute keeps its seconds'
eq "$(sb_dur 3600)" '1h00m'  'dur: rolls into hours'
eq "$(sb_dur junk)" 'n/a'    'dur: non-numeric is n/a'

eq "$(sb_span 240 10)" '40m'    'span: 240 cells at 10s is 40m'
eq "$(sb_span 240 1)"  '4m'     'span: 240 cells at 1s is 4m'
eq "$(sb_span 600 10)" '1h40m'  'span: rolls into hours'
eq "$(sb_span junk 10)" 'n/a'   'span: non-numeric is n/a'

# sb_rtt_tenths: ping output → the integer unit the charts scale against.
eq "$(sb_rtt_tenths '0.516ms')" '5'   'rtt: 0.516ms -> 5 tenths'
eq "$(sb_rtt_tenths '3.12ms')"  '31'  'rtt: 3.12ms -> 31 tenths'
eq "$(sb_rtt_tenths '')"        ''    'rtt: empty stays empty (a gap, not a zero)'
eq "$(sb_rtt_tenths 'down')"    ''    'rtt: garbage stays empty'

# sb_cols: charts off when stdout is not a terminal (which keeps --once diffable),
# and forceable so the layout is testable at all.
eq "$(sb_cols 0)" '0' 'cols: a non-terminal output means no charts'
eq "$(STATUSBOARD_COLS=133 sb_cols 0)" '133' 'cols: STATUSBOARD_COLS forces a width'
eq "$(STATUSBOARD_COLS=junk sb_cols 0)" '0'  'cols: a junk override disables charts rather than erroring'
# The tty-ness is an ARGUMENT because render_frame runs inside a command
# substitution where fd 1 is a pipe. An internal `[ -t 1 ]` disabled every chart on
# tty1 while every forced-width test still passed, so the signature is the fix.
grep -q 'sb_cols "\$SB_ISTTY"' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'cols: the frame passes in a tty-ness measured outside the subshell'
grep -qE '^SB_ISTTY=0; \[ -t 1 \] && SB_ISTTY=1$' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'cols: -t 1 is evaluated in the shell that owns the real fd 1'
# The ramp choice has the same hazard and the same fix: -ef against /dev/tty[0-9]*
# needs no substitution, so it sees the real fd 1. Reading /proc/self/fd/1 from a
# helper would always report a pipe, and tty1 would get glyphs it cannot draw.
grep -q -- '-ef /dev/stdout' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'ramp: the VT test compares devices without a command substitution'
! grep -q 'readlink /proc/self/fd/1' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'ramp: no readlink of fd 1 (it would see the frame subshell pipe)'
# STATUSBOARD_RAMP='' rather than unset: it is exported for the chart assertions
# above, and an empty value takes the same "not set" branch.
eq "$(STATUSBOARD_RAMP='' SB_IS_VT=1 sb_ramp_name)" 'ascii'  'ramp: a VT gets the ASCII ramp'
eq "$(STATUSBOARD_RAMP='' SB_IS_VT=0 sb_ramp_name)" 'height' 'ramp: anything else gets the block ramp'
eq "$(SB_IS_VT=1 STATUSBOARD_RAMP=height sb_ramp_name)" 'height' 'ramp: the override wins on a VT too'

# sb_console_font_file: console-setup names files height-x-width while FONTSIZE is
# width-x-height. Reversing them is a silent no-op that leaves the font unchanged.
eq "$(sb_console_font_file Uni3 TerminusBold 16x32)" '/usr/share/consolefonts/Uni3-TerminusBold32x16.psf.gz' \
  'font: FONTSIZE 16x32 maps to the 32x16 file'
eq "$(sb_console_font_file Lat15 Fixed 8x16)" '/usr/share/consolefonts/Lat15-Fixed16x8.psf.gz' \
  'font: the mapping is mechanical, not special-cased'
eq "$(sb_console_font_file Uni3 TerminusBold junk)" '' 'font: a malformed size yields nothing'

# ── Disks ─────────────────────────────────────────────────────────────────────
# latitude carries four USB disks across two docks plus a spare NVMe, and a dock
# that comes back empty is invisible on a headless box — hence rows per filesystem
# and a row for connected-but-unmounted disks.
eq "$(sb_kb_to_gib 1048576)"   '1'   'gib: 1048576 KiB is 1 GiB'
eq "$(sb_kb_to_gib 474794016)" '453' 'gib: latitude root, 474794016 KiB -> 453G'
eq "$(sb_kb_to_gib '')"        'n/a' 'gib: empty -> n/a'
eq "$(sb_kb_to_gib junk)"      'n/a' 'gib: non-numeric -> n/a'

OUT="$(sb_disk_row nvme1n1p3 / 2524584 474794016 1)"
has "$OUT" '/'          'disk row: shows the mount point'
has "$OUT" 'nvme1n1p3'  'disk row: shows the device'
has "$OUT" '1%'         'disk row: shows the percentage'
has "$OUT" '453G'       'disk row: shows the total in GB'
has "$OUT" '[░'         'disk row: has a horizontal bar'
# A deep mount point must not widen the text column for every other row.
OUT="$(sb_disk_row sdc2 /mnt/media/library/photos 100 200 50)"
has "$OUT" '<'          'disk row: an over-long mount point is truncated tail-first'
eq "$(sb_vislen "$(sb_disk_row sdc2 /mnt/media/library/photos 100 200 50)")" \
   "$(sb_vislen "$(sb_disk_row sdc2 /srv 100 200 50)")" \
   'disk row: width does not depend on the mount point length'
# A full disk still renders; the bar is coloured by FREE space, so this is the
# inverse of the battery row and a 99% disk must not read as healthy.
OUT="$(sb_disk_row sda1 /mnt/x 900 1000 99)"
has "$OUT" '99%' 'disk row: a nearly-full disk renders'
OUT="$(sb_disk_row sda1 /mnt/x '' '' '')"
has "$OUT" 'n/a' 'disk row: missing sizes degrade to n/a rather than breaking the row'

# The per-mount series store. An associative array would keep stale keys after an
# unplug; a flat string is prunable and testable.
S="$(sb_series_set '' /mnt/a '1,2,3')"
eq "$(sb_series_get "$S" /mnt/a)" '1,2,3' 'series: set then get'
S="$(sb_series_set "$S" /mnt/b '4,5')"
eq "$(sb_series_get "$S" /mnt/b)" '4,5'   'series: a second key coexists'
eq "$(sb_series_get "$S" /mnt/a)" '1,2,3' 'series: the first key survives'
S="$(sb_series_set "$S" /mnt/a '9')"
eq "$(sb_series_get "$S" /mnt/a)" '9'     'series: set overwrites in place'
eq "$(sb_series_get "$S" /mnt/b)" '4,5'   'series: overwriting one key leaves the other'
eq "$(sb_series_get "$S" /mnt/zz)" ''     'series: an unknown key is empty, not an error'
S="$(sb_series_keep "$S" /mnt/b)"
eq "$(sb_series_get "$S" /mnt/b)" '4,5'   'series: keep retains a live mount'
eq "$(sb_series_get "$S" /mnt/a)" ''      'series: keep drops an unmounted one'
eq "$(sb_series_keep "$S")" ''            'series: keeping nothing empties the store'
# The mount point / is a substring of every other mount point — the store must
# match keys whole, or unplugging a dock would drop the root filesystem's history.
S="$(sb_series_set "$(sb_series_set '' / '1')" /mnt/a '2')"
eq "$(sb_series_get "$(sb_series_keep "$S" /)" /)" '1' 'series: / is matched whole, not as a prefix'
eq "$(sb_series_get "$(sb_series_keep "$S" /)" /mnt/a)" '' 'series: pruning / does not keep /mnt/a'

# sb_mounts must report real filesystems only: the virtual tree (tmpfs, devtmpfs,
# efivarfs) and loop devices are not disks and would crowd out the ones that are.
if [ -r /proc/mounts ] || command -v df >/dev/null 2>&1; then
  OUT="$(sb_mounts)"
  eq "$(printf '%s\n' "$OUT" | awk -F'|' 'NF && NF != 5 { c++ } END { printf "%d", c+0 }')" '0' \
    'mounts: every line has five fields'
  eq "$(printf '%s\n' "$OUT" | grep -c 'tmpfs')" '0' 'mounts: no tmpfs'
  eq "$(printf '%s\n' "$OUT" | grep -c '^loop')" '0' 'mounts: no loop devices'
  eq "$(printf '%s\n' "$OUT" | awk -F'|' 'NF && $2 !~ /^\// { c++ } END { printf "%d", c+0 }')" '0' \
    'mounts: every mount point is an absolute path'
fi

unset STATUSBOARD_RAMP

# ── The script itself ─────────────────────────────────────────────────────────
bash -n "$REPO/provision/statusboard/statusboard.sh"; eq "$?" '0' 'script: syntax is valid'
# The unit text is only materialised under --install (root), so assert on the
# template plus the value it interpolates: without BOTH the Conflicts= line and
# disabling the getty, agetty repaints a login prompt over the frame.
grep -q 'Conflicts=\$GETTY_UNIT' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'unit: template carries Conflicts= for the getty'
grep -qE 'GETTY_UNIT="?getty@tty1\.service' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'unit: the conflicting unit is the tty1 getty'
# `disable`, not `disable --now`: Conflicts= already stops the getty when the
# board starts, and --now here would race that stop against the service start.
# disable is purely about the next boot.
grep -qE 'systemctl disable "\$GETTY_UNIT"' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'install: disables the tty1 getty for the next boot'
grep -q 'systemctl enable --now "\$GETTY_UNIT"' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'uninstall: restores the tty1 getty (a one-way install would be a trap)'

# The console-killing regression, 2026-07-29. Two independent guards, because the
# failure is unrecoverable from the screen itself: tty1 owned by nobody.
grep -q 'SupplementaryGroups=tty' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'unit: SupplementaryGroups=tty — an unprivileged service cannot open root:tty 620 /dev/tty1'

# Ordering: the service must be proven running BEFORE the getty is disabled.
SB="$REPO/provision/statusboard/statusboard.sh"
start_ln="$(grep -n 'systemctl restart "\$SERVICE_NAME"' "$SB" | head -1 | cut -d: -f1)"
disable_ln="$(grep -n 'systemctl disable "\$GETTY_UNIT"' "$SB" | head -1 | cut -d: -f1)"
[ -n "$start_ln" ] && [ -n "$disable_ln" ] && [ "$start_ln" -lt "$disable_ln" ]
eq "$?" '0' 'install: starts the board before disabling the getty, never the reverse'

grep -q 'is-active --quiet "\$SERVICE_NAME"' "$SB"
eq "$?" '0' 'install: verifies the service is actually active'
# `start` on an already-active unit does nothing, so a re-install after a code
# change would report success while the old process kept painting the screen.
grep -q 'systemctl start "\$SERVICE_NAME"' "$SB"
eq "$?" '1' 'install: uses restart, never a bare start (which no-ops when active)'
rollback_ln="$(grep -n 'restored %s. Nothing else changed' "$SB" | head -1 | cut -d: -f1)"
[ -n "$rollback_ln" ]; eq "$?" '0' 'install: rolls the getty back when the service fails to start'
grep -q 'ProtectSystem=strict' "$REPO/provision/statusboard/statusboard.sh"
eq "$?" '0' 'unit: read-only filesystem — the board only reads /sys and /proc'

# --once must work headless (this is how the frame is smoke-tested on any box).
OUT="$(bash "$REPO/provision/statusboard/statusboard.sh" --once 2>&1)"; rc=$?
eq "$rc" '0' 'run: --once exits 0 even with no battery and no tailscale'
has "$OUT" 'battery'  'run: --once frame has a battery row'
has "$OUT" 'lan'      'run: --once frame has a lan row'
has "$OUT" 'internet' 'run: --once frame has an internet row'
has "$OUT" 'uptime'   'run: --once frame has an uptime row'
# No ANSI escapes when stdout is a pipe, or the frame is unreadable in a log.
eq "$(printf '%s' "$OUT" | grep -c $'\033')" '0' 'run: no colour escapes when not a tty'
# Charts must be absent by default in a pipe — every assertion above depends on it.
hasnt "$OUT" 'charts: last' 'run: no chart column when stdout is not a tty'

# ── The frame, laid out with charts ────────────────────────────────────────────
# STATUSBOARD_COLS is the only way to exercise the real two-pass layout off a tty.
# The ASCII ramp, deliberately: this measures ROW WIDTH, and awk's length() counts
# bytes, so a multi-byte glyph would read as an over-wide row that is in fact
# correct. It is also the ramp tty1 actually runs.
OUT="$(STATUSBOARD_COLS=120 STATUSBOARD_RAMP=ascii bash "$REPO/provision/statusboard/statusboard.sh" --once 2>&1)"; rc=$?
eq "$rc" '0' 'layout: --once with a forced width exits 0'
has "$OUT" 'charts: last' 'layout: the header names the span the charts cover'
# The axis carries BOTH cadences now: how much time a cell covers, and how often a
# sample was actually taken. They are no longer the same number, and a reader who
# assumes they are will misread every chart.
has "$OUT" '5m/cell'      'layout: the header names the cell duration in readable units'
has "$OUT" '10s samples'  'layout: the header also names the sample cadence'
OUT_FAST="$(STATUSBOARD_COLS=120 STATUSBOARD_CELL=10 bash "$REPO/provision/statusboard/statusboard.sh" --once 2>&1)"
has "$OUT_FAST" '10s/cell' 'layout: STATUSBOARD_CELL reaches the axis label'
# Nothing may exceed the width — a frame one cell too wide wraps and the whole
# display walks up the screen on every repaint.
eq "$(printf '%s\n' "$OUT" | awk '{ if (length($0) > 120) c++ } END { printf "%d", c+0 }')" '0' \
  'layout: no row is wider than the terminal'
# Every charted row must end at the SAME column, or the column is not a column.
eq "$(printf '%s\n' "$OUT" | awk '/^(battery|source|lan|internet|tailnet|uptime|\/|<)/ { print length($0) }' | sort -u | wc -l | tr -d ' ')" '1' \
  'layout: all charted rows end at the same column (disk rows included)'
has "$OUT" 'G / ' 'layout: the frame lists filesystems with their sizes'
# An uncharted row must not narrow the chart column. The "not mounted" list is the
# widest row on this box by 40 columns, and letting it set the text width cost every
# chart most of its span.
eq "$(printf '%s\n' "$OUT" | awk '/^battery/ { print length($0) }')" \
   "$(printf '%s\n' "$OUT" | awk '/^tailnet/ { print length($0) }')" \
   'layout: charted rows agree on width regardless of the uncharted ones'

# ── Paint cadence vs probe cadence ─────────────────────────────────────────────
# The clock is repainted every second; the pings are NOT run every second. Both
# halves matter: a 3s clock reads as a frozen box, and a 1s ping loop is a busy
# box doing nothing useful.
grep -qE '^INTERVAL=1$' "$SB";  eq "$?" '0' 'cadence: repaints default to 1s so the clock ticks'
grep -qE '^PROBE=10$' "$SB";    eq "$?" '0' 'cadence: network probes default to 10s'
grep -q 'ExecStart=/bin/bash $SELF --interval $INTERVAL --probe $PROBE' "$SB"
eq "$?" '0' 'cadence: the unit passes both cadences through'
# The series MUST be appended to outside the frame subshell, or every chart shows
# exactly one sample forever.
# grep -E, not \| in a BRE: BSD grep does not take \| and the alternation would
# silently match nothing, passing this assertion for the wrong reason.
sample_ln="$(grep -nE '^  sb_sample_fast$' "$SB" | tail -1 | cut -d: -f1)"
frame_ln="$(grep -nE '^  frame="\$\(render_frame\)"$' "$SB" | head -1 | cut -d: -f1)"
[ -n "$sample_ln" ] && [ -n "$frame_ln" ] && [ "$sample_ln" -lt "$frame_ln" ]
eq "$?" '0' 'cadence: sampling happens in the main shell, before the frame subshell'

# --bigfont must stay out of --install: that path has already broken the console
# once, and a font change is an unrelated risk to fold into it.
grep -q 'MODE=bigfont' "$SB"; eq "$?" '0' 'font: --bigfont is its own mode'
grep -q 'setfont' "$SB"; eq "$?" '0' 'font: --bigfont can apply the font without a reboot'
grep -q 'pre-statusboard' "$SB"; eq "$?" '0' 'font: the previous console-setup config is backed up'
# The install path must NOT touch the font.
inst_ln="$(grep -n 'if \[ "\$MODE" = install \] || \[ "\$MODE" = uninstall \]' "$SB" | cut -d: -f1)"
font_ln="$(grep -n 'if \[ "\$MODE" = bigfont \]' "$SB" | cut -d: -f1)"
[ -n "$inst_ln" ] && [ -n "$font_ln" ] && [ "$font_ln" -lt "$inst_ln" ]
eq "$?" '0' 'font: the bigfont mode exits before the install path is reached'

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
