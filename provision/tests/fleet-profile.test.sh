#!/usr/bin/env bash
# Unit tests for provision/lib/fleet.sh profile resolvers. Asserts against the
# REAL repo fleet.json (it is the source of truth this ships with).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/fleet.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

# shellcheck source=/dev/null
source "$LIB"

# fleet_profile: an explicit `profile` field wins; absent, it defaults to
# workstation. hub and latitude carry one (latitude gained `server` in 380cb55,
# ahead of its post-NixOS reinstall as a headless box); `air` and `desktop` carry
# none, so they exercise the default path. Keep at least one of each here — a
# manifest edit that gives every machine an explicit profile would otherwise leave
# the default branch untested.
eq "$(fleet_profile hub)" "hub" "fleet_profile hub == hub (explicit)"
eq "$(fleet_profile latitude)" "server" "fleet_profile latitude == server (explicit, post-NixOS)"
eq "$(fleet_profile air)" "workstation" "fleet_profile air defaults to workstation"

# fleet_platform: the manifest is the only source — a new platform needs no
# code change here, but `air` must resolve to darwin or every downstream
# platform `case` (provision/roles/*.sh, fleet-dispatch.sh) misroutes it.
eq "$(fleet_platform air)" "darwin" "fleet_platform air == darwin"
# latitude is Debian since the 2026-07-29 reinstall — NixOS is gone from the fleet.
eq "$(fleet_platform latitude)" "debian" "fleet_platform latitude == debian"

# fleet_profile_for_host: OS hostname -> profile.
eq "$(fleet_profile_for_host 27608)" "hub" "for_host 27608 == hub"
eq "$(fleet_profile_for_host latitude5520)" "server" "for_host latitude5520 == server"
eq "$(fleet_profile_for_host air)" "workstation" "for_host air == workstation"

# macOS reports the Bonjour name (`air.local`) from `hostname`/`uname -n` whenever
# configd has no better name — the normal DHCP case, even after
# `scutil --set HostName air`. Resolution must survive that, or provision.sh
# drops to its interactive picker and macos.sh resolves its profile from the
# default rather than the manifest. Mirrors agents/bootstrap.sh's host_id().
eq "$(fleet_hostname air.local)" "air" "fleet_hostname strips the mDNS suffix"
eq "$(fleet_hostname air)" "air" "fleet_hostname leaves a bare name alone"
eq "$(fleet_hostname latitude5520.lan)" "latitude5520" "fleet_hostname strips any DNS suffix"
eq "$(fleet_profile_for_host air.local)" "workstation" "for_host air.local resolves like air"
eq "$(fleet_profile_for_host 27608.example.net)" "hub" "for_host tolerates a suffix on the hub too"
eq "$(fleet_profile_for_host no-such-box)" "" "for_host unknown host is empty"

# jq-free path: hub has no jq, so resolution must fall back to python3. Build a
# PATH holding only python3 + dirname (fleet_manifest_path needs dirname) + bash
# (the PATH= prefix below applies to the `bash` lookup itself, so it must resolve).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for b in bash python3 dirname; do ln -s "$(command -v "$b")" "$tmp/bin/$b"; done
nojq="$(PATH="$tmp/bin" bash -c 'source "$1"; fleet_profile_for_host 27608' _ "$LIB")"
eq "$nojq" "hub" "for_host resolves without jq (python3 fallback)"

# The suffix strip happens before the jq/python3 branch, so it must hold on the
# jq-free path too — asserted rather than assumed, since hub is the box that
# runs it and a regression there is invisible until a provision fails.
nojq_sfx="$(PATH="$tmp/bin" bash -c 'source "$1"; fleet_profile_for_host 27608.example.net' _ "$LIB")"
eq "$nojq_sfx" "hub" "for_host strips the suffix on the python3 fallback too"

# fleet_has_machine + the front door's unknown-machine guard. The bug this closes:
# `--machine <not-a-member>` used to print `platform: null`, emit a raw
# `jq: error ... Cannot iterate over null`, list NO roles, and exit 0 -- provisioned
# nothing, reported success. It surfaced when `server` was removed from the manifest
# on 2026-08-01, but it was never specific to that name.
fleet_has_machine latitude && pass "fleet_has_machine accepts a real member" \
  || die "fleet_has_machine accepts a real member"
fleet_has_machine no-such-box && die "fleet_has_machine accepts a non-member" \
  || pass "fleet_has_machine rejects a non-member"
fleet_has_machine "" && die "fleet_has_machine accepts an empty name" \
  || pass "fleet_has_machine rejects an empty name"
# `server` by name, because muscle memory outlives a manifest edit and this is the
# regression that would make a retired member silently look provisionable again.
fleet_has_machine server && die "fleet_has_machine still accepts the retired 'server'" \
  || pass "fleet_has_machine rejects the retired 'server'"

# The exit CODE is the assertion: a nonzero status is what stops `just provision
# --machine typo --apply` from reading as a successful no-op.
PROV="$HERE/../provision.sh"
out="$(bash "$PROV" --machine no-such-box --dry-run 2>&1)"; rc=$?
eq "$rc" "2" "provision.sh exits 2 for an unknown machine"
printf '%s\n' "$out" | grep -q 'unknown machine: no-such-box' \
  && pass "provision.sh names the unknown machine" \
  || die "provision.sh names the unknown machine"
printf '%s\n' "$out" | grep -q 'known machines:' \
  && pass "provision.sh lists the known machines" \
  || die "provision.sh lists the known machines"
printf '%s\n' "$out" | grep -q 'Cannot iterate over null' \
  && die "provision.sh still leaks the raw jq error" \
  || pass "provision.sh no longer leaks a raw jq error"

# ── The same guard, one level down: an unknown ROLE (review item 6) ───────────
# fleet_has_machine stops a typo'd MACHINE from provisioning nothing and exiting
# 0. The role loop had the identical hole and no guard: a role with no executor
# printed "not yet implemented (skipped)" and left rc untouched, so
# `just provision --machine latitude --apply` reported success while doing
# nothing for four of its seven roles.
#
# The fix is a DECLARED opt-out, not a silent one: PLANNED_ROLES names the roles
# known to have no executor yet. In it → skipped, rc unchanged. Not in it → rc=1.
# So the guard fires for exactly the case worth catching: a role added to
# fleet.json, or renamed, with nothing behind it.
#
# Every prompt is answered `n`, so the implemented roles are skipped and the exit
# code can only come from the fallback arm.
prov_apply() { printf 'n\nn\nn\nn\nn\nn\nn\n' | bash "$PROV" --machine "$1" --apply 2>&1; }

out="$(prov_apply air)"; rc=$?
eq "$rc" "0" "provision.sh exits 0 when every executor-less role is DECLARED planned"

out="$(MACHINES_PLANNED_ROLES="" prov_apply air)"; rc=$?
eq "$rc" "1" "provision.sh exits 1 for a role with no executor and no declaration"
printf '%s\n' "$out" | grep -q 'no executor' \
  && pass "provision.sh names the undeclared role's missing executor" \
  || die "provision.sh names the undeclared role's missing executor"

out="$(prov_apply air)"
printf '%s\n' "$out" | grep -q 'no executor yet (declared)' \
  && pass "a declared role reports itself as declared, not as a failure" \
  || die "a declared role reports itself as declared, not as a failure"

# The declaration must cover today's stubs on EVERY machine, or the commit that
# adds the guard turns the whole fleet's --apply red. air carries base and
# ssh-server; latitude is the only member carrying the two backup roles, so it
# has to be exercised separately — asserting all four against air would pass
# vacuously for the two air does not have.
out="$(prov_apply latitude)"; rc=$?
eq "$rc" "0" "provision.sh exits 0 on latitude, whose seven roles include both backup stubs"
for r in backup-hub backup-client; do
  printf '%s\n' "$out" | grep -q "$r — apply: no executor yet (declared)" \
    && pass "'$r' is declared, not silently skipped" \
    || die "'$r' is declared, not silently skipped"
done
# And the guard still bites there: a future executor lands by DELETING a name
# from the declaration, and that deletion is what this asserts stays reviewable.
out="$(MACHINES_PLANNED_ROLES="base ssh-server" prov_apply latitude)"; rc=$?
eq "$rc" "1" "dropping the backup roles from the declaration fails latitude's --apply"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
