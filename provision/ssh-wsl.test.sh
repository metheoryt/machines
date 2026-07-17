#!/usr/bin/env bash
# provision/ssh-wsl.test.sh — unit tests for the pure helpers in ssh-wsl.sh
# (hostname sanitizer, fleet client-config renderer, authorized-key presence).
# No sudo, no network, no /etc — sources the script in SSH_WSL_LIB_ONLY mode so
# only the functions load and main never runs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SSH_WSL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$here/ssh-wsl.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

# ── ssh_wsl_sanitize ──────────────────────────────────────────────────────────
eq "$(ssh_wsl_sanitize 'Ubuntu-26.04')"     'ubuntu-26-04'   'sanitize dotted'
eq "$(ssh_wsl_sanitize 'My_Cool Distro!!')" 'my-cool-distro' 'sanitize punctuation'

# ── ssh_wsl_render_config (needs jq) ──────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  # Fixture: a hub (role hub, ssh.user debian, ssh.host cyphy.kz), a non-me
  # member (ssh.user methe), and a default-me member (no ssh.user).
  FIXTURE='{
    "machines": {
      "latitude": { "mesh": { "role": "member" } },
      "server":   { "mesh": { "role": "member" }, "ssh": { "user": "methe" } },
      "hub":      { "mesh": { "role": "hub" }, "ssh": { "user": "debian", "host": "cyphy.kz" } }
    }
  }'
  RENDERED="$(ssh_wsl_render_config "$FIXTURE")"

  echo "$RENDERED" | grep -q '^  HostName cyphy.kz$' || fail 'render: hub HostName cyphy.kz'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  HostName ')" = 1 ] || fail 'render: only the hub gets a HostName'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  User ')" = 2 ] || fail 'render: exactly the two non-me members get a User line'
  echo "$RENDERED" | grep -q '^  User methe$'  || fail 'render: server → User methe'
  echo "$RENDERED" | grep -q '^  User debian$' || fail 'render: hub → User debian'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  IdentityFile ~/.ssh/id_fleet$')" = 3 ] || fail 'render: every block has IdentityFile'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  StrictHostKeyChecking accept-new$')" = 3 ] || fail 'render: every block has StrictHostKeyChecking'
  echo "$RENDERED" | grep -q '^Host latitude$' || fail 'render: latitude block present'
  # The default-me member (latitude) must NOT carry a User line. Extract its block.
  LAT_BLOCK="$(printf '%s\n' "$RENDERED" | awk '/^Host latitude$/{f=1} f&&/^$/{exit} f{print}')"
  echo "$LAT_BLOCK" | grep -q '^  User ' && fail 'render: default-me member must have no User line'
else
  echo "SKIP: ssh_wsl_render_config tests (jq not installed)"
fi

# ── ssh_wsl_merge_config (idempotency + preserves foreign content) ────────────
GITHUB_BLOCK='Host github.com
  HostName github.com
  IdentityFile ~/.ssh/id_metheoryt'
NEWBLOCK="$CONFIG_MARKER_BEGIN
Host latitude
  IdentityFile ~/.ssh/id_fleet
$CONFIG_MARKER_END"

M1="$(ssh_wsl_merge_config "$GITHUB_BLOCK" "$NEWBLOCK")"
echo "$M1" | grep -q '^Host github.com$' || fail 'merge: pre-existing github block preserved'
echo "$M1" | grep -q '^Host latitude$'   || fail 'merge: fleet block appended'
[ "$(printf '%s\n' "$M1" | grep -cF '>>> fleet-ssh')" = 1 ] || fail 'merge: exactly one begin marker'
# Idempotency — the property that discriminates a correct merge from the buggy one.
M2="$(ssh_wsl_merge_config "$M1" "$NEWBLOCK")"
eq "$M2" "$M1" 'merge: idempotent (merge∘merge == merge)'
# Empty existing → just the block.
eq "$(ssh_wsl_merge_config '' "$NEWBLOCK")" "$NEWBLOCK" 'merge: empty existing → just the block'

# ── ssh_wsl_key_present ───────────────────────────────────────────────────────
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' \
  'ssh-ed25519 AAAABODYONE first@host' \
  'ssh-ed25519 AAAABODYTWO second@host' > "$tmp"
ssh_wsl_key_present 'AAAABODYONE' "$tmp" || fail 'key_present: present body → 0'
ssh_wsl_key_present 'AAAABODYTWO' "$tmp" || fail 'key_present: present body (2nd line) → 0'
ssh_wsl_key_present 'AAAAMISSING' "$tmp" && fail 'key_present: absent body → nonzero'
# Comment differs but body identical → still present.
printf '%s\n' 'ssh-ed25519 AAAABODYONE a-totally-different-comment' > "$tmp"
ssh_wsl_key_present 'AAAABODYONE' "$tmp" || fail 'key_present: comment differs, body same → 0'
ssh_wsl_key_present 'AAAABODYONE' /nonexistent/file && fail 'key_present: unreadable file → nonzero'

echo "PASS: ssh-wsl.test.sh"
