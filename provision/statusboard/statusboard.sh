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
#   bash statusboard.sh --interval 5    # seconds between frames (default 3)
#   sudo bash statusboard.sh --install  # install + enable the tty1 service
#   sudo bash statusboard.sh --uninstall
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

INTERVAL=3
ONCE=0
MODE=run
SERVICE_NAME=statusboard.service
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
TTY_TARGET="${STATUSBOARD_TTY:-/dev/tty1}"
GETTY_UNIT="getty@tty1.service"

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --interval) INTERVAL="${2:-3}"; shift 2 ;;
    --install) MODE=install; shift ;;
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
sb_bar() {
  local pct="${1:-0}" width="${2:-20}" filled i out=""
  case "$pct" in '' | *[!0-9]*) pct=0 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100))
  for ((i = 0; i < width; i++)); do
    if [ "$i" -lt "$filled" ]; then out="$out#"; else out="$out."; fi
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

[ "${STATUSBOARD_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Install / uninstall ───────────────────────────────────────────────────────
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
ExecStart=/bin/bash $SELF --interval $INTERVAL
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
  systemctl disable --now "$GETTY_UNIT" 2>/dev/null
  systemctl enable --now "$SERVICE_NAME" || { printf 'failed to start %s\n' "$SERVICE_NAME" >&2; exit 1; }
  printf 'installed %s on %s as %s\n' "$SERVICE_NAME" "$TTY_TARGET" "$RUN_USER"
  printf 'gettys remain on tty2..tty6 — Alt-F2 for a console login.\n'
  exit 0
fi

# ── Readers ───────────────────────────────────────────────────────────────────
_read() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null || printf ''; }

BAT_DIR=""
for d in /sys/class/power_supply/BAT*; do [ -d "$d" ] && { BAT_DIR="$d"; break; }; done

# Which supply is actually feeding the box, and at what rating. On USB-C PD the
# negotiated contract lives in the ucsi source psy, and reading it is the only
# way to tell a 65W brick from the 15W port that browned this box out.
sb_power_source() {
  local ac="" src="" volts amps watts
  for d in /sys/class/power_supply/*/; do
    case "$(_read "$d/type")" in
      Mains) [ "$(_read "$d/online")" = 1 ] && ac="AC" ;;
      USB)
        if [ "$(_read "$d/online")" = 1 ]; then
          volts="$(_read "$d/voltage_now")"; amps="$(_read "$d/current_max")"
          if [ -n "$volts" ] && [ -n "$amps" ]; then
            watts="$(awk -v v="$volts" -v a="$amps" 'BEGIN { printf "%.0f", v / 1000000 * (a / 1000000) }')"
            src="USB-C ${watts}W"
          else
            src="USB-C"
          fi
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

# ── Frame ─────────────────────────────────────────────────────────────────────
render_frame() {
  local host now up_s load
  host="$(hostname)"
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  up_s="$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)"
  load="$(awk '{ print $1, $2, $3 }' /proc/loadavg 2>/dev/null)"

  printf '%s%s%s   %s%s%s\n' "$C_B$C_INFO" "$host" "$C_RST" "$C_DIM" "$now" "$C_RST"
  printf '%s%s%s\n\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"

  # Power. Prefer the energy-reporting attributes; fall back to charge × voltage
  # for the ECs (this box included) that only expose charge_*.
  local b_volt b_pw b_en b_ef
  b_volt="$(_read "$BAT_DIR/voltage_now")"
  b_pw="$(_read "$BAT_DIR/power_now")"
  [ -n "$b_pw" ] || b_pw="$(sb_uwatts "$(_read "$BAT_DIR/current_now")" "$b_volt")"
  b_en="$(_read "$BAT_DIR/energy_now")"
  [ -n "$b_en" ] || b_en="$(sb_uwatthours "$(_read "$BAT_DIR/charge_now")" "$b_volt")"
  b_ef="$(_read "$BAT_DIR/energy_full")"
  [ -n "$b_ef" ] || b_ef="$(sb_uwatthours "$(_read "$BAT_DIR/charge_full")" "$b_volt")"

  printf '%s\n' "$(sb_battery_line \
    "$(_read "$BAT_DIR/capacity")" \
    "$(_read "$BAT_DIR/status")" \
    "$b_pw" "$b_en" "$b_ef")"
  printf 'source    %s\n' "$(sb_power_source)"
  local lim; lim="$(_read "$BAT_DIR/charge_control_end_threshold")"
  [ -n "$lim" ] && printf 'limit     %s%s%%%s\n' "$C_DIM" "$lim" "$C_RST"
  printf '\n'

  # Network
  local IFS='|'
  read -r lan_st lan_dev lan_ip lan_gw <<< "$(sb_lan)"
  printf 'lan      %s  %s%s %s%s\n' "$(sb_status_glyph "$lan_st")" \
    "$C_DIM" "${lan_dev:-—}" "${lan_ip:-—}" "$C_RST"

  local gw_st gw_rtt
  if [ -n "${lan_gw:-}" ] && [ "$lan_gw" != '?' ]; then
    read -r gw_st gw_rtt <<< "$(sb_reach "$lan_gw")"
    printf 'gateway  %s  %s%s %s%s\n' "$(sb_status_glyph "$gw_st")" "$C_DIM" "$lan_gw" "${gw_rtt:-}" "$C_RST"
  fi

  local net_st net_rtt
  read -r net_st net_rtt <<< "$(sb_reach 1.1.1.1)"
  printf 'internet %s  %s%s%s\n' "$(sb_status_glyph "$net_st")" "$C_DIM" "${net_rtt:-—}" "$C_RST"

  local ts_st ts_ip ts_peers ts_total
  read -r ts_st ts_ip ts_peers ts_total <<< "$(sb_tailnet)"
  if [ "$ts_st" = up ]; then
    printf 'tailnet  %s  %s%s  %s/%s peers online%s\n' "$(sb_status_glyph up)" \
      "$C_DIM" "$ts_ip" "$ts_peers" "$ts_total" "$C_RST"
  else
    printf 'tailnet  %s\n' "$(sb_status_glyph "$ts_st")"
  fi
  unset IFS
  printf '\n'

  # Host
  printf 'uptime    %s%s%s   load %s%s%s\n' "$C_DIM" "$(sb_secs_to_hm "$up_s")" "$C_RST" "$C_DIM" "$load" "$C_RST"
  printf 'disk /    %s%s%s\n' "$C_DIM" "$(df -h / 2>/dev/null | awk 'NR==2 { printf "%s used of %s (%s)", $3, $2, $5 }')" "$C_RST"
  if command -v systemctl >/dev/null 2>&1; then
    local failed
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${failed:-0}" -gt 0 ]; then
      printf 'units     %s%s failed%s\n' "$C_BAD" "$failed" "$C_RST"
    else
      printf 'units     %sall ok%s\n' "$C_DIM" "$C_RST"
    fi
  fi
}

if [ "$ONCE" = 1 ]; then
  render_frame
  exit 0
fi

# Hide the cursor and restore it however we exit — a blinking cursor parked
# mid-frame on an unattended screen looks like a hung box.
[ -t 1 ] && printf '\033[?25l'
cleanup() { [ -t 1 ] && printf '\033[?25h\033[?7h'; }
trap cleanup EXIT INT TERM

while :; do
  # Build the frame into a variable, then paint in one write: rendering directly
  # to the tty makes the display visibly tear on a slow VT.
  frame="$(render_frame)"
  [ -t 1 ] && printf '\033[H\033[2J'
  printf '%s\n' "$frame"
  sleep "$INTERVAL"
done
