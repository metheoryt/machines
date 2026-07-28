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
eq "$(fleet_platform latitude)" "nixos" "fleet_platform latitude == nixos"

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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
