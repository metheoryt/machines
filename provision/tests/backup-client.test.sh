#!/usr/bin/env bash
# Unit tests for provision/backup-client.sh — the one implementation behind both
# the `backup-client` role and step 6 of the WSL chain.
#
# THE TEST THAT MATTERS IS THE FIRST ONE. `fleet_detect` returns the WRONG
# machine on a WSL box, differently wrong on each: on g16-wsl `hostname` is
# g614jv, which IS `g16`'s detect.hostname, so detection hands the distro the
# WINDOWS parent's backup profile; on g15-wsl the hostname matches nothing and it
# returns empty. So fleet.local.json's nickname must win OUTRIGHT — never a
# "prefer, else fall back", because falling back lands on a known-wrong answer.
#
# Everything runs against a synthetic repo in $TMPDIR, so the assertions do not
# depend on which box the suite happens to run on.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../backup-client.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A synthetic repo: provision/backup-client.sh + provision/lib/fleet.sh (the
# script resolves REPO from its own path, so the layout has to be real) and a
# fleet.json whose detect.hostname is THIS box's — which is what makes the trap
# reproducible anywhere rather than only on a WSL distro.
# fleet_detect strips any DNS/mDNS suffix before matching (macOS returns
# `air.local`), so the synthetic manifest must carry the STRIPPED name or the
# trap setup silently fails to reproduce on a Mac.
fleet_hostname_for_test() { local h; h="$(hostname)"; printf '%s' "${h%%.*}"; }

mkrepo() {  # mkrepo <dir>
  local r="$1"
  mkdir -p "$r/provision/lib" "$r/backup"
  cp "$SRC" "$r/provision/backup-client.sh"
  cp "$HERE/../lib/fleet.sh" "$r/provision/lib/fleet.sh"
  cat > "$r/fleet.json" <<EOF
{"machines":{"trapmachine":{"platform":"debian","roles":["backup-client"],"detect":{"hostname":"$(fleet_hostname_for_test)"}}}}
EOF
}

# ── 1. fleet.local.json WINS OUTRIGHT ────────────────────────────────────────
r="$tmp/trap"; mkrepo "$r"
printf '{"self":{"nickname":"the-distro","fleet":true}}\n' > "$r/fleet.local.json"
det="$(cd "$r" && bash -c 'source provision/lib/fleet.sh; fleet_detect' 2>/dev/null)"
got="$(BACKUP_CLIENT_LIB_ONLY=1 bash -c 'source "$1"; backup_client_identity' _ "$r/provision/backup-client.sh" 2>&1)"
[ "$det" = "trapmachine" ] \
  && pass "the trap is live: fleet_detect resolves this host to the manifest machine" \
  || die "test setup broken: fleet_detect returned '$det', expected 'trapmachine'"
[ "$got" = "the-distro" ] \
  && pass "identity comes from fleet.local.json, NOT from detection" \
  || die "identity was '$got' — detection leaked through and would schedule the parent's profile"

# ── 2. A malformed self-declaration FAILS, it does not fall through ──────────
# Falling back here would land on the known-wrong detection above, so an empty
# nickname has to be an error rather than a shrug.
r="$tmp/malformed"; mkrepo "$r"
printf '{"self":{"fleet":true}}\n' > "$r/fleet.local.json"
out="$(BACKUP_CLIENT_LIB_ONLY=1 bash -c 'source "$1"; backup_client_identity' _ "$r/provision/backup-client.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "a nickname-less fleet.local.json is an error, not a fallback" \
  || die "a nickname-less fleet.local.json resolved to '$out' instead of failing"

# ── 3. No self-declaration → detection, which is right for a fleet member ────
r="$tmp/member"; mkrepo "$r"
got="$(BACKUP_CLIENT_LIB_ONLY=1 bash -c 'source "$1"; backup_client_identity' _ "$r/provision/backup-client.sh" 2>&1)"
[ "$got" = "trapmachine" ] && pass "with no fleet.local.json, detection is used" \
  || die "detection path returned '$got'"

# ── 4. Missing profile dir is a NAMED skip that exits 0 ─────────────────────
# The opposite of a role with no executor, which exits 1 by design: an
# unconfigured client must stay visible without turning a provision run red.
r="$tmp/noprofile"; mkrepo "$r"
out="$(bash "$r/provision/backup-client.sh" --dry-run nobody 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "missing profile dir exits 0" || die "missing profile dir exited $rc"
case "$out" in
  *"no profile dir for nobody (skipped)"*) pass "missing profile dir names the identity" ;;
  *) die "missing-dir message changed — $out" ;;
esac

# ── 5. Profile dir with no install script is LOUD ───────────────────────────
# The scope decision (sudo or not, elevated or not) lives in that script, so
# there is nothing sensible to guess.
r="$tmp/noscript"; mkrepo "$r"; mkdir -p "$r/backup/someone"
out="$(bash "$r/provision/backup-client.sh" --dry-run someone 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "profile dir without install-tasks.sh exits 1" \
  || die "profile dir without install-tasks.sh exited $rc — a misconfiguration must not be silent"

# ── 6. Unresolvable identity FAILS ──────────────────────────────────────────
r="$tmp/nobodyknows"; mkrepo "$r"
printf '{"machines":{"elsewhere":{"platform":"debian","detect":{"hostname":"not-this-box-at-all"}}}}\n' > "$r/fleet.json"
out="$(bash "$r/provision/backup-client.sh" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "an unresolvable identity fails instead of skipping" \
  || die "an unresolvable identity exited 0 — that is a silent no-backup"

# ── 7. THE DRY RUN WRITES NOTHING ───────────────────────────────────────────
# `resticprofile schedule` creates systemd units and has no dry-run of its own,
# so the preview can only print the command. Reading the output proves the
# message; only a tripwire proves the silence.
r="$tmp/real"; mkrepo "$r"; mkdir -p "$r/backup/whoever" "$tmp/bin"
printf '#!/bin/sh\necho ran > "$TRIPWIRE"\n' > "$r/backup/whoever/install-tasks.sh"
for b in resticprofile sudo systemctl loginctl; do
  printf '#!/bin/sh\necho "%s $*" >> "$TRIPWIRE"\n' "$b" > "$tmp/bin/$b"; chmod +x "$tmp/bin/$b"
done
TRIPWIRE="$tmp/fired"
out="$(PATH="$tmp/bin:$PATH" TRIPWIRE="$TRIPWIRE" bash "$r/provision/backup-client.sh" --dry-run whoever 2>&1)"
[ -e "$TRIPWIRE" ] && die "dry-run EXECUTED: $(cat "$TRIPWIRE")" || pass "dry-run runs nothing"
case "$out" in
  *"would run: bash "*install-tasks.sh) pass "dry-run prints the command it would run" ;;
  *) die "dry-run did not print the command — $out" ;;
esac

# ── 8. Apply DOES run it (the mirror of 7 — a silent apply is the real risk) ─
rm -f "$TRIPWIRE"
PATH="$tmp/bin:$PATH" TRIPWIRE="$TRIPWIRE" bash "$r/provision/backup-client.sh" whoever >/dev/null 2>&1
[ -e "$TRIPWIRE" ] && pass "apply runs install-tasks.sh" \
  || die "apply did NOT run install-tasks.sh — the whole point of the role"

# ── 8b. resticprofile in ~/.local/bin is FOUND, not reported missing ────────
# g15 has no NOPASSWD sudo, so backup/restic-install.sh (apt + a curl'd
# installer into /usr/local/bin) cannot run there at all -- which makes a wrong
# "missing" verdict a hard failure of the role rather than a slow path. It
# installs resticprofile in ~/.local/bin instead, the same place tier_gortex
# puts gortex, and a NON-INTERACTIVE ssh PATH does not include that directory.
# Asserted through the dry-run message because that is the branch the verdict
# feeds; the tripwire proves the install was not even considered.
r="$tmp/localbin"; mkrepo "$r"; mkdir -p "$r/backup/whoever" "$tmp/lbin" "$tmp/fakehome/.local/bin"
printf '#!/bin/sh\necho ran > "$TRIPWIRE"\n' > "$r/backup/whoever/install-tasks.sh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/lbin/restic"; chmod +x "$tmp/lbin/restic"
printf '#!/bin/sh\nexit 0\n' > "$tmp/fakehome/.local/bin/resticprofile"
chmod +x "$tmp/fakehome/.local/bin/resticprofile"
rm -f "$TRIPWIRE"
out="$(HOME="$tmp/fakehome" PATH="$tmp/lbin:/usr/bin:/bin" TRIPWIRE="$TRIPWIRE" \
       bash "$r/provision/backup-client.sh" --dry-run whoever 2>&1)"
case "$out" in
  *"restic + resticprofile present"*)
    pass "resticprofile in ~/.local/bin counts as present" ;;
  *"would install"*)
    die "resticprofile in ~/.local/bin reported MISSING — the role would try a sudo install" ;;
  *) die "unexpected dry-run output — $out" ;;
esac
# And the mirror: with ~/.local/bin empty it must still report it missing, or
# the case above would pass for the wrong reason.
out="$(HOME="$tmp/emptyhome" PATH="$tmp/lbin:/usr/bin:/bin" TRIPWIRE="$TRIPWIRE" \
       bash "$r/provision/backup-client.sh" --dry-run whoever 2>&1)"
case "$out" in
  *"would install"*resticprofile*) pass "with no ~/.local/bin, resticprofile is still missing" ;;
  *) die "missing resticprofile was not reported — $out" ;;
esac

# ── 9. The Windows half is REGISTERED ───────────────────────────────────────
# provision.ps1 has no PLANNED_ROLES equivalent: a role missing from its
# $RoleExecutors map prints "not yet implemented (skipped)" and leaves $rc at 0.
# So the map entry is the only thing between a declared role and a silent green
# skip, and it is asserted textually because pwsh is not in the fleet toolchain.
ps1="$HERE/../roles/backup-client.ps1"
[ -f "$ps1" ] && pass "provision/roles/backup-client.ps1 exists" \
  || die "provision/roles/backup-client.ps1 missing"
grep -q 'function Invoke-RoleBackupClient' "$ps1" \
  && pass "backup-client.ps1 defines Invoke-RoleBackupClient" \
  || die "backup-client.ps1 does not define Invoke-RoleBackupClient"
grep -q "'backup-client'.*Invoke-RoleBackupClient" "$HERE/../provision.ps1" \
  && pass "provision.ps1 maps 'backup-client' to its executor" \
  || die "provision.ps1 has no 'backup-client' map entry — the role would silently skip and exit 0"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
