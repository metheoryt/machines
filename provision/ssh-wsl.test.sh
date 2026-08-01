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
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY' 'me@desktop-wsl')" \
   'ssh-ed25519 AAAABODY me@desktop-wsl' 'stamp_pub: no embedded comment → stamp once'
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY old@comment' 'me@desktop-wsl')" \
   'ssh-ed25519 AAAABODY me@desktop-wsl' 'stamp_pub: strip embedded comment (no doubling)'
eq "$(ssh_wsl_stamp_pub 'ssh-ed25519 AAAABODY old comment with spaces' 'me@desktop-wsl')" \
   'ssh-ed25519 AAAABODY me@desktop-wsl' 'stamp_pub: strip multi-word comment'

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
  # 4 User lines: EVERY block carries one now — latitude (me, defaulted), server
  # (methe), hub (debian), plus the trailing *.gg.ez wildcard (me). Emitting it
  # unconditionally is the fix for the Windows members, whose local user is
  # `methe`: an omitted User line there resolved to methe@<member>, not me@.
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  User ')" = 4 ] || fail 'render: every block gets a User line'
  echo "$RENDERED" | grep -q '^  User methe$'  || fail 'render: server → User methe'
  echo "$RENDERED" | grep -q '^  User debian$' || fail 'render: hub → User debian'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  User me$')" = 2 ] || fail 'render: latitude and the wildcard both → User me'
  # 4 blocks now: latitude, server, hub, and the trailing *.gg.ez wildcard.
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  IdentityFile ~/.ssh/id_fleet$')" = 4 ] || fail 'render: every block (incl. wildcard) has IdentityFile'
  [ "$(printf '%s\n' "$RENDERED" | grep -c '^  StrictHostKeyChecking accept-new$')" = 4 ] || fail 'render: every block (incl. wildcard) has StrictHostKeyChecking'
  echo "$RENDERED" | grep -q '^Host latitude latitude\.gg\.ez$' || fail 'render: latitude block present'
  # Every per-host block matches the bare name AND the MagicDNS FQDN. Without the
  # alias the FQDN fell through to the `Host *.gg.ez` catch-all's `User me`, so
  # `ssh desktop.gg.ez` / `server.gg.ez` / `hub.gg.ez` went out as the wrong user
  # and were refused while the bare name worked.
  echo "$RENDERED" | grep -q '^Host server server\.gg\.ez$' || fail 'render: server block aliases its FQDN'
  echo "$RENDERED" | grep -q '^Host hub hub\.gg\.ez$'       || fail 'render: hub block aliases its FQDN'
  # The wildcard is the only remaining bare `Host *.gg.ez` — every other block
  # carries a two-token pattern, so no member can fall through to it.
  [ "$(printf '%s\n' "$RENDERED" | grep -cE '^Host [^ ]+$')" = 1 ] || fail 'render: only the wildcard is a single-pattern Host line'
  # A member with no ssh.user must carry an EXPLICIT `User me` — this is the
  # assertion that inverted on 2026-07-29. Relying on ssh's fallback to the local
  # username is only correct where that username happens to be `me`.
  LAT_BLOCK="$(printf '%s\n' "$RENDERED" | awk '/^Host latitude /{f=1} f&&/^$/{exit} f{print}')"
  EXPECTED_LAT='Host latitude latitude.gg.ez
  User me
  IdentityFile ~/.ssh/id_fleet
  StrictHostKeyChecking accept-new'
  eq "$LAT_BLOCK" "$EXPECTED_LAT" 'render: a default-user member gets an explicit User me'

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

# ── ssh_wsl_merge_authorized_keys (authoritative managed span) ────────────────
eq "$TRUST_MARKER_BEGIN" '# >>> fleet-trust (managed by machines) >>>' 'trust marker begin exact'
eq "$TRUST_MARKER_END"   '# <<< fleet-trust <<<'                       'trust marker end exact'

FLEET='ssh-ed25519 AAAABODYONE me@latitude
ssh-ed25519 AAAABODYTWO methe@server
ssh-ed25519 AAAABODYSELF me@desktop-wsl'
# Empty existing → the fleet keys wrapped in exactly one marked span.
eq "$(ssh_wsl_merge_authorized_keys '' "$FLEET")" \
   "$TRUST_MARKER_BEGIN
$FLEET
$TRUST_MARKER_END" 'merge_ak: empty existing → fleet keys inside one span'
# Idempotent — merge∘merge == merge. The span must not nest or accrete markers.
M="$(ssh_wsl_merge_authorized_keys '' "$FLEET")"
eq "$(ssh_wsl_merge_authorized_keys "$M" "$FLEET")" "$M" 'merge_ak: idempotent'
[ "$(printf '%s\n' "$(ssh_wsl_merge_authorized_keys "$M" "$FLEET")" | grep -cF '>>> fleet-trust')" = 1 ] \
  || fail 'merge_ak: exactly one begin marker after re-merge'

# Foreign (non-fleet) key preserved OUTSIDE the span; fleet key present once.
M3="$(ssh_wsl_merge_authorized_keys 'ssh-ed25519 AAAAMYOWNKEY me@laptop' "$FLEET")"
echo "$M3" | grep -q '^ssh-ed25519 AAAAMYOWNKEY me@laptop$' || fail 'merge_ak: foreign key preserved'
[ "$(printf '%s\n' "$M3" | grep -c 'AAAABODYONE')" = 1 ] || fail 'merge_ak: fleet key present exactly once'
# ...and the foreign key must sit BEFORE the span, i.e. outside management.
[ "$(printf '%s\n' "$M3" | grep -n 'AAAAMYOWNKEY' | cut -d: -f1)" \
  -lt "$(printf '%s\n' "$M3" | grep -nF '>>> fleet-trust' | cut -d: -f1)" ] \
  || fail 'merge_ak: foreign key must land outside the managed span'

# REVOCATION — the whole point. A key that is no longer in the fleet input and
# lives INSIDE the span is dropped. Append-only merging could never do this.
SHRUNK='ssh-ed25519 AAAABODYONE me@latitude'
M5="$(ssh_wsl_merge_authorized_keys "$M" "$SHRUNK")"
echo "$M5" | grep -q 'AAAABODYTWO'  && fail 'merge_ak: removed fleet key must be revoked from the span'
echo "$M5" | grep -q 'AAAABODYONE'  || fail 'merge_ak: surviving fleet key kept'

# RENAME — same body, new comment. The span carries the fleet-side comment, so a
# rename in fleet-authorized-keys reaches the box. (Body-keyed appending could
# not: the body already matched, so nothing was ever rewritten.)
RENAMED='ssh-ed25519 AAAABODYONE me@latitude-renamed'
M6="$(ssh_wsl_merge_authorized_keys "$M" "$RENAMED")"
echo "$M6" | grep -q '^ssh-ed25519 AAAABODYONE me@latitude-renamed$' || fail 'merge_ak: renamed comment propagates'
[ "$(printf '%s\n' "$M6" | grep -c 'AAAABODYONE')" = 1 ] || fail 'merge_ak: rename must not duplicate the key'

# ABSORB — the migration path off the old append-only layout. A fleet key sitting
# UNMANAGED outside the span is pulled inside rather than duplicated; otherwise
# the stray copy would keep granting access after the span revoked it.
M7="$(ssh_wsl_merge_authorized_keys 'ssh-ed25519 AAAABODYONE an-old-stale-comment' "$FLEET")"
[ "$(printf '%s\n' "$M7" | grep -c 'AAAABODYONE')" = 1 ] || fail 'merge_ak: pre-existing fleet key absorbed, not duplicated'
echo "$M7" | grep -q 'an-old-stale-comment' && fail 'merge_ak: absorbed key must take the fleet-side comment'
[ "$(printf '%s\n' "$M7" | grep -n 'AAAABODYONE' | cut -d: -f1)" \
  -gt "$(printf '%s\n' "$M7" | grep -nF '>>> fleet-trust' | cut -d: -f1)" ] \
  || fail 'merge_ak: absorbed key must end up inside the span'

# REFUSE — no key lines in the fleet input → nonzero, no output. Writing an empty
# span here would revoke every fleet key and lock the box out.
ssh_wsl_merge_authorized_keys "$M" ''                 && fail 'merge_ak: empty fleet input → nonzero'
ssh_wsl_merge_authorized_keys "$M" '# only a comment' && fail 'merge_ak: comment-only fleet input → nonzero'
eq "$(ssh_wsl_merge_authorized_keys "$M" '' || true)" '' 'merge_ak: refusal emits nothing'

# Blank lines + #-comments in the fleet input are skipped.
FLEET_C='# a header comment

ssh-ed25519 AAAABODYONE me@latitude'
eq "$(ssh_wsl_merge_authorized_keys '' "$FLEET_C")" \
   "$TRUST_MARKER_BEGIN
ssh-ed25519 AAAABODYONE me@latitude
$TRUST_MARKER_END" 'merge_ak: fleet comments + blanks dropped'
# An existing #-comment outside the span is content, not noise — keep it.
M8="$(ssh_wsl_merge_authorized_keys '# my own note' "$FLEET")"
echo "$M8" | grep -q '^# my own note$' || fail 'merge_ak: foreign comment preserved'

echo "PASS: ssh-wsl.test.sh"
