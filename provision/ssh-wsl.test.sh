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

# ── marker constants (must match the spec strings verbatim) ───────────────────
eq "$CONFIG_MARKER_BEGIN" '# >>> fleet-ssh (managed by ssh-wsl.sh) >>>' 'marker begin exact'
eq "$CONFIG_MARKER_END"   '# <<< fleet-ssh <<<'                          'marker end exact'

# ── ssh_wsl_sanitize ──────────────────────────────────────────────────────────
eq "$(ssh_wsl_sanitize 'Ubuntu-26.04')"     'ubuntu-26-04'   'sanitize dotted'
eq "$(ssh_wsl_sanitize 'My_Cool Distro!!')" 'my-cool-distro' 'sanitize punctuation'

# ── ssh_wsl_stamp_pub (no double/blank comment regardless of input comment) ───
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY' 'me@wsl-desktop')" \
   'ssh-ed25519 AAAABODY me@wsl-desktop' 'stamp_pub: no embedded comment → stamp once'
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY old@comment' 'me@wsl-desktop')" \
   'ssh-ed25519 AAAABODY me@wsl-desktop' 'stamp_pub: strip embedded comment (no doubling)'
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY old comment with spaces' 'me@wsl-desktop')" \
   'ssh-ed25519 AAAABODY me@wsl-desktop' 'stamp_pub: strip multi-word comment'

# ── ssh_wsl_render_config (needs jq) ──────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  # Fixture: a hub (ssh.user debian, ssh.host cyphy.kz), a non-me member
  # (ssh.user methe), and a default-me member (no ssh block). Mirrors the real
  # fleet.json shape — the hub is identified by ssh.host, not a mesh role.
  FIXTURE='{
    "machines": {
      "latitude": {},
      "server":   { "ssh": { "user": "methe" } },
      "hub":      { "ssh": { "user": "debian", "host": "cyphy.kz" } }
    }
  }'
  RENDERED="$(ssh_wsl_render_config "$FIXTURE")"

  echo "$RENDERED" | grep -q '^  HostName cyphy.kz$' || fail 'render: hub HostName cyphy.kz'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  HostName ')" = 1 ] || fail 'render: only the hub gets a HostName'
  # 3 User lines: server (methe), hub (debian), and the trailing *.gg.ez wildcard (me).
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  User ')" = 3 ] || fail 'render: the two non-me members plus the wildcard get a User line'
  echo "$RENDERED" | grep -q '^  User methe$'  || fail 'render: server → User methe'
  echo "$RENDERED" | grep -q '^  User debian$' || fail 'render: hub → User debian'
  echo "$RENDERED" | grep -q '^  User me$'     || fail 'render: wildcard → User me'
  # 4 blocks now: latitude, server, hub, and the trailing *.gg.ez wildcard.
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  IdentityFile ~/.ssh/id_fleet$')" = 4 ] || fail 'render: every block (incl. wildcard) has IdentityFile'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  StrictHostKeyChecking accept-new$')" = 4 ] || fail 'render: every block (incl. wildcard) has StrictHostKeyChecking'
  echo "$RENDERED" | grep -q '^Host latitude$' || fail 'render: latitude block present'
  # The default-me member (latitude) must NOT carry a User line. Extract its block.
  LAT_BLOCK="$(printf '%s\n' "$RENDERED" | awk '/^Host latitude$/{f=1} f&&/^$/{exit} f{print}')"
  echo "$LAT_BLOCK" | grep -q '^  User ' && fail 'render: default-me member must have no User line'

  # The trailing *.gg.ez wildcard block must be present, last, and exact.
  echo "$RENDERED" | grep -q '^Host \*\.gg\.ez$' || fail 'render: wildcard *.gg.ez block present'
  WILDCARD_BLOCK="$(printf '%s\n' "$RENDERED" | awk '/^Host \*\.gg\.ez$/{f=1} f{print}')"
  EXPECTED_WILDCARD='Host *.gg.ez
  User me
  IdentityFile ~/.ssh/id_fleet
  StrictHostKeyChecking accept-new'
  eq "$WILDCARD_BLOCK" "$EXPECTED_WILDCARD" 'render: wildcard block is the exact expected stanza and comes last'

  # ── ssh_wsl_host_label (maps hostname → fleet name; needs jq) ────────────────
  HL_FIXTURE='{ "machines": {
    "desktop": { "detect": { "hostname": "g614jv" } },
    "hub":     { "detect": { "hostname": "27608" } }
  } }'
  eq "$(ssh_wsl_host_label "$HL_FIXTURE" 'g614jv')"    'desktop'   'host_label: detect.hostname match → fleet name'
  eq "$(ssh_wsl_host_label "$HL_FIXTURE" 'G614JV')"    'desktop'   'host_label: match is case-insensitive'
  eq "$(ssh_wsl_host_label "$HL_FIXTURE" '27608')"     'hub'       'host_label: hub matches too'
  eq "$(ssh_wsl_host_label "$HL_FIXTURE" 'Weird.Box')" 'weird-box' 'host_label: no match → sanitized hostname'
else
  echo "SKIP: ssh_wsl_render_config + ssh_wsl_host_label tests (jq not installed)"
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

# Re-merging with a DIFFERENT block must REPLACE the old span, not keep both.
OLDBLOCK="$CONFIG_MARKER_BEGIN
Host latitude
  IdentityFile ~/.ssh/id_fleet
$CONFIG_MARKER_END"
NEWER_BLOCK="$CONFIG_MARKER_BEGIN
Host server
  User methe
  IdentityFile ~/.ssh/id_fleet
$CONFIG_MARKER_END"
SEEDED="$(ssh_wsl_merge_config "$GITHUB_BLOCK" "$OLDBLOCK")"
REPLACED="$(ssh_wsl_merge_config "$SEEDED" "$NEWER_BLOCK")"
echo "$REPLACED" | grep -q '^Host server$'     || fail 'merge: new block content present after re-merge'
echo "$REPLACED" | grep -q '^Host latitude$'   && fail 'merge: old block content must be dropped on re-merge'
echo "$REPLACED" | grep -q '^Host github.com$' || fail 'merge: foreign content preserved across re-merge'
[ "$(printf '%s\n' "$REPLACED" | grep -cF '>>> fleet-ssh')" = 1 ] || fail 'merge: still exactly one begin marker after re-merge'

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

# ── ssh_wsl_merge_authorized_keys (union by key body; idempotent) ─────────────
FLEET='ssh-ed25519 AAAABODYONE me-nixos-latitude
ssh-ed25519 AAAABODYTWO methe@server
ssh-ed25519 AAAABODYSELF me@wsl-desktop'
# Empty existing → exactly the fleet keys, no leading blank line injected.
eq "$(ssh_wsl_merge_authorized_keys '' "$FLEET")" "$FLEET" 'merge_ak: empty existing → fleet keys verbatim'
# Idempotent — merge∘merge == merge (the property that discriminates a correct union).
M="$(ssh_wsl_merge_authorized_keys '' "$FLEET")"
eq "$(ssh_wsl_merge_authorized_keys "$M" "$FLEET")" "$M" 'merge_ak: idempotent'
# Foreign (non-fleet) key preserved; each fleet key appended exactly once.
M3="$(ssh_wsl_merge_authorized_keys 'ssh-ed25519 AAAAMYOWNKEY me@laptop' "$FLEET")"
echo "$M3" | grep -q '^ssh-ed25519 AAAAMYOWNKEY me@laptop$' || fail 'merge_ak: foreign key preserved'
[ "$(printf '%s\n' "$M3" | grep -c 'AAAABODYONE')" = 1 ] || fail 'merge_ak: fleet key appended exactly once'
# Same body already present under a DIFFERENT comment → not re-added (body-keyed).
M4="$(ssh_wsl_merge_authorized_keys 'ssh-ed25519 AAAABODYONE a-different-comment' "$FLEET")"
[ "$(printf '%s\n' "$M4" | grep -c 'AAAABODYONE')" = 1 ] || fail 'merge_ak: existing body not duplicated on differing comment'
echo "$M4" | grep -q 'AAAABODYTWO' || fail 'merge_ak: other fleet keys still added'
# Blank lines + #-comments in the fleet input are skipped.
FLEET_C='# a header comment

ssh-ed25519 AAAABODYONE me-nixos-latitude'
eq "$(ssh_wsl_merge_authorized_keys '' "$FLEET_C")" 'ssh-ed25519 AAAABODYONE me-nixos-latitude' 'merge_ak: fleet comments + blanks dropped'

echo "PASS: ssh-wsl.test.sh"
