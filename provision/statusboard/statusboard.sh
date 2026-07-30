#!/usr/bin/env bash
# provision/statusboard/statusboard.sh — a live console dashboard for a headless
# fleet member that still has a screen attached.
#
# latitude is a laptop turned always-on server: the lid stays open, the display
# is otherwise wasted, and the two things you actually want to read off it from
# across the room are "is it powered" and "is it on the network". This paints
# both, refreshing in place, on tty1.
#
# Written for that box but host-agnostic: every source it reads is optional and
# degrades to "n/a" when absent (no battery on a desktop, no tailscale on a box
# that has not enrolled).
#
# Usage:
#   bash statusboard.sh                 # run in the foreground (any terminal)
#   bash statusboard.sh --once          # paint one frame and exit (for testing)
#   bash statusboard.sh --interval 1    # seconds between REPAINTS (default 1)
#   bash statusboard.sh --probe 10      # seconds between network probes (default 10)
#   bash statusboard.sh --cell 60       # seconds of samples per chart cell (default 60)
#   bash statusboard.sh --page fleet    # start on (or, with --once, paint) one page
#   sudo bash statusboard.sh --install  # install + enable the tty1 service
#   sudo bash statusboard.sh --uninstall
#   sudo bash statusboard.sh --bigfont  # double the console font (16x32) on every VT
#
# The board ROTATES through its pages every STATUSBOARD_PAGE_SECS (default 15): the
# frame fits 26 rows and the fleet does not fit beside the disks. With a keyboard
# attached, 1..9 pick a page, n/p step, and space holds and releases the rotation. The
# alert strip is on every page, so a page you are not looking at cannot hide a fault.
#
# --install takes over tty1 and leaves gettys on tty2..tty6, so a console login
# is still one Alt-F2 away. That trade is deliberate: a dashboard you have to
# remember to start is a dashboard you never see.
#
# Deliberately dependency-free: bash, coreutils, /sys, /proc, and whatever of
# ip / tailscale / ping happens to exist. No python, no curl in the hot loop.
# Every value-formatting helper is a pure function of its arguments so
# provision/tests/statusboard.test.sh can exercise the logic with fixtures
# instead of needing a battery.
set -u

# Two cadences, deliberately. INTERVAL is how often the frame is REPAINTED — it
# wants to be 1s so the clock reads like a clock. PROBE is how often the network is
# actually measured, and it must not be 1s: every probe costs two pings plus a
# `tailscale status` fork, and doing that every second on a box whose job is to be
# quiet is a waste with no readable benefit (a gateway RTT does not need a 1s
# sample rate). Cheap readings — /sys battery, /proc load — refresh on every paint.
#
# CELL is the third cadence, and it exists because the first two pull in opposite
# directions. The charts used to advance at the PROBE rate, which tied "how often is
# the network measured" to "how much time does a chart cover" — and the only way to
# widen the span was to measure less often, which makes every NUMBER on the board
# stale (sb_sample_slow drives the text as well as the charts). So samples are still
# taken every PROBE seconds and the text stays live; CELL samples' worth are folded
# into one chart cell at render time.
INTERVAL=1
PROBE=10
CELL="${STATUSBOARD_CELL:-60}"
ONCE=0
MODE=run
SERVICE_NAME=statusboard.service
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
TTY_TARGET="${STATUSBOARD_TTY:-/dev/tty1}"
GETTY_UNIT="getty@tty1.service"

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --interval) INTERVAL="${2:-1}"; shift 2 ;;
    --probe) PROBE="${2:-10}"; shift 2 ;;
    --cell) CELL="${2:-60}"; shift 2 ;;
    --page) SB_PAGE_ARG="${2:-}"; shift 2 ;;
    --install) MODE=install; shift ;;
    --bigfont) MODE=bigfont; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h | --help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ── Colour ────────────────────────────────────────────────────────────────────
# Suppressed when stdout is not a terminal, so --once output is diffable in tests.
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_INFO=$'\033[36m'
else
  C_RST=""; C_DIM=""; C_B=""; C_OK=""; C_WARN=""; C_BAD=""; C_INFO=""
fi

# ── Pure formatting helpers (unit-tested) ─────────────────────────────────────

# sb_bar <percent> <width>: an ASCII meter. Clamps out-of-range input rather than
# emitting a negative-width bar, because a flaky EC reporting 255% should not
# corrupt the whole frame.
# The fill glyphs follow the chart ramp, for the same reason: U+2588/U+2591 are the
# two block glyphs a psf console font does carry, but the DEFAULT VT table here is
# Latin-1 only, so a VT gets #/. and everything else gets the solid/shade pair.
sb_bar() {
  local pct="${1:-0}" width="${2:-20}" filled i out="" on='#' off='.'
  case "$pct" in '' | *[!0-9]*) pct=0 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  [ "$(sb_ramp_name)" = ascii ] || { on='█'; off='░'; }
  filled=$((pct * width / 100))
  for ((i = 0; i < width; i++)); do
    if [ "$i" -lt "$filled" ]; then out="$out$on"; else out="$out$off"; fi
  done
  printf '[%s]' "$out"
}

# sb_pct_colour <percent> <warn> <bad>: pick a colour by threshold. Separate from
# sb_bar so the same thresholds can tint a number and a meter identically.
sb_pct_colour() {
  local pct="${1:-0}" warn="${2:-40}" bad="${3:-15}"
  case "$pct" in '' | *[!0-9]*) printf '%s' "$C_DIM"; return ;; esac
  if [ "$pct" -le "$bad" ]; then printf '%s' "$C_BAD"
  elif [ "$pct" -le "$warn" ]; then printf '%s' "$C_WARN"
  else printf '%s' "$C_OK"; fi
}

# sb_hi_colour <value> <warn> <bad>: the same idea for metrics where HIGH is the
# bad end — latency, load, anything measured rather than remaining. Falls back to
# C_DIM rather than no colour, so a healthy value keeps the quiet styling it had
# and only a bad one draws the eye. A zero threshold disables that tier.
sb_hi_colour() {
  local v="${1:-}" warn="${2:-0}" bad="${3:-0}"
  case "$v" in '' | *[!0-9]*) printf '%s' "$C_DIM"; return ;; esac
  case "$warn" in '' | *[!0-9]*) warn=0 ;; esac
  case "$bad" in '' | *[!0-9]*) bad=0 ;; esac
  if [ "$bad" -gt 0 ] && [ "$v" -ge "$bad" ]; then printf '%s' "$C_BAD"
  elif [ "$warn" -gt 0 ] && [ "$v" -ge "$warn" ]; then printf '%s' "$C_WARN"
  else printf '%s' "$C_DIM"; fi
}

# sb_micro_to_unit <microvalue> <suffix>: µW/µV/µA → one decimal place. The whole
# /sys/class/power_supply tree is in micro-units; printing them raw is unreadable.
sb_micro_to_unit() {
  local v="${1:-}" suffix="${2:-}"
  case "$v" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  awk -v v="$v" -v s="$suffix" 'BEGIN { printf "%.1f%s", v / 1000000, s }'
}

# sb_secs_to_hm <seconds>: 5400 → "1h30m". Used for uptime and battery estimates.
sb_secs_to_hm() {
  local s="${1:-}"
  case "$s" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
}

# sb_status_glyph <state>: one word → a marker plus colour. Keeps the frame
# scannable from a distance, which is the entire point of this thing.
sb_status_glyph() {
  case "${1:-}" in
    up | ok | online | active | yes) printf '%s  ok %s' "$C_OK" "$C_RST" ;;
    warn | slow | degraded) printf '%s warn%s' "$C_WARN" "$C_RST" ;;
    down | fail | offline | inactive | no) printf '%s down%s' "$C_BAD" "$C_RST" ;;
    *) printf '%s  ? %s' "$C_DIM" "$C_RST" ;;
  esac
}

# The charge-vs-energy split. Half the world's batteries report energy
# (energy_now/energy_full in µWh, power_now in µW); the rest report charge
# (charge_now/charge_full in µAh, current_now in µA) and expose no power_now at
# all. latitude's Dell EC is the latter — verified 2026-07-29: power_now,
# energy_now and energy_full are all absent, so without these two converters the
# board showed "Charging" with no wattage and no time estimate, which is the
# useful half of the row. µA × µV = 1e-12 W, so scale by 1e-6 to land in µ-units
# and keep one code path downstream.

# sb_uwatts <current_uA> <voltage_uV>: instantaneous power in µW.
sb_uwatts() {
  local i="${1:-}" v="${2:-}"
  case "$i" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$v" in '' | *[!0-9]*) printf ''; return ;; esac
  awk -v i="$i" -v v="$v" 'BEGIN { printf "%d", i * v / 1000000 }'
}

# sb_uwatthours <charge_uAh> <voltage_uV>: charge expressed as energy in µWh.
sb_uwatthours() {
  local c="${1:-}" v="${2:-}"
  case "$c" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$v" in '' | *[!0-9]*) printf ''; return ;; esac
  awk -v c="$c" -v v="$v" 'BEGIN { printf "%d", c * v / 1000000 }'
}

# sb_battery_line <capacity> <status> <power_now_uW> <energy_now> <energy_full>:
# the battery row, assembled from already-read values so tests need no hardware.
# "Discharging" while an AC adapter is present is the exact condition that killed
# this box twice on 2026-07-29 (a low-power USB-C source), so it is called out
# rather than left for the reader to infer.
sb_battery_line() {
  local cap="${1:-}" st="${2:-}" pw="${3:-}" en="${4:-}" ef="${5:-}" col bar draw="" est=""
  [ -n "$cap" ] || { printf '%sbattery   n/a%s' "$C_DIM" "$C_RST"; return; }
  col="$(sb_pct_colour "$cap" 40 15)"
  bar="$(sb_bar "$cap" 20)"
  [ -n "$pw" ] && [ "$pw" != 0 ] && draw=" $(sb_micro_to_unit "$pw" W)"

  # Time-to-empty only while discharging, and only when the EC gives a rate.
  if [ "$st" = Discharging ] && [ -n "$pw" ] && [ "$pw" != 0 ] && [ -n "$en" ]; then
    est=" ~$(sb_secs_to_hm "$(awk -v e="$en" -v p="$pw" 'BEGIN { printf "%d", e / p * 3600 }')" ) left"
  elif [ "$st" = Charging ] && [ -n "$pw" ] && [ "$pw" != 0 ] && [ -n "$en" ] && [ -n "$ef" ]; then
    est=" ~$(sb_secs_to_hm "$(awk -v e="$en" -v f="$ef" -v p="$pw" 'BEGIN { d = f - e; if (d < 0) d = 0; printf "%d", d / p * 3600 }')" ) to full"
  fi

  printf 'battery   %s%s %3s%%%s  %s%s%s' "$col" "$bar" "$cap" "$C_RST" "$st" "$draw" "$est"
}

# sb_source_watts <voltage_uV> <current_uA>: the negotiated USB-C contract in
# whole watts, or empty when the connector has no number to give.
#
# Zero is NOT a reading, and conflating the two is what this function exists to
# stop. Measured on latitude 2026-07-29: a 65W adapter behind a PD hub left every
# voltage and current attribute on the ucsi source psy at 0 while `usb_type` said
# `C [PD] PD_PPS` and the battery took 15W. The old code guarded with -n, which
# the literal string `0` satisfies, so it multiplied out to `USB-C 0W` — the same
# text it would print for a supply really delivering nothing, next to a battery
# the same frame called Charging. Unknown has to look different from
# browning-out, because acting on the difference is the point of the row.
sb_source_watts() {
  local uv="${1:-}" ua="${2:-}" watts
  case "$uv" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$ua" in '' | *[!0-9]*) printf ''; return ;; esac
  { [ "$uv" -gt 0 ] && [ "$ua" -gt 0 ]; } || { printf ''; return; }
  watts="$(awk -v v="$uv" -v a="$ua" 'BEGIN { printf "%.0f", v / 1000000 * (a / 1000000) }')"
  [ "$watts" = 0 ] && { printf ''; return; }
  printf '%s' "$watts"
}

# sb_source_label <watts> <usb_type>: what to call an attached USB-C supply.
#
# With a wattage it is the wattage. Without one, `usb_type` still says whether a
# PD contract is live — the kernel brackets the ACTIVE type, so `C [PD] PD_PPS`
# is PD and `[C] PD PD_PPS` is a plain Type-C port that merely lists PD among the
# types it could do. That distinction is worth printing even with no rating:
# `PD ?W` is a supply that will not name its contract, `?W` alone is a port that
# never negotiated one.
sb_source_label() {
  local watts="${1:-}" utype="${2:-}"
  [ -n "$watts" ] && { printf 'USB-C %sW' "$watts"; return; }
  case "$utype" in
    *'[PD'*) printf 'USB-C PD ?W' ;;
    *) printf 'USB-C ?W' ;;
  esac
}

# sb_limit_line <percent> <charge_types>: the charge-ceiling row.
#
# A threshold the EC is not in the mode to honour is decoration, and printing it
# bare is how this box charged to 94% under a displayed `limit 85%` for as long as
# the limit existed — see tier_battery_limit in provision/lib/tiers.sh. Dell's EC
# applies charge_control_* only in Custom mode, so the mode is part of the reading,
# not context for it. The kernel brackets the active entry.
#
# An EC with no charge_types file at all is not suspect: nothing there says the
# threshold is being ignored, so the row stays quiet. Only a mode that is present
# AND is not Custom earns the warning.
sb_limit_line() {
  local pct="${1:-}" types="${2:-}"
  [ -n "$pct" ] || return 0
  if [ -z "$types" ] || [ "${types#*\[Custom\]}" != "$types" ]; then
    printf 'limit     %s%s%%%s' "$C_DIM" "$pct" "$C_RST"
    return 0
  fi
  printf 'limit     %s%s%%%s %s(not enforced: %s)%s' \
    "$C_DIM" "$pct" "$C_RST" "$C_WARN" \
    "$(printf '%s' "$types" | tr ' ' '\n' | grep '^\[' | tr -d '[]')" "$C_RST"
}

# ── Platform power draw ───────────────────────────────────────────────────────
# The battery row answers "what is flowing in or out of the cell", which on a box
# that never unplugs is zero — the one number it cannot give is what the machine is
# actually spending. RAPL can, within limits spelled out on sb_power_line.

# The longest window sb_rapl_watts will average over, in seconds. Generous next to
# the 10s probe so one slow paint still publishes a number, tight enough that a
# suspend/resume gap does not: the energy counter keeps running while the loop is
# stopped, so a 6-hour gap would average out to something arithmetically correct and
# physically meaningless.
SB_RAPL_MAX_WINDOW="${STATUSBOARD_RAPL_MAX_WINDOW:-120}"

# sb_rapl_watts <prev_uj> <cur_uj> <max_range_uj> <seconds>: average power in µW
# across the window between two RAPL energy reads, or empty when the pair cannot
# yield a number.
#
# RAPL exposes a monotonic ENERGY counter, not a power reading, so watts only exist
# BETWEEN two samples. That makes the first sample after startup blank by
# construction — which is the correct output, not a bug to paper over with a zero.
#
# The counter WRAPS, and here it wraps often enough to matter: the range is 262143 J
# and psys idles near 18W on this box, so it rolls over roughly every four hours. A
# negative delta is that rollover rather than a fault, and adding one range back
# recovers the true delta. Only ONE wrap is assumed — at a 10s probe a second one
# would need 26kW.
sb_rapl_watts() {
  local prev="${1:-}" cur="${2:-}" max="${3:-}" secs="${4:-}"
  case "$prev" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$cur" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$secs" in '' | *[!0-9]*) printf ''; return ;; esac
  [ "$secs" -ge 1 ] || { printf ''; return; }
  [ "$secs" -le "${SB_RAPL_MAX_WINDOW:-120}" ] || { printf ''; return; }
  case "$max" in *[!0-9]*) max=0 ;; esac
  # µJ per second IS µW, so the division is the whole conversion.
  awk -v p="$prev" -v c="$cur" -v m="${max:-0}" -v s="$secs" 'BEGIN {
    d = c - p
    if (d < 0) {
      if (m <= 0) exit          # wrapped, but no range to correct by — say nothing
      d += m
      if (d < 0) exit           # more than one wrap: not a window we can average
    }
    printf "%d", d / s
  }'
}

# sb_power_line <uwatts> <domain>: the platform-draw row.
#
# The DOMAIN is printed rather than merely recorded here, because the fallback
# changes what the number MEANS by a factor of three. Measured on latitude
# 2026-07-30, at the same moment: psys 18.3W, package-0 6.4W. A row reading just
# "6.4W" on a box without psys would be taken for the machine's draw.
#
# And neither domain is wall power — psys is not either. It is the SoC platform
# rail: CPU, GPU, memory, board logic. The five bus-powered USB spinners on this box
# sit outside it, which is why 18W is plainly less than what the brick delivers.
# Measuring the real total needs a meter at the socket, not a counter in the CPU.
sb_power_line() {
  local uw="${1:-}" dom="${2:-}" suffix=""
  [ -n "$uw" ] || { printf '%spower     n/a%s' "$C_DIM" "$C_RST"; return; }
  [ -n "$dom" ] && suffix="  $C_DIM$dom$C_RST"
  printf 'power     %s%s' "$(sb_micro_to_unit "$uw" W)" "$suffix"
}

# ── Drive temperature ─────────────────────────────────────────────────────────
# Seven drives, five of them 2.5" spinners stacked in USB docks with no airflow
# designed for them, is exactly the arrangement where heat is the thing that kills
# the array — and the one condition the disk block could not show.

# sb_smart_temp_parse <smartctl -j output>: current temperature in whole °C.
#
# From the JSON, not the attribute table, on purpose. The table is ambiguous — sdc
# on this box reports BOTH `190 Airflow_Temperature_Cel` and `194
# Temperature_Celsius` — and its raw column carries trailing commentary
# (`39 (Min/Max 3/63)`) that a naive field grab turns into a number it is not.
# smartctl 7.x has already resolved both into .temperature.current.
#
# Narrowed to the temperature object before the number is taken, because "current"
# occurs in other objects of the same document.
sb_smart_temp_parse() {
  local json="${1:-}" c
  c="$(printf '%s' "$json" | tr -d ' \n' |
    sed -n 's/.*"temperature":{[^}]*"current":\([0-9]\{1,\}\).*/\1/p' | head -1)"
  case "$c" in '' | *[!0-9]*) printf ''; return ;; esac
  printf '%s' "$c"
}

# sb_smart_asleep <smartctl -j output>: true when smartctl declined to read because
# the drive is parked.
#
# Needed because smartctl's exit code cannot answer this. Bit 1 of its status means
# "device open failed, OR did not return IDENTIFY, OR is in a low-power mode", and
# measured on latitude 2026-07-30 both a sleeping sdf and a nonexistent /dev/sdZZ
# exited 2. The distinction lives only in the message, and it is a distinction worth
# keeping: one drive is resting, the other cannot be monitored at all.
sb_smart_asleep() {
  local json="${1:-}"
  printf '%s' "$json" | tr -d ' \n' |
    grep -qiE '"string":"Deviceisin(SLEEP|STANDBY|IDLE)mode'
}

# sb_apm_parks <smartctl -g apm output>: whether this drive may spin itself down.
#
# This is the gate that decides whether asking a drive for its temperature is free,
# and it exists because `-n standby` turned out not to be able to answer. Measured on
# latitude 2026-07-30: of five USB spinners, only sdf's bridge implements CHECK POWER
# MODE at all — and sdf is the one drive that returns no SMART temperature anyway. The
# four that DO report a temperature all answer `CHECK POWER MODE not implemented,
# ignoring -n option`, so on those the flag protects nothing.
#
# APM level does answer it, and by specification rather than by guess: ATA defines
# 0x01-0x7F (1-127) as the levels that PERMIT standby and 0x80-0xFE (128-254) as the
# levels that forbid it. So a drive at 128 cannot park itself and can be polled as
# often as we like; one at 96 or 1 can, and must be left alone unless it is already
# spinning. That is exactly the split on this box — sdc and sde at 128, sdd at 96,
# sdg at 1 with 639k load cycles already on it.
#
# Anything unparsable answers "yes, it parks". Unknown has to take the cautious branch
# here, because the cost of being wrong is measured in the drive's remaining life.
sb_apm_parks() {
  local out="${1:-}" lvl
  lvl="$(printf '%s' "$out" | sed -n 's/.*APM level is:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)"
  case "$lvl" in '' | *[!0-9]*) printf yes; return ;; esac
  if [ "$lvl" -ge 128 ] && [ "$lvl" -le 254 ]; then printf no; else printf yes; fi
}

# sb_temp_cell <celsius|zzz> [rotational]: the temperature field of a disk row.
#
# Three outcomes, deliberately three distinct strings:
#   47C   a reading
#   zzz   parked — no temperature BECAUSE the drive is asleep, which is the healthy
#         state for a spinner nobody is using, and is worth saying out loud
#   -     no reading and no reason: an unknown USB bridge, no smartctl, no root
#
# Collapsing the last two would hide the difference between "resting" and "cannot be
# monitored", and only one of those is an answer.
#
# `C`, not `°C`: the primary display is a Linux VT whose console font is a 256-glyph
# psf table, and the same gap that keeps the block ramp off this screen (see
# sb_ramp_name) makes a degree sign a gamble for one column of decoration. It would
# also break the field's width, being multi-byte where printf pads bytes.
#
# Every branch is FOUR visible columns wide. The disk block pads to the widest row
# and every following column lines up against it, so a field that changed width with
# its own content would move the chart column per row.
sb_temp_cell() {
  local c="${1:-}" rota="${2:-1}" col
  case "$c" in
    zzz) printf '%s%4s%s' "$C_DIM" 'zzz' "$C_RST"; return ;;
    '' | *[!0-9]*) printf '%s%4s%s' "$C_DIM" '-' "$C_RST"; return ;;
  esac
  # Spinners and flash have different limits, so one threshold pair cannot serve
  # both. 2.5" mobile drives are specced to a 55°C case; NVMe throttles in the 70s
  # and is rated past that, so warning at 50 on an SSD would cry wolf on every one.
  if [ "${rota:-1}" = 0 ]; then
    col="$(sb_hi_colour "$c" 70 80)"
  else
    col="$(sb_hi_colour "$c" 50 55)"
  fi
  printf '%s%3sC%s' "$col" "$c" "$C_RST"
}

# ── Time charts ───────────────────────────────────────────────────────────────
# Every measured row gets a second column: a one-line sparkline of that metric's
# recent history, sized to whatever horizontal space the frame has left. The
# numbers answer "what is it now"; the chart answers "has it been like that", and
# on an unattended box the second question is usually the interesting one.
#
# History is in-memory only. The unit runs ProtectSystem=strict + ProtectHome=
# read-only, and loosening either so a chart can survive a restart is a bad trade.
#
# At the 1m cell a chart column of ~76 cells fills in about 76 minutes, so a restart
# costs an hour of history rather than the 24 minutes it cost when a cell was one
# probe — and rather than the 6h+ a 5m cell cost, which is why 5m did not last a day.
# A wider span is one --cell away; keeping it across restarts is not, and would mean
# giving the unit somewhere writable. A real trade to make deliberately.

# SB_K: samples folded into one chart cell. Clamped to at least 1 — a --cell below
# --probe cannot mean "less than one sample per cell".
SB_K=$((CELL / PROBE))
[ "$SB_K" -ge 1 ] || SB_K=1
# The DISPLAYED cell duration is derived back from k, never taken from CELL: with
# --cell 250 --probe 10 the chart really shows 240s cells, and an axis that claims
# 250 is a lie about the data.
SB_CELL_SECS=$((SB_K * PROBE))

# Samples kept per series. In CELLS this is 200 — more than any console is wide —
# so the depth follows the fold factor rather than being a fixed sample count that
# silently truncates a slow chart to a fraction of its width.
SB_HIST_CAP=$((200 * SB_K))
[ "$SB_HIST_CAP" -ge 400 ] || SB_HIST_CAP=400

# Two ramps, and the default is chosen by the OUTPUT DEVICE rather than by TERM.
#
# The 8-level block ramp ▁▂▃▄▅▆▇█ is what the user's statusline uses, so a terminal
# gets that. A Linux VT cannot: a psf console font holds 256/512 glyphs, and the
# ones on this box simply do not contain the partial blocks. Measured on latitude
# 2026-07-29 — the default Lat15/Fixed table is Latin-1 only, and even
# Uni3-TerminusBold32x16 carries just U+2588, U+2591 and U+2592 (and no U+00D7).
# So on a VT the pretty ramp would paint as replacement boxes.
#
# The test is the DEVICE behind stdout, not $TERM: /dev/ttyN is a VT, /dev/pts/N is
# not. That is a fact rather than an inference — but it can only be established in
# the shell that owns the real fd 1, so SB_IS_VT is set once at startup (below) and
# merely consulted here. Reading /proc/self/fd/1 from inside this function would
# see the frame subshell's pipe and always answer "not a VT", which is how the
# unreadable glyphs reached tty1 in the first place. STATUSBOARD_RAMP overrides.
SB_IS_VT=0

sb_ramp_name() {
  if [ -n "${STATUSBOARD_RAMP:-}" ]; then printf '%s' "$STATUSBOARD_RAMP"; return; fi
  if [ "${SB_IS_VT:-0}" = 1 ]; then printf 'ascii'; else printf 'height'; fi
}

sb_ramp() {
  case "$(sb_ramp_name)" in
    ascii) printf '%s' '.,:-=+*#' ;;
    *) printf '%s' '▁▂▃▄▅▆▇█' ;;
  esac
}

# The "sample taken, target unreachable" glyph — distinct from a missing sample,
# which is a gap. Plain x on a VT: U+00D7 is absent from the console fonts here.
sb_down_glyph() {
  case "$(sb_ramp_name)" in
    ascii) printf 'x' ;;
    *) printf '×' ;;
  esac
}

# ── Chart colour ──────────────────────────────────────────────────────────────
# 24-bit colour is a SEPARATE capability from "has colour at all", and it needs its
# own gate: a Linux VT has 16, and a gradient painted with 38;2 there loses exactly
# the distinctions it was drawn to make. Set once at startup next to SB_IS_VT (a
# capability probe belongs where fd 1 is real), consulted here.
#
# Measured on latitude 2026-07-29: foot exports COLORTERM=truecolor, and tmux
# reports RGB in #{client_termfeatures}, so the kiosk and the SSH window both light
# up. A terminal that advertises nothing keeps the 16-colour thresholds rather than
# being fed escapes it may not parse. STATUSBOARD_TRUECOLOR overrides either way.
SB_TRUECOLOR=0

sb_truecolor() {
  if [ -n "${STATUSBOARD_TRUECOLOR:-}" ]; then printf '%s' "$STATUSBOARD_TRUECOLOR"; return; fi
  printf '%s' "${SB_TRUECOLOR:-0}"
}

# sb_heat_color <level> <levels> [polarity]: the colour for a chart cell at <level>
# of <levels>. Green at the bottom through amber to red at the ceiling — the ceiling
# is per-metric and fixed (see sb_chart), so "red" always means "at the limit this
# metric was given", never "the highest value in this window".
#
# POLARITY exists because that is only true for half the metrics on this board. A
# full battery painted red and a fully-reachable fleet painted red are both wrong,
# and they were both wrong on screen (2026-07-29):
#
#   hi-bad   default. Latency, load, anything where the ceiling is the problem.
#   hi-good  battery charge, peers online. The gradient is inverted: a full bar is
#            green and a DIP goes amber then red, which is when to look at it.
#   flat     activity, not condition — disk throughput, charge draw. One accent
#            colour, because the glyph height already carries the magnitude and a
#            gradient here would only invent an alarm that does not exist.
#
# Returns the empty string when colour is off, which is what keeps --once diffable
# and every existing chart assertion byte-identical.
sb_heat_color() {
  local lvl="${1:-0}" n="${2:-8}" pol="${3:-hi-bad}" t f r g b
  case "$lvl" in '' | *[!0-9]*) lvl=0 ;; esac
  case "$n" in '' | *[!0-9]*) n=8 ;; esac
  [ "$n" -gt 1 ] || n=2
  [ "$lvl" -lt "$n" ] || lvl=$((n - 1))
  [ "$pol" = flat ] && { printf '%s' "$C_INFO"; return; }
  [ "$pol" = hi-good ] && lvl=$((n - 1 - lvl))
  t=$((lvl * 100 / (n - 1)))
  if [ "$(sb_truecolor)" = 1 ]; then
    # Two linear segments, integer-only: green→amber over the lower half, amber→red
    # over the upper. Endpoints are picked for a dark background at both ends.
    if [ "$t" -lt 50 ]; then
      f=$((t * 2))
      r=$((88 + 126 * f / 100)); g=$((166 + 12 * f / 100)); b=$((110 - 40 * f / 100))
    else
      f=$(((t - 50) * 2))
      r=$((214 - 14 * f / 100)); g=$((178 - 108 * f / 100)); b=70
    fi
    printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
  elif [ "$t" -lt 50 ]; then printf '%s' "$C_OK"
  elif [ "$t" -lt 80 ]; then printf '%s' "$C_WARN"
  else printf '%s' "$C_BAD"
  fi
}

# sb_heat_table <levels>: fill SB_HEAT with one colour per ramp level.
#
# The table exists for cost, not style. Colouring per SAMPLE would fork a subshell
# for every cell — ~1500 per frame across ten charts on a 146-column display, which
# is more than the whole frame budget at a 1s interval. There are only as many
# distinct colours as there are ramp levels, so eight forks cover every chart.
sb_heat_table() {
  local n="${1:-8}" pol="${2:-hi-bad}" i
  case "$n" in '' | *[!0-9]*) n=8 ;; esac
  SB_HEAT=()
  for ((i = 0; i < n; i++)); do SB_HEAT[i]="$(sb_heat_color "$i" "$n" "$pol")"; done
}

# sb_push <csv> <sample> <cap>: append, trimming the oldest. Pure — takes the old
# series and returns the new one, so the render loop holds the state and the
# function stays testable.
#
# A missing reading becomes '-' rather than an empty field: bash's read -a drops a
# trailing empty field, so an empty sample would silently shorten the series and
# shift every later frame one cell to the right.
sb_push() {
  local csv="${1:-}" v="${2:-}" cap="${3:-$SB_HIST_CAP}"
  case "$cap" in '' | *[!0-9]*) cap="$SB_HIST_CAP" ;; esac
  [ -n "$v" ] || v='-'
  if [ -z "$csv" ]; then csv="$v"; else csv="$csv,$v"; fi
  local -a a=()
  # IFS is local so the join below can reuse it without leaking a comma into every
  # later `read -a` in the same frame.
  local IFS=','
  read -r -a a <<< "$csv"
  local n=${#a[@]} start=0
  [ "$n" -gt "$cap" ] && start=$((n - cap))
  # One slice-and-join rather than a concatenation loop: the fold factor pushed the
  # cap from 400 samples to thousands, and appending to a string n times is
  # quadratic — at 6000 samples across a dozen series that stalls the paint.
  printf '%s' "${a[*]:start}"
}

# sb_fold <k> <csv>: fold every <k> consecutive samples into one chart cell.
#
# This is what decouples the chart's time axis from the sample rate. Called by
# render_frame on the way into sb_chart, deliberately NOT from inside it, so every
# chart assertion keeps testing glyph maths on raw samples.
#
# Buckets are aligned from the NEWEST sample backwards (sliding, not anchored to a
# wall-clock boundary). A fixed alignment would need a probe counter carried between
# frames, and the frame runs in a `$(render_frame)` subshell that discards exactly
# that kind of state — the same trap the sampling section warns about. The cost is
# that completed cells re-derive on each probe instead of freezing, which on these
# metrics is invisible.
#
# A bucket takes the MAX of its samples, not the mean: a 5-minute cell that hides a
# 30-second latency spike or a brief outage is worse than one that looks alarming.
# Any unreachable sample makes the whole cell unreachable, for the same reason.
sb_fold() {
  local k="${1:-1}" csv="${2:-}" j len pos n v best down seen
  case "$k" in '' | *[!0-9]*) k=1 ;; esac
  [ "$k" -ge 1 ] || k=1
  [ "$k" = 1 ] && { printf '%s' "$csv"; return; }
  [ -n "$csv" ] || { printf ''; return; }

  local -a a=() folded=()
  local IFS=','
  read -r -a a <<< "$csv"
  n=${#a[@]}
  # The PARTIAL bucket is the oldest one, which is what keeps the newest cell
  # advancing every probe instead of the whole chart jumping once per cell.
  len=$((n % k)); [ "$len" -ne 0 ] || len="$k"
  pos=0
  while [ "$pos" -lt "$n" ]; do
    down=0; seen=0; best=0
    for ((j = pos; j < pos + len && j < n; j++)); do
      v="${a[j]}"
      case "$v" in
        x | X) down=1 ;;
        '' | *[!0-9]*) : ;;
        *) seen=1; [ "$v" -gt "$best" ] && best="$v" ;;
      esac
    done
    if [ "$down" = 1 ]; then folded+=('x')
    elif [ "$seen" = 1 ]; then folded+=("$best")
    else folded+=('-')
    fi
    pos=$((pos + len))
    len="$k"
  done
  printf '%s' "${folded[*]}"
}

# sb_chart <width> <max> <csv>: the sparkline. Newest sample at the RIGHT edge, so
# the chart scrolls the way a chart should; a series shorter than the width is
# left-padded with blanks rather than stretched.
#
# <max> is a FIXED ceiling per metric, deliberately not the window maximum:
# auto-scaling makes a 0.5ms→0.6ms gateway fill the chart and look alarming. With
# a fixed ceiling, flat-and-low is the healthy shape and stays visually boring.
sb_chart() {
  local width="${1:-0}" max="${2:-100}" csv="${3:-}" pol="${4:-hi-bad}" ramp levels out="" i v idx
  case "$width" in '' | *[!0-9]*) printf ''; return ;; esac
  [ "$width" -gt 0 ] || { printf ''; return; }
  case "$max" in '' | *[!0-9]*) max=100 ;; esac
  [ "$max" -gt 0 ] || max=1
  ramp="$(sb_ramp)"
  levels="${#ramp}"

  # Colour is emitted only where it CHANGES. The naive per-cell form costs ~19 bytes
  # a cell, which is 28KB of escapes a frame on a wide display — run-length keeps a
  # typical chart down to a handful.
  local -a SB_HEAT=()
  local want="" cur=""
  [ -n "$C_RST" ] && sb_heat_table "$levels" "$pol"

  local -a a=()
  IFS=',' read -r -a a <<< "$csv"
  local n=${#a[@]} start=0
  [ "$n" -gt "$width" ] && start=$((n - width))
  for ((i = 0; i < width - (n - start); i++)); do out="$out "; done

  for ((i = start; i < n; i++)); do
    v="${a[i]}"
    case "$v" in
      # A down sample is always the alarm colour, whatever level surrounds it.
      x | X) want="$C_BAD"; idx=-1 ;;
      # A gap carries no colour at all, so it also ends any run before it.
      '' | *[!0-9]*) want=""; idx=-2 ;;
      *)
        [ "$v" -gt "$max" ] && v="$max"
        idx=$((v * levels / max))
        [ "$idx" -ge "$levels" ] && idx=$((levels - 1))
        want="${SB_HEAT[idx]:-}"
        ;;
    esac
    if [ "$want" != "$cur" ]; then
      # Leaving colour behind needs an explicit reset; entering another does not.
      [ -n "$cur" ] && [ -z "$want" ] && out="$out$C_RST"
      out="$out$want"
      cur="$want"
    fi
    case "$idx" in
      -1) out="$out$(sb_down_glyph)" ;;
      -2) out="$out " ;;
      *) out="$out${ramp:idx:1}" ;;
    esac
  done
  [ -n "$cur" ] && out="$out$C_RST"
  printf '%s' "$out"
}

# sb_vislen <string>: length in printable cells — ANSI escapes stripped. Padding
# the text column with ${#s} instead would make every coloured row short by the
# width of its escape sequences, which is most of them.
sb_vislen() {
  local plain
  plain="$(printf '%s' "${1:-}" | sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g')"
  printf '%s' "${#plain}"
}

# sb_pad <string> <width>: right-pad to a visible width, escapes and all.
sb_pad() {
  local s="${1:-}" w="${2:-0}" vis pad=""
  vis="$(sb_vislen "$s")"
  case "$w" in '' | *[!0-9]*) w=0 ;; esac
  while [ "$vis" -lt "$w" ]; do pad="$pad "; vis=$((vis + 1)); done
  printf '%s%s' "$s" "$pad"
}

# sb_lpad <string> <width>: pad on the LEFT to a visible width. The unit column is
# flush right, which gives the frame a straight right edge and — because the widest
# label ends the line — leaves no trailing whitespace on any row.
sb_lpad() {
  local s="${1:-}" w="${2:-0}" vis pad=""
  vis="$(sb_vislen "$s")"
  case "$w" in '' | *[!0-9]*) w=0 ;; esac
  while [ "$vis" -lt "$w" ]; do pad="$pad "; vis=$((vis + 1)); done
  printf '%s%s' "$pad" "$s"
}

# sb_trim <string> <width>: keep a row inside the frame. Only uncharted rows can
# exceed the width (charted ones are padded to a computed column), and one that does
# WRAPS — which on a repainting full-screen frame makes the whole display walk up
# the screen. Colour is dropped when trimming: cutting a string mid-escape would
# leave the rest of the frame tinted.
sb_trim() {
  local s="${1:-}" w="${2:-0}" vis plain
  case "$w" in '' | *[!0-9]*) printf '%s' "$s"; return ;; esac
  [ "$w" -gt 1 ] || { printf '%s' "$s"; return ; }
  vis="$(sb_vislen "$s")"
  [ "$vis" -le "$w" ] && { printf '%s' "$s"; return; }
  plain="$(printf '%s' "$s" | sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g')"
  printf '%s>' "${plain:0:$((w - 1))}"
}

# sb_span <cells> <interval>: how much time a full chart covers. Without this the
# same picture means 20 minutes on tty1 (3s) and 67 minutes in tmux (10s), and
# there is no axis to tell them apart.
sb_span() {
  local cells="${1:-0}" iv="${2:-0}" s
  case "$cells" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  case "$iv" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  s=$((cells * iv))
  if [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60))
  else printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

# sb_dur <seconds>: a cell duration for the axis label. "300s/cell" is arithmetic
# the reader should not have to do.
sb_dur() {
  local s="${1:-0}"
  case "$s" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ] && [ $((s % 60)) -eq 0 ]; then printf '%dm' $((s / 60))
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

# ── Disk I/O ──────────────────────────────────────────────────────────────────
# The disk charts used to plot USAGE, which was the one metric on the board with
# nothing to say: a filesystem's fill level changes over days, so at any span a
# console can show, the chart was a flat line restating the bar next to it. Throughput
# is the question a chart can actually answer — "was this array busy at 03:00" — and
# it is the one the numbers cannot.

# sb_dev_sectors <dev> [diskstats]: sectors read + written for one block device,
# straight from the kernel's counters. Partitions have their own rows, so a mount
# point maps to its own line rather than to the whole disk's.
sb_dev_sectors() {
  local dev="${1:-}" f="${2:-/proc/diskstats}"
  [ -n "$dev" ] || { printf ''; return; }
  [ -r "$f" ] || { printf ''; return; }
  awk -v d="$dev" '$3 == d { printf "%d", $6 + $10; exit }' "$f"
}

# sb_io_mbs <prev_sectors> <cur_sectors> <seconds>: throughput in whole MB/s.
#
# Sectors are 512 bytes regardless of the device's physical sector size — that is
# what the kernel's counter is defined in, and reading the real geometry to "fix" it
# would make the number wrong.
sb_io_mbs() {
  local prev="${1:-}" cur="${2:-}" secs="${3:-1}"
  case "$prev" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$cur" in '' | *[!0-9]*) printf ''; return ;; esac
  case "$secs" in '' | *[!0-9]*) secs=1 ;; esac
  [ "$secs" -ge 1 ] || secs=1
  # A counter that went BACKWARDS means the device was re-enumerated — a dock replug
  # renumbers sda — so the delta is meaningless. Report a gap, not a spike.
  [ "$cur" -ge "$prev" ] || { printf ''; return; }
  awk -v p="$prev" -v c="$cur" -v s="$secs" 'BEGIN { printf "%d", (c - p) * 512 / 1048576 / s }'
}

# sb_rtt_tenths <"0.516ms">: a ping time as tenths of a millisecond, which is the
# integer unit the charts scale against (bash has no floats).
sb_rtt_tenths() {
  local v="${1:-}"
  v="${v%ms}"
  case "$v" in '' | *[!0-9.]*) printf ''; return ;; esac
  awk -v v="$v" 'BEGIN { printf "%d", v * 10 }'
}

# ── Disks ─────────────────────────────────────────────────────────────────────
# This box is a media server with four USB disks in two docks plus a spare NVMe, so
# "is the array still there and is it filling up" is a first-class question — as
# much as battery and network.

# sb_kb_to_gib <kilobytes>: 1K blocks → whole GiB. df -h would be shorter but its
# unit suffix is not stable across implementations, and parsing it back to compare
# two filesystems is worse than doing the arithmetic once.
sb_kb_to_gib() {
  local kb="${1:-}"
  case "$kb" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  awk -v k="$kb" 'BEGIN { printf "%.0f", k / 1048576 }'
}

# Layout constants for the disk block, named because two functions and a test all
# have to agree on them.
SB_DISK_PATHW=23   # fits /mnt/immich-2024-backup, the longest on this box
SB_DISK_BARW=20    # the widest a bar can get — the size of the LARGEST disk

# sb_disk_bar <pct> <total_kb> <max_total_kb> <maxw>: a meter whose LENGTH is the
# disk's capacity and whose FILL is how much of that is used.
#
# A fixed-width bar makes a full 1G EFI partition and a full 931G array look like
# the same event. Scaling the length to the biggest disk present means the block
# reads as the actual shape of the storage: one long bar mostly full is a problem,
# one short bar mostly full is not.
#
# The bar is then PADDED to maxw, because its length is now data and data of varying
# width cannot also be the anchor every following column lines up against.
sb_disk_bar() {
  local pct="${1:-0}" total="${2:-0}" maxtotal="${3:-0}" maxw="${4:-$SB_DISK_BARW}"
  local cells filled i out="" pad="" on='#' off='.'
  case "$pct" in '' | *[!0-9]*) pct=0 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  case "$total" in '' | *[!0-9]*) total=0 ;; esac
  case "$maxtotal" in '' | *[!0-9]*) maxtotal=0 ;; esac
  case "$maxw" in '' | *[!0-9]*) maxw="$SB_DISK_BARW" ;; esac
  [ "$maxw" -ge 1 ] || maxw=1
  # No reference size means "you are the biggest" — which is what a single-disk box
  # and every direct call in a test gets.
  [ "$maxtotal" -gt 0 ] || maxtotal="$total"
  if [ "$maxtotal" -gt 0 ] && [ "$total" -gt 0 ]; then
    cells=$((total * maxw / maxtotal))
  else
    cells=0
  fi
  # A disk two orders of magnitude smaller than the array still gets one cell: a
  # zero-width bar reads as a missing disk rather than a tiny one.
  [ "$cells" -ge 1 ] || cells=1
  [ "$cells" -le "$maxw" ] || cells="$maxw"
  [ "$(sb_ramp_name)" = ascii ] || { on='█'; off='░'; }
  filled=$((pct * cells / 100))
  for ((i = 0; i < cells; i++)); do
    if [ "$i" -lt "$filled" ]; then out="$out$on"; else out="$out$off"; fi
  done
  for ((i = cells; i < maxw; i++)); do pad="$pad "; done
  printf '[%s]%s' "$out" "$pad"
}

# sb_disk_row <dev> <mount> <total_kb> <pct> [max_total_kb] [state] [temp_c] [rota]:
# one filesystem.
#
# The used figure is gone on purpose: the bar already carries "how full", the total
# carries "how big", and a third number saying the same thing in GB was the widest
# field in the block for the least information in it.
#
# The bar is coloured by FREE space, so it greens down as the disk fills — the
# inverse of the battery row, where a high number is the healthy one.
#
# Temperature is a property of the DRIVE, not of the filesystem, so two partitions of
# one disk deliberately show the same figure — / and /boot/efi are both nvme1n1 here.
# It renders through sb_temp_cell even when there is no reading, because a column
# that appeared only on some rows would break the alignment of every row.
sb_disk_row() {
  local dev="${1:-}" mnt="${2:-}" total="${3:-}" pct="${4:-}" maxtotal="${5:-}" state="${6:-ok}"
  local temp="${7:-}" rota="${8:-1}"
  local col free=100 bar
  case "$pct" in '' | *[!0-9]*) pct=0 ;; esac
  # Long mount points are shown tail-first behind a <: every row pads to the widest
  # one, so a single deep path would push the chart column off the screen for all of
  # them. The tail is the part that identifies the disk.
  [ "${#mnt}" -gt "$SB_DISK_PATHW" ] && mnt="<${mnt: -$((SB_DISK_PATHW - 1))}"
  free=$((100 - pct))
  col="$(sb_pct_colour "$free" 20 10)"
  bar="$(sb_disk_bar "$pct" "$total" "$maxtotal" "$SB_DISK_BARW")"
  if [ "$state" != ok ]; then
    # Everything df still reports about a vanished disk is a memory, so the row says
    # so where the bar was and dims the stale figures rather than dropping them —
    # "it was 60% full when it went" is worth more than a blank.
    bar="$(sb_pad "$(printf '!! %s !!' "$state")" $((SB_DISK_BARW + 2)))"
    col="$C_BAD"
    # A vanished disk has no temperature and no prospect of one, but it keeps the
    # column: the block pads to the widest row, so dropping a field here would shift
    # the chart column for every OTHER row in the frame.
    printf '%-*s %s%s%s %s%3s%%  %5sG%s  %s  %s%s%s' \
      "$SB_DISK_PATHW" "${mnt:-?}" \
      "$C_BAD" "$bar" "$C_RST" \
      "$C_DIM" "$pct" "$(sb_kb_to_gib "$total")" "$C_RST" \
      "$(sb_temp_cell '' "$rota")" \
      "$C_DIM" "${dev:-?}" "$C_RST"
    return
  fi
  printf '%-*s %s%s %3s%%%s  %5sG  %s  %s%s%s' \
    "$SB_DISK_PATHW" "${mnt:-?}" \
    "$col" "$bar" "$pct" "$C_RST" \
    "$(sb_kb_to_gib "$total")" \
    "$(sb_temp_cell "$temp" "$rota")" \
    "$C_DIM" "${dev:-?}" "$C_RST"
}

# Per-disk history cannot use an associative array keyed by mount point: mounts come
# and go when a dock is unplugged, and `declare -A` would still be carrying the
# stale key. A flat "key=csv" store is trivially prunable and, being a string, is
# testable the same way every other helper here is.
sb_series_get() {
  printf '%s\n' "${1:-}" | awk -F= -v k="${2:-}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

sb_series_set() {
  printf '%s\n' "${1:-}" | awk -F= -v k="${2:-}" -v v="${3:-}" '
    NF == 0 { next }
    $1 == k { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }'
}

# sb_series_keep <store> <keys...>: drop every series whose key is gone. Without
# this, unplugging a dock leaves its history in memory forever and a remount shows
# a chart spliced onto readings from hours ago.
sb_series_keep() {
  local store="${1:-}" keep=" ${*:2} " line key out="" first=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    case "$keep" in *" $key "*) ;; *) continue ;; esac
    if [ "$first" = 1 ]; then out="$line"; first=0; else out="$out
$line"; fi
  done <<< "$store"
  printf '%s' "$out"
}

# sb_console_font_file <codeset> <face> <WxH>: the psf path console-setup would
# use. Its own naming is REVERSED relative to FONTSIZE — FONTSIZE="16x32" (width x
# height) is the file Uni3-TerminusBold32x16.psf.gz (height x width) — and getting
# that backwards is a silent no-op that leaves the console at the old size.
sb_console_font_file() {
  local codeset="${1:-Uni3}" face="${2:-TerminusBold}" size="${3:-16x32}" w h
  w="${size%x*}"; h="${size#*x}"
  case "$w$h" in '' | *[!0-9]*) printf ''; return ;; esac
  printf '/usr/share/consolefonts/%s-%s%sx%s.psf.gz' "$codeset" "$face" "$h" "$w"
}

# sb_cols <is-tty>: the frame width. Charts are OFF (0) when the output is not a
# terminal, so --once stays diffable; STATUSBOARD_COLS forces a width either way,
# which is how the chart and padding maths get tested.
#
# Whether the output IS a terminal has to be passed in, and that is not fussiness:
# render_frame runs inside frame="$(render_frame)", where fd 1 is a pipe. An
# internal `[ -t 1 ]` therefore answered "not a terminal" on every frame and
# silently disabled every chart on tty1 while the tests — which force
# STATUSBOARD_COLS — all passed (2026-07-29). The caller evaluates -t 1 once, in the
# shell that owns the real fd 1.
#
# The width itself comes from `stty size`, which reads fd 0 and so is unaffected by
# the substitution; the unit passes StandardInput=tty for exactly this reason.
sb_cols() {
  local istty="${1:-0}" c="${STATUSBOARD_COLS:-}"
  if [ -z "$c" ]; then
    [ "$istty" = 1 ] || { printf '0'; return; }
    c="$(stty size 2>/dev/null | awk '{ print $2 }')"
    [ -n "$c" ] || c="$(tput cols 2>/dev/null)"
    [ -n "$c" ] || c=80
  fi
  case "$c" in '' | *[!0-9]*) c=0 ;; esac
  printf '%s' "$c"
}

# sb_chart_width <cols> <textwidth> [reserve]: cells left for the chart column, or 0
# when there is not enough room to be worth it. A chart under 8 cells wide is noise.
#
# <reserve> is whatever sits to the RIGHT of the charts — the unit column. It has to
# be subtracted here rather than trimmed later: a chart sized to the full width and
# then followed by a label is a chart one label too wide, and on a repainting frame
# a row that wraps walks the whole display up the screen.
sb_chart_width() {
  local cols="${1:-0}" textw="${2:-0}" reserve="${3:-0}" w
  case "$cols" in '' | *[!0-9]*) printf '0'; return ;; esac
  case "$textw" in '' | *[!0-9]*) printf '0'; return ;; esac
  case "$reserve" in '' | *[!0-9]*) reserve=0 ;; esac
  w=$((cols - textw - 3 - reserve))
  [ "$w" -ge 8 ] || w=0
  # The ceiling is in CELLS, not samples: with a fold factor of k the history holds
  # SB_HIST_CAP/k cells, and comparing a cell count against a sample count would let
  # the chart claim k times the depth it has.
  local maxcells=$((SB_HIST_CAP / ${SB_K:-1}))
  [ "$maxcells" -ge 1 ] || maxcells=1
  [ "$w" -gt "$maxcells" ] && w="$maxcells"
  printf '%s' "$w"
}

# sb_ts_parse: `tailscale status` text on stdin, this node's own tailnet IP as $1 —
# out comes the summary line and then one line per peer. It lives up here, above the
# LIB_ONLY gate and away from sb_tailnet which calls it, for the reason every other
# parser in this section does: the fork is what needs a tailnet, the parse does not,
# and the parse is the half that can be wrong.
#
# Line 1 is the summary: "up|<self-ip>|<online>|<total>". Lines 2..N are one peer
# each: "ip|node|os|state|last_seen". Summary FIRST so the caller still reads it with
# a plain `read -r` and the peer lines are whatever follows.
#
# The second column is the NODE name — `latitude`, `desktop`, `server` — which is
# exactly what fleet.json is keyed by. `--json` looks like the more honest source and
# is the worse one: its HostName is the OS hostname (g614jv, g513ie), which joins to
# nothing, and it would want jq on a board whose every other parser is awk.
#
# `state` is direct / relay / idle / offline, and **idle counts as ONLINE**.
# `tailscale status` prints "-" for a node it currently holds no session with, which
# is the normal resting state of a quiet fleet; the counter this replaces read that as
# down. It only ever agreed with reality because the line is space-padded, so its
# ` -$` anchor never actually matched.
#
# Self is excluded from both counts. It was included before, which is why the row
# could say 6/7 while all six peers were up.
sb_ts_parse() {
  awk -v self="${1:-}" '
    $1 !~ /^100\./ { next }
    $1 == self { next }
    {
      age = ""
      if ($5 ~ /^offline/) {
        state = "offline"
        if (index($0, "last seen")) {
          age = $0
          sub(/^.*last seen /, "", age)
          sub(/ ago[[:space:]]*$/, "", age)
        }
      } else if ($5 == "active;") {
        state = ($6 == "direct" ? "direct" : "relay")
      } else {
        state = "idle"
      }
      n++
      if (state != "offline") up++
      rows = rows sprintf("%s|%s|%s|%s|%s\n", $1, $2, $4, state, age)
    }
    # NR discriminates "no tailnet" from "alone on the tailnet", and it is exact: a
    # working daemon with zero peers STILL prints its own line, so NR >= 1. NR == 0
    # only happens when the fork produced nothing — timeout fired, or tailscaled
    # wedged between `tailscale ip` and this call. Reporting that as up|0|0 would
    # paint "I am alone" and "I cannot see" as the same pixels, and the alert strip
    # would call it fine.
    END {
      if (NR == 0) { printf "down|%s||\n", self; exit }
      printf "up|%s|%d|%d\n%s", self, up + 0, n + 0, rows
    }
  '
}

# ── Docker ────────────────────────────────────────────────────────────────────
# sb_mib <bytes>: a container's memory, in the unit a container is actually sized in.
# GiB would round every one of them to 0 or 1; MiB up to a gibibyte and then one
# decimal of GiB keeps the whole range readable in four characters.
sb_mib() {
  local b="${1:-}"
  case "$b" in '' | *[!0-9]*) printf 'n/a'; return ;; esac
  awk -v b="$b" 'BEGIN {
    if (b >= 1073741824) printf "%.1fG", b / 1073741824
    else printf "%dM", b / 1048576
  }'
}

# sb_dk_short <status>: docker's own status prose, compressed to fit a row.
#
# "Up About an hour (healthy)" is 26 characters of which four carry information, and
# the frame's binding constraint is width. Shortened at SAMPLE time, once per probe per
# container, rather than per paint.
#
# The health note is kept: a container that is up and failing its own health check is
# the single most useful thing this page can tell you, and it is invisible in any
# up/total count.
sb_dk_short() {
  printf '%s' "${1:-}" | awk '{
    s = $0
    sub(/^Up /, "up ", s); sub(/^Exited /, "exited ", s)
    sub(/^Restarting /, "restarting ", s); sub(/^Created/, "created", s)
    sub(/^Paused/, "paused", s); sub(/^Dead/, "dead", s)
    gsub(/About an hour/, "1h", s); gsub(/About a minute/, "1m", s)
    gsub(/ seconds?/, "s", s); gsub(/ minutes?/, "m", s); gsub(/ hours?/, "h", s)
    gsub(/ days?/, "d", s); gsub(/ weeks?/, "w", s); gsub(/ months?/, "mo", s)
    gsub(/ years?/, "y", s)
    sub(/ ago$/, "", s)
    gsub(/\(healthy\)/, "healthy", s); gsub(/\(unhealthy\)/, "UNHEALTHY", s)
    gsub(/\(health: starting\)/, "starting", s)
    print s
  }'
}

# ── The fleet ─────────────────────────────────────────────────────────────────
# sb_fleet_parse: fleet.json on stdin -> "name|ip|platform|hostname", one machine per
# line, in manifest order.
#
# awk, not jq: the board's entire dependency list is bash, coreutils, /sys and /proc,
# and provision/lib/fleet.sh (which does use jq) is a provisioning helper that may run
# on a box where the board does not. It is parsed ONCE at startup — the manifest cannot
# change while the board runs, and re-reading a five-line file every second would be a
# fork for nothing.
#
# Anchored on indent: a machine opens at four spaces with the brace ENDING the line,
# while every field sits at six with its value on the same line. That is the shape this
# repo has always written, and the fixture test is what keeps the assumption honest.
sb_fleet_parse() {
  awk '
    function lastq(s, n, a) { n = split(s, a, "\""); return (n >= 2) ? a[n - 1] : "" }
    /^    "[^"]+": \{[ \t]*$/ { name = lastq($0); ip = ""; plat = ""; host = ""; next }
    name == "" { next }
    $1 == "\"platform\":" { plat = lastq($0); next }
    $1 == "\"tailnet\":"  { ip   = lastq($0); next }
    $1 == "\"detect\":"   { host = lastq($0); next }
    /^    \}/ { print name "|" ip "|" plat "|" host; name = ""; next }
  '
}

# sb_fleet_join <fleet-lines> <peer-lines> <self-ip> <tailnet-up>: the fleet page's
# data. One line per MANIFEST member — "name|ip|platform|state|age" — then a trailing
# "_others|<count>|<online>" for tailnet nodes that are not fleet members.
#
# Driven by fleet.json and NOT by the tailnet, deliberately. A member that has fallen
# off the tailnet then renders as a ROW saying `missing`, which is the one failure the
# peer COUNT cannot express: "5/5 peers online" is also what a fleet of six looks like
# when the sixth never enrolled.
#
# The non-fleet nodes are counted on their own line rather than mixed in, so a phone
# and a scratch WSL distro cannot flatter or spoil the fleet's own numbers.
#
# With the local tailnet unreadable every member is `unknown`, not `missing`: nothing
# was learned about them, and painting five red rows for one local fault would bury the
# one alert that is true.
sb_fleet_join() {
  # BOTH lists arrive on stdin, peers first, separated by a bare "--". Not `awk -v`: a
  # variable assigned there may not contain a newline (awk rejects it outright), and
  # both of these are multi-line.
  printf '%s\n--\n%s\n' "${2:-}" "${1:-}" |
    awk -v self="${3:-}" -v tsup="${4:-0}" '
    $0 == "--" { members = 1; next }
    $0 == "" { next }
    members == 0 {
      split($0, f, "|")
      pstate[f[1]] = f[4]; page[f[1]] = f[5]; seen[f[1]] = 0
      next
    }
    {
      split($0, m, "|")
      name = m[1]; ip = m[2]; plat = m[3]
      age = ""
      if (tsup != 1)        state = "unknown"
      else if (ip == "")    state = "missing"
      else if (ip == self)  state = "self"
      else if (ip in pstate) { state = pstate[ip]; age = page[ip]; seen[ip] = 1 }
      else                  state = "missing"
      printf "%s|%s|%s|%s|%s\n", name, ip, plat, state, age
    }
    END {
      others = 0; up = 0
      if (tsup == 1) for (ip in pstate) if (!seen[ip]) { others++; if (pstate[ip] != "offline") up++ }
      printf "_others|%d|%d||\n", others, up
    }
  '
}

# ── The alert strip ───────────────────────────────────────────────────────────
# The two loops below are the strip's SEVERITY POLICY — the judgement about what is worth
# waking someone for. They take one argument each so the policy is fixture-testable;
# sb_alerts, which has to read a dozen globals, calls them.

# sb_fleet_alerts <fleet-rows>: NAMED, not counted. "1 peer offline" sends you to the
# fleet page to find out which; the strip is what is read from across the room, so it says
# which. Missing outranks offline: offline is a box that is switched off, missing is a box
# that is no longer enrolled in the tailnet at all.
sb_fleet_alerts() {
  local name state age
  while IFS='|' read -r name _ _ state age; do
    case "$name" in '' | _others) continue ;; esac
    case "$state" in
      missing) printf 'bad:%s missing\n' "$name" ;;
      offline) printf 'warn:%s offline%s\n' "$name" "${age:+ $age}" ;;
    esac
  done <<< "${1:-}"
  return 0
}

# sb_docker_alerts <docker-rows>: this box's services ARE its containers, so the alert is
# "immich_server exited", not "1 of 5 not running".
#
# Unhealthy outranks the state and is checked first: a container that is up and failing
# its own health check is invisible in every running/total count, and `running` is exactly
# what its state field says.
sb_docker_alerts() {
  local name state status
  while IFS='|' read -r name state status _ _; do
    [ -n "$name" ] || continue
    case "$status" in *UNHEALTHY*) printf 'bad:%s unhealthy\n' "$name"; continue ;; esac
    case "$state" in
      running) ;;
      exited | dead) printf 'bad:%s %s\n' "$name" "$state" ;;
      *) printf 'warn:%s %s\n' "$name" "$state" ;;
    esac
  done <<< "${1:-}"
  return 0
}

# sb_alert_line <sev:text>…: the one line every page carries, whichever page is up.
#
# It is what makes paging safe. The board's whole value is that a glance from across
# the room says the box is fine, and a page that is not on screen cannot say that —
# so every condition worth a colour is summarised here, at a fixed position on the
# frame, on all pages.
#
# Deliberately NOT "stop rotating and hold on the failing page": a box that flaps
# would then never show you anything else.
#
# Worst severity wins the colour and its alerts are listed first — a dead mount and a
# slow ping are not the same news. Zero alerts is not an empty line: "all clear" is
# how the strip says it is working rather than missing.
sb_alert_line() {
  local a sev text col sep out="" i
  local -a bad=() warn=() all=()
  for a in "$@"; do
    [ -n "$a" ] || continue
    sev="${a%%:*}"; text="${a#*:}"
    case "$sev" in
      bad) bad+=("$text") ;;
      *) warn+=("$text") ;;
    esac
  done
  if [ "${#bad[@]}" = 0 ] && [ "${#warn[@]}" = 0 ]; then
    printf '%sall clear%s' "$C_DIM" "$C_RST"
    return
  fi
  all+=(${bad[@]+"${bad[@]}"})
  all+=(${warn[@]+"${warn[@]}"})
  # Alert texts contain spaces, so the list is built by index — an unquoted array
  # expansion would split "2 units failed" into three alerts.
  sep=' · '
  [ "$(sb_ramp_name)" = ascii ] && sep=' | '
  for ((i = 0; i < ${#all[@]}; i++)); do
    if [ -z "$out" ]; then out="${all[i]}"; else out="$out$sep${all[i]}"; fi
  done
  col="$C_WARN"
  [ "${#bad[@]}" -gt 0 ] && col="$C_BAD"
  printf '%s%s%s' "$col" "$out" "$C_RST"
}

# sb_page_tabs <active-index> <name>…: the page list with the active one lit. Its
# VISIBLE width does not depend on which page is active — only the colour moves — so
# the alert text beside it does not shift as the board rotates.
sb_page_tabs() {
  local active="${1:-0}" i=0 out="" n
  shift
  for n in "$@"; do
    if [ "$i" = "$active" ]; then
      out="$out${out:+ }$C_B$C_INFO$n$C_RST"
    else
      out="$out${out:+ }$C_DIM$n$C_RST"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

[ "${STATUSBOARD_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Install / uninstall ───────────────────────────────────────────────────────
# ── Bigger console font ───────────────────────────────────────────────────────
# Its own mode, NOT part of --install: --install already earned a reputation for
# breaking the console, and a font change is an unrelated risk to fold into it.
# Persistent rather than a bare `setfont`, because a font that reverts on reboot is
# worse than no font change on a box whose whole point is being unattended.
if [ "$MODE" = bigfont ]; then
  [ "$(id -u)" = 0 ] || { printf 'need root for --bigfont\n' >&2; exit 1; }
  CONF=/etc/default/console-setup
  FACE="${STATUSBOARD_FONTFACE:-TerminusBold}"
  SIZE="${STATUSBOARD_FONTSIZE:-16x32}"
  CODESET="${STATUSBOARD_CODESET:-Uni3}"
  FONT_FILE="$(sb_console_font_file "$CODESET" "$FACE" "$SIZE")"

  [ -f "$CONF" ] || { printf 'no %s — this box does not use console-setup.\n' "$CONF" >&2; exit 1; }
  [ -f "$FONT_FILE" ] || {
    printf 'font not installed: %s\n' "$FONT_FILE" >&2
    printf 'try: apt install xfonts-terminus console-setup\n' >&2
    exit 1
  }

  printf 'current: %s\n' "$(grep -E '^(CODESET|FONTFACE|FONTSIZE)=' "$CONF" | tr '\n' ' ')"
  [ -f "$CONF.pre-statusboard" ] || cp "$CONF" "$CONF.pre-statusboard"

  for kv in "CODESET=\"$CODESET\"" "FONTFACE=\"$FACE\"" "FONTSIZE=\"$SIZE\""; do
    key="${kv%%=*}"
    if grep -qE "^$key=" "$CONF"; then
      sed -i "s|^$key=.*|$kv|" "$CONF"
    else
      printf '%s\n' "$kv" >> "$CONF"
    fi
  done

  # setupcon applies the config to every VT now and console-setup replays it at
  # boot. setfont is the fallback for a box without setupcon: same font, this
  # session only.
  if command -v setupcon >/dev/null 2>&1; then
    setupcon --force 2>/dev/null || setfont "$FONT_FILE" 2>/dev/null
  else
    setfont "$FONT_FILE" 2>/dev/null
  fi

  printf 'console font is now %s %s (%s)\n' "$FACE" "$SIZE" "$FONT_FILE"
  printf 'the board re-reads the terminal width every frame, so the charts resize themselves.\n'
  printf 'to undo: cp %s.pre-statusboard %s && setupcon --force\n' "$CONF" "$CONF"
  exit 0
fi

if [ "$MODE" = install ] || [ "$MODE" = uninstall ]; then
  [ "$(id -u)" = 0 ] || { printf 'need root for --%s\n' "$MODE" >&2; exit 1; }
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  RUN_USER="${STATUSBOARD_USER:-${SUDO_USER:-me}}"

  if [ "$MODE" = uninstall ]; then
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    systemctl enable --now "$GETTY_UNIT" 2>/dev/null
    printf 'removed %s; %s restored\n' "$SERVICE_NAME" "$GETTY_UNIT"
    exit 0
  fi

  # Conflicts= plus disabling the getty: without both, systemd and agetty fight
  # over the same VT and the frame gets overwritten by a login prompt.
  cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Fleet status board on ${TTY_TARGET}
Documentation=file://$SELF
After=network-online.target tailscaled.service
Wants=network-online.target
Conflicts=$GETTY_UNIT

[Service]
Type=simple
User=$RUN_USER
# SupplementaryGroups=tty is REQUIRED and its absence is why the first install
# left a dead console: /dev/tty1 is root:tty mode 620, a getty normally chowns it
# to whoever logs in, and with the getty stopped an unprivileged service simply
# cannot open it. The unit failed to start, the getty was already disabled, and
# tty1 was left with nothing painting it — a blinking cursor and no way in.
SupplementaryGroups=tty
ExecStart=/bin/bash $SELF --interval $INTERVAL --probe $PROBE --cell $CELL
StandardInput=tty
StandardOutput=tty
StandardError=journal
TTYPath=$TTY_TARGET
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
Restart=always
RestartSec=2
# Read-only everywhere except the tty; the board only ever reads /sys and /proc.
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload

  # ORDER MATTERS, and getting it wrong once cost a working console. Prove the
  # service starts BEFORE taking the getty away, and roll the getty back if it
  # does not. The original order — disable the getty, then enable the service —
  # leaves tty1 owned by nobody the moment the service fails to start, which is
  # unrecoverable from the screen itself.
  #
  # Starting the service is enough to free the tty right now: Conflicts= stops
  # the getty automatically. `disable` is only about what happens at the NEXT
  # boot, so it is safe to defer to the end.
  # restart, not start: `start` is a NO-OP when the unit is already active, so a
  # re-install after a code change left the OLD process painting the screen while
  # reporting success (seen 2026-07-29 — tty1 kept the pre-update frame). restart
  # also covers the not-yet-running case, so it is strictly better here.
  systemctl restart "$SERVICE_NAME" 2>/dev/null
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    printf '%s failed to start — rolling back so the console stays usable:\n' "$SERVICE_NAME" >&2
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' >&2
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    systemctl enable --now "$GETTY_UNIT" 2>/dev/null
    printf '\nrestored %s. Nothing else changed.\n' "$GETTY_UNIT" >&2
    exit 1
  fi

  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl disable "$GETTY_UNIT" >/dev/null 2>&1
  printf 'installed %s on %s as %s\n' "$SERVICE_NAME" "$TTY_TARGET" "$RUN_USER"
  printf 'gettys remain on tty2..tty6 — Alt-F2 for a console login.\n'
  printf 'to undo: sudo bash %s --uninstall\n' "$SELF"
  exit 0
fi

# ── Readers ───────────────────────────────────────────────────────────────────
_read() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null || printf ''; }

BAT_DIR=""
for d in /sys/class/power_supply/BAT*; do [ -d "$d" ] && { BAT_DIR="$d"; break; }; done

# Which supply is actually feeding the box, and at what rating. On USB-C PD the
# negotiated contract lives in the ucsi source psy, and reading it is the only
# way to tell a 65W brick from the 15W port that browned this box out.
#
# Each of the two figures has a fallback, because which attribute carries the
# contract varies by connector: voltage_now is live and voltage_max is the PDO
# ceiling, and a connector that zeroes one sometimes fills the other.
sb_power_source() {
  local ac="" src="" volts amps
  for d in /sys/class/power_supply/*/; do
    case "$(_read "$d/type")" in
      Mains) [ "$(_read "$d/online")" = 1 ] && ac="AC" ;;
      USB)
        if [ "$(_read "$d/online")" = 1 ]; then
          volts="$(_read "$d/voltage_now")"
          [ "${volts:-0}" != 0 ] || volts="$(_read "$d/voltage_max")"
          amps="$(_read "$d/current_max")"
          [ "${amps:-0}" != 0 ] || amps="$(_read "$d/current_now")"
          src="$(sb_source_label "$(sb_source_watts "$volts" "$amps")" "$(_read "$d/usb_type")")"
        fi
        ;;
    esac
  done
  if [ -n "$ac" ] && [ -n "$src" ]; then printf '%s (%s)' "$ac" "$src"
  elif [ -n "$ac" ]; then printf '%s' "$ac"
  elif [ -n "$src" ]; then printf '%s' "$src"
  else printf 'battery only'; fi
}

# sb_rapl_pick: the powercap domain to meter, as "dir|name", or empty.
#
# Chosen by NAME, never by index. The intel-rapl:* glob also matches SUBdomains —
# this box has intel-rapl:0:0 (core) and intel-rapl:0:1 (uncore) — so an
# index-ordered pick would land on a fraction of the package and call it the
# platform. psys first because it is the widest rail the CPU exposes; package-0 is
# the fallback and means something much smaller, which is why sb_power_line prints
# whichever one won.
#
# Readability is part of the match. energy_uj ships 0400 root:root (the kernel
# restricted it after the PLATYPUS side channel), so on a box where nothing has
# widened it this returns empty and the row honestly says n/a instead of 0W.
sb_rapl_pick() {
  local d want
  for want in psys package-0; do
    for d in /sys/class/powercap/intel-rapl:*; do
      [ -f "$d/name" ] || continue
      [ "$(_read "$d/name")" = "$want" ] || continue
      [ -r "$d/energy_uj" ] || continue
      printf '%s|%s' "$d" "$want"
      return 0
    done
  done
  printf ''
}

# sb_disk_of <partition-or-disk>: the whole-disk device a partition belongs to.
#
# Via sysfs, never by trimming trailing digits: `nvme1n1p3` trimmed that way is
# `nvme1n`, which is not a device. The parent link answers both naming schemes
# uniformly. A name with no `partition` file already IS a whole disk and comes back
# unchanged, rather than walking up into /sys/class/block itself.
sb_disk_of() {
  local p="${1:-}" l
  [ -n "$p" ] || { printf ''; return; }
  [ -e "/sys/class/block/$p" ] || { printf ''; return; }
  [ -f "/sys/class/block/$p/partition" ] || { printf '%s' "$p"; return; }
  l="$(readlink -f "/sys/class/block/$p/.." 2>/dev/null)" || { printf ''; return; }
  [ -n "$l" ] || { printf ''; return; }
  basename "$l"
}

# sb_rotational <disk>: 1 for a spinner, 0 for flash, 1 when unknown.
#
# Defaults to spinner because that is the assumption with the safer consequences: it
# picks the tighter temperature thresholds and it keeps the drive in the
# poll-only-when-busy path.
sb_rotational() {
  local r
  r="$(_read "/sys/block/${1:-}/queue/rotational")"
  case "$r" in 0) printf 0 ;; *) printf 1 ;; esac
}

# sb_hwmon_temp <disk>: temperature in whole °C from the kernel's own hwmon node, or
# empty. Free — one sysfs read, no fork, no root — which is why it is tried first and
# why NVMe temperatures need no rate limiting at all.
#
# Matches the `Composite` label rather than assuming temp1: nvme1n1 here exposes
# temp1 Composite and temp2 "Sensor 1", and which index carries which is a property
# of the drive's firmware. Composite is the drive's own summary figure. Falls back to
# the lowest-numbered sensor when nothing is labelled — which is what a
# drivetemp-backed SATA disk looks like, should that module ever load here.
sb_hwmon_temp() {
  local disk="${1:-}" f lab first="" m="" raw
  [ -n "$disk" ] || { printf ''; return; }
  for f in /sys/block/"$disk"/device/hwmon*/temp*_input; do
    [ -f "$f" ] || continue
    [ -n "$first" ] || first="$f"
    lab="${f%_input}_label"
    if [ -f "$lab" ] && [ "$(_read "$lab")" = Composite ]; then m="$f"; break; fi
  done
  [ -n "$m" ] || m="$first"
  [ -n "$m" ] || { printf ''; return; }
  raw="$(_read "$m")"
  # iwlwifi exposes a temp1_input that reads EMPTY on this box, so a sensor file
  # existing is not a promise that it holds a number.
  case "$raw" in '' | *[!0-9]*) printf ''; return ;; esac
  awk -v v="$raw" 'BEGIN { printf "%d", (v + 500) / 1000 }'
}

# smartctl lives in /usr/sbin, which is NOT on this user's PATH — a bare `smartctl`
# is exactly why an earlier probe on this box concluded it was not installed. Root is
# probed once rather than per call, and its absence simply means no SMART readings.
SB_SMARTCTL="${STATUSBOARD_SMARTCTL:-/usr/sbin/smartctl}"
SB_SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SB_SUDO="sudo -n"; fi
fi

# sb_smart_temp <disk>: temperature over the USB-SATA bridge, `zzz` when the drive is
# parked, or empty when it cannot be read. Costs a fork, root, and 0.1-0.6s measured
# on latitude — which is why sb_sample_slow asks about one drive per probe at most.
#
# `-n standby` is insurance, not the mechanism. It cannot be the mechanism: sdd's
# bridge answers `CHECK POWER MODE not implemented, ignoring -n option`, so on that
# drive smartctl will read — and therefore spin up — whatever the flag says. The real
# protection is upstream, in only asking about drives that are already doing IO.
# sb_drive_parks <disk>: `no` when the drive's APM level forbids it spinning itself
# down, `yes` otherwise. One fork, asked once per drive per board lifetime — APM level
# is a persistent drive setting, not a live reading.
sb_drive_parks() {
  local disk="${1:-}"
  [ -n "$disk" ] || { printf yes; return; }
  [ -x "$SB_SMARTCTL" ] || { printf yes; return; }
  sb_apm_parks "$($SB_SUDO "$SB_SMARTCTL" -g apm -d sat "/dev/$disk" 2>/dev/null)"
}

sb_smart_temp() {
  local disk="${1:-}" out rc
  [ -n "$disk" ] || { printf ''; return; }
  [ -x "$SB_SMARTCTL" ] || { printf ''; return; }
  out="$($SB_SUDO "$SB_SMARTCTL" -n standby -A -j -d sat "/dev/$disk" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Exit 2 alone proves nothing: measured on latitude, a sleeping sdf and a
    # nonexistent /dev/sdZZ both exited 2. Only the message separates them.
    sb_smart_asleep "$out" && { printf 'zzz'; return; }
  fi
  sb_smart_temp_parse "$out"
}

sb_lan() {
  local dev ip4 gw
  dev="$(ip route show default 2>/dev/null | awk '/^default/ { print $5; exit }')"
  [ -n "$dev" ] || { printf 'down|||'; return; }
  ip4="$(ip -4 -br addr show dev "$dev" 2>/dev/null | awk '{ print $3; exit }')"
  gw="$(ip route show default 2>/dev/null | awk '/^default/ { print $3; exit }')"
  printf 'up|%s|%s|%s' "$dev" "${ip4:-?}" "${gw:-?}"
}

# Gateway first, then a public address: distinguishes "no LAN" from "LAN but no
# internet", which are different problems with different fixes.
sb_reach() {
  local target="$1" out
  if command -v ping >/dev/null 2>&1; then
    out="$(ping -n -c1 -W1 "$target" 2>/dev/null | awk -F'time=' '/time=/ { print $2; exit }')"
    [ -n "$out" ] && { printf 'up|%s' "${out% ms}ms"; return; }
  fi
  printf 'down|'
}

# sb_bounded <seconds> <command…>: run a slow-path fork with a ceiling on it.
#
# Everything else on that path is bounded by the tool itself (ping -W1, df over live
# devices only). These are not: `tailscale status` and `docker ps` both talk to a
# daemon over a unix socket, and a wedged daemon blocks forever — which would freeze
# the clock painted right next to the numbers.
#
# Resolved, not assumed: a box with no coreutils `timeout` runs the command unbounded
# rather than reporting the reading permanently missing (which is what macOS did while
# the tailnet parse was being written).
SB_TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && SB_TIMEOUT_BIN=timeout
sb_bounded() {
  local secs="${1:-5}"
  shift
  if [ -n "$SB_TIMEOUT_BIN" ]; then "$SB_TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

sb_tailnet() {
  local ip
  command -v tailscale >/dev/null 2>&1 || { printf 'n/a|||\n'; return; }
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] || { printf 'down|||\n'; return; }
  # ONE fork for the whole tailnet. This ran `tailscale status` TWICE — once counting
  # peers, once counting the online ones — and one parse yields both counts plus every
  # per-peer field, so the second fork was buying nothing even before the fleet page
  # needed the details.
  #
  # timeout because this sits on the paint loop's slow path: the command talks to
  # tailscaled over a socket, and a wedged daemon would otherwise freeze the clock
  # next to the numbers.
  sb_bounded 5 tailscale status --peers 2>/dev/null | sb_ts_parse "$ip"
}

# sb_mounts: one line per real filesystem — "dev|mount|used_kb|total_kb|pct".
# df -P -k rather than -h: POSIX output, one line per filesystem however long the
# device name, and 1K blocks instead of a suffix that varies by implementation.
# Only /dev/* sources, so tmpfs, devtmpfs, efivarfs and the rest of the virtual
# tree stay out; loop devices are excluded too — a snap mount is not a disk.
# The sixth field is the mount's LIVENESS, and it exists because df cannot be
# trusted on its own. Unplug a dock and the kernel keeps the mount: df goes on
# reporting the mount point with its last-known size, used and percentage, so the
# board showed two vanished disks as healthy at 60% and 70% while the disks
# themselves had come back as different device nodes, unmounted (2026-07-29).
#
# The test is whether the backing device node still exists. That is the cheapest
# question with an unambiguous answer — stat()ing the mount point itself would block
# on a dead NFS mount, and reading it would spin up a sleeping disk on every probe.
# sb_docker: the local containers, one line each — "name|state|status|full-id".
#
# `docker ps -a`, not `docker ps`: without -a a crashed container leaves BOTH the
# numerator and the denominator, so four of four read "up" while one was dead. -a still
# cannot see a service that was `compose down`'d — nothing that does not exist can be
# counted missing, and reconstructing the expected set from compose files is a different
# feature with a different failure mode.
#
# --no-trunc because the cgroup path is keyed by the FULL container id, and that is
# where the per-container CPU and memory come from.
#
# Two seconds, not five: this is asked every probe, and dockerd is likelier to be
# mid-restart than tailscaled. No sudo — the board's user is in the docker group.
sb_docker() {
  sb_bounded 2 docker ps -a --no-trunc \
    --format '{{.Names}}|{{.State}}|{{.Status}}|{{.ID}}' 2>/dev/null
}

sb_mounts() {
  local dev mnt used total pct state
  df -P -k 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/dev\// && $1 !~ /^\/dev\/(loop|ram)/ {
    dev = $1; sub(/^\/dev\//, "", dev)
    mnt = $6
    for (i = 7; i <= NF; i++) mnt = mnt " " $i      # mount points may contain spaces
    pct = $5; sub(/%$/, "", pct)
    printf "%s|%s|%s|%s|%s\n", dev, mnt, $3, $2, pct
  }' | while IFS='|' read -r dev mnt used total pct; do
    state=ok
    [ -b "/dev/$dev" ] || state=gone
    printf '%s|%s|%s|%s|%s|%s\n' "$dev" "$mnt" "$used" "$total" "$pct" "$state"
  done
}

# sb_unmounted: connected disks with nothing mounted off them — the whole point of
# listing them is that a headless box gives no other sign a dock came back empty.
# A disk counts as mounted if ANY of its partitions has a mount point; [SWAP] and
# the EFI partition count, so the root disk never shows up here.
sb_unmounted() {
  command -v lsblk >/dev/null 2>&1 || return 0
  lsblk -rno NAME,TYPE,SIZE,MOUNTPOINT 2>/dev/null | awk '
    $2 == "disk" { disks[++n] = $1; size[$1] = $3; next }
    { if (NF >= 4 && $4 != "") { for (d in size) if (index($1, d) == 1) used[d] = 1 } }
    END {
      out = ""
      for (i = 1; i <= n; i++) {
        d = disks[i]
        if (!(d in used)) out = out (out == "" ? "" : "  ") d " " size[d]
      }
      print out
    }'
}

# ── Sampling ──────────────────────────────────────────────────────────────────
# The readers run HERE, in the main shell, and not inside render_frame — because
# the loop paints with frame="$(render_frame)", a SUBSHELL. A series appended to
# from in there is discarded the instant the subshell exits, so every chart would
# show one sample forever. Sample in the shell, format in the subshell.
SER_BAT=""; SER_PW=""; SER_GW=""; SER_NET=""; SER_TS=""; SER_LOAD=""; SER_PSYS=""
SER_DISKS=""   # "mountpoint=csv" per line, one entry per mounted filesystem — MB/s
# Previous diskstats reading per mount, and when it was taken. Throughput is a
# DELTA, so it needs the last counter kept in the main shell for the same reason the
# series are: a value computed inside the frame subshell dies with it.
SB_IO_PREV=""
SB_IO_T=0
# Same reason again for RAPL: watts are a delta of an energy counter, so the previous
# reading and its timestamp have to outlive the frame that used them. The domain is
# resolved once — powercap does not gain or lose domains at runtime.
SB_RAPL_DIR=""; SB_RAPL_NAME=""; SB_RAPL_MAX=""
SB_RAPL_PREV=""; SB_RAPL_T=0; SB_PSYS=""
IFS='|' read -r SB_RAPL_DIR SB_RAPL_NAME <<< "$(sb_rapl_pick)"
[ -n "$SB_RAPL_DIR" ] && SB_RAPL_MAX="$(_read "$SB_RAPL_DIR/max_energy_range_uj")"
# Drive temperatures, and the round-robin cursor over the spinners. Keyed by DISK
# rather than by mount, because temperature is a property of the drive: / and
# /boot/efi are two filesystems on one nvme1n1 and share its figure.
SB_TEMPS=""; SB_DISKOF=""; SB_ROTA=""; SB_TEMP_RR=0
# Whether each drive can spin itself down, learned once from its APM level. Cached for
# the process lifetime because it is a persistent drive setting, not a reading.
SB_PARKS=""
# Evaluated ONCE here, where fd 1 is the real output; see sb_cols.
SB_ISTTY=0; [ -t 1 ] && SB_ISTTY=1
# And which device that output is. `-ef` compares device+inode, so this asks "is fd
# 1 one of the virtual consoles" WITHOUT a command substitution — the whole point,
# since a substitution's fd 1 is a pipe and the answer would always be no.
for _d in /dev/tty[0-9]*; do
  [ -e "$_d" ] && [ "$_d" -ef /dev/stdout ] && { SB_IS_VT=1; break; }
done
unset _d
# 24-bit capability, probed here for the same reason and under the same conditions:
# only when there is colour at all and the device is not a VT. tmux is asked
# directly rather than trusted through COLORTERM, which it can forward while still
# refusing to pass RGB through without terminal-features.
if [ -n "$C_RST" ] && [ "$SB_IS_VT" = 0 ]; then
  case "${COLORTERM:-}" in truecolor | 24bit) SB_TRUECOLOR=1 ;; esac
  if [ "$SB_TRUECOLOR" = 0 ] && [ -n "${TMUX:-}" ] &&
    tmux display -p '#{client_termfeatures}' 2>/dev/null | grep -q RGB; then
    SB_TRUECOLOR=1
  fi
fi
SB_MOUNTS=""; SB_UNMOUNTED=""
# Declared up front because the frame reads them under `set -u`: the loop always
# probes before its first paint, but --once and any future caller ordering should
# not be able to turn a missing reading into a crash.
SB_CAP=""; SB_ST=""; SB_PW=""; SB_EN=""; SB_EF=""; SB_LIM=""; SB_SRC=""
SB_UP=""; SB_LOAD=""; SB_FAILED=""
SB_LAN_ST=""; SB_LAN_DEV=""; SB_LAN_IP=""; SB_LAN_GW=""
SB_GW_ST=""; SB_GW_RTT=""; SB_NET_ST=""; SB_NET_RTT=""
# The manifest, parsed once — it cannot change while the board runs. A board outside
# the repo, or one whose checkout is mid-rebuild, is not an error: the fleet page then
# says it has no manifest instead of claiming an empty fleet.
SB_REPO="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
SB_FLEET_JSON="${STATUSBOARD_FLEET_JSON:-$SB_REPO/fleet.json}"
SB_FLEET=""
[ -r "$SB_FLEET_JSON" ] && SB_FLEET="$(sb_fleet_parse < "$SB_FLEET_JSON")"
SB_FLEET_ROWS=""
SB_FLEET_UP=0; SB_FLEET_TOTAL=0; SB_FLEET_OTHERS=0
SER_PEERS=""   # "member=csv" per line — one binary online series per fleet member

# Containers. SB_DK_ST is n/a (no docker on this box) / down (daemon unreachable) / up.
SB_DOCKER=""; SB_DK_ST="n/a"; SB_DK_UP=0; SB_DK_TOTAL=0
# CPU% is a DELTA of a cumulative counter, so — like the disk throughput and the RAPL
# energy — the previous reading and the moment it was taken must outlive the frame.
SB_DK_PREV=""; SB_DK_T=0
SER_DK=""      # "container=csv" per line — CPU% of one core
SER_DKUP=""    # how many containers were running

SB_TS_ST=""; SB_TS_IP=""; SB_TS_PEERS=""; SB_TS_TOTAL=""
# One "ip|node|os|state|last_seen" line per tailnet peer, from the same single fork
# that produced the counts above. Sampled but not yet rendered — the fleet page is
# what reads it, and the parse landed first so the format could be checked against a
# real tailnet before anything depended on it.
# shellcheck disable=SC2034
SB_TS_PEERLIST=""
SB_NCPU="$(nproc 2>/dev/null || printf 1)"

# Fixed chart ceilings. 65W is this box's brick, so the 15W port that browned it
# out on 2026-07-29 draws a visibly short bar instead of a full one — which is the
# entire reason the power series is charted.
SB_MAX_PW=65
SB_MAX_GW=500    # tenths of a ms: 50ms
SB_MAX_NET=2000  # tenths of a ms: 200ms
# MB/s a disk chart calls "full". 100 saturates the USB docks and the spinners in
# them, which are the disks worth watching; the NVMe will clip during a big copy and
# that is the honest reading of "this disk was as busy as this board can show".
SB_MAX_IO="${STATUSBOARD_IO_MAX:-100}"
# One core. A container busier than a core clips, which is the honest reading of "this
# container was as busy as this board can show"; scaling to all cores instead would draw
# every service on this box as a flat line one cell high.
SB_MAX_DKCPU=100
# How many container rows the docker page will draw, and how wide a name may be. Both
# are bounds on things docker does not bound: exited containers accumulate for as long as
# compose has been running here, and `docker compose run` mints 34-character names. The
# frame is 26 rows and the text column is what the charts get the remainder of.
SB_DK_ROWS="${STATUSBOARD_DOCKER_ROWS:-18}"
SB_DK_NAMEW="${STATUSBOARD_DOCKER_NAMEW:-24}"

# sb_sample_fast: everything that is a file read. Runs on EVERY paint, so the
# numbers on screen are never staler than the clock beside them.
sb_sample_fast() {
  local b_volt
  b_volt="$(_read "$BAT_DIR/voltage_now")"
  SB_CAP="$(_read "$BAT_DIR/capacity")"
  SB_ST="$(_read "$BAT_DIR/status")"
  SB_PW="$(_read "$BAT_DIR/power_now")"
  [ -n "$SB_PW" ] || SB_PW="$(sb_uwatts "$(_read "$BAT_DIR/current_now")" "$b_volt")"
  SB_EN="$(_read "$BAT_DIR/energy_now")"
  [ -n "$SB_EN" ] || SB_EN="$(sb_uwatthours "$(_read "$BAT_DIR/charge_now")" "$b_volt")"
  SB_EF="$(_read "$BAT_DIR/energy_full")"
  [ -n "$SB_EF" ] || SB_EF="$(sb_uwatthours "$(_read "$BAT_DIR/charge_full")" "$b_volt")"
  SB_LIM="$(_read "$BAT_DIR/charge_control_end_threshold")"
  SB_LIM_MODE="$(_read "$BAT_DIR/charge_types")"
  SB_SRC="$(sb_power_source)"
  SB_UP="$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)"
  SB_LOAD="$(awk '{ print $1, $2, $3 }' /proc/loadavg 2>/dev/null)"
}

# sb_sample_slow: the measurements that fork — two pings, `tailscale status`, df,
# and `systemctl --failed`. Runs at the PROBE cadence and also drives the charts,
# so one probe is one chart cell.
sb_sample_slow() {
  local w ts_out
  local IFS='|'
  read -r SB_LAN_ST SB_LAN_DEV SB_LAN_IP SB_LAN_GW <<< "$(sb_lan)"
  SB_GW_ST=""; SB_GW_RTT=""
  if [ -n "${SB_LAN_GW:-}" ] && [ "$SB_LAN_GW" != '?' ]; then
    read -r SB_GW_ST SB_GW_RTT <<< "$(sb_reach "$SB_LAN_GW")"
  fi
  read -r SB_NET_ST SB_NET_RTT <<< "$(sb_reach 1.1.1.1)"
  # Multi-line now: summary first, then the peers. `read -r` takes the summary and the
  # rest is split off with parameter expansion rather than `tail -n +2`, because the
  # point of the rewrite was to stop forking here.
  ts_out="$(sb_tailnet)"
  read -r SB_TS_ST SB_TS_IP SB_TS_PEERS SB_TS_TOTAL <<< "$ts_out"
  unset IFS
  # shellcheck disable=SC2034  # read by the fleet page; see the declaration
  case "$ts_out" in
    *$'\n'*) SB_TS_PEERLIST="${ts_out#*$'\n'}" ;;
    *) SB_TS_PEERLIST="" ;;
  esac

  # The fleet, joined to the tailnet once per PROBE and not per paint: the manifest is
  # fixed for the run and the peer list changed exactly when the fork above ran.
  local f_name f_f2 f_state ts_up=0
  [ "${SB_TS_ST:-}" = up ] && ts_up=1
  SB_FLEET_ROWS="$(sb_fleet_join "$SB_FLEET" "$SB_TS_PEERLIST" "${SB_TS_IP:-}" "$ts_up")"
  # One binary series per member, so a box that flaps reads differently from a box that
  # has been down all hour. A probe that learned nothing about the peers — the local
  # tailnet unreadable — pushes a GAP, not a down mark: the chart must not blame five
  # remote machines for one local fault.
  SB_FLEET_UP=0; SB_FLEET_TOTAL=0; SB_FLEET_OTHERS=0
  while IFS='|' read -r f_name f_f2 _ f_state _; do
    # The trailing line carries the non-fleet counts, not a member — see sb_fleet_join.
    if [ "$f_name" = _others ]; then SB_FLEET_OTHERS="${f_f2:-0}"; continue; fi
    [ -n "$f_name" ] || continue
    SB_FLEET_TOTAL=$((SB_FLEET_TOTAL + 1))
    case "$f_state" in self | direct | relay | idle) SB_FLEET_UP=$((SB_FLEET_UP + 1)) ;; esac
    if [ "$ts_up" = 0 ]; then
      SER_PEERS="$(sb_series_set "$SER_PEERS" "$f_name" \
        "$(sb_push "$(sb_series_get "$SER_PEERS" "$f_name")" '')")"
      continue
    fi
    case "$f_state" in
      self | direct | relay | idle)
        SER_PEERS="$(sb_series_set "$SER_PEERS" "$f_name" \
          "$(sb_push "$(sb_series_get "$SER_PEERS" "$f_name")" 1)")" ;;
      *)
        SER_PEERS="$(sb_series_set "$SER_PEERS" "$f_name" \
          "$(sb_push "$(sb_series_get "$SER_PEERS" "$f_name")" x)")" ;;
    esac
  done <<< "$SB_FLEET_ROWS"

  # Containers. The LIST is one bounded fork; the per-container numbers are plain file
  # reads off cgroup v2, which is why `docker stats` is not here — that is a second
  # daemon round-trip, streaming, for figures already sitting in /sys.
  local dk_out dk_rc dk_name dk_state dk_status dk_id dk_scope dk_mem dk_usec dk_prev
  local dk_pct dk_el
  SB_DOCKER=""; SB_DK_UP=0; SB_DK_TOTAL=0
  if ! command -v docker >/dev/null 2>&1; then
    SB_DK_ST=n/a
  else
    dk_out="$(sb_docker)"; dk_rc=$?
    # A dead daemon and an empty machine both print nothing, so the EXIT CODE is what
    # separates them. Without it "docker is down" would render as "0 containers", which
    # is what a box with nothing deployed looks like.
    if [ "$dk_rc" = 0 ]; then SB_DK_ST=up; else SB_DK_ST=down; fi
    dk_el=$((SECONDS - SB_DK_T)); [ "$dk_el" -gt 0 ] || dk_el=1
    if [ "$SB_DK_ST" = up ]; then
      while IFS='|' read -r dk_name dk_state dk_status dk_id; do
        [ -n "$dk_name" ] || continue
        SB_DK_TOTAL=$((SB_DK_TOTAL + 1))
        [ "$dk_state" = running ] && SB_DK_UP=$((SB_DK_UP + 1))
        dk_scope="/sys/fs/cgroup/system.slice/docker-$dk_id.scope"
        dk_mem="$(_read "$dk_scope/memory.current")"
        dk_usec="$(awk '/^usage_usec/ { print $2; exit }' "$dk_scope/cpu.stat" 2>/dev/null)"
        dk_pct=""
        dk_prev="$(sb_series_get "$SB_DK_PREV" "$dk_name")"
        # Percent of ONE core, so a container pinning a core reads 100 whatever the box
        # has. usage_usec over an interval in seconds: delta / (elapsed x 10^4).
        if [ -n "$dk_usec" ] && [ -n "$dk_prev" ]; then
          dk_pct="$(awk -v a="$dk_prev" -v b="$dk_usec" -v el="$dk_el" \
            'BEGIN { d = b - a; if (d < 0) d = 0; printf "%d", d / (el * 10000) }')"
        fi
        [ -n "$dk_usec" ] && SB_DK_PREV="$(sb_series_set "$SB_DK_PREV" "$dk_name" "$dk_usec")"
        SER_DK="$(sb_series_set "$SER_DK" "$dk_name" \
          "$(sb_push "$(sb_series_get "$SER_DK" "$dk_name")" "$dk_pct")")"
        SB_DOCKER="$SB_DOCKER$dk_name|$dk_state|$(sb_dk_short "$dk_status")|$dk_mem|$dk_pct
"
      done <<< "$dk_out"
    fi
    SB_DK_T=$SECONDS
  fi
  case "$SB_DK_ST" in
    up) SER_DKUP="$(sb_push "$SER_DKUP" "$SB_DK_UP")" ;;
    down) SER_DKUP="$(sb_push "$SER_DKUP" x)" ;;
    *) SER_DKUP="$(sb_push "$SER_DKUP" '')" ;;
  esac

  SB_MOUNTS="$(sb_mounts)"
  SB_UNMOUNTED="$(sb_unmounted)"
  SB_FAILED=""
  command -v systemctl >/dev/null 2>&1 &&
    SB_FAILED="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')"

  # Series. Whole watts and hundredths of load: a glyph is the resolution here, so
  # decimals would be carried around for nothing.
  SER_BAT="$(sb_push "$SER_BAT" "$SB_CAP")"
  w=""
  [ -n "$SB_PW" ] && w="$(awk -v p="$SB_PW" 'BEGIN { printf "%d", p / 1000000 }')"
  SER_PW="$(sb_push "$SER_PW" "$w")"
  if [ "${SB_GW_ST:-}" = up ]; then
    SER_GW="$(sb_push "$SER_GW" "$(sb_rtt_tenths "$SB_GW_RTT")")"
  elif [ -n "${SB_GW_ST:-}" ]; then
    SER_GW="$(sb_push "$SER_GW" x)"
  else
    SER_GW="$(sb_push "$SER_GW" '')"
  fi
  if [ "${SB_NET_ST:-}" = up ]; then
    SER_NET="$(sb_push "$SER_NET" "$(sb_rtt_tenths "$SB_NET_RTT")")"
  else
    SER_NET="$(sb_push "$SER_NET" x)"
  fi
  # Charted against the FLEET, not the tailnet, wherever a manifest exists: a sleeping
  # phone is a tailnet peer going offline and it is not news, so counting it left the
  # row permanently amber — which is how a warning colour stops meaning anything.
  case "${SB_TS_ST:-}" in
    up)
      if [ -n "$SB_FLEET" ]; then SER_TS="$(sb_push "$SER_TS" "$SB_FLEET_UP")"
      else SER_TS="$(sb_push "$SER_TS" "$SB_TS_PEERS")"; fi ;;
    down) SER_TS="$(sb_push "$SER_TS" x)" ;;
    *) SER_TS="$(sb_push "$SER_TS" '')" ;;
  esac
  SER_LOAD="$(sb_push "$SER_LOAD" "$(awk '{ printf "%d", $1 * 100 }' /proc/loadavg 2>/dev/null)")"

  # Platform draw. Sampled here rather than on the fast path because it is a DELTA:
  # the window between two probes is the averaging interval, which makes one probe
  # one chart cell — the same relationship the disk throughput series has.
  #
  # Re-resolved while it is still missing, rather than only at startup. The energy
  # counter is root-readable by default and a unit widens it (tier_rapl_read), so a
  # board that came up first would otherwise be stuck at "no domain" until its next
  # restart — and on the kiosk a restart costs an hour of chart history. Four failed
  # globs per probe is a cheaper standing cost than that.
  [ -n "$SB_RAPL_DIR" ] || {
    IFS='|' read -r SB_RAPL_DIR SB_RAPL_NAME <<< "$(sb_rapl_pick)"
    [ -n "$SB_RAPL_DIR" ] && SB_RAPL_MAX="$(_read "$SB_RAPL_DIR/max_energy_range_uj")"
  }
  if [ -n "$SB_RAPL_DIR" ]; then
    local e_now
    e_now="$(_read "$SB_RAPL_DIR/energy_uj")"
    SB_PSYS="$(sb_rapl_watts "$SB_RAPL_PREV" "$e_now" "$SB_RAPL_MAX" "$((SECONDS - SB_RAPL_T))")"
    SB_RAPL_PREV="$e_now"
    SB_RAPL_T=$SECONDS
  fi
  w=""
  [ -n "$SB_PSYS" ] && w="$(awk -v p="$SB_PSYS" 'BEGIN { printf "%d", p / 1000000 }')"
  SER_PSYS="$(sb_push "$SER_PSYS" "$w")"

  # One series per mounted filesystem, keyed by mount point, pruned to what is
  # mounted right now so an unplugged dock cannot leave a stale chart behind.
  #
  # The value is THROUGHPUT, not fill level: the elapsed time is measured rather than
  # assumed to be PROBE, because the first sample after startup and any probe that
  # ran long would otherwise scale the delta by the wrong divisor.
  local dev mnt total pct keys="" cur prev el mbs
  local disk disks="" busy="" spinners=""
  el=$((SECONDS - SB_IO_T))
  [ "$el" -ge 1 ] || el=1
  # The used field is read into _ : df still reports it, the board no longer shows it.
  while IFS='|' read -r dev mnt _ total pct state; do
    [ -n "$mnt" ] || continue
    keys="$keys $mnt"
    # A vanished device has no diskstats row, so this is already a gap — asking
    # anyway would be one fork per dead mount per probe for a guaranteed empty.
    cur=""
    [ "$state" = ok ] && cur="$(sb_dev_sectors "$dev")"
    prev="$(sb_series_get "$SB_IO_PREV" "$mnt")"
    mbs="$(sb_io_mbs "$prev" "$cur" "$el")"
    SER_DISKS="$(sb_series_set "$SER_DISKS" "$mnt" \
      "$(sb_push "$(sb_series_get "$SER_DISKS" "$mnt")" "$mbs")")"
    SB_IO_PREV="$(sb_series_set "$SB_IO_PREV" "$mnt" "$cur")"

    # Which physical drive this filesystem sits on, resolved here rather than in the
    # frame: the frame repaints every second and this is a readlink.
    disk=""
    [ "$state" = ok ] && disk="$(sb_disk_of "$dev")"
    SB_DISKOF="$(sb_series_set "$SB_DISKOF" "$mnt" "$disk")"
    [ -n "$disk" ] || continue
    case " $disks " in *" $disk "*) : ;; *) disks="$disks $disk" ;; esac
    # Nonzero throughput on ANY of a drive's filesystems means the drive is spinning
    # right now, which is what makes asking it for a temperature free.
    if [ -n "$mbs" ] && [ "$mbs" -gt 0 ] 2>/dev/null; then
      case " $busy " in *" $disk "*) : ;; *) busy="$busy $disk" ;; esac
    fi
  done <<< "$SB_MOUNTS"
  SB_IO_T=$SECONDS
  # shellcheck disable=SC2086
  SER_DISKS="$(sb_series_keep "$SER_DISKS" $keys)"
  # shellcheck disable=SC2086
  SB_IO_PREV="$(sb_series_keep "$SB_IO_PREV" $keys)"
  # shellcheck disable=SC2086
  SB_DISKOF="$(sb_series_keep "$SB_DISKOF" $keys)"

  # Temperatures, in two tiers with very different costs.
  #
  # hwmon is free — a sysfs read — so every drive that has one is refreshed on every
  # probe. That covers both NVMe drives here outright.
  #
  # SMART over the USB bridges is not free: a fork, root, and 0.1-0.6s per drive
  # measured on latitude. Five spinners polled every probe would spend a fifth of the
  # board's time in smartctl, so at most ONE is asked per probe, round-robin.
  #
  # And a spinner is only asked when asking is FREE — which is either because it is
  # already doing IO, or because its APM level forbids it parking at all (see
  # sb_apm_parks for why the APM level and not `-n standby` is the gate). A drive that
  # can park and is idle is left alone: waking it every probe to read a temperature
  # would cost it exactly the wear the reading is meant to warn about, and sdg has
  # already passed 639k load cycles. It keeps its last figure, which is honest — a
  # drive doing nothing is not changing temperature quickly.
  for disk in $disks; do
    SB_ROTA="$(sb_series_set "$SB_ROTA" "$disk" "$(sb_rotational "$disk")")"
    cur="$(sb_hwmon_temp "$disk")"
    if [ -n "$cur" ]; then
      SB_TEMPS="$(sb_series_set "$SB_TEMPS" "$disk" "$cur")"
    elif [ "$(sb_series_get "$SB_ROTA" "$disk")" = 1 ]; then
      spinners="$spinners $disk"
    fi
  done
  if [ -n "$spinners" ]; then
    local rr parks i n idx cand=""
    # Word splitting is the point — $spinners is a space-joined list.
    # shellcheck disable=SC2206
    rr=($spinners)
    n="${#rr[@]}"
    # The cursor is clamped rather than wrapped with %, so unplugging a dock
    # mid-rotation cannot leave it pointing past the end of a shorter list.
    [ "$SB_TEMP_RR" -lt "$n" ] || SB_TEMP_RR=0
    # SCAN from the cursor rather than taking whatever it happens to point at, and take
    # BUSY drives first. The plain round-robin skipped a drive that was spinning in this
    # probe merely because its turn had not come up — and eligibility for a
    # standby-capable drive is per-probe, so a missed burst meant reading `-` for as
    # long as it stayed idle afterwards. Here that is precisely the two drives carrying
    # the backups (sdd, sdg).
    #
    # Busy first also means no APM query for a drive that is already spinning: being
    # busy is sufficient on its own, so the cheaper test is the one asked first.
    #
    # Still exactly ONE temperature read per probe. The scan picks which drive to spend
    # it on; it never spends more.
    for ((i = 0; i < n; i++)); do
      idx=$(((SB_TEMP_RR + i) % n))
      case " $busy " in
        *" ${rr[$idx]} "*) cand="${rr[$idx]}"; SB_TEMP_RR=$((idx + 1)); break ;;
      esac
    done
    # Nothing spinning, so fall back to the drives that cannot park anyway. Their APM
    # level is learned lazily here and cached for the process lifetime: worst case one
    # fork per spinner across the first few probes, then never again.
    if [ -z "$cand" ]; then
      for ((i = 0; i < n; i++)); do
        idx=$(((SB_TEMP_RR + i) % n))
        disk="${rr[$idx]}"
        parks="$(sb_series_get "$SB_PARKS" "$disk")"
        if [ -z "$parks" ]; then
          parks="$(sb_drive_parks "$disk")"
          SB_PARKS="$(sb_series_set "$SB_PARKS" "$disk" "$parks")"
        fi
        [ "$parks" = no ] && { cand="$disk"; SB_TEMP_RR=$((idx + 1)); break; }
      done
    fi
    if [ -n "$cand" ]; then
      cur="$(sb_smart_temp "$cand")"
      [ -n "$cur" ] && SB_TEMPS="$(sb_series_set "$SB_TEMPS" "$cand" "$cur")"
    fi
  fi
  # shellcheck disable=SC2086
  SB_TEMPS="$(sb_series_keep "$SB_TEMPS" $disks)"
  # shellcheck disable=SC2086
  SB_ROTA="$(sb_series_keep "$SB_ROTA" $disks)"
  # shellcheck disable=SC2086
  SB_PARKS="$(sb_series_keep "$SB_PARKS" $disks)"
}

# ── Frame ─────────────────────────────────────────────────────────────────────
# Rows are collected first and painted second. The text column is padded to the
# widest row in the frame, and that width is not knowable until every row exists —
# which is also what keeps the chart column aligned as values change width
# ("41.4W ~0h26m to full" one frame, "5.2W" the next).
SB_ROW_TEXT=(); SB_ROW_SERIES=(); SB_ROW_MAX=(); SB_ROW_POL=(); SB_ROW_UNIT=()

# sb_row <text> [series-csv] [chart-max] [polarity] [unit]: queue one row. No series
# means no chart (headings, blank separators, and the flat rows where a chart would
# say nothing). Polarity is which end of the chart is the bad end — see
# sb_heat_color. Unit is the label printed to the right of the chart: one column
# carrying six different metrics needs to say which is which, per row, where the eye
# already is.
sb_row() {
  SB_ROW_TEXT+=("$1"); SB_ROW_SERIES+=("${2:-}"); SB_ROW_MAX+=("${3:-100}")
  SB_ROW_POL+=("${4:-hi-bad}"); SB_ROW_UNIT+=("${5:-}")
}

# ── Pages ─────────────────────────────────────────────────────────────────────
# One entry per page, in rotation order. The name is both what the tabs print and the
# emitter that is called for it (sb_page_<name>), so adding a page is adding a
# function and a word to this list.
#
# The pages exist because the frame's binding constraint is VERTICAL: 25 rows into 27,
# with the mount list and the conditional rows able to eat the rest. Rotating costs
# nothing an unattended board misses — the alert strip is on every page precisely so
# a hidden page cannot hide a failure.
SB_PAGES=(system fleet docker)
# Seconds each page holds before the board rotates. Long enough to read a full frame,
# short enough that a glance from across the room catches every page inside a minute.
SB_PAGE_SECS="${STATUSBOARD_PAGE_SECS:-15}"
SB_PAGE=0        # index into SB_PAGES — which page is on screen
SB_PAGE_HOLD=0   # 1 while a keypress has paused the rotation
next_page=0      # $SECONDS at which the next rotation is due

# --page (and --once --page) pick a starting page BY NAME. Resolved here rather than
# during argument parsing, because the page set is defined here: an unknown name is a
# usage error and must not silently paint page 1.
if [ -n "${SB_PAGE_ARG:-}" ]; then
  SB_PAGE=-1
  for ((_i = 0; _i < ${#SB_PAGES[@]}; _i++)); do
    [ "${SB_PAGES[_i]}" = "$SB_PAGE_ARG" ] && SB_PAGE="$_i"
  done
  if [ "$SB_PAGE" -lt 0 ]; then
    printf 'unknown page: %s (have: %s)\n' "$SB_PAGE_ARG" "${SB_PAGES[*]}" >&2
    exit 2
  fi
fi

# sb_alerts: every condition worth the strip, one "sev:text" per line, and NOTHING
# else — no forks, no probes. It reads only what sb_sample_* already sampled, because
# it runs inside the frame subshell on every paint.
#
# The severities are a judgement about what wakes someone up. A filesystem at 95%, a
# vanished mount and a failed unit are bad; a peer offline, a disk at 90% and a box
# that has fallen back to battery are warnings — real, but they do not mean the box
# has stopped doing its job.
sb_alerts() {
  local dev mnt total pct state count=0
  if [ -n "${SB_FAILED:-}" ] && [ "${SB_FAILED:-0}" -gt 0 ] 2>/dev/null; then
    printf 'bad:%s unit%s failed\n' "$SB_FAILED" "$([ "$SB_FAILED" = 1 ] || printf s)"
  fi
  # A mount whose backing device is gone: df goes on reporting its last-known size, so
  # without this the strip would call a vanished disk healthy.
  count=0
  while IFS='|' read -r dev mnt _ total pct state; do
    [ -n "$mnt" ] || continue
    [ "${state:-ok}" = ok ] || { count=$((count + 1)); continue; }
    case "$pct" in '' | *[!0-9]*) continue ;; esac
    if [ "$pct" -ge 95 ]; then printf 'bad:%s %s%% full\n' "$mnt" "$pct"
    elif [ "$pct" -ge 90 ]; then printf 'warn:%s %s%% full\n' "$mnt" "$pct"; fi
  done <<< "${SB_MOUNTS:-}"
  [ "$count" -gt 0 ] && printf 'bad:%s mount%s gone\n' "$count" "$([ "$count" = 1 ] || printf s)"
  case "${SB_LAN_ST:-}" in up | '') : ;; *) printf 'bad:lan down\n' ;; esac
  case "${SB_GW_ST:-}" in up | '') : ;; *) printf 'bad:gateway unreachable\n' ;; esac
  case "${SB_NET_ST:-}" in up | '') : ;; *) printf 'bad:no internet\n' ;; esac
  if [ "${SB_TS_ST:-}" = down ]; then
    printf 'bad:tailnet down\n'
  elif [ "${SB_TS_ST:-}" = up ] && [ -n "$SB_FLEET" ]; then
    sb_fleet_alerts "$SB_FLEET_ROWS"
  elif [ "${SB_TS_ST:-}" = up ] && [ "${SB_TS_PEERS:-0}" -lt "${SB_TS_TOTAL:-0}" ] 2>/dev/null; then
    # No manifest to name them by — fall back to the count.
    count=$((SB_TS_TOTAL - SB_TS_PEERS))
    printf 'warn:%s peer%s offline\n' "$count" "$([ "$count" = 1 ] || printf s)"
  fi
  # On an always-on box wired to the wall, running on battery IS the alert — it is the
  # only warning of a power cut that reaches the screen before the box dies.
  case "${SB_ST:-}" in
    Discharging)
      if [ -n "${SB_CAP:-}" ] && [ "${SB_CAP:-100}" -lt 20 ] 2>/dev/null; then
        printf 'bad:on battery, %s%%\n' "$SB_CAP"
      elif [ -n "${SB_CAP:-}" ]; then
        printf 'warn:on battery, %s%%\n' "$SB_CAP"
      else
        printf 'warn:on battery\n'
      fi
      ;;
  esac
  [ -n "${SB_UNMOUNTED:-}" ] && printf 'warn:disks unmounted\n'
  if [ "${SB_DK_ST:-}" = down ]; then
    printf 'bad:docker unreachable\n'
  elif [ "${SB_DK_ST:-}" = up ]; then
    sb_docker_alerts "$SB_DOCKER"
  fi
  return 0
}

# sb_page_docker: the container stacks, one row each. This box runs its services as
# compose stacks, so "is the box up" and "are the services up" are different questions
# and the second one needs the rows.
#
# Local docker only. Reaching the Windows members' Docker Desktop needs the metrics bus;
# this page needs nothing that is not already on this machine, which is why it lands
# before the bus rather than behind it.
sb_page_docker() {
  local name state status mem pct glyph col up_col namew=4 statw=6
  case "$SB_DK_ST" in
    n/a)
      sb_row "$(printf '%sno docker on this box%s' "$C_DIM" "$C_RST")"
      return 0 ;;
    down)
      sb_row "$(printf 'docker   %s  %sdaemon unreachable%s' "$(sb_status_glyph down)" \
        "$C_BAD" "$C_RST")" "$SER_DKUP" 1 hi-good ctr
      return 0 ;;
  esac
  up_col="$C_DIM"
  [ "$SB_DK_UP" -lt "$SB_DK_TOTAL" ] && up_col="$C_WARN"
  sb_row "$(printf 'docker   %s  %s%s/%s running%s' "$(sb_status_glyph up)" \
    "$up_col" "$SB_DK_UP" "$SB_DK_TOTAL" "$C_RST")" \
    "$SER_DKUP" "${SB_DK_TOTAL:-1}" hi-good ctr
  [ "$SB_DK_TOTAL" -gt 0 ] || return 0
  sb_row ""
  # The name column is CAPPED, unlike every other page's. Container names are unbounded
  # — `docker compose run` mints things like 5355-pure-api-app-run-4135a6842430 (34
  # characters) — and the text column is what the charts get the remainder of. One such
  # container would otherwise take the chart column down to nothing for every row on the
  # page, which is the failure the six-disk "not mounted" row caused historically.
  # Truncated for DISPLAY only: the series stays keyed by the full name, so two
  # containers whose names share a prefix cannot end up sharing a chart.
  local dispname phase shown=0
  while IFS='|' read -r name _ status _ _; do
    [ -n "$name" ] || continue
    dispname="$name"
    [ "${#dispname}" -gt "$SB_DK_NAMEW" ] && dispname="${dispname:0:$((SB_DK_NAMEW - 1))}>"
    [ "${#dispname}" -gt "$namew" ] && namew="${#dispname}"
    [ "${#status}" -gt "$statw" ] && statw="${#status}"
  done <<< "$SB_DOCKER"

  # Stopped containers FIRST, then running ones, and the list is capped. `docker ps -a`
  # counts exited containers, which accumulate on a box that has been running compose
  # for months — so the row count is unbounded in exactly the dimension the frame cannot
  # afford. Ordering by "not running first" means the cap can only ever hide healthy
  # containers, and the count of what it hid is printed rather than left silent.
  for phase in stopped running; do
    while IFS='|' read -r name state status mem pct; do
      [ -n "$name" ] || continue
      case "$phase:$state" in
        stopped:running) continue ;;
        running:running) ;;
        running:*) continue ;;
      esac
      [ "$shown" -ge "$SB_DK_ROWS" ] && break 2
      shown=$((shown + 1))
      case "$state" in
        running) glyph=ok;   col="$C_DIM" ;;
        restarting | paused | created) glyph=warn; col="$C_WARN" ;;
        *) glyph=down; col="$C_BAD" ;;
      esac
      # A container that is up and failing its own health check is the most useful thing
      # this page can say, and it is invisible in any running/total count — so the status
      # column overrides the state's colour when docker reports it unhealthy.
      case "$status" in *UNHEALTHY*) col="$C_BAD" ;; esac
      dispname="$name"
      [ "${#dispname}" -gt "$SB_DK_NAMEW" ] && dispname="${dispname:0:$((SB_DK_NAMEW - 1))}>"
      sb_row "$(printf '%-*s %s  %s%-*s%s %s%5s %3s%%%s' \
        "$namew" "$dispname" "$(sb_status_glyph "$glyph")" \
        "$col" "$statw" "$status" "$C_RST" \
        "$C_DIM" "$(sb_mib "$mem")" "${pct:-0}" "$C_RST")" \
        "$(sb_series_get "$SER_DK" "$name")" "$SB_MAX_DKCPU" flat '%cpu'
    done <<< "$SB_DOCKER"
  done
  if [ "$SB_DK_TOTAL" -gt "$shown" ]; then
    # Not "all running": with more stopped containers than the cap, the hidden ones are
    # stopped too. The count is what is honest without a second pass to classify them.
    sb_row "$(printf '%s+%s more not shown%s' "$C_DIM" $((SB_DK_TOTAL - shown)) "$C_RST")"
  fi
  return 0
}

# sb_page_fleet: one row per manifest member, which is the point — the system page can
# only ever say how MANY peers are up, and the question a fleet raises is WHICH.
#
# Every column here is free: it all comes out of the single `tailscale status` fork the
# system page's tailnet row already pays for. Uptime, disks and converge state per
# member need the metrics bus, and land on this page when it exists.
sb_page_fleet() {
  local name ip plat state age glyph col statetxt namew=4 statew=5
  if [ -z "$SB_FLEET" ]; then
    sb_row "$(printf '%sno fleet manifest at %s%s' "$C_DIM" "$SB_FLEET_JSON" "$C_RST")"
    return 0
  fi
  # Two passes, for the same reason the disk rows take two: the columns are as wide as
  # their widest value, which is not known until every row has been seen. Padded with
  # printf's own %-*s rather than sb_pad — these fields carry no escapes, so there is
  # no reason to spend a fork per field per paint on measuring them.
  while IFS='|' read -r name _ _ state age; do
    case "$name" in '' | _others) continue ;; esac
    [ "${#name}" -gt "$namew" ] && namew="${#name}"
    statetxt="$state${age:+ $age}"
    [ "${#statetxt}" -gt "$statew" ] && statew="${#statetxt}"
  done <<< "$SB_FLEET_ROWS"

  while IFS='|' read -r name ip plat state age; do
    [ -n "$name" ] || continue
    if [ "$name" = _others ]; then
      # The counts ride in the ip and platform fields on this line — see sb_fleet_join.
      [ "${ip:-0}" -gt 0 ] 2>/dev/null || continue
      sb_row ""
      sb_row "$(printf '%s%s non-fleet node%s, %s online%s' "$C_DIM" "$ip" \
        "$([ "$ip" = 1 ] || printf s)" "$plat" "$C_RST")"
      continue
    fi
    case "$state" in
      self | direct | idle) glyph=ok;   col="$C_DIM" ;;
      # A relay works, it just works worse — the fleet is up but two boxes could not
      # find each other, which is worth amber and is invisible in any peer count.
      relay)                glyph=warn; col="$C_WARN" ;;
      offline | missing)    glyph=down; col="$C_BAD" ;;
      *)                    glyph="";   col="$C_DIM" ;;
    esac
    sb_row "$(printf '%-*s %s  %s%-11s%s %s%-*s%s %s%s%s' \
      "$namew" "$name" "$(sb_status_glyph "$glyph")" \
      "$C_DIM" "${ip:--}" "$C_RST" \
      "$col" "$statew" "$state${age:+ $age}" "$C_RST" \
      "$C_DIM" "${plat:--}" "$C_RST")" \
      "$(sb_series_get "$SER_PEERS" "$name")" 1 hi-good up
  done <<< "$SB_FLEET_ROWS"
  return 0
}

# sb_page_system: the board as it was before there were pages — power, network,
# uptime, filesystems, units.
sb_page_system() {
  sb_row "$(sb_battery_line "$SB_CAP" "$SB_ST" "$SB_PW" "$SB_EN" "$SB_EF")" "$SER_BAT" 100 hi-good '%'
  # Draw is activity, not condition: 40W into a charging battery is not an alarm.
  sb_row "$(printf 'source    %s' "$SB_SRC")" "$SER_PW" "$SB_MAX_PW" flat W
  # Consumption, and flat for the same reason: a busy machine drawing more is the
  # machine working, not a fault. Charted against the same 65W ceiling as the source
  # row so the two can be read against each other — what comes in versus what the
  # platform spends. Suppressed entirely where RAPL is unreadable rather than shown
  # as a permanent n/a, since on such a box it is not a reading that has gone missing.
  [ -n "$SB_RAPL_DIR" ] &&
    sb_row "$(sb_power_line "${SB_PSYS:-}" "$SB_RAPL_NAME")" "$SER_PSYS" "$SB_MAX_PW" flat W
  [ -n "${SB_LIM:-}" ] && sb_row "$(sb_limit_line "$SB_LIM" "${SB_LIM_MODE:-}")"
  sb_row ""

  # No chart. The series is binary, so at a ceiling of 1 every cell was the top
  # glyph — a solid bar that said exactly what the ok/down glyph beside it already
  # said, in the loudest colour on the board. A link that flaps still shows up: the
  # gateway RTT chart gaps at the same moment.
  sb_row "$(printf 'lan      %s  %s%s %s%s' "$(sb_status_glyph "$SB_LAN_ST")" \
    "$C_DIM" "${SB_LAN_DEV:--}" "${SB_LAN_IP:--}" "$C_RST")"
  # The RTT is the number that goes bad, so it carries its own colour while the
  # address next to it stays dim. Thresholds are in tenths of a ms, matching what the
  # series is scaled in: a LAN gateway over 5ms is odd, over 20ms is wrong.
  [ -n "${SB_GW_ST:-}" ] && sb_row "$(printf 'gateway  %s  %s%s %s%s%s' "$(sb_status_glyph "$SB_GW_ST")" \
    "$C_DIM" "$SB_LAN_GW" "$(sb_hi_colour "$(sb_rtt_tenths "${SB_GW_RTT:-}")" 50 200)" \
    "${SB_GW_RTT:-}" "$C_RST")" "$SER_GW" "$SB_MAX_GW" hi-bad ms
  sb_row "$(printf 'internet %s  %s%s%s' "$(sb_status_glyph "$SB_NET_ST")" \
    "$(sb_hi_colour "$(sb_rtt_tenths "${SB_NET_RTT:-}")" 500 2000)" "${SB_NET_RTT:--}" "$C_RST")" \
    "$SER_NET" "$SB_MAX_NET" hi-bad ms
  if [ "${SB_TS_ST:-}" = up ]; then
    # Scaled against the peer TOTAL, so a full chart means "the whole fleet was
    # up" and a dip means peers dropped — not just "some number of peers".
    # A missing peer is the bad number here, so the count carries the colour: amber
    # while any peer is down, dim only when the whole fleet is up.
    # Counted over the FLEET where there is a manifest, and over raw tailnet peers only
    # where there is not. The tailnet also carries a phone and a scratch WSL distro, and
    # counting those meant the row sat amber whenever a phone was asleep — a warning
    # colour that is always on is a warning colour that says nothing. The strangers are
    # still shown, dim, because they are not nothing either.
    local ts_col="$C_DIM" ts_up ts_tot ts_what="peers" ts_extra=""
    if [ -n "$SB_FLEET" ]; then
      ts_up="$SB_FLEET_UP"; ts_tot="$SB_FLEET_TOTAL"; ts_what="fleet"
      [ "${SB_FLEET_OTHERS:-0}" -gt 0 ] 2>/dev/null &&
        ts_extra="$(printf '  %s+%s other%s%s' "$C_DIM" "$SB_FLEET_OTHERS" \
          "$([ "$SB_FLEET_OTHERS" = 1 ] || printf s)" "$C_RST")"
    else
      ts_up="$SB_TS_PEERS"; ts_tot="$SB_TS_TOTAL"
    fi
    [ "${ts_up:-0}" -lt "${ts_tot:-0}" ] 2>/dev/null && ts_col="$C_WARN"
    sb_row "$(printf 'tailnet  %s  %s%s  %s%s/%s %s online%s%s' "$(sb_status_glyph up)" \
      "$C_DIM" "$SB_TS_IP" "$ts_col" "$ts_up" "$ts_tot" "$ts_what" "$C_RST" "$ts_extra")" \
      "$SER_TS" "${ts_tot:-1}" hi-good "$ts_what"
  else
    sb_row "$(printf 'tailnet  %s' "$(sb_status_glyph "$SB_TS_ST")")" "$SER_TS" 1 hi-good peers
  fi
  sb_row ""

  # Load thresholds are per-CPU: one runnable process per core is a busy box, two is
  # a queue. In hundredths, matching the series.
  local load1="" load_col="$C_DIM"
  load1="$(awk '{ printf "%d", $1 * 100 }' /proc/loadavg 2>/dev/null)"
  [ -n "$load1" ] && load_col="$(sb_hi_colour "$load1" $((SB_NCPU * 100)) $((SB_NCPU * 200)))"
  sb_row "$(printf 'uptime    %s%s%s   load %s%s%s' "$C_DIM" "$(sb_secs_to_hm "$SB_UP")" "$C_RST" \
    "$load_col" "${SB_LOAD:-n/a}" "$C_RST")" "$SER_LOAD" $((SB_NCPU * 100)) hi-bad load
  sb_row ""

  # Two passes over the mount list: the bar lengths are relative to the LARGEST disk
  # present, which is not known until every disk has been seen.
  local d_dev d_mnt d_total d_pct d_max=0
  while IFS='|' read -r _ _ _ d_total _ d_state; do
    case "$d_total" in '' | *[!0-9]*) continue ;; esac
    # A dead mount's size is stale, so it does not get to set the scale every live
    # disk is measured against.
    [ "$d_state" = ok ] || continue
    [ "$d_total" -gt "$d_max" ] && d_max="$d_total"
  done <<< "$SB_MOUNTS"
  local d_state d_disk
  while IFS='|' read -r d_dev d_mnt _ d_total d_pct d_state; do
    [ -n "$d_mnt" ] || continue
    # Both lookups are keyed by DRIVE, not by mount: temperature belongs to the
    # hardware, so every filesystem on one disk shows the same figure.
    d_disk="$(sb_series_get "$SB_DISKOF" "$d_mnt")"
    sb_row "$(sb_disk_row "$d_dev" "$d_mnt" "$d_total" "$d_pct" "$d_max" "${d_state:-ok}" \
      "$(sb_series_get "$SB_TEMPS" "$d_disk")" "$(sb_series_get "$SB_ROTA" "$d_disk")")" \
      "$(sb_series_get "$SER_DISKS" "$d_mnt")" "$SB_MAX_IO" flat MB/s
  done <<< "$SB_MOUNTS"
  # A dock that came back with nothing mounted is otherwise invisible on a headless
  # box, so it gets a row of its own rather than silently missing from the list.
  [ -n "${SB_UNMOUNTED:-}" ] && sb_row "$(printf 'not mounted      %s%s%s' "$C_WARN" "$SB_UNMOUNTED" "$C_RST")"
  if [ -n "${SB_FAILED:-}" ]; then
    if [ "${SB_FAILED:-0}" -gt 0 ]; then
      sb_row "$(printf 'units     %s%s failed%s' "$C_BAD" "$SB_FAILED" "$C_RST")"
    else
      sb_row "$(printf 'units     %sall ok%s' "$C_DIM" "$C_RST")"
    fi
  fi

  return 0
}

# render_frame [page]: the shared tail — layout, header, strip, rule, paint. The rows
# themselves come from whichever page emitter is named, defaulting to the one on
# screen.
render_frame() {
  local page="${1:-${SB_PAGES[SB_PAGE]}}"
  SB_ROW_TEXT=(); SB_ROW_SERIES=(); SB_ROW_MAX=(); SB_ROW_POL=(); SB_ROW_UNIT=()
  "sb_page_$page"

  # Layout: the widest CHARTED row wins the text column, and the charts take
  # everything left. Only charted rows count — a row with no chart is free to run
  # long, so the "not mounted" list of six disks cannot squeeze the chart column for
  # every other row (it did: 107 columns of text left 10 cells of chart on a 120-col
  # console after the font was doubled).
  #
  # Computed PER PAGE, deliberately: each page gets the full chart width its own rows
  # allow. Taking the widest text column across every page would keep the charts from
  # shifting as the board rotates, at the price of squeezing every page down to the
  # worst one — and the chart width is what the board is for.
  local i vis textw=0 unitw=0 chartw cols
  for ((i = 0; i < ${#SB_ROW_TEXT[@]}; i++)); do
    [ -n "${SB_ROW_SERIES[i]}" ] || continue
    vis="$(sb_vislen "${SB_ROW_TEXT[i]}")"
    [ "$vis" -gt "$textw" ] && textw="$vis"
    # The unit column is as wide as its widest label, so the labels line up as a
    # column instead of ragging along the right edge of the charts.
    vis="${#SB_ROW_UNIT[i]}"
    [ "$vis" -gt "$unitw" ] && unitw="$vis"
  done
  cols="$(sb_cols "$SB_ISTTY")"
  chartw="$(sb_chart_width "$cols" "$textw" $((unitw > 0 ? unitw + 1 : 0)))"

  # Header. The span marker is not decoration: the same picture is 20 minutes at
  # the tty1 interval and over an hour in the tmux window.
  local span=""
  [ "$chartw" -gt 0 ] && span="$(printf '   %scharts: last %s (%s/cell, %ss samples)%s' \
    "$C_DIM" "$(sb_span "$chartw" "$SB_CELL_SECS")" "$(sb_dur "$SB_CELL_SECS")" "$PROBE" "$C_RST")"
  # The clock is the one thing on this board read from across the room, and it is also
  # how you tell a live frame from a frozen one — so the TIME is bright and the date
  # beside it stays dim. One `date` call: two would let the seconds disagree.
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s%s%s   %s%s%s %s%s%s%s\n' "$C_B$C_INFO" "$(hostname)" "$C_RST" \
    "$C_DIM" "${now%% *}" "$C_RST" "$C_B" "${now##* }" "$C_RST" "$span"
  local rule=60 dashes="" rulech='-'
  [ "$(sb_ramp_name)" = ascii ] || rulech='─'
  [ "$chartw" -gt 0 ] && rule=$((textw + 3 + chartw))
  for ((i = 0; i < rule; i++)); do dashes="$dashes$rulech"; done
  printf '%s%s%s\n' "$C_DIM" "$dashes" "$C_RST"

  # The strip, at a fixed line on every page — see sb_alert_line. One row is what it
  # costs, forever, which is why it gets no separator rule of its own.
  #
  # Its left field is the page tabs once there is more than one page, and the word
  # "alerts" while there is only one: the tabs are the more useful thing to spend
  # those columns on, and their visible width is constant, so the alert text does not
  # move when the board rotates. Trimmed like an uncharted row, since a wrapped line
  # scrolls the whole repainting frame.
  local strip_label alerts_txt strip al
  local -a alerts=()
  while IFS= read -r al; do [ -n "$al" ] && alerts+=("$al"); done <<< "$(sb_alerts)"
  alerts_txt="$(sb_alert_line ${alerts[@]+"${alerts[@]}"})"
  if [ "${#SB_PAGES[@]}" -gt 1 ]; then
    strip_label="$(sb_page_tabs "$SB_PAGE" "${SB_PAGES[@]}")"
  else
    strip_label="alerts"
  fi
  strip="$(printf '%s   %s' "$strip_label" "$alerts_txt")"
  if [ "$cols" -gt 0 ]; then printf '%s\n\n' "$(sb_trim "$strip" "$cols")"
  else printf '%s\n\n' "$strip"; fi

  for ((i = 0; i < ${#SB_ROW_TEXT[@]}; i++)); do
    if [ "$chartw" = 0 ] || [ -z "${SB_ROW_SERIES[i]}" ]; then
      # Uncharted rows are trimmed rather than padded: they are the only ones that
      # can be longer than the frame (the six-disk "not mounted" list on an
      # 80-column client), and a wrapped row scrolls the whole repainting frame.
      if [ "$cols" -gt 0 ]; then
        printf '%s\n' "$(sb_trim "${SB_ROW_TEXT[i]}" "$cols")"
      else
        printf '%s\n' "${SB_ROW_TEXT[i]}"
      fi
    else
      # No C_DIM wrapper any more: the chart carries its own per-level colour and
      # resets itself. SGR 2 composed with a 38;2 foreground is terminal-dependent
      # — foot dims it, others drop one of the two — so the two never overlap.
      # The unit label rides at the right edge of the chart, padded to the column
      # width so it reads as a column. It is what a chart column carrying six
      # different metrics needs to be readable: the label sits where the eye already
      # is, rather than in a legend at the bottom that has to be looked up.
      printf '%s   %s %s%s%s\n' "$(sb_pad "${SB_ROW_TEXT[i]}" "$textw")" \
        "$(sb_chart "$chartw" "${SB_ROW_MAX[i]}" "$(sb_fold "$SB_K" "${SB_ROW_SERIES[i]}")" \
          "${SB_ROW_POL[i]}")" \
        "$C_DIM" "$(sb_lpad "${SB_ROW_UNIT[i]}" "$unitw")" "$C_RST"
    fi
  done
  return 0
}

if [ "$ONCE" = 1 ]; then
  sb_sample_fast
  sb_sample_slow
  render_frame
  exit 0
fi

# Hide the cursor and restore it however we exit — a blinking cursor parked
# mid-frame on an unattended screen looks like a hung box.
[ -t 1 ] && printf '\033[?25l'
cleanup() { [ -t 1 ] && printf '\033[?25h\033[?7h'; }
trap cleanup EXIT INT TERM

# sb_wait_key: the pacing between paints, and the keyboard, in one call. `read -t` is
# the sleep, so a keypress is acted on the moment it arrives rather than up to
# INTERVAL later.
#
# ONLY when stdin is a terminal. With stdin closed or redirected — a unit with no tty,
# a pipe, a test — `read -t` returns instantly every iteration, which turns an
# unattended kiosk into a 100%-CPU spin loop. A board with no keyboard sleeps exactly
# as it did before pages existed.
#
# Manual selection HOLDS: picking a page means you want to look at it, and rotating
# away from it four seconds later is the opposite of the request. Space releases.
sb_wait_key() {
  local key="" idx
  if [ ! -t 0 ]; then sleep "$INTERVAL"; return 0; fi
  read -r -t "$INTERVAL" -n 1 key 2>/dev/null || true
  [ -n "$key" ] || return 0
  case "$key" in
    ' ')
      SB_PAGE_HOLD=$((1 - SB_PAGE_HOLD))
      # Releasing a hold restarts the dwell, so the page you were reading does not
      # flip away the instant you let go of it.
      [ "$SB_PAGE_HOLD" = 0 ] && next_page=$((SECONDS + SB_PAGE_SECS)) ;;
    n | N | ']')
      SB_PAGE=$(((SB_PAGE + 1) % ${#SB_PAGES[@]})); SB_PAGE_HOLD=1 ;;
    p | P | '[')
      SB_PAGE=$(((SB_PAGE - 1 + ${#SB_PAGES[@]}) % ${#SB_PAGES[@]})); SB_PAGE_HOLD=1 ;;
    [1-9])
      idx=$((key - 1))
      [ "$idx" -lt "${#SB_PAGES[@]}" ] && { SB_PAGE="$idx"; SB_PAGE_HOLD=1; } ;;
  esac
  return 0
}

# The probe clock is $SECONDS (shell uptime), not date arithmetic: it needs no fork
# and cannot drift against the loop, since it IS the loop's own elapsed time. The page
# clock is the same clock, for the same reason.
next_probe=0
next_page=$((SECONDS + SB_PAGE_SECS))
while :; do
  # Sample in this shell — the chart series must outlive the frame, and
  # frame="$(render_frame)" is a subshell.
  #
  # EVERY series is sampled on every probe, whichever page is on screen. Sampling only
  # what the visible page renders would gut the "one probe is one chart cell"
  # invariant: fifteen seconds on another page and the charts come back either holed
  # or, worse, with cells that lie about how much time they cover. Paging selects what
  # is RENDERED, never what is measured.
  sb_sample_fast
  if [ "$SECONDS" -ge "$next_probe" ]; then
    sb_sample_slow
    next_probe=$((SECONDS + PROBE))
  fi
  # Build the frame into a variable, then paint in one write: rendering straight to
  # the tty makes the display visibly tear on a slow VT.
  frame="$(render_frame)"
  [ -t 1 ] && printf '\033[H\033[2J'
  printf '%s\n' "$frame"
  sb_wait_key
  if [ "$SB_PAGE_HOLD" = 0 ] && [ "${#SB_PAGES[@]}" -gt 1 ] && [ "$SECONDS" -ge "$next_page" ]; then
    SB_PAGE=$(((SB_PAGE + 1) % ${#SB_PAGES[@]}))
    next_page=$((SECONDS + SB_PAGE_SECS))
  fi
done
