#!/usr/bin/env bash
# provision/tests/sudo-nopasswd.test.sh — the passwordless-sudo tier.
#
# What makes this worth testing is not the one sudoers line, it is the ORDER: a
# syntactically broken file under /etc/sudoers.d makes sudo refuse to run at all,
# and the only way back on a headless box is a trip to the physical console. So
# `visudo -c` must gate the install, and a rejection must leave sudo untouched.
#
# The tier is driven with SUDO="" (already root, from its point of view), a
# SUDOERS_DIR pointing at a temp directory, and a stub visudo on PATH whose verdict
# the test controls.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
absent() { if [ -e "$1" ]; then fail "$2 (unexpected $1)"; else pass "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/sudoers.d"

# Stub visudo: exits 0 or 1 depending on a file the test flips.
cat > "$TMP/bin/visudo" <<'STUB'
#!/usr/bin/env bash
[ -f "$VISUDO_VERDICT" ] && exit 0
exit 1
STUB
chmod +x "$TMP/bin/visudo"
export PATH="$TMP/bin:$PATH"
export VISUDO_VERDICT="$TMP/ok"

# tiers.sh expects these from its driver.
# shellcheck disable=SC2034  # WARNINGS/APT_UPDATED are read by other tiers in tiers.sh
REPO="$REPO"; SUDO=""; PRIV=1; WARNINGS=0; APT_UPDATED=0
info() { printf '  %s\n' "$*"; }
ok()   { printf '  ok %s\n' "$*"; }
warn() { printf '  warn %s\n' "$*"; }
die()  { printf '  die %s\n' "$*"; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# shellcheck source=provision/lib/tiers.sh
TIERS_LIB_ONLY=1 source "$REPO/provision/lib/tiers.sh"

export SUDOERS_DIR="$TMP/sudoers.d"
export SUDO_USER=me

# ── visudo rejects: nothing may be installed ──────────────────────────────────
rm -f "$VISUDO_VERDICT"
OUT="$(tier_sudo_nopasswd 2>&1)"; rc=$?
eq "$rc" '0' 'rejected: the tier does not abort the whole provision run'
has "$OUT" 'visudo rejected' 'rejected: says what happened'
absent "$SUDOERS_DIR/me" 'rejected: NO file is installed — a bad sudoers file locks sudo out entirely'

# ── visudo accepts ────────────────────────────────────────────────────────────
touch "$VISUDO_VERDICT"
OUT="$(tier_sudo_nopasswd 2>&1)"; rc=$?
eq "$rc" '0' 'accepted: succeeds'
eq "$(cat "$SUDOERS_DIR/me")" 'me ALL=(ALL) NOPASSWD: ALL' 'accepted: the drop-in grants what it says'
# 0440 is what sudo checks: it ignores a sudoers file that is group- or
# world-writable. Ownership is not asserted — the install runs as root, so the file
# is root-owned by construction, and passing -o/-g explicitly would break on any
# system whose root group has another name.
eq "$(ls -l "$SUDOERS_DIR/me" | cut -c1-10)" '-r--r-----' 'accepted: mode is 0440, which sudo will actually read'

# ── Idempotence ───────────────────────────────────────────────────────────────
OUT="$(tier_sudo_nopasswd 2>&1)"
has "$OUT" 'already configured' 'second run: recognises its own work'
eq "$(cat "$SUDOERS_DIR/me")" 'me ALL=(ALL) NOPASSWD: ALL' 'second run: content unchanged'

# ── Degradations ──────────────────────────────────────────────────────────────
# No reachable root (a detached converge): warn and skip, per the tier contract.
rm -f "$SUDOERS_DIR/me"
PRIV=0
OUT="$(tier_sudo_nopasswd 2>&1)"
has "$OUT" 'no root available' 'PRIV=0: skips rather than failing'
absent "$SUDOERS_DIR/me" 'PRIV=0: writes nothing'
PRIV=1

# Root with no SUDO_USER: there is no way to tell whose account to grant, and
# granting root NOPASSWD to root would be meaningless.
OUT="$(SUDO_USER='' tier_sudo_nopasswd 2>&1)"
case "$(id -un)" in
  root) has "$OUT" 'cannot tell which user' 'no SUDO_USER as root: refuses to guess' ;;
  *) pass 'no SUDO_USER: falls back to the invoking user (not root here, so nothing to assert)' ;;
esac

if [ "$FAIL" -gt 0 ]; then printf 'FAILURES: %d\n' "$FAIL" >&2; exit 1; fi
printf 'PASS: %s\n' "$(basename "${BASH_SOURCE[0]}")"
