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
#   sudo bash statusboard.sh --install  # install + enable the tty1 service
#   sudo bash statusboard.sh --uninstall
#   sudo bash statusboard.sh --bigfont  # double the console font (16x32) on every VT
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
    --install) MODE=install; shift ;;
    --bigfont) MODE=bigfont; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# sb_disk_row <dev> <mount> <total_kb> <pct> [max_total_kb]: one filesystem.
#
# The used figure is gone on purpose: the bar already carries "how full", the total
# carries "how big", and a third number saying the same thing in GB was the widest
# field in the block for the least information in it.
#
# The bar is coloured by FREE space, so it greens down as the disk fills — the
# inverse of the battery row, where a high number is the healthy one.
sb_disk_row() {
  local dev="${1:-}" mnt="${2:-}" total="${3:-}" pct="${4:-}" maxtotal="${5:-}" state="${6:-ok}"
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
    printf '%-*s %s%s%s %s%3s%%  %5sG  %s%s' \
      "$SB_DISK_PATHW" "${mnt:-?}" \
      "$C_BAD" "$bar" "$C_RST" \
      "$C_DIM" "$pct" "$(sb_kb_to_gib "$total")" "${dev:-?}" "$C_RST"
    return
  fi
  printf '%-*s %s%s %3s%%%s  %5sG  %s%s%s' \
    "$SB_DISK_PATHW" "${mnt:-?}" \
    "$col" "$bar" "$pct" "$C_RST" \
    "$(sb_kb_to_gib "$total")" "$C_DIM" "${dev:-?}" "$C_RST"
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

sb_tailnet() {
  local ip peers total
  command -v tailscale >/dev/null 2>&1 || { printf 'n/a|||'; return; }
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] || { printf 'down|||'; return; }
  # `tailscale status` without --json: one line per peer, no jq dependency.
  total="$(tailscale status --peers 2>/dev/null | grep -cE '^100\.')"
  peers="$(tailscale status --peers 2>/dev/null | grep -E '^100\.' | grep -cvE ' offline| -$')"
  printf 'up|%s|%s|%s' "$ip" "${peers:-0}" "${total:-0}"
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
SER_BAT=""; SER_PW=""; SER_GW=""; SER_NET=""; SER_TS=""; SER_LOAD=""
SER_DISKS=""   # "mountpoint=csv" per line, one entry per mounted filesystem — MB/s
# Previous diskstats reading per mount, and when it was taken. Throughput is a
# DELTA, so it needs the last counter kept in the main shell for the same reason the
# series are: a value computed inside the frame subshell dies with it.
SB_IO_PREV=""
SB_IO_T=0
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
SB_TS_ST=""; SB_TS_IP=""; SB_TS_PEERS=""; SB_TS_TOTAL=""
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
  local w
  local IFS='|'
  read -r SB_LAN_ST SB_LAN_DEV SB_LAN_IP SB_LAN_GW <<< "$(sb_lan)"
  SB_GW_ST=""; SB_GW_RTT=""
  if [ -n "${SB_LAN_GW:-}" ] && [ "$SB_LAN_GW" != '?' ]; then
    read -r SB_GW_ST SB_GW_RTT <<< "$(sb_reach "$SB_LAN_GW")"
  fi
  read -r SB_NET_ST SB_NET_RTT <<< "$(sb_reach 1.1.1.1)"
  read -r SB_TS_ST SB_TS_IP SB_TS_PEERS SB_TS_TOTAL <<< "$(sb_tailnet)"
  unset IFS

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
  case "${SB_TS_ST:-}" in
    up) SER_TS="$(sb_push "$SER_TS" "$SB_TS_PEERS")" ;;
    down) SER_TS="$(sb_push "$SER_TS" x)" ;;
    *) SER_TS="$(sb_push "$SER_TS" '')" ;;
  esac
  SER_LOAD="$(sb_push "$SER_LOAD" "$(awk '{ printf "%d", $1 * 100 }' /proc/loadavg 2>/dev/null)")"

  # One series per mounted filesystem, keyed by mount point, pruned to what is
  # mounted right now so an unplugged dock cannot leave a stale chart behind.
  #
  # The value is THROUGHPUT, not fill level: the elapsed time is measured rather than
  # assumed to be PROBE, because the first sample after startup and any probe that
  # ran long would otherwise scale the delta by the wrong divisor.
  local dev mnt total pct keys="" cur prev el
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
    SER_DISKS="$(sb_series_set "$SER_DISKS" "$mnt" \
      "$(sb_push "$(sb_series_get "$SER_DISKS" "$mnt")" "$(sb_io_mbs "$prev" "$cur" "$el")")")"
    SB_IO_PREV="$(sb_series_set "$SB_IO_PREV" "$mnt" "$cur")"
  done <<< "$SB_MOUNTS"
  SB_IO_T=$SECONDS
  # shellcheck disable=SC2086
  SER_DISKS="$(sb_series_keep "$SER_DISKS" $keys)"
  # shellcheck disable=SC2086
  SB_IO_PREV="$(sb_series_keep "$SB_IO_PREV" $keys)"
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

render_frame() {
  SB_ROW_TEXT=(); SB_ROW_SERIES=(); SB_ROW_MAX=(); SB_ROW_POL=(); SB_ROW_UNIT=()

  sb_row "$(sb_battery_line "$SB_CAP" "$SB_ST" "$SB_PW" "$SB_EN" "$SB_EF")" "$SER_BAT" 100 hi-good '%'
  # Draw is activity, not condition: 40W into a charging battery is not an alarm.
  sb_row "$(printf 'source    %s' "$SB_SRC")" "$SER_PW" "$SB_MAX_PW" flat W
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
    local ts_col="$C_DIM"
    [ "${SB_TS_PEERS:-0}" -lt "${SB_TS_TOTAL:-0}" ] 2>/dev/null && ts_col="$C_WARN"
    sb_row "$(printf 'tailnet  %s  %s%s  %s%s/%s peers online%s' "$(sb_status_glyph up)" \
      "$C_DIM" "$SB_TS_IP" "$ts_col" "$SB_TS_PEERS" "$SB_TS_TOTAL" "$C_RST")" \
      "$SER_TS" "${SB_TS_TOTAL:-1}" hi-good peers
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
    "$load_col" "$SB_LOAD" "$C_RST")" "$SER_LOAD" $((SB_NCPU * 100)) hi-bad load
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
  local d_state
  while IFS='|' read -r d_dev d_mnt _ d_total d_pct d_state; do
    [ -n "$d_mnt" ] || continue
    sb_row "$(sb_disk_row "$d_dev" "$d_mnt" "$d_total" "$d_pct" "$d_max" "${d_state:-ok}")" \
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

  # Layout: the widest CHARTED row wins the text column, and the charts take
  # everything left. Only charted rows count — a row with no chart is free to run
  # long, so the "not mounted" list of six disks cannot squeeze the chart column for
  # every other row (it did: 107 columns of text left 10 cells of chart on a 120-col
  # console after the font was doubled).
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
  printf '%s%s%s\n\n' "$C_DIM" "$dashes" "$C_RST"

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

# The probe clock is $SECONDS (shell uptime), not date arithmetic: it needs no fork
# and cannot drift against the loop, since it IS the loop's own elapsed time.
next_probe=0
while :; do
  # Sample in this shell — the chart series must outlive the frame, and
  # frame="$(render_frame)" is a subshell.
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
  sleep "$INTERVAL"
done
