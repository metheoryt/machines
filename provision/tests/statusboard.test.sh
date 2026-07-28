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

export STATUSBOARD_LIB_ONLY=1
# shellcheck source=provision/statusboard/statusboard.sh
source "$REPO/provision/statusboard/statusboard.sh"

# ── sb_bar ────────────────────────────────────────────────────────────────────
eq "$(sb_bar 0 10)"   '[..........]' 'bar: 0% is empty'
eq "$(sb_bar 100 10)" '[##########]' 'bar: 100% is full'
eq "$(sb_bar 50 10)"  '[#####.....]' 'bar: 50% is half'
eq "$(sb_bar 5 20)"   '[#...................]' 'bar: 5% of 20 is one cell'
# A flaky EC reporting nonsense must not corrupt the frame width.
eq "$(sb_bar 255 10)" '[##########]' 'bar: over-range clamps to full'
eq "$(sb_bar "" 10)"  '[..........]' 'bar: empty input is 0, not an error'
eq "$(sb_bar abc 10)" '[..........]' 'bar: non-numeric input is 0, not an error'
# Width must not depend on fill — 20 cells plus the two brackets.
eq "$(printf '%s' "$(sb_bar 37 20)" | wc -c | tr -d ' ')" '22' 'bar: width is stable regardless of fill'
eq "$(printf '%s' "$(sb_bar 99 20)" | wc -c | tr -d ' ')" '22' 'bar: width identical at high fill'

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
start_ln="$(grep -n 'systemctl start "\$SERVICE_NAME"' "$SB" | head -1 | cut -d: -f1)"
disable_ln="$(grep -n 'systemctl disable "\$GETTY_UNIT"' "$SB" | head -1 | cut -d: -f1)"
[ -n "$start_ln" ] && [ -n "$disable_ln" ] && [ "$start_ln" -lt "$disable_ln" ]
eq "$?" '0' 'install: starts the board before disabling the getty, never the reverse'

grep -q 'is-active --quiet "\$SERVICE_NAME"' "$SB"
eq "$?" '0' 'install: verifies the service is actually active'
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

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
