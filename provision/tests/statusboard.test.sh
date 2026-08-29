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

# ── Power source ──────────────────────────────────────────────────────────────
# The wattage and the label are split out of the sysfs walk for the same reason
# sb_battery_line is: the interesting cases are the ones no attached hardware is
# currently in, and a hub that reports zeros is one of them.

eq "$(sb_source_watts 20000000 3250000)" '65' 'source: 20V at 3.25A reads as 65W'
eq "$(sb_source_watts 20000000 3000000)" '60' 'source: 20V at 3A reads as 60W'
eq "$(sb_source_watts 5000000 3000000)" '15'  'source: the 15W port that browned the box out still reads 15W'

# The whole point: a zero is a missing reading, never a 0W supply.
eq "$(sb_source_watts 0 0)" ''         'source: both figures zero gives no wattage'
eq "$(sb_source_watts 0 3000000)" ''   'source: zero volts gives no wattage'
eq "$(sb_source_watts 20000000 0)" ''  'source: zero amps gives no wattage'
eq "$(sb_source_watts '' '')" ''       'source: absent attributes give no wattage'
eq "$(sb_source_watts abc 3000000)" '' 'source: junk volts give no wattage'
eq "$(sb_source_watts 20000000 xyz)" '' 'source: junk amps give no wattage'
# 100mV at 1mA rounds to 0W. Printing that as 0W would be the original bug by a
# longer route, so it has to come back empty too.
eq "$(sb_source_watts 100000 1000)" ''  'source: a product that rounds to zero gives no wattage'

eq "$(sb_source_label 65 'C [PD] PD_PPS')" 'USB-C 65W' \
  'source: a known wattage wins over the type string'
# The kernel brackets the ACTIVE type. Both directions are asserted because an
# inverted match would pass the first case on its own.
eq "$(sb_source_label '' 'C [PD] PD_PPS')" 'USB-C PD ?W' \
  'source: bracketed PD with no rating says PD and admits the unknown'
eq "$(sb_source_label '' '[C] PD PD_PPS')" 'USB-C ?W' \
  'source: PD merely listed, not active, does not claim PD'
eq "$(sb_source_label '' '')" 'USB-C ?W' \
  'source: no type string at all still admits the unknown'
eq "$(printf '%s' "$(sb_source_label '' 'C [PD] PD_PPS')" | grep -c '0W')" '0' \
  'source: an unknown rating never renders as 0W'

# ── Charge limit ──────────────────────────────────────────────────────────────
# A threshold the EC is not in the mode to honour is decoration. This box charged
# to 94% under a displayed `limit 85%`, so the mode is part of the reading.

OUT="$(sb_limit_line 85 'Trickle Fast Standard Adaptive [Custom]')"
has "$OUT" '85%' 'limit: Custom mode shows the ceiling'
eq "$(printf '%s' "$OUT" | grep -c 'not enforced')" '0' \
  'limit: Custom mode adds no warning'

OUT="$(sb_limit_line 85 'Trickle [Fast] Standard Adaptive Custom')"
has "$OUT" '85%'          'limit: an unenforced ceiling still shows the number'
has "$OUT" 'not enforced' 'limit: a mode that is not Custom is called out'
has "$OUT" 'Fast'         'limit: the warning names the mode actually in force'

# No charge_types file at all says nothing about enforcement, so it must not
# manufacture an alarm — plenty of ECs honour the threshold directly.
OUT="$(sb_limit_line 85 '')"
has "$OUT" '85%' 'limit: absent charge_types still shows the ceiling'
eq "$(printf '%s' "$OUT" | grep -c 'not enforced')" '0' \
  'limit: absent charge_types raises no warning'

# No threshold, no row.
eq "$(sb_limit_line '' 'Trickle [Fast] Standard')" '' \
  'limit: no threshold renders nothing at all'

# ── Platform power draw (sb_rapl_watts / sb_power_line) ───────────────────────
# RAPL gives an energy COUNTER, so every assertion here is about a pair of readings
# and the window between them — there is no such thing as one-sample watts.

# µJ per second is µW, so this is the whole conversion: 183 J over 10s is 18.3W.
eq "$(sb_rapl_watts 0 183000000 262143328850 10)" '18300000' \
  'rapl: energy delta over the window becomes µW'
eq "$(sb_rapl_watts 1000000 19300000 262143328850 1)" '18300000' \
  'rapl: a one-second window needs no special case'

# The first sample after startup has no predecessor. Empty, never zero — the same
# rule sb_source_watts exists to enforce.
eq "$(sb_rapl_watts '' 500 262143328850 10)" '' \
  'rapl: no previous reading yields no watts, not 0W'
eq "$(sb_rapl_watts 500 '' 262143328850 10)" '' \
  'rapl: an unreadable counter yields no watts, not 0W'
eq "$(sb_rapl_watts abc 500 262143328850 10)" '' 'rapl: junk yields nothing'

# The counter wraps about every four hours at this box's idle draw, so a negative
# delta is a rollover and one range has to be added back.
eq "$(sb_rapl_watts 262143328000 182999150 262143328850 10)" '18300000' \
  'rapl: a wrapped counter is corrected by one range, not reported as a drop'
eq "$(sb_rapl_watts 500 100 0 10)" '' \
  'rapl: a wrap with no known range yields nothing rather than a guess'
eq "$(sb_rapl_watts 500 100 '' 10)" '' \
  'rapl: a wrap with an empty range yields nothing'

# A window far longer than a probe means the loop stalled or the box slept. The
# counter kept running, so the average would be arithmetically fine and physically
# meaningless.
eq "$(sb_rapl_watts 0 183000000 262143328850 21600)" '' \
  'rapl: a suspend-length window is a gap, not a tiny wattage'
eq "$(sb_rapl_watts 0 183000000 262143328850 0)" '' \
  'rapl: a zero-length window yields nothing'

# The DOMAIN has to reach the screen: psys and package-0 differ by 3x on this box,
# so a bare number would be read as the machine's draw either way.
OUT="$(sb_power_line 18300000 psys)"
has "$OUT" '18.3W' 'power: the row carries the wattage'
has "$OUT" 'psys'   'power: the row names the RAPL domain it measured'
has "$(sb_power_line 6400000 package-0)" 'package-0' \
  'power: the narrower fallback domain is named too'
has "$(sb_power_line '' psys)" 'n/a' \
  'power: no reading reads n/a rather than 0W'

# ── Drive temperature ─────────────────────────────────────────────────────────
# sb_smart_temp_parse: from smartctl's JSON, because the attribute table is ambiguous.
eq "$(sb_smart_temp_parse '{"temperature":{"current":47}}')" '47' \
  'temp: the current temperature is read out of the JSON'
eq "$(sb_smart_temp_parse '{"power":{"current":9},"temperature":{"current":47}}')" '47' \
  'temp: a "current" in another object does not win'
eq "$(sb_smart_temp_parse '{"temperature":{"op_limit_min":10,"current":39,"lifetime_max":63}}')" '39' \
  'temp: the current field is found among its siblings'
eq "$(sb_smart_temp_parse '{"device":{"name":"/dev/sdf"}}')" '' \
  'temp: no temperature object yields nothing'
eq "$(sb_smart_temp_parse '')" '' 'temp: empty output yields nothing'

# sb_smart_asleep: smartctl's exit code cannot tell these apart — measured on
# latitude, a sleeping sdf and a nonexistent /dev/sdZZ both exited 2.
# sb_apm_parks: the gate that decides whether polling a drive is free. ATA defines
# 1-127 as the APM levels that PERMIT standby and 128-254 as the ones that forbid it,
# so the boundary is a specification, not a guess.
eq "$(sb_apm_parks 'APM level is:     128 (minimum power consumption without standby)')" no \
  'apm: 128 forbids standby, so the drive is safe to poll'
eq "$(sb_apm_parks 'APM level is:     254 (maximum performance)')" no \
  'apm: 254 is the top of the no-standby band'
eq "$(sb_apm_parks 'APM level is:     127')" yes \
  'apm: 127 is the top of the standby-permitted band'
eq "$(sb_apm_parks 'APM level is:     96 (intermediate level with standby)')" yes \
  'apm: 96 permits standby, so the drive must be left alone when idle'
eq "$(sb_apm_parks 'APM level is:     1 (minimum power consumption with standby)')" yes \
  'apm: 1 parks aggressively'
eq "$(sb_apm_parks 'APM level is:     255')" yes \
  'apm: 255 is outside the no-standby band and takes the cautious branch'
# Unknown must take the cautious branch: being wrong here is paid in drive life.
eq "$(sb_apm_parks 'APM feature is:   Unavailable')" yes \
  'apm: an unavailable APM feature is assumed to park'
eq "$(sb_apm_parks 'APM feature is:   Disabled')" yes \
  'apm: a disabled APM feature is assumed to park'
eq "$(sb_apm_parks '')" yes 'apm: no output is assumed to park'
eq "$(sb_apm_parks 'garbage')" yes 'apm: unparsable output is assumed to park'

asleep() {
  if sb_smart_asleep "$1"; then printf yes; else printf no; fi
}
eq "$(asleep '{"messages":[{"string":"Device is in SLEEP mode, exit(2)"}],"exit_status":2}')" yes \
  'temp: a sleeping drive is recognised from the message, not the exit code'
eq "$(asleep '{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}],"exit_status":2}')" yes \
  'temp: STANDBY counts as parked as well as SLEEP'
eq "$(asleep '{"messages":[{"string":"Smartctl open device: /dev/sdZZ [SAT] failed"}],"exit_status":2}')" no \
  'temp: an absent device exits 2 as well and must NOT be called parked'
eq "$(asleep '{"temperature":{"current":47},"exit_status":0}')" no \
  'temp: a healthy reading is not parked'

# sb_temp_cell: three outcomes, three strings, and all of them exactly four columns —
# the disk block pads to the widest row, so a field that changed width with its own
# content would move the chart column on whichever rows had a reading.
strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
while read -r t_c t_rota; do
  CELL="$(strip "$(sb_temp_cell "$t_c" "$t_rota")")"
  eq "${#CELL}" '4' "temp: the cell for '$t_c' is four columns wide"
done <<'PROBES'
47 1
5 1
105 0
zzz 1
junk 1
PROBES
eq "$(strip "$(sb_temp_cell '' 1)")" '   -' \
  'temp: no reading renders a dash, never 0C'
eq "$(strip "$(sb_temp_cell zzz 1)")" ' zzz' \
  'temp: a parked drive says so instead of showing a dash'
eq "$(strip "$(sb_temp_cell 47 1)")" ' 47C' \
  'temp: a reading renders without a degree sign — the VT console font may lack it'

# Spinners and flash have different limits, so one threshold pair cannot serve both —
# and this is the one part of the board where that distinction is load-bearing, since
# 52C is a warning on a 2.5" spinner and unremarkable on an NVMe.
#
# Colour is suppressed here (stdout is not a tty), which would make every colour
# assertion vacuously true against an empty needle. So the palette is swapped for
# legible markers for the duration of this block, and restored afterwards.
T_WARN_SAVE="$C_WARN"; T_BAD_SAVE="$C_BAD"; T_DIM_SAVE="$C_DIM"; T_RST_SAVE="$C_RST"
T_OK_SAVE="$C_OK"
C_WARN='<warn>'; C_BAD='<bad>'; C_DIM='<dim>'; C_RST='<rst>'; C_OK='<ok>'
has   "$(sb_temp_cell 52 1)" '<warn>' 'temp: 52C warns on a spinner'
hasnt "$(sb_temp_cell 52 0)" '<warn>' 'temp: 52C is unremarkable on an SSD'
has   "$(sb_temp_cell 58 1)" '<bad>'  'temp: 58C is bad on a spinner'
hasnt "$(sb_temp_cell 58 0)" '<bad>'  'temp: 58C is not yet bad on an SSD'
has   "$(sb_temp_cell 72 0)" '<warn>' 'temp: 72C warns on an SSD'
has   "$(sb_temp_cell 82 0)" '<bad>'  'temp: 82C is bad on an SSD'
# A READING below the warn threshold is painted, and the two non-readings are not:
# that is the whole distinction the dim-everything version could not draw, and a block
# of seven quiet numbers could not say which of them were measurements at all.
has   "$(sb_temp_cell 30 1)" '<ok>'   'temp: a cool drive reads as healthy, not as unknown'
has   "$(sb_temp_cell 45 0)" '<ok>'   'temp: an SSD below its warn threshold is healthy too'
has   "$(sb_temp_cell zzz)"  '<dim>'  'temp: a parked drive stays quiet'
has   "$(sb_temp_cell '')"   '<dim>'  'temp: an unreadable drive stays quiet'
hasnt "$(sb_temp_cell zzz)"  '<ok>'   'temp: parked is not a clean bill of health'
hasnt "$(sb_temp_cell '')"   '<ok>'   'temp: unreadable is not a clean bill of health'
# An unknown rotational flag must take the spinner thresholds: it is the assumption
# whose consequences are safer, and the disk row passes an empty string for a mount
# whose drive could not be resolved.
has   "$(sb_temp_cell 52 '')" '<warn>' 'temp: unknown rotation warns like a spinner'
C_WARN="$T_WARN_SAVE"; C_BAD="$T_BAD_SAVE"; C_DIM="$T_DIM_SAVE"; C_RST="$T_RST_SAVE"
C_OK="$T_OK_SAVE"

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
# The unit column is subtracted BEFORE the chart is sized. A chart sized to the full
# width and then followed by a label is a chart one label too wide, and a row that
# wraps walks the whole repainting frame up the screen.
eq "$(sb_chart_width 120 60 6)" '51' 'chart_width: the unit column is reserved out of the chart'
eq "$(sb_chart_width 120 60)"   '57' 'chart_width: no reserve is the old behaviour'
eq "$(sb_chart_width 120 60 junk)" '57' 'chart_width: a non-numeric reserve is treated as none'
eq "$(sb_chart_width 80 62 8)"  '0'  'chart_width: the reserve can take the chart below the 8-cell floor'
# The depth must cover a full screen of folded cells, or a 5m chart silently shows
# a fraction of its width.
[ "$SB_HIST_CAP" -ge $((200 * SB_K)) ] \
  && pass 'cap: the history holds at least 200 cells at the configured fold' \
  || fail 'cap: the history is too shallow for the fold factor'
eq "$SB_CELL_SECS" "$((SB_K * PROBE))" 'cell: the displayed duration is derived from k, not from --cell'

# sb_lpad: the unit column is flush right.
eq "$(sb_lpad ab 5)" '   ab' 'lpad: pads on the left'
eq "$(sb_lpad abcde 5)" 'abcde' 'lpad: an exact fit is untouched'
eq "$(sb_lpad abcdef 3)" 'abcdef' 'lpad: never truncates'
eq "$(sb_lpad '' 3)" '   ' 'lpad: an empty label still holds its column'
eq "$(sb_vislen "$(sb_lpad "$(printf '\033[32mab\033[0m')" 5)")" '5' 'lpad: counts visible cells, not escapes'

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

# ── sb_disk_bar ───────────────────────────────────────────────────────────────
# The bar's LENGTH is the disk's size and its FILL is how full it is, so a full 1G
# EFI partition and a full 931G array stop looking like the same event.
eq "$(sb_disk_bar 100 1000 1000 10)" '[██████████]' 'disk bar: the biggest disk gets the full width'
eq "$(sb_disk_bar 50 1000 1000 10)"  '[█████░░░░░]' 'disk bar: fill is the percentage of ITS length'
eq "$(sb_disk_bar 100 500 1000 10)"  '[█████]     ' 'disk bar: half the size is half the length'
eq "$(sb_disk_bar 50 500 1000 10)"   '[██░░░]     ' 'disk bar: length and fill compose'
# A tiny disk must still be visible: a zero-width bar reads as a missing disk.
eq "$(sb_disk_bar 100 1 1000 10)"    '[█]         ' 'disk bar: a disk far smaller than the array keeps one cell'
# THE alignment invariant — the bar field is a fixed width whatever the disk size,
# or every column after it walks left and right per row.
eq "$(sb_vislen "$(sb_disk_bar 50 1 1000 10)")" "$(sb_vislen "$(sb_disk_bar 50 1000 1000 10)")" \
  'disk bar: padded to the same visible width regardless of length'
eq "$(sb_disk_bar 50 1000 0 10)" '[█████░░░░░]' 'disk bar: no reference size means you are the biggest'
eq "$(sb_disk_bar 255 1000 1000 10)" '[██████████]' 'disk bar: over-range clamps to full'
eq "$(sb_disk_bar junk junk junk junk)" "$(sb_disk_bar 0 0 0 "$SB_DISK_BARW")" \
  'disk bar: garbage in every argument degrades rather than erroring'
eq "$(STATUSBOARD_RAMP=ascii sb_disk_bar 50 1000 1000 10)" '[#####.....]' 'disk bar: a VT gets the ASCII fill'

OUT="$(sb_disk_row nvme1n1p3 / 474794016 1)"
has "$OUT" '/'          'disk row: shows the mount point'
has "$OUT" 'nvme1n1p3'  'disk row: with no bay given, the device names the row'
has "$OUT" '1%'         'disk row: shows the percentage'
has "$OUT" '453G'       'disk row: shows the total in GB'
has "$OUT" '[░'         'disk row: has a horizontal bar'
# The used figure is deliberately gone: the bar says how full, the total says how
# big, and a third number in GB said neither for the widest field in the block.
hasnt "$OUT" '2G'       'disk row: does NOT show the used figure'
hasnt "$OUT" 'G / '     'disk row: no used/total pair remains'

# ── The bay column ────────────────────────────────────────────────────────────
# Which physical drive a filesystem sits on is the one thing the mount point cannot
# say: /mnt/immich and /mnt/immich-2024 are two drives and / and /boot/efi are one.
OUT="$(sb_disk_row nvme1n1p3 / 474794016 90 474794016 ok 38 0 nvme1n1)"
has "$OUT" 'nvme1n1' 'disk row: the bay leads the row'
# The bay REPLACES the trailing device column — the partition node was the same fact
# one column finer, and those columns come out of the charts.
hasnt "$OUT" 'nvme1n1p3' 'disk row: a named bay drops the partition node'
# A second filesystem on the same drive says so with a marker instead of repeating the
# name, which is what makes the block read as drives rather than as a flat list.
OUT="$(sb_disk_row nvme1n1p1 /boot/efi 973952 1 474794016 ok 38 0 nvme1n1 1)"
hasnt "$OUT" 'nvme1n1 ' 'disk row: a continuation row does not repeat the bay'
has "$OUT" '╰'          'disk row: a continuation row is marked'
has "$(STATUSBOARD_RAMP=ascii sb_disk_row nvme1n1p1 /boot/efi 9 1 9 ok 38 0 nvme1n1 1)" '`' \
   'disk row: a VT gets an ASCII continuation marker'
# Every one of those shapes has to end at the same column: the block pads to its widest
# row, so a bay field of varying width would move the chart column per row.
eq "$(sb_vislen "$(sb_disk_row nvme1n1p3 / 474794016 90 474794016 ok 38 0 nvme1n1)")" \
   "$(sb_vislen "$(sb_disk_row nvme1n1p1 /boot/efi 973952 1 474794016 ok 38 0 nvme1n1 1)")" \
   'disk row: a continuation row is exactly as wide as the row it continues'
eq "$(sb_vislen "$(sb_disk_row sdg1 /mnt/public 312568828 60 474794016 ok 39 1 sdg)")" \
   "$(sb_vislen "$(sb_disk_row nvme1n1p3 / 474794016 90 474794016 ok 38 0 nvme1n1)")" \
   'disk row: a short bay name is padded to the long one'
eq "$(sb_vislen "$(sb_disk_row nvme1n1p3 / 474794016 90 474794016 ok 38 0)")" \
   "$(sb_vislen "$(sb_disk_row nvme1n1p3 / 474794016 90 474794016 ok 38 0 nvme1n1)")" \
   'disk row: the device fallback is as wide as a named bay'
# A deep mount point must not widen the text column for every other row.
OUT="$(sb_disk_row sdc2 /mnt/media/library/photos/2024/raw 200 50)"
has "$OUT" '<'          'disk row: an over-long mount point is truncated tail-first'
eq "$(sb_vislen "$(sb_disk_row sdc2 /mnt/media/library/photos/2024/raw 200 50)")" \
   "$(sb_vislen "$(sb_disk_row sdc2 /srv 200 50)")" \
   'disk row: width does not depend on the mount point length'
# The paths that actually live on this box must fit unabbreviated — widening the
# field was the point, so assert the widest real one rather than the constant.
hasnt "$(sb_disk_row sdd2 /mnt/immich-2024-backup 976000000 72)" '<' \
  'disk row: the longest real mount point on this box is not truncated'
# A full disk still renders; the bar is coloured by FREE space, so this is the
# inverse of the battery row and a 99% disk must not read as healthy.
OUT="$(sb_disk_row sda1 /mnt/x 1000 99)"
has "$OUT" '99%' 'disk row: a nearly-full disk renders'
OUT="$(sb_disk_row sda1 /mnt/x '' '')"
has "$OUT" 'n/a' 'disk row: missing sizes degrade to n/a rather than breaking the row'
# Relative sizing reaches the row, not just the bar.
eq "$(sb_vislen "$(sb_disk_row sda1 /mnt/x 1000 50 1000)")" \
   "$(sb_vislen "$(sb_disk_row sda1 /mnt/x 10 50 1000)")" \
   'disk row: a small disk and a big one still end at the same column'

# ── Disk I/O ──────────────────────────────────────────────────────────────────
# Usage charts said nothing a console span could show — a fill level moves over
# days. Throughput is what a chart can answer and the numbers cannot.
DS="$(mktemp)"
cat > "$DS" <<'STATS'
 259       0 nvme0n1 1000 0 4096 200 500 0 2048 100 0 0 0
 259       1 nvme0n1p1 900 0 2048 180 400 0 1024 90 0 0 0
   8       0 sda 10 0 100 5 20 0 200 8 0 0 0
STATS
eq "$(sb_dev_sectors nvme0n1p1 "$DS")" '3072' 'dev sectors: sectors read + written'
eq "$(sb_dev_sectors sda "$DS")"       '300'  'dev sectors: a second device is not confused with the first'
eq "$(sb_dev_sectors nvme0n1 "$DS")"   '6144' 'dev sectors: the whole disk is a separate row from its partition'
eq "$(sb_dev_sectors nope "$DS")"      ''     'dev sectors: an unknown device is empty, not 0'
eq "$(sb_dev_sectors '' "$DS")"        ''     'dev sectors: no device name is empty'
eq "$(sb_dev_sectors sda /nonexistent/diskstats)" '' 'dev sectors: an unreadable file is empty, not an error'
rm -f "$DS"

# 2048 sectors x 512B = 1MiB, over 1s.
eq "$(sb_io_mbs 0 2048 1)"      '1'  'io: 2048 sectors in a second is 1 MB/s'
eq "$(sb_io_mbs 0 2048 2)"      '0'  'io: the same delta over 2s rounds down to 0'
eq "$(sb_io_mbs 0 204800 10)"   '10' 'io: 100MiB over 10s is 10 MB/s'
eq "$(sb_io_mbs 1000 1000 10)"  '0'  'io: an idle disk is 0, not a gap'
# The FIRST sample has no predecessor, and inventing 0 there would draw a floor
# under every chart at startup.
eq "$(sb_io_mbs '' 2048 10)"    ''   'io: no previous reading is a gap'
# A dock replug renumbers sda, so the counter restarts and the delta is nonsense.
eq "$(sb_io_mbs 5000 100 10)"   ''   'io: a counter that went backwards is a gap, not a spike'
eq "$(sb_io_mbs 0 2048 0)"      '1'  'io: a zero interval is treated as one second'
eq "$(sb_io_mbs 0 2048 junk)"   '1'  'io: a non-numeric interval is treated as one second'

# ── sb_hi_colour ──────────────────────────────────────────────────────────────
# Colour is suppressed here (not a tty), so what is asserted is that the tiers are
# DISTINCT and that garbage does not error — the escapes themselves are covered by
# the chart-colour block above.
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour 10 50 200)"  'd' 'hi_colour: a healthy value stays dim'
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour 50 50 200)"  'w' 'hi_colour: at the warn threshold it warns'
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour 200 50 200)" 'b' 'hi_colour: at the bad threshold it alarms'
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour '' 50 200)"  'd' 'hi_colour: no reading is dim, not alarming'
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour junk 50 200)" 'd' 'hi_colour: non-numeric is dim'
eq "$(C_DIM=d C_WARN=w C_BAD=b sb_hi_colour 9999 0 0)"   'd' 'hi_colour: zero thresholds disable both tiers'

# ── chart polarity ────────────────────────────────────────────────────────────
# A full battery painted red and a fully-reachable fleet painted red were both on
# screen (2026-07-29). The gradient's direction is per-metric, not global.
FLOOR="$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 0 8)"
CEIL="$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8)"
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8 hi-good)" "$FLOOR" 'polarity: hi-good paints a FULL chart green'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 0 8 hi-good)" "$CEIL"  'polarity: hi-good paints an EMPTY chart red'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8 hi-bad)"  "$CEIL"  'polarity: hi-bad is unchanged at the ceiling'
eq "$(STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8)"         "$CEIL"  'polarity: hi-bad is still the default'
# flat is for activity rather than condition — throughput, charge draw. One colour,
# because the glyph height already carries the magnitude.
eq "$(C_INFO=i STATUSBOARD_TRUECOLOR=1 sb_heat_color 0 8 flat)" 'i' 'polarity: flat is one accent colour at the floor'
eq "$(C_INFO=i STATUSBOARD_TRUECOLOR=1 sb_heat_color 7 8 flat)" 'i' 'polarity: and the same colour at the ceiling'
# End to end through sb_chart: a full flat-polarity chart must emit exactly one
# colour, and a hi-good one must not open in the alarm colour.
FLATC="$(C_RST=${ESC}'[0m' C_INFO=${ESC}'[36m' STATUSBOARD_TRUECOLOR=1 sb_chart 4 100 '100,100,100,100' flat)"
eq "$(count_sub "$FLATC" "${ESC}[36m")" '1' 'polarity: a flat chart emits its accent colour once'
GOODC="$(C_RST=${ESC}'[0m' STATUSBOARD_TRUECOLOR=1 sb_chart 4 100 '100,100,100,100' hi-good)"
has "$GOODC" "$FLOOR" 'polarity: a full hi-good chart is painted with the green end'
hasnt "$GOODC" "$CEIL" 'polarity: and never with the red end'

# ── a mount whose device vanished ─────────────────────────────────────────────
# Unplug a dock and the kernel keeps the mount, so df goes on reporting size, used
# and percentage from memory. On 2026-07-29 that showed two disks as healthy at 60%
# and 70% while the disks had come back as different device nodes, unmounted. df
# alone cannot be trusted; the row has to say so.
OUT="$(sb_disk_row sdb1 /mnt/public 312568828 60 976628732 gone)"
has "$OUT" 'gone'        'gone mount: says so where the bar was'
hasnt "$OUT" '[█'        'gone mount: draws no fill — the figure is a memory, not a reading'
hasnt "$OUT" '[░'        'gone mount: draws no bar at all'
has "$OUT" '/mnt/public' 'gone mount: still names the mount point'
has "$OUT" '60%'         'gone mount: keeps the last-known figure ("it was 60% when it went")'
# THE alignment invariant, which a differently-shaped row is exactly how you break.
eq "$(sb_vislen "$OUT")" \
   "$(sb_vislen "$(sb_disk_row sdb1 /mnt/public 312568828 60 976628732 ok)")" \
   'gone mount: the row is the same visible width as a live one'
# Default is live, so every existing caller and test keeps its old meaning.
hasnt "$(sb_disk_row sdb1 /mnt/public 312568828 60 976628732)" 'gone' \
  'gone mount: omitting the state means live'
# A vanished device has no drive to name — sb_disk_of cannot resolve a node that is
# gone — so the bay column carries the PARTITION node, the only identity left. Passing
# a bay anyway must not override that.
has "$(sb_disk_row sdb1 /mnt/public 312568828 60 976628732 gone '' 1 sdb)" 'sdb1' \
  'gone mount: the bay column falls back to the partition node'

# ── Physical bays ─────────────────────────────────────────────────────────────
# Real sysfs paths from latitude, captured 2026-08-01. The point of every one of them
# is that the DRIVE'S OWN hop wins: sdg hangs off port 4 of a hub on 2-1, and the slot
# is the hub port, not the hub.
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:14.0/usb4/4-1/4-1:1.0/host0/target0:0:0/0:0:0:0)" \
   'u4-1:0' 'bay: a single-bay dock is its port and LUN 0'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:14.0/usb4/4-2/4-2:1.0/host2/target2:0:0/2:0:0:0)" \
   'u4-2:0' 'bay: the first bay of a two-bay dock'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:14.0/usb4/4-2/4-2:1.0/host2/target2:0:0/2:0:0:1)" \
   'u4-2:1' 'bay: the second bay of the SAME bridge differs only in the LUN'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:0d.0/usb2/2-1/2-1.4/2-1.4:1.0/host4/target4:0:0/4:0:0:0)" \
   'u2-1.4:0' 'bay: a drive behind a hub names the hub PORT, not the hub'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:0d.0/usb2/2-2/2-2:1.0/host1/target1:0:0/1:0:0:0)" \
   'u2-2:0' 'bay: a drive plugged straight into the machine'
# NVMe has no bay anyone hot-swaps, and the controller name is already stable.
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:06.0/0000:01:00.0/nvme/nvme0)" \
   'nvme0' 'bay: an NVMe controller is its own name'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:1d.0/0000:73:00.0/nvme/nvme1)" \
   'nvme1' 'bay: the second NVMe is not confused with the first'
# `target2:0:0` has three fields and starts with a letter; `4-2:1.0` carries a colon.
# Both sit on the path of every USB disk, and mistaking either for the SCSI address or
# the port would put the wrong number in every label.
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:1f.2/ata3/host2/target2:0:0/2:0:0:0)" \
   'ata3:0' 'bay: a plain SATA disk falls back to its ata link'
eq "$(sb_bay_tag_parse /sys/devices/pci0000:00/0000:00:07.0/virtio3/block/vda)" '' \
   'bay: a bus this parser does not know yields nothing, not a guess'
eq "$(sb_bay_tag_parse '')" '' 'bay: no path is not an error'

# The map is a rename LAYER over those tags: an unmapped drive shows the tag, and a
# drive whose tag could not be derived shows the fallback the caller passes.
BM="$(sb_diskmap_parse bay "$(printf '%s\n' \
  '# the two-bay dock on the left' \
  'bay u4-2:0  dockB0' \
  'bay u4-2:1  dockB1   trailing junk' \
  'transient /mnt/xs' \
  'nonsense line' \
  'bay u2-2:0  waaaaaaaaaaaytoolong')")"
eq "$(sb_bay_label u4-2:1 "$BM" sdd)" 'dockB1' 'bay: a mapped tag shows its label'
eq "$(sb_bay_label u4-1:0 "$BM" sdb)" 'u4-1:0' 'bay: an unmapped tag shows the tag itself'
eq "$(sb_bay_label '' "$BM" sdb)"     'sdb'    'bay: no tag falls back to the device name'
# Clipped, not allowed to run long: the disk block pads every row to the widest one and
# the chart column starts after it, so one long label would move the charts for its row.
BM_LAB="$(sb_bay_label u2-2:0 "$BM" sda)"
eq "${#BM_LAB}" "$SB_DISK_BAYW" 'bay: an over-long label is clipped to the column width'
# A typo must cost a label, never the board: unknown directives are ignored.
eq "$(sb_bay_label u9-9:9 "$BM" sdz)" 'u9-9:9' 'bay: a nonsense line maps nothing'

# transient: keyed by MOUNT POINT, because a vanished device resolves to no drive and
# the mount point is the only key left to recognise it by.
TM="$(sb_diskmap_parse transient "$(printf '%s\n' 'transient /mnt/xs' 'bay u4-1:0 dockA')")"
transient() { if sb_transient "$1" "$TM"; then printf yes; else printf no; fi; }
eq "$(transient /mnt/xs)"  yes 'transient: the declared mount is transient'
eq "$(transient /mnt/immich)" no 'transient: an undeclared mount is not'
eq "$(transient /mnt)"     no  'transient: a PREFIX of the declared mount is not it'
eq "$(transient '')"       no  'transient: an empty mount is not transient'
eq "$(sb_diskmap_parse bay "$TM")" '' 'diskmap: directives do not leak into each other'

# The bay store is REBUILT every probe, never filled in per node. An sd letter is
# handed out lowest-free, so a replug gives the same letter to a different disk in a
# different bay — latitude painted `dockB0` on two rows at once because `sdd` kept the
# label it was given in an earlier plug cycle (2026-08-19). The stub moves sdd from
# u4-2:0 to u4-1:0 between calls, which is exactly what the kernel log showed.
RM="$(sb_diskmap_parse bay "$(printf '%s\n' \
  'bay u4-1:0 dockA0' 'bay u4-1:1 dockA1' 'bay u4-2:0 dockB0' 'bay u4-2:1 dockB1')")"
BAY_SDD=u4-2:0
sb_bay_tag() { case "${1:-}" in sdd) printf '%s' "$BAY_SDD" ;; sdg) printf 'u4-2:0' ;; *) printf '' ;; esac; }
eq "$(sb_series_get "$(sb_bays_resolve "$RM" sdd)" sdd)" 'dockB0' 'bays: a drive gets its slot label'
BAY_SDD=u4-1:0
eq "$(sb_series_get "$(sb_bays_resolve "$RM" sdd)" sdd)" 'dockA0' 'bays: a REUSED node re-resolves, it is not kept'
# The rebuild is also the prune: a drive that is gone is simply absent from the list.
eq "$(sb_series_get "$(sb_bays_resolve "$RM" sdg)" sdd)" '' 'bays: a vanished drive leaves no entry'
eq "$(sb_series_get "$(sb_bays_resolve "$RM" sdg)" sdg)" 'dockB0' 'bays: the drive now in that bay owns the label'
# Two drives can never hold one label, which is the symptom the user saw.
BAYS_BOTH="$(sb_bays_resolve "$RM" sdd sdg)"
eq "$(sb_series_get "$BAYS_BOTH" sdd)" 'dockA0' 'bays: one label per bay, first drive'
eq "$(sb_series_get "$BAYS_BOTH" sdg)" 'dockB0' 'bays: one label per bay, second drive'
# A drive whose tag cannot be derived falls back to its own node name, as before.
eq "$(sb_series_get "$(sb_bays_resolve "$RM" sdz)" sdz)" 'sdz' 'bays: no tag falls back to the device name'
unset -f sb_bay_tag

# Eject safety: two fields, reads and writes in flight. Either one nonzero means
# pulling the cable now loses data, which is the only thing between "nothing is
# mounted" and "safe to unplug".
eq "$(sb_inflight_busy '       0        0')" '0' 'eject: an idle drive is safe'
eq "$(sb_inflight_busy '       1        0')" '1' 'eject: a read in flight is busy'
eq "$(sb_inflight_busy '       0       12')" '1' 'eject: a write in flight is busy'
eq "$(sb_inflight_busy '')" '0' 'eject: an unreadable node is not called busy'
eq "$(sb_inflight_busy 'junk')" '0' 'eject: nonsense is not called busy'

# A ZERO-SIZE disk is an empty card-reader slot, not a disk. This box carries a
# two-slot reader whose nodes exist whether or not a card is in them, so the board
# warned permanently about two "unmounted disks" that were empty slots (2026-08-01).
# The fixture is real `lsblk -rno NAME,TYPE,SIZE,MOUNTPOINT` output.
LSB="$(printf '%s\n' \
  'sda disk 931.5G' \
  'sda1 part 931.4G /mnt/immich-2024' \
  'sdb disk 298.1G' \
  'sdb1 part 298.1G' \
  'sde disk 0B' \
  'sdf disk 0B' \
  'nvme0n1 disk 476.9G' \
  'nvme0n1p1 part 461.1G /')"
eq "$(sb_unmounted_parse "$LSB")" 'sdb|298.1G' 'unmounted: only the disk with nothing mounted'
hasnt "$(sb_unmounted_parse "$LSB")" 'sde' 'unmounted: an empty card slot is not an unmounted disk'
hasnt "$(sb_unmounted_parse "$LSB")" 'sdf' 'unmounted: neither is the second slot'
hasnt "$(sb_unmounted_parse "$LSB")" 'nvme0n1' 'unmounted: the root disk is mounted through a partition'
# Put a card in and it acquires a size — at which point it IS a disk and being told
# about it is the entire point of the row.
has "$(sb_unmounted_parse "$(printf '%s\n' 'sde disk 29.7G')")" 'sde|29.7G' \
  'unmounted: a slot with a card in it counts again'
eq "$(sb_unmounted_parse '')" '' 'unmounted: no input is not an error'

# sb_mounts must decide liveness by the DEVICE NODE. stat()ing the mount point would
# block on a dead NFS mount and reading it would spin up a sleeping disk every probe.
MSRC="$(awk '/^sb_mounts\(\)/,/^}/' "$REPO/provision/statusboard/statusboard.sh")"
has "$MSRC" '[ -b "/dev/$dev" ]' 'mounts: liveness is the block device node existing'
has "$MSRC" 'state=gone'         'mounts: emits a gone state'
hasnt "$MSRC" 'stat '            'mounts: does not stat the mount point'
# The list is ORDERED by drive, which is the whole basis of the grouping in the disk
# block: adjacency is only sound if the rows of one bay arrive together. Root's drive
# leads, because / is the row on this board most likely to be read first.
has "$MSRC" 'sort -t$'"'"'\t'"'"' -k1,1n -k2,2 -k3,3' 'mounts: output is sorted by drive, then mount'
has "$MSRC" 'if (mnt == "/") root = disk' 'mounts: the ROOT DRIVE is what ranks first'
has "$MSRC" 'sub(/p?[0-9]+$/, "", disk)' 'mounts: the sort key strips the partition suffix'

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

# ── The tailnet (sb_ts_parse) ─────────────────────────────────────────────────
# Fixtures are real `tailscale status --peers` lines, trailing padding included —
# that padding is why the counter this replaced was wrong, so a test that trims it
# would test the wrong text.
TS_FIX="$(printf '%s\n' \
  '100.64.0.7  air               fleet  macOS    -                                            ' \
  '100.64.0.6  desktop-ubuntu26  fleet  linux    -                                            ' \
  '100.64.0.4  desktop           fleet  windows  active; direct 192.168.8.145:41641, tx 4 rx 1' \
  '100.64.0.1  hub               fleet  linux    -                                            ' \
  '100.64.0.5  ipheoryt12        fleet  iOS      offline, last seen 1d ago                    ' \
  '100.64.0.8  latitude          fleet  linux    active; relay "fra", tx 137496 rx 129592      ' \
  '100.64.0.3  server            fleet  windows  -                                            ')"
TS_OUT="$(printf '%s\n' "$TS_FIX" | sb_ts_parse 100.64.0.8)"

# Six peers, five up: idle ("-") is ONLINE, only the iOS node is down, and self is
# neither counted nor listed.
eq "$(printf '%s\n' "$TS_OUT" | head -1)" 'up|100.64.0.8|5|6' 'tailnet: summary is self, online, total'
eq "$(printf '%s\n' "$TS_OUT" | grep -c '^100\.')" '6' 'tailnet: one line per peer'
hasnt "$TS_OUT" '|latitude|' 'tailnet: self is not one of its own peers'
# The three connection shapes, and the OS column carried through for the fleet page.
has "$TS_OUT" '100.64.0.4|desktop|windows|direct|' 'tailnet: an active direct session'
has "$TS_OUT" '100.64.0.1|hub|linux|idle|' 'tailnet: "-" is idle, not offline'
has "$TS_OUT" '100.64.0.5|ipheoryt12|iOS|offline|1d' 'tailnet: offline carries its last-seen age'
# A relayed peer is up, and DERP-vs-direct is a distinction the board should keep:
# the fleet still works over a relay, it just works worse.
TS_RELAY="$(printf '%s\n' '100.64.0.9  air  fleet  macOS  active; relay "fra", tx 1 rx 2' | sb_ts_parse 100.64.0.8)"
has "$TS_RELAY" '|air|macOS|relay|' 'tailnet: a relayed peer is up, and says so'
eq "$(printf '%s\n' "$TS_RELAY" | head -1)" 'up|100.64.0.8|1|1' 'tailnet: a relayed peer counts as online'
# Degradations. A fork that produced nothing is NOT a tailnet with no peers: a live
# daemon always prints its own line, so no output means the fork failed or timed out.
# Reporting that as up|0|0 would paint "I am alone" and "I cannot see" identically, and
# the alert strip would read it as healthy.
eq "$(printf '' | sb_ts_parse 100.64.0.8)" 'down|100.64.0.8||' 'tailnet: an empty fork is down, not 0 peers'
eq "$(printf '%s\n' '100.64.0.5  ipheoryt12  fleet  iOS  offline' | sb_ts_parse 100.64.0.8 | head -1)" \
  'up|100.64.0.8|0|1' 'tailnet: offline with no last-seen still parses'
eq "$(printf '%s\n' '# Health check:' '#   - some warning' '100.64.0.1  hub  fleet  linux  -' \
  | sb_ts_parse 100.64.0.8 | head -1)" 'up|100.64.0.8|1|1' 'tailnet: health-check preamble is not a peer'

# ── Containers (sb_mib / sb_dk_short) ─────────────────────────────────────────
# MiB, because GiB rounds every container on this box to 0 or 1.
eq "$(sb_mib 967135232)" '922M'  'mib: a container under a gibibyte reads in MiB'
eq "$(sb_mib 1073741824)" '1.0G' 'mib: a gibibyte switches unit'
eq "$(sb_mib 3221225472)" '3.0G' 'mib: and keeps one decimal above it'
eq "$(sb_mib 0)" '0M'            'mib: zero is a reading, not an absence'
# A stopped container has no cgroup, so the file is missing rather than zero.
eq "$(sb_mib '')" 'n/a'          'mib: no cgroup is n/a, not 0'
eq "$(sb_mib junk)" 'n/a'        'mib: non-numeric is n/a'

# docker's status prose is up to 26 characters of which four carry information, and the
# frame's binding constraint is width.
eq "$(sb_dk_short 'Up 20 minutes (healthy)')" 'up 20m healthy' 'dk: minutes and a health note'
eq "$(sb_dk_short 'Up About an hour (healthy)')" 'up 1h healthy' 'dk: "About an hour" is 1h'
eq "$(sb_dk_short 'Up 2 hours')" 'up 2h' 'dk: no health check, no note'
eq "$(sb_dk_short 'Up 3 weeks')" 'up 3w' 'dk: weeks'
eq "$(sb_dk_short 'Exited (0) 5 minutes ago')" 'exited (0) 5m' 'dk: the exit code is kept, the "ago" is not'
eq "$(sb_dk_short 'Restarting (1) 3 seconds ago')" 'restarting (1) 3s' 'dk: a restart loop keeps its code'
eq "$(sb_dk_short 'Created')" 'created' 'dk: a created container has no age yet'
# UPPERCASE deliberately: a container that is up and failing its own health check is the
# most useful thing the page can say, and it is invisible in any running/total count.
eq "$(sb_dk_short 'Up 5 minutes (unhealthy)')" 'up 5m UNHEALTHY' 'dk: unhealthy is shouted'
eq "$(sb_dk_short 'Up 5 seconds (health: starting)')" 'up 5s starting' 'dk: a health check still warming up'
eq "$(sb_dk_short '')" '' 'dk: no status is not an error'

# ── The fleet (sb_fleet_parse / sb_fleet_join) ────────────────────────────────
# The real manifest, not a fixture: this parse is anchored on fleet.json's INDENT, so
# the thing worth asserting is that it still matches the file the repo actually ships.
FLEET="$(sb_fleet_parse < "$REPO/fleet.json")"
eq "$(printf '%s\n' "$FLEET" | wc -l | tr -d ' ')" \
   "$(grep -cE '^    "[^"]+": \{$' "$REPO/fleet.json" | tr -d ' ')" \
   'fleet: every machine in the manifest is parsed'
has "$FLEET" 'latitude|100.64.0.8|debian|latitude5520' 'fleet: name, tailnet IP, platform and OS hostname'
has "$FLEET" 'hub|100.64.0.1|debian|27608' 'fleet: the VPS parses like any other member'
# The roles array and the ssh block sit in the same machine block and are full of
# quoted strings — neither may leak into a field.
hasnt "$FLEET" 'base' 'fleet: the roles array is not mistaken for a field'
hasnt "$FLEET" 'methe' 'fleet: the ssh block is not mistaken for a field'

# The join is what the page renders. States, in the order they matter.
#
# A SYNTHETIC manifest on purpose. sb_fleet_parse above is what pins the REAL
# fleet.json (that assertion is the whole reason it reads the shipped file); the
# join's semantics have nothing to do with who is in the fleet this month. These
# rows used to be the real manifest's, which meant every membership change broke
# three assertions down here — removing `server` on 2026-08-01 did exactly that,
# and the join code was correct throughout. `oldbox` is deliberately not a real
# member: five rows keep all five join states coverable with a four-member fleet.
FLEETX="$(printf '%s\n' \
  'latitude|100.64.0.8|debian|latitude5520' \
  'desktop|100.64.0.4|windows|g614jv' \
  'oldbox|100.64.0.3|windows|oldbox5000' \
  'hub|100.64.0.1|debian|27608' \
  'air|100.64.0.7|darwin|air')"
FPEERS="$(printf '%s\n' \
  '100.64.0.4|desktop|windows|direct|' \
  '100.64.0.3|oldbox|windows|offline|3d' \
  '100.64.0.1|hub|linux|relay|' \
  '100.64.0.9|somephone|iOS|idle|')"
FJ="$(sb_fleet_join "$FLEETX" "$FPEERS" 100.64.0.8 1)"
has "$FJ" 'latitude|100.64.0.8|debian|self|'    'join: the box running the board is self'
has "$FJ" 'desktop|100.64.0.4|windows|direct|'  'join: an active session is direct'
has "$FJ" 'oldbox|100.64.0.3|windows|offline|3d' 'join: an offline member keeps its last-seen age'
has "$FJ" 'hub|100.64.0.1|debian|relay|'        'join: a relayed member is distinguishable from a direct one'
# The failure a peer COUNT cannot express: air is in the manifest and not on the
# tailnet, so it is a ROW that says so rather than a number that never mentions it.
has "$FJ" 'air|100.64.0.7|darwin|missing|'      'join: a member absent from the tailnet is missing'
# Non-fleet nodes are counted apart, so a phone cannot flatter the fleet's own numbers.
has "$FJ" '_others|1|1|'                        'join: non-fleet nodes are counted separately'
hasnt "$FJ" 'somephone'                         'join: a non-fleet node gets no row of its own'
# Nothing was learned about the peers, so nothing is claimed about them. Five red rows
# for one local fault would bury the single alert that is true.
FJD="$(sb_fleet_join "$FLEETX" "" "" 0)"
eq "$(printf '%s\n' "$FJD" | grep -c 'unknown')" '5' 'join: an unreadable local tailnet makes every member unknown'
hasnt "$FJD" 'missing' 'join: an unreadable local tailnet accuses nobody of being missing'
eq "$(printf '%s\n' "$FJD" | grep -c '_others|0|0')" '1' 'join: and counts no strangers either'
# No manifest is not an empty fleet.
eq "$(sb_fleet_join "" "$FPEERS" 100.64.0.8 1 | grep -cv '^_others')" '0' 'join: no manifest yields no member rows'

# ── The alert strip (sb_alert_line) ───────────────────────────────────────────
# Escapes are stripped before comparing: whether the helpers emit colour depends on
# whether the TEST's stdout is a terminal, so an exact-string assertion that kept them
# would pass in CI and fail for a human running the same file.
plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'; }

# No alerts is not an empty strip. "all clear" is how a working strip says nothing is
# wrong — an empty line is indistinguishable from a strip that broke.
eq "$(plain "$(sb_alert_line)")" 'all clear' 'strip: no alerts reads as all clear'
eq "$(plain "$(sb_alert_line '')")" 'all clear' 'strip: an empty alert is not an alert'
# Alert texts contain spaces. The list is built by index for exactly this reason: an
# unquoted array expansion would split "2 units failed" into three alerts.
eq "$(plain "$(sb_alert_line 'bad:2 units failed')")" '2 units failed' \
  'strip: an alert keeps its spaces'
# Worst first, whatever order they arrive in: a dead mount and a slow peer are not the
# same news, and the strip is read left to right.
eq "$(plain "$(STATUSBOARD_RAMP=ascii sb_alert_line 'warn:1 peer offline' 'bad:tailnet down')")" \
  'tailnet down | 1 peer offline' 'strip: bad alerts are listed before warnings'
# Colour is the WORST severity's, not the first one's.
eq "$(count_sub "$(C_BAD=${ESC}'[31m' C_WARN=${ESC}'[33m' sb_alert_line 'warn:x' 'bad:y')" "${ESC}[31m")" '1' \
  'strip: one bad alert makes the whole strip bad-coloured'
eq "$(count_sub "$(C_BAD=${ESC}'[31m' C_WARN=${ESC}'[33m' sb_alert_line 'warn:x' 'warn:y')" "${ESC}[31m")" '0' \
  'strip: warnings alone stay amber'
# An unknown severity is treated as a warning rather than dropped: an alert nobody can
# classify is still an alert, and silently swallowing it is the one failure mode this
# line exists to prevent.
eq "$(plain "$(sb_alert_line 'weird:something')")" 'something' 'strip: an unknown severity still shows'
# The separator follows the ramp, like every other glyph: U+00B7 is not in the VT font.
has "$(plain "$(STATUSBOARD_RAMP=ascii sb_alert_line 'bad:a' 'bad:b')")" 'a | b' \
  'strip: a VT gets an ASCII separator'
has "$(plain "$(STATUSBOARD_RAMP=height sb_alert_line 'bad:a' 'bad:b')")" 'a · b' \
  'strip: everything else gets the middle dot'

# ── Severity policy (sb_fleet_alerts / sb_docker_alerts) ──────────────────────
# What is worth waking someone for. Both take one argument precisely so this judgement is
# testable — the strip's other half, sb_alerts, has to read a dozen globals.
# `server` below is raw input, not a manifest lookup — sb_fleet_alerts is handed
# rows directly, so the name is arbitrary and stayed put when the member was
# removed from fleet.json on 2026-08-01. Same for the sb_ts_parse fixture above.
FA="$(sb_fleet_alerts "$(printf '%s\n' \
  'latitude|100.64.0.8|debian|self|' \
  'desktop|100.64.0.4|windows|direct|' \
  'server|100.64.0.3|windows|offline|3d' \
  'hub|100.64.0.1|debian|missing|' \
  '_others|2|1||')")"
# Missing outranks offline: offline is a box that is switched off, missing is a box that is
# no longer enrolled at all.
has "$FA" 'bad:hub missing'        'severity: a member off the tailnet is bad'
has "$FA" 'warn:server offline 3d' 'severity: a member that is merely off is a warning, with its age'
hasnt "$FA" 'latitude'             'severity: the board does not alert about itself'
hasnt "$FA" 'desktop'              'severity: a healthy member is not an alert'
hasnt "$FA" '_others'              'severity: non-fleet nodes never alert'
eq "$(sb_fleet_alerts '')" ''      'severity: no fleet rows, no alerts'

DA="$(sb_docker_alerts "$(printf '%s\n' \
  'immich_server|running|up 2h healthy|916M|3' \
  'immich_redis|running|up 5m UNHEALTHY|32M|0' \
  'jellyfin|exited|exited (0) 5m||' \
  'immich_db|restarting|restarting (1) 3s||' \
  'old_thing|created|created||')")"
# A container that is up and failing its own health check is invisible in any
# running/total count, and its STATE field says `running` — so the status is checked first.
has "$DA" 'bad:immich_redis unhealthy' 'severity: unhealthy outranks a running state'
has "$DA" 'bad:jellyfin exited'        'severity: an exited service is bad'
has "$DA" 'warn:immich_db restarting'  'severity: a restart loop is a warning, not yet a failure'
has "$DA" 'warn:old_thing created'     'severity: a created-but-never-started container is a warning'
hasnt "$DA" 'immich_server'            'severity: a healthy container is not an alert'
eq "$(sb_docker_alerts '')" ''         'severity: no containers, no alerts'

# ── Page tabs ─────────────────────────────────────────────────────────────────
# The VISIBLE width must not depend on which page is active — only the colour moves —
# or the alert text beside the tabs shifts every time the board rotates.
eq "$(plain "$(sb_page_tabs 0 system fleet docker)")" 'system fleet docker' 'tabs: every page is listed'
eq "$(plain "$(sb_page_tabs 2 system fleet docker)")" 'system fleet docker' 'tabs: the text is the same on any page'
t0="$(sb_page_tabs 0 system fleet docker)"; t2="$(sb_page_tabs 2 system fleet docker)"
eq "$(sb_vislen "$t0")" "$(sb_vislen "$t2")" 'tabs: visible width does not move with the active page'
eq "$(count_sub "$(C_B=${ESC}'[1m' sb_page_tabs 1 system fleet docker)" "${ESC}[1m")" '1' \
  'tabs: exactly one page is lit'

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
has "$OUT" '1m/cell'      'layout: the header names the cell duration in readable units'
has "$OUT" '10s samples'  'layout: the header also names the sample cadence'
OUT_FAST="$(STATUSBOARD_COLS=120 STATUSBOARD_CELL=10 bash "$REPO/provision/statusboard/statusboard.sh" --once 2>&1)"
has "$OUT_FAST" '10s/cell' 'layout: STATUSBOARD_CELL reaches the axis label'
# Nothing may exceed the width — a frame one cell too wide wraps and the whole
# display walks up the screen on every repaint.
eq "$(printf '%s\n' "$OUT" | awk '{ if (length($0) > 120) c++ } END { printf "%d", c+0 }')" '0' \
  'layout: no row is wider than the terminal'
# Every charted row must end at the SAME column, or the column is not a column.
# `lan` is deliberately absent from this list: it no longer has a chart, so it is
# free to run short like any other uncharted row.
eq "$(printf '%s\n' "$OUT" | awk '/^(battery|source|internet|tailnet|uptime|\/|<)/ { print length($0) }' | sort -u | wc -l | tr -d ' ')" '1' \
  'layout: all charted rows end at the same column (disk rows included)'
# The lan chart was a binary series at a ceiling of 1: every cell the top glyph, in
# the loudest colour on the board, saying what the ok/down glyph already said.
lan_len="$(printf '%s\n' "$OUT" | awk '/^lan /{ print length($0); exit }')"
bat_len="$(printf '%s\n' "$OUT" | awk '/^battery /{ print length($0); exit }')"
[ -n "$lan_len" ] && [ -n "$bat_len" ] && [ "$lan_len" -lt "$bat_len" ] \
  && pass 'layout: the lan row has no chart' \
  || fail "layout: lan should be uncharted (lan=$lan_len charted=$bat_len)"
# The legend is a per-row COLUMN at the right edge, not a footer: one chart column
# carrying six metrics has to say which is which where the eye already is.
# The tailnet row counts the FLEET where there is a manifest to define one, and raw
# tailnet peers only where there is not — so the chart's label names which. Counting
# peers meant a sleeping phone sat the row permanently amber, and a warning colour that
# is always on says nothing.
has "$OUT" ' fleet' 'layout: the tailnet chart is labelled for the fleet it counts'
NOFLEET_OUT="$(STATUSBOARD_FLEET_JSON=/nonexistent/fleet.json STATUSBOARD_COLS=120 \
  STATUSBOARD_RAMP=ascii bash "$REPO/provision/statusboard/statusboard.sh" --once 2>&1)"
has "$NOFLEET_OUT" ' peers' 'layout: with no manifest it falls back to counting peers'
has "$OUT" ' MB/s'  'layout: the disk charts are labelled'
has "$OUT" ' load'  'layout: the load chart is labelled'
has "$OUT" ' ms'    'layout: the latency charts are labelled'
# Flush right, so the frame has a straight right edge — and because the widest label
# ends its line, no row carries trailing whitespace.
eq "$(printf '%s\n' "$OUT" | grep -c ' $')" '0' 'layout: no row ends in whitespace'
# Every charted row's label sits in the same column, or it is not a column.
eq "$(printf '%s\n' "$OUT" | awk '/^(battery|source|internet|tailnet|uptime|\/|<)/ { print length($0) }' | sort -u | wc -l | tr -d ' ')" '1' \
  'layout: the unit column ends every charted row at the same place'
# A whole disk row, end to end: bar, percentage, size. Asserted as a shape rather
# than a literal so the fields can be reordered without a false failure, and as a
# COUNT so a frame that lost its disk block cannot pass.
disk_rows="$(printf '%s\n' "$OUT" | grep -cE '\[[#.]+\] *[0-9]+% +[0-9]+G')"
[ "${disk_rows:-0}" -ge 1 ] \
  && pass 'layout: the frame lists filesystems as bar + percentage + size' \
  || fail "layout: no disk row matched bar+pct+size (got $disk_rows)"
hasnt "$OUT" 'G / ' 'layout: the used/total pair is gone from the frame'
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

# The tailnet costs ONE fork per probe. It used to cost two — one counting peers, one
# counting the online ones — and the second bought nothing even before the per-peer
# parse existed.
# Comment lines stripped first — the rewrite's rationale names the command more often
# than the code runs it, and counting prose would make this assert nothing.
eq "$(grep -vE '^[[:space:]]*#' "$SB" | grep -c 'tailscale status')" '1' \
  'cadence: the tailnet is one fork per probe'
# And it is bounded. Everything else on the slow path already is (ping -W1, df on
# live devices only); an unbounded socket call to a wedged tailscaled would freeze the
# clock painted beside it.
grep -q 'sb_bounded 5 tailscale status' "$SB"; eq "$?" '0' 'cadence: the tailnet fork cannot hang the paint loop'
grep -q 'sb_bounded 2 docker ps' "$SB"; eq "$?" '0' 'cadence: nor can the docker fork'
# …and resolved, not assumed: a box with no coreutils `timeout` must still read its
# tailnet rather than report it permanently down (which is what macOS did).
grep -q 'command -v timeout' "$SB"; eq "$?" '0' 'cadence: a box without timeout still reads its tailnet'

# ── Pages ─────────────────────────────────────────────────────────────────────
# The page list is read out of the script rather than repeated here, so a page added
# in step N is exercised by these assertions without touching this file.
PAGES="$(grep -oE '^SB_PAGES=\([^)]*\)' "$SB" | sed -E 's/^SB_PAGES=\(//; s/\)$//')"
[ -n "$PAGES" ]; eq "$?" '0' 'pages: the script declares a page list'
# Three widths, not one: 146 is the kiosk's real pane (cage -> foot -> tmux, measured on
# latitude), 120 is the tmux window over SSH, and 80 is narrow enough that the chart column
# collapses entirely — a different print path for every row on every page.
for pgw in 146 120 80; do
  for pg in $PAGES; do
    POUT="$(STATUSBOARD_COLS=$pgw STATUSBOARD_RAMP=ascii bash "$SB" --once --page "$pg" 2>&1)"; prc=$?
    eq "$prc" '0' "pages: --once --page $pg exits 0 at ${pgw}c"
    # Every page pays the same width rule. A page whose rows are one cell too wide wraps,
    # and a wrapped row makes the whole repainting frame walk up the screen — which is
    # invisible in a test that only ever renders page 1.
    #
    # The docker page is why the widths are a loop: container names are unbounded, and one
    # `docker compose run` name (34 characters, seen on the mac) is enough to push the text
    # column past a narrow frame.
    eq "$(printf '%s\n' "$POUT" | awk -v w="$pgw" '{ if (length($0) > w) c++ } END { printf "%d", c+0 }')" '0' \
      "pages: no row on $pg is wider than ${pgw}c"
    # And every page carries the strip, because that is the whole reason rotating is safe.
    # The strip's left field is the whole tab list, which is why this matches the pages
    # joined by spaces rather than any single page name — the docker page has a `docker`
    # ROW of its own, and matching one name at a time counted that as a second strip.
    eq "$(printf '%s\n' "$POUT" | grep -cE "^(alerts|$PAGES) " | tr -d ' ')" '1' \
      "pages: $pg carries exactly one alert strip at ${pgw}c"
    # Trailing whitespace on any page, for the same reason as on the first one: it is
    # invisible until something diffs the frame or a terminal reflows it.
    eq "$(printf '%s\n' "$POUT" | grep -c '[[:space:]]$' | tr -d ' ')" '0' \
      "pages: no row on $pg ends in whitespace at ${pgw}c"
  done
done
# Both docker bounds must stay wired: container rows are capped because `docker ps -a`
# counts exited containers, which accumulate for as long as compose has been running here,
# and the name column is capped because `docker compose run` mints unbounded names. Neither
# bound comes from docker.
grep -q 'SB_DK_ROWS="\${STATUSBOARD_DOCKER_ROWS:-18}"' "$SB"; eq "$?" '0' 'pages: the container list is capped'
grep -q 'shown" -ge "\$SB_DK_ROWS" \] && break 2' "$SB"; eq "$?" '0' 'pages: and the cap is enforced in the emitter'
grep -q 'more not shown' "$SB"; eq "$?" '0' 'pages: a truncated container list says so'
grep -q 'SB_DK_NAMEW="\${STATUSBOARD_DOCKER_NAMEW:-24}"' "$SB"; eq "$?" '0' 'pages: the container name column is capped'
# The fleet page's whole point is naming members, not counting peers.
FOUT="$(STATUSBOARD_COLS=120 STATUSBOARD_RAMP=ascii bash "$SB" --once --page fleet 2>&1)"
for m in $(sb_fleet_parse < "$REPO/fleet.json" | cut -d'|' -f1); do
  has "$FOUT" "$m" "fleet page: $m has a row"
done
# No manifest is a page that says so, not a blank page: a board running outside the
# repo (or over a checkout mid-rebuild) must not look like a fleet of zero machines.
NOFLEET="$(STATUSBOARD_FLEET_JSON=/nonexistent/fleet.json STATUSBOARD_COLS=120 \
  bash "$SB" --once --page fleet 2>&1)"
has "$NOFLEET" 'no fleet manifest' 'fleet page: a missing manifest says so'
# An unknown page name is a usage error, not a silent fall back to page 1: --page is
# how a test or a human asks for one specific page, and painting a different one is a
# wrong answer that looks like a right one.
bash "$SB" --once --page nosuchpage >/dev/null 2>&1
eq "$?" '2' 'pages: an unknown --page name exits 2'

# The keyboard must never turn the kiosk into a spin loop. `read -t` with stdin closed
# or redirected returns instantly, every iteration, forever — so the read is guarded on
# stdin being a TERMINAL (-t 0), not on stdout being one, and a board with no keyboard
# sleeps exactly as it did before pages existed.
grep -q 'if \[ ! -t 0 \]; then sleep "\$INTERVAL"' "$SB"
eq "$?" '0' 'pages: no keyboard means sleep, not a busy read'
grep -q 'IFS= read -r -s -t "\$INTERVAL" -n 1 key' "$SB"; eq "$?" '0' 'pages: a keypress is acted on without waiting out the interval'
# Without IFS= the SPACE key is word-split away and arrives as an empty string, so the
# hold did nothing whatsoever — measured 2026-07-31, and invisible until then because
# every other binding is a non-whitespace character.
grep -q 'IFS= read' "$SB"; eq "$?" '0' 'keys: space survives the read instead of being word-split away'

# ── Arrow keys and the dwell ──────────────────────────────────────────────────
# An arrow is ESC [ C — THREE bytes. Read one byte per iteration they arrive as three
# keystrokes and the second is a bare `[`, which meant "previous page": that is why
# both arrows paged backwards and why pressing one killed the rotation for good
# (2026-07-31). The tail must be drained inside the same call.
grep -qF 'if [ "$key" = $'"'"'\033'"'"' ]' "$SB"
eq "$?" '0' 'keys: an escape sequence is recognised as one keystroke'
grep -qF 'read -r -s -t 0.05 -n 2 rest' "$SB"
eq "$?" '0' 'keys: the two bytes after ESC are drained in the same call'
grep -q "'\[C' | 'OC'" "$SB"; eq "$?" '0' 'keys: right arrow, in both cursor modes'
grep -q "'\[D' | 'OD'" "$SB"; eq "$?" '0' 'keys: left arrow, in both cursor modes'
# The rotation must resume by itself: a manual pick DWELLS, it does not hold forever.
# Space remains the explicit indefinite hold.
grep -q 'SB_PAGE_SECS="\${STATUSBOARD_PAGE_SECS:-5}"' "$SB"
eq "$?" '0' 'pages: the rotation is five seconds a page'
grep -q 'SB_PAGE_MANUAL_SECS="\${STATUSBOARD_PAGE_MANUAL_SECS:-60}"' "$SB"
eq "$?" '0' 'pages: a hand-picked page dwells for a minute'
# A bash signal handler resumes the script when it returns, so a trap that only tidies
# up does not STOP anything: the board outlived SIGTERM indefinitely (measured on
# latitude 2026-07-31) and every systemctl stop paid the 90s timeout and a SIGKILL.
grep -qF "trap 'cleanup; exit 0' INT TERM HUP" "$SB"
eq "$?" '0' 'signals: the board exits on a signal instead of resuming'
# The paint must OVERWRITE, never erase-then-draw: `\033[2J` as its own write left the
# pane momentarily blank, and tmux flushed that blank downstream — a blink every 2-5s on
# a 1s loop (reported 2026-07-31). Both directions are asserted, because reintroducing
# the clear would bring the blink back without failing anything else.
grep -qF "printf '\\033[H%s\\033[J'" "$SB"
eq "$?" '0' 'paint: home, overwrite each line, erase only the tail'
grep -qF "\\033[K" "$SB"
eq "$?" '0' 'paint: every overwritten line erases to end of line'
# Comments are stripped first: the paint block deliberately QUOTES the old clear while
# explaining why it went, and that mention must not read as a reintroduction.
grep -vE '^[[:space:]]*#' "$SB" | grep -qF '\033[2J'
eq "$?" '1' 'paint: no code clears the whole screen before drawing'
DSRC="$(awk '/^sb_page_dwell\(\)/,/^}/' "$SB")"
has "$DSRC" 'SB_PAGE_HOLD=0' 'dwell: picking a page clears any indefinite hold'
has "$DSRC" 'next_page=$((SECONDS + SB_PAGE_MANUAL_SECS))' 'dwell: and arms the one-minute deadline'
# Nothing on the keyboard may set an indefinite hold except space. A stray
# `SB_PAGE_HOLD=1` in the key handler is the old bug.
KSRC="$(awk '/^sb_wait_key\(\)/,/^}/' "$SB")"
has "$KSRC" 'SB_PAGE_HOLD=$((1 - SB_PAGE_HOLD))' 'keys: space toggles the indefinite hold'
hasnt "$KSRC" 'SB_PAGE_HOLD=1' 'keys: and nothing else sets one — a pick dwells, it does not hold'
# The wrap arithmetic, which is the one testable piece of the keyboard path: a bare
# (i - 1) % n is NEGATIVE in bash, which indexes the array from the end.
eq "$(sb_page_advance 0 1 3)"  '1' 'advance: forward'
eq "$(sb_page_advance 2 1 3)"  '0' 'advance: forward wraps'
eq "$(sb_page_advance 0 -1 3)" '2' 'advance: backward wraps rather than going negative'
eq "$(sb_page_advance 1 -1 3)" '0' 'advance: backward'
eq "$(sb_page_advance 0 1 1)"  '0' 'advance: a single page stays put'
eq "$(sb_page_advance junk junk junk)" '0' 'advance: garbage degrades rather than erroring'
# Paging selects what is RENDERED, never what is measured: sampling stays unconditional
# in the loop, or fifteen seconds on another page comes back as a hole in every chart.
sample_ln="$(grep -nE '^  sb_sample_slow$' "$SB" | tail -1 | cut -d: -f1)"
page_ln="$(grep -nE '^  if \[ "\$SB_PAGE_HOLD" = 0 \]' "$SB" | head -1 | cut -d: -f1)"
[ -n "$sample_ln" ] && [ -n "$page_ln" ] && [ "$sample_ln" -lt "$page_ln" ]
eq "$?" '0' 'pages: every series is sampled before any page selection happens'

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
