#!/usr/bin/env bash
# agents/plugin/skills/kb-refresh/tests/test_fleet_gather.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../fleet-gather.sh"

# fake HOME with an ssh config that lists two of three fleet aliases
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Test helpers
fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

mkdir -p "$tmp/.ssh"
cat > "$tmp/.ssh/config" <<EOF
Host latitude
  HostName 100.64.0.2
Host server
  HostName 100.64.0.3
EOF

# source the script's functions without running main
export HOME="$tmp"
KB_GATHER_NO_MAIN=1 source "$script"

# ── fixture fleet.json (shared by the pure-function tests) ────────────────────
fixture_json="$tmp/fleet.json"
cat > "$fixture_json" <<'JSON'
{ "machines": {
  "latitude": { "platform": "nixos", "detect": { "hostname": "latitude5520" } },
  "desktop":  { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "g614jv" } },
  "server":   { "platform": "windows", "ssh": { "user": "methe" }, "detect": { "hostname": "methe-server" } },
  "hub":      { "platform": "debian", "ssh": { "user": "debian", "host": "cyphy.kz" }, "detect": { "hostname": "27608" } }
} }
JSON

if command -v jq >/dev/null 2>&1; then
  # ── fleet_hosts: hub excluded, correct tuples ───────────────────────────────
  fh="$(fleet_hosts "$fixture_json")"
  # `| tr -d '[:space:]'` is load-bearing: BSD/macOS `wc -l` PADS its output
  # ("       3"), so a bare string compare against 3 fails on air while passing on
  # every Linux box. This suite ran green in CI-ish Linux use and red on macOS for
  # exactly that reason — nothing to do with the fixture.
  [ "$(printf '%s\n' "$fh" | wc -l | tr -d '[:space:]')" = 3 ] || { echo "FAIL: fleet_hosts expected 3 rows, got: $fh"; exit 1; }
  # grep -F -x, not grep -P: -P is GNU-only and BSD/macOS grep prints its usage
  # instead of matching. -Fx is an exact WHOLE-LINE match, which is what these
  # anchored patterns meant, and printf gives us the real tabs.
  has_row() { printf '%s\n' "$1" | grep -Fxq "$(printf "$2")"; }
  has_row "$fh" 'latitude\tnixos\tlatitude5520\t' || { echo "FAIL: fleet_hosts latitude tuple"; exit 1; }
  has_row "$fh" 'desktop\twindows\tg614jv\tmethe'  || { echo "FAIL: fleet_hosts desktop tuple"; exit 1; }
  has_row "$fh" 'server\twindows\tmethe-server\tmethe' || { echo "FAIL: fleet_hosts server tuple"; exit 1; }
  printf '%s\n' "$fh" | grep -q 'hub' && { echo "FAIL: fleet_hosts must exclude hub"; exit 1; }

  # ── local_host_id: known hostname → canonical id; unknown → passthrough ──────
  eq "$(local_host_id "$fixture_json" latitude5520)" 'latitude5520' 'local_host_id: known → canonical'
  eq "$(local_host_id "$fixture_json" g614jv)"       'g614jv'       'local_host_id: windows known → canonical'
  eq "$(local_host_id "$fixture_json" Weird.Box)"    'Weird.Box'    'local_host_id: unknown → passthrough'
else
  echo "SKIP: fleet_hosts test (jq not installed)"
fi

# ── roots_for_platform ────────────────────────────────────────────────────────
# ONE root on every platform, deliberately. This test used to assert a second
# /mnt/c/Users/<user>/.claude/projects root for windows; that was dropped from the
# implementation when Windows dispatch moved to Git Bash and WSL distros became
# separate fleet hosts (harvested directly via fd_wsl_hosts). Git Bash has no
# /mnt/c, so the extra root would fail the set -e remote distill. The test was not
# updated with it and had been failing since.
rw="$(roots_for_platform windows methe)"
eq "$rw" '~/.claude/projects' 'roots windows: the single profile root'
[ "$(printf '%s\n' "$rw" | wc -l | tr -d '[:space:]')" = 1 ] || { echo "FAIL: roots windows expected exactly 1 root"; exit 1; }
ru="$(roots_for_platform nixos '')"
eq "$ru" '~/.claude/projects' 'roots unix: single home root'
eq "$rw" "$ru" 'roots: platform makes no difference now (~ expands per box)'

# ── remote_distill_script: static, argv-driven, per-root loop ─────────────────
rds="$(remote_distill_script)"
printf '%s\n' "$rds" | grep -q -- '--projects-root' || fail 'rds: has --projects-root'
printf '%s\n' "$rds" | grep -q -- '--host'          || fail 'rds: passes --host'
printf '%s\n' "$rds" | grep -q '~/.cache/distill.py' || fail 'rds: invokes pushed distiller'
# argv-driven (values arrive as positional args, not interpolated):
printf '%s\n' "$rds" | grep -q 'shift'              || fail 'rds: consumes positional args'
printf '%s\n' "$rds" | grep -qF '"$@"'              || fail 'rds: reads remaining args'
# leading-~ expansion against remote $HOME:
printf '%s\n' "$rds" | grep -qF '${root/#\~/$HOME}' || fail 'rds: expands leading ~ against HOME'
# It is valid bash:
printf '%s\n' "$rds" | bash -n || fail 'rds: emitted script is not valid bash'

# ── detect_hosts: fleet.json workstations ∩ ssh config Host entries ───────────
if command -v jq >/dev/null 2>&1; then
  aliases="$(detect_hosts "$fixture_json" "$tmp/.ssh/config" | cut -f1 | sort | tr '\n' ' ')"
  # desktop absent from config → excluded; hub never a workstation
  eq "$aliases" 'latitude server ' 'detect_hosts: config-present workstations only'
  # the emitted row is the full tuple, not just the alias
  detect_hosts "$fixture_json" "$tmp/.ssh/config" | grep -Fxq "$(printf 'server\twindows\tmethe-server\tmethe')" \
    || fail 'detect_hosts: emits full tuple per host'
else
  echo "SKIP: detect_hosts test (jq not installed)"
fi

echo "PASS: test_fleet_gather.sh"
