#!/usr/bin/env bash
# Unit tests for the macOS provisioning chain: provision-mac.sh, macos-prep.sh,
# tailscale-mac.sh.
#
# These run on the NixOS dev box, so the privileged and Darwin-only paths cannot
# execute. The split mirrors how tiers.test.sh handles macos.sh:
#   • --dry-run prints the stage plan and exits BEFORE the Darwin guard, so the
#     orchestration is assertable anywhere.
#   • *_LIB_ONLY=1 sourcing exposes the pure helpers for direct test — the same
#     convention as ssh-wsl.sh (SSH_WSL_LIB_ONLY) and tiers.sh (TIERS_LIB_ONLY).
# Privileged calls are asserted as PLAN OUTPUT, never run.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$HERE/.."
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qE "$2" && die "$3" || pass "$3"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP (jq absent)"; exit 0; }

# ── provision-mac.sh: validation happens BEFORE any mutation ──────────────────
out="$(bash "$PROV/provision-mac.sh" no-such-box --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "unknown machine is rejected" || die "unknown machine should fail"
has "$out" "not in fleet.json" "unknown machine names the problem"
has "$out" "air" "unknown machine lists the known members"

out="$(bash "$PROV/provision-mac.sh" latitude --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "a non-darwin machine is rejected" || die "latitude (debian) should be refused"
has "$out" "platform 'debian', not darwin" "non-darwin refusal names the platform"

out="$(bash "$PROV/provision-mac.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "missing machine argument is rejected" || die "no-arg should fail"

# ── provision-mac.sh --dry-run: the stage plan ────────────────────────────────
plan="$(bash "$PROV/provision-mac.sh" air --dry-run 2>&1)"; rc=$?
eq "$rc" "0" "dry-run for a valid darwin machine exits 0"
has "$plan" '^1/4 macos-prep\.sh air$'                    "stage 1 is macos-prep"
has "$plan" '^2/4 tailscale-mac\.sh --hostname air$'      "stage 2 is tailscale-mac"
has "$plan" '^3/4 macos\.sh$'                             "stage 3 is the tier driver"
has "$plan" '^4/4 provision\.sh --machine air --apply$'   "stage 4 is the role front door"

# The dry run must be inert — no sudo, no scutil, no brew, nothing mutating.
hasnt "$plan" 'Password|sudo:'  "dry-run does not invoke sudo"

# --authkey-file must reach stage 2, or the key silently never arrives.
plan_k="$(bash "$PROV/provision-mac.sh" air --dry-run --authkey-file /tmp/k 2>&1)"
has "$plan_k" 'tailscale-mac\.sh --hostname air --authkey-file /tmp/k' \
    "--authkey-file is threaded through to stage 2"

# ── macos-prep.sh pure helpers ────────────────────────────────────────────────
# shellcheck source=provision/macos-prep.sh
MACOS_PREP_LIB_ONLY=1 source "$PROV/macos-prep.sh"

eq "$(mp_brew_prefix arm64)"   "/opt/homebrew" "brew prefix on Apple Silicon"
eq "$(mp_brew_prefix aarch64)" "/opt/homebrew" "brew prefix on aarch64 spelling"
eq "$(mp_brew_prefix x86_64)"  "/usr/local"    "brew prefix on Intel"

FJ="$(cat "$PROV/../fleet.json")"
eq "$(mp_fleet_hostname "$FJ" air)"      "air"    "fleet hostname for air"
eq "$(mp_fleet_platform "$FJ" air)"      "darwin" "fleet platform for air"
eq "$(mp_fleet_hostname "$FJ" nope)"     ""       "absent machine yields empty hostname"

# ── tailscale-mac.sh pure helpers ─────────────────────────────────────────────
# shellcheck source=provision/tailscale-mac.sh
TAILSCALE_MAC_LIB_ONLY=1 source "$PROV/tailscale-mac.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '  hskey-from-file  \n' > "$tmp/key"      # padded: whitespace must be stripped
: > "$tmp/empty"

# Precedence: file beats env.
got="$(tsm_resolve_key "$tmp/key" "hskey-from-env")"
eq "$got" "$(printf 'authkey-file\thskey-from-file')" "authkey-file wins over the env var"
got="$(tsm_resolve_key "" "hskey-from-env")"
eq "$got" "$(printf 'HEADSCALE_AUTHKEY\thskey-from-env')" "env var used when no file given"

# Neither source → rc 1 (caller prints the mint-a-key instructions).
tsm_resolve_key "" "" >/dev/null 2>&1; eq "$?" "1" "no key at all returns 1"

# A SET-but-broken file is rc 2, not a silent fallthrough to the env var — a
# typo'd path must not quietly join with the wrong key.
tsm_resolve_key "$tmp/nonexistent" "hskey-from-env" >/dev/null 2>&1
eq "$?" "2" "unreadable authkey-file is an error, not a fallthrough"
tsm_resolve_key "$tmp/empty" "hskey-from-env" >/dev/null 2>&1
eq "$?" "2" "empty authkey-file is an error, not a fallthrough"

# IP verification against the manifest.
eq "$(tsm_expected_ip "$FJ" air)" "100.64.0.7" "expected tailnet IP for air"
eq "$(tsm_ip_verdict 100.64.0.7 100.64.0.7)" "match"    "matching IP"
eq "$(tsm_ip_verdict 100.64.0.9 100.64.0.7)" "mismatch" "mismatched IP is detected"
eq "$(tsm_ip_verdict "" 100.64.0.7)"         "unknown"  "absent actual IP is unknown, not a match"
eq "$(tsm_ip_verdict 100.64.0.7 "")"         "unknown"  "absent expected IP is unknown, not a match"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
