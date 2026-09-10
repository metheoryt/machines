#!/usr/bin/env bash
# provision/tests/docker-ordering.test.sh — unit tests for the pure parts of
# hosts/latitude/debian/install-docker-ordering.sh. No root, no docker, no
# /etc/fstab: the script is SOURCED (it guards its own run block) and its
# helpers are called with files passed in.
#
# WHY THIS SUITE EXISTS. That script is the guard against the fleet's most
# expensive failure mode — Docker creating a missing bind source on the root
# filesystem, so a container serves an empty directory while the host looks
# healthy. It has cost two incidents (servarr 2026-08-03, immich-2024
# 2026-09-03) and had ZERO tests until 2026-09-10. What is covered here is the
# decision-making: which fstab lines get rewritten, whether a candidate file is
# safe to install, and which mountpoints are frozen or unfrozen. The parts that
# need root (chattr, mount --bind, systemctl) are not, and cannot be, here.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/hosts/latitude/debian/install-docker-ordering.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || bad "$3: expected '$2', got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qF -- "$2" && pass "$3" || bad "$3: missing '$2'"; }
hasnt(){ printf '%s\n' "$1" | grep -qF -- "$2" && bad "$3: found '$2'" || pass "$3"; }

[ -f "$SCRIPT" ] || { echo "FAIL script missing: $SCRIPT"; exit 1; }
# shellcheck disable=SC1090
. "$SCRIPT" || true
command -v fstab_gate >/dev/null || { echo "FAIL sourcing did not define fstab_gate — did the main() guard change?"; exit 1; }

# ── the source is inert when sourced ────────────────────────────────────────
# The whole suite depends on this. The old shape ran a full dry run on source:
# it read /etc/fstab, shelled out to findmnt and bind-mounted / at $ROOTVIEW.
has "$(sed -n '$p' "$SCRIPT")" 'BASH_SOURCE' "the run block is behind a BASH_SOURCE guard"

# ── MOUNTS is the guard set, and membership is a claim about live binds ──────
mounts=" ${MOUNTS[*]} "
has "$mounts" "/mnt/wd8"      "wd8 is guarded (it holds ServarrMedia and the restic repos)"
has "$mounts" "/mnt/immich"   "immich is guarded"
hasnt "$mounts" "/mnt/servarr" "servarr is NOT guarded — that mount no longer exists"
hasnt "$mounts" "/mnt/immich-2024-backup" "the archive target is not guarded — no container binds it"

# ── fstab_errors: a comparable set of [E] lines, warnings excluded ───────────
# Warnings are excluded on purpose: a non-root findmnt emits "cannot detect
# on-disk filesystem type (Permission denied)" for every device, which says
# nothing about the file being checked.
sample='/mnt/one
   [E] unreachable on boot required target: No such file or directory
   [W] cannot detect on-disk filesystem type (Permission denied)
/mnt/two
   [E] unreachable on boot required source: UUID=dead

 0 parse errors, 2 errors, 1 warnings'
out="$(fstab_errors "$sample")"
eq "$(printf '%s\n' "$out" | wc -l)" 2 "fstab_errors returns one line per [E]"
has "$out" "/mnt/one :: [E] unreachable on boot required target" "each error is tagged with its entry"
hasnt "$out" "[W]" "warnings are excluded"
eq "$(fstab_errors "")" "" "empty input yields nothing, not a blank line"

# ── fstab_gate: the question is 'did MY edit add an error' ───────────────────
# Deliberately version-agnostic: these compare a file against a file rather than
# asserting findmnt's wording, which has changed across util-linux releases.
BOGUS1='UUID=00000000-0000-0000-0000-000000000000 /mnt/nope-one ext4 defaults 0 2'
BOGUS2='UUID=11111111-1111-1111-1111-111111111111 /mnt/nope-two ext4 defaults 0 2'
printf '# only comments\n' > "$TMP/clean"
printf '%s\n' "$BOGUS1" > "$TMP/one"
printf '%s\n%s\n' "$BOGUS1" "$BOGUS2" > "$TMP/two"

fstab_gate "$TMP/clean" "$TMP/clean" >/dev/null 2>&1 \
  && pass "a clean candidate against a clean current is allowed" \
  || bad "a clean candidate against a clean current was refused"

out="$(fstab_gate "$TMP/one" "$TMP/one" 2>&1)"
if [ $? -eq 0 ]; then
  pass "a PRE-EXISTING error does not block the install — the whole point of the rewrite"
  has "$out" "already has findmnt errors" "and it says so rather than staying silent"
else
  bad "a pre-existing error still blocks the install"
fi

fstab_gate "$TMP/two" "$TMP/one" >/dev/null 2>&1 \
  && bad "a candidate that ADDS an error was allowed" \
  || pass "a candidate that adds an error is refused"

out="$(fstab_gate "$TMP/two" "$TMP/one" 2>&1)"
has "$out" "/mnt/nope-two" "the refusal names the entry that is newly broken"
hasnt "$out" "/mnt/nope-one" "and not the one that was already broken"

fstab_gate "$TMP/one" "$TMP/two" >/dev/null 2>&1 \
  && pass "REMOVING a broken entry is allowed" \
  || bad "removing a broken entry was refused"

# ── fstab_gate: a findmnt that CRASHES must refuse, not compare ──────────────
# util-linux 2.41 segfaults (rc 139) on an fstab entry with fewer than three
# fields: it prints "parse error at line N -- ignored" and dies. A crashed
# process emits no [E] lines at all, so a diff-based gate on its own would see
# "no new errors" and install the very file that killed it. Stubbed rather than
# reproduced so the case holds on any util-linux, including one where the bug is
# fixed.
findmnt() { echo "findmnt: parse error at line 1 -- ignored"; return 139; }
out="$(fstab_gate "$TMP/clean" "$TMP/clean" 2>&1)"
rc=$?
eq "$rc" 1 "a segfaulting findmnt (rc 139) refuses the install"
has "$out" "itself failed" "and reports the checker as the failure, not the file"
findmnt() { return 2; }
fstab_gate "$TMP/clean" "$TMP/clean" >/dev/null 2>&1 \
  && bad "rc 2 from findmnt was treated as success" \
  || pass "any rc >= 2 refuses — 'unknown' is not 'fine'"
unset -f findmnt

# ── fstab_patch: only MOUNTS targets, only the one option ────────────────────
cat > "$TMP/fstab" <<'FSTAB'
# a comment naming /mnt/wd8 that must not be touched
UUID=aaaa /mnt/wd8 ext4 defaults,noatime,nofail 0 2
UUID=bbbb /mnt/immich-2024-backup ext4 defaults,noatime,nofail 0 2
UUID=cccc none swap sw 0 0
FSTAB
FSTAB="$TMP/fstab" fstab_patch add "$TMP/added" 2>/dev/null
got="$(cat "$TMP/added")"
# A rewritten line is REFORMATTED into aligned columns, so compare fields, not
# bytes. That is worth pinning: it is why `remove` below is the inverse of `add`
# field-wise and not byte-wise, and why a naive diff of /etc/fstab after a run
# shows every guarded line as changed even when only one option moved.
fields(){ awk -v t="$2" '$2==t {print $1, $2, $3, $4, $5, $6}' "$1"; }
eq "$(fields "$TMP/added" /mnt/wd8)" \
   "UUID=aaaa /mnt/wd8 ext4 defaults,noatime,nofail,x-systemd.before=docker.service 0 2" \
   "add appends the option to a guarded mount"
has "$got" "# a comment naming /mnt/wd8 that must not be touched" "a comment mentioning a guarded path is left alone"
hasnt "$got" "/mnt/immich-2024-backup ext4 defaults,noatime,nofail,x-systemd.before" "an unguarded mount is not rewritten"
has "$got" "UUID=cccc none swap sw 0 0" "unrelated entries survive byte-for-byte"
eq "$(wc -l < "$TMP/added")" "$(wc -l < "$TMP/fstab")" "the line count is unchanged — no trailing-newline damage"

FSTAB="$TMP/added" fstab_patch remove "$TMP/removed" 2>/dev/null
norm(){ awk '{$1=$1; print}' "$1"; }
eq "$(norm "$TMP/removed")" "$(norm "$TMP/fstab")" "remove is the inverse of add, field for field"
eq "$(fields "$TMP/removed" /mnt/wd8)" "UUID=aaaa /mnt/wd8 ext4 defaults,noatime,nofail 0 2" \
   "and the option is the only thing it takes away"

# ── the retirement scan: source-text assertions ─────────────────────────────
# It cannot be exercised without root (chattr + a bind mount of /), so what is
# checked is that the loop exists and iterates the right thing. Deleting a path
# from MOUNTS used to leave its mountpoint immutable forever, silently.
src="$(cat "$SCRIPT")"
has "$src" 'for under in "$ROOTVIEW"/mnt/*' "the retirement scan iterates /mnt one level deep"
has "$src" 'case " ${MOUNTS[*]} " in *" $m "*) continue ;; esac' "and skips anything still in MOUNTS"
has "$src" 'sudo chattr -i "$under" && say "guard3: retired' "and unfreezes what is left"

printf '\n'
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
