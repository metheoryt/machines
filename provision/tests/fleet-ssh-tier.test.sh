#!/usr/bin/env bash
# Unit tests for tier_fleet_ssh (provision/lib/tiers.sh) — the outbound fleet
# SSH client config for boxes with neither home-manager nor ssh-wsl.sh (macOS).
#
# Runs the REAL tier against a throwaway $HOME, so it exercises the actual
# ssh-wsl.sh helper reuse rather than a re-implementation. No network: the tier
# only runs jq, ssh-keygen and file writes.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP (jq absent)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Drive the tier in a subshell with the driver contract the tier library expects
# (helpers + globals set before sourcing) and a fake HOME.
run_tier() {
  HOME="$TMP" bash -c '
    REPO="$1"
    info(){ :; }; ok(){ :; }; warn(){ printf "WARN %s\n" "$*" >&2; }
    die(){ printf "DIE %s\n" "$*" >&2; exit 1; }
    have(){ command -v "$1" >/dev/null 2>&1; }
    WARNINGS=0; SUDO=""; PRIV=1; APT_UPDATED=""
    TIERS_LIB_ONLY=1 source "$REPO/provision/lib/tiers.sh"
    tier_fleet_ssh
  ' _ "$REPO" 2>&1
}

out="$(run_tier)"
CFG="$TMP/.ssh/config"

[ -f "$TMP/.ssh/id_fleet" ] && pass "generates ~/.ssh/id_fleet" || die "no fleet key generated"
[ -f "$CFG" ] && pass "writes ~/.ssh/config" || die "no ~/.ssh/config written"
cfg="$(cat "$CFG" 2>/dev/null || true)"

# A freshly generated key nobody has enrolled yet must say so LOUDLY — silently
# producing a key no fleet member trusts is the failure this warning prevents.
has "$out" 'ENROLLMENT NEEDED' "warns that the new key needs enrolling"

# Every fleet member gets a block, generated from fleet.json — including `air`
# itself and, critically, the hosts the Mac needs to reach. Each block matches
# the bare name AND the MagicDNS FQDN: without the second pattern the FQDN form
# fell through to the `Host *.gg.ez` catch-all's `User me` and was refused on the
# members whose user is methe/debian.
for h in air latitude desktop server hub; do
  has "$cfg" "^Host ${h} ${h}\.gg\.ez\$" "config has a Host block for ${h} + its FQDN"
done

# Mirrors modules/home/ssh.nix: HostName only for hub, User only when != me.
has "$cfg" '^Host hub hub\.gg\.ez$'      "hub block present"
has "$cfg" '^  HostName cyphy\.kz$'      "hub carries its ssh.host HostName"
has "$cfg" '^  User debian$'             "hub carries User debian"
has "$cfg" '^  User methe$'              "windows members carry User methe"
has "$cfg" '^Host \*\.gg\.ez$'           "the MagicDNS wildcard block is present"

# The whole point: an identity file on every block, so `ssh latitude` from the
# Mac presents id_fleet instead of falling back to the local account name.
n_id="$(grep -c '^  IdentityFile ~/.ssh/id_fleet$' "$CFG")"
[ "$n_id" -ge 6 ] && pass "every block sets IdentityFile id_fleet ($n_id)" \
  || die "expected >=6 IdentityFile lines, got $n_id"

# 0600 or ssh refuses the file outright.
perm="$(stat -c '%a' "$CFG" 2>/dev/null || stat -f '%Lp' "$CFG" 2>/dev/null)"
# shellcheck disable=SC2088  # the tilde is prose in a test label, not a path
[ "$perm" = 600 ] && pass "~/.ssh/config is 0600" || die "~/.ssh/config perms are $perm"

# Idempotent: a second run must not duplicate the block or re-warn about the key.
out2="$(run_tier)"
cfg2="$(cat "$CFG")"
[ "$(printf '%s\n' "$cfg2" | grep -c '^Host latitude latitude\.gg\.ez$')" = 1 ] \
  && pass "re-run does not duplicate the fleet block" \
  || die "re-run duplicated blocks: $(printf '%s\n' "$cfg2" | grep -c '^Host latitude latitude\.gg\.ez$') latitude blocks"
printf '%s\n' "$out2" | grep -q 'ENROLLMENT NEEDED' \
  && die "re-run re-warned about enrollment despite an existing key" \
  || pass "re-run reuses the existing key silently"

# Coexistence with tier_ssh_accounts: a pre-existing foreign block outside our
# markers must survive. This is what lets both tiers own ~/.ssh/config.
{ printf '# >>> machines-bootstrap ssh accounts >>>\n'
  printf 'Host cyphy671.github.com\n    IdentityFile ~/.ssh/id_cyphy671\n'
  printf '# <<< machines-bootstrap ssh accounts <<<\n'; } >> "$CFG"
run_tier >/dev/null
cfg3="$(cat "$CFG")"
has "$cfg3" '^Host cyphy671\.github\.com$' "a foreign ssh_accounts block survives a re-run"
has "$cfg3" '^Host latitude latitude\.gg\.ez$'     "the fleet block is still present alongside it"
[ "$(printf '%s\n' "$cfg3" | grep -c '^Host cyphy671\.github\.com$')" = 1 ] \
  && pass "the foreign block is not duplicated" \
  || die "foreign block duplicated"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
