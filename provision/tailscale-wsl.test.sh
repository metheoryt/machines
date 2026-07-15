#!/usr/bin/env bash
# provision/tailscale-wsl.test.sh — unit tests for the pure helpers in
# tailscale-wsl.sh (hostname sanitizer + pre-auth key precedence). No sudo, no
# network, no /etc — sources the script in TS_WSL_LIB_ONLY mode so only the
# functions load and main never runs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS_WSL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$here/tailscale-wsl.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

# ── ts_sanitize_hostname ──────────────────────────────────────────────────────
eq "$(ts_sanitize_hostname 'Ubuntu-26.04')"     'ubuntu-26-04'   'sanitize dotted'
eq "$(ts_sanitize_hostname 'My_Cool Distro!!')" 'my-cool-distro' 'sanitize punctuation'
eq "$(ts_sanitize_hostname '--Edgy--')"         'edgy'           'sanitize trim edges'

# ── ts_pick_key precedence: --authkey-file > env > persisted ──────────────────
eq "$(ts_pick_key 'F' 'E' 'P')" $'authkey-file\tF' 'pick file first'
eq "$(ts_pick_key ''  'E' 'P')" $'env\tE'          'pick env second'
eq "$(ts_pick_key ''  ''  'P')" $'persisted\tP'    'pick persisted last'
eq "$(ts_pick_key ''  ''  '')"  $'\t'              'pick none → empty source+key'

echo "PASS: tailscale-wsl.test.sh"
