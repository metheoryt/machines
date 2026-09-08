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

# ── ts_extract_key_json ───────────────────────────────────────────────────────
json_line='{"id":"5","key":"abc123def456","user":{"id":"1","name":"fleet"},"reusable":true}'
eq "$(ts_extract_key_json "$json_line")" 'abc123def456' 'extract key (single line, nested user obj)'

json_pretty='{
  "id": "5",
  "key": "K9xYz-Token_007",
  "reusable": true
}'
eq "$(ts_extract_key_json "$json_pretty")" 'K9xYz-Token_007' 'extract key (pretty/multiline)'

eq "$(ts_extract_key_json '{"id":"5","reusable":true}')" '' 'extract key (missing → empty)'

# ── ts_headscale_target ───────────────────────────────────────────────────────
# The default must be the ssh ALIAS. `debian@cyphy.kz` — what this defaulted to
# until 2026-09-08 — matches no block in the generated ~/.ssh/config (the VPS is
# `Host hub hub.gg.ez` with HostName cyphy.kz), so it loses the User, the
# id_fleet identity and accept-new, and fails on host-key verification. Asserted
# on the value AND against the old literal, so a revert cannot pass quietly.
eq "$(HEADSCALE_SSH= ts_headscale_target)" 'hub'  'headscale target defaults to the hub alias'
[ "$(HEADSCALE_SSH= ts_headscale_target)" = 'debian@cyphy.kz' ] \
  && fail 'headscale target must not default to a bare address that matches no ssh block'
eq "$(HEADSCALE_SSH=me@elsewhere ts_headscale_target)" 'me@elsewhere' 'headscale target honours the env override'

# One definition, not three. Matched on the DEFAULT-EXPANSION form, not on the
# bare string: the accessor's comment names the old address to explain why it is
# wrong, and a grep for the address alone fails on that prose — which it did,
# first run. What must not come back is `${HEADSCALE_SSH:-debian@cyphy.kz}`.
# The accessor itself is the one legitimate expansion, so this counts rather
# than greps: exactly one. Two failed first attempts are why it is written this
# way — a grep for the bare address hits the comment that explains the address,
# and a grep for the expansion hits the accessor it is meant to protect.
# CODE lines only — a leading-# line is prose. Three failed attempts are why it
# reads like this: a grep for the bare address hits the comment that explains why
# the address is wrong, a grep for the expansion hits the accessor it protects,
# and a count over all lines hits the comment that says the accessor replaced
# three expansions. The assertion is about what runs, so it looks at what runs.
eq "$(grep -cE '^[^#]*\$\{HEADSCALE_SSH:-' "$here/tailscale-wsl.sh")" '1' \
   'exactly one $HEADSCALE_SSH default in the code (ts_headscale_target owns it)'

echo "PASS: tailscale-wsl.test.sh"
