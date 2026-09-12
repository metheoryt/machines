#!/usr/bin/env bash
# provision/tests/backup-offsite.test.sh — the offsite site's pure helpers.
#
# No disks, no network: every judgement here is a function of its arguments, so
# the severity policy and the content-addressing rule are testable on any box.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2' in '$1')" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac; }

export RESTIC_PACK_VERIFY_LIB_ONLY=1
# shellcheck source=hosts/latitude/debian/restic-pack-verify.sh
source "$REPO/hosts/latitude/debian/restic-pack-verify.sh"

# ── rpv_is_content_addressed ──────────────────────────────────────────────────
# The whole keyless design rests on this split. data/, index/ and snapshots/ are
# named by the SHA-256 of their own stored bytes; config and keys/* are not, and
# hashing them against their names would report every healthy repo as corrupt.
eq "$(rpv_is_content_addressed data/8a/8a1f4cce)" yes 'data/ is content-addressed'
eq "$(rpv_is_content_addressed index/ab12)"       yes 'index/ is content-addressed'
eq "$(rpv_is_content_addressed snapshots/cd34)"   yes 'snapshots/ is content-addressed'
eq "$(rpv_is_content_addressed config)"           no  'config is NOT content-addressed'
eq "$(rpv_is_content_addressed keys/ef56)"        no  'keys/ is NOT content-addressed'
eq "$(rpv_is_content_addressed locks/aa)"         no  'locks/ is NOT content-addressed'

# ── rpv_check_line ────────────────────────────────────────────────────────────
# The name is the hash, so a match is silence and a mismatch names the file. The
# comparison is on the BASENAME: data files sit one directory deep under a
# two-hex-char prefix, and comparing the whole relative path would never match.
eq "$(rpv_check_line data/8a/8a1f4ccec0325b33 8a1f4ccec0325b33)" '' \
  'a pack whose name equals its hash is silent'
has "$(rpv_check_line data/8a/8a1f4ccec0325b33 deadbeefdeadbeef)" 'BAD data/8a/8a1f4ccec0325b33' \
  'a pack whose bytes changed is named'

# Every suite in this repo prints ALL PASS and exits nonzero on failure — that is
# what `just test` reads. Keep this block LAST in the file; later tasks append
# above it.
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "$FAIL FAILED" >&2
exit $((FAIL > 0))
