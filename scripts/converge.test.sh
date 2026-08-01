#!/usr/bin/env bash
# Unit tests for scripts/converge.sh pure helpers. No privilege, no rebuild:
# sources the script in CONVERGE_LIB_ONLY mode so functions load but converge_main
# never runs. Builds a throwaway git repo to exercise range/gate logic.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/converge.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a throwaway repo that looks like the machines checkout: converge.sh
# derives REPO from its own dir ($0/..), so copy it into <repo>/scripts/.
repo="$tmp/machines"
mkdir -p "$repo/scripts"
cp "$SCRIPT" "$repo/scripts/converge.sh"
git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" checkout -q -b main
: > "$repo/a.txt"; git -C "$repo" add .; git -C "$repo" commit -qm c1
rev1="$(git -C "$repo" rev-parse HEAD)"
echo change > "$repo/mod.nix"; git -C "$repo" add .; git -C "$repo" commit -qm c2
rev2="$(git -C "$repo" rev-parse HEAD)"

# Source the COPY so REPO resolves to the throwaway repo.
CONVERGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$repo/scripts/converge.sh"

# range_low: empty when no converged-rev file yet.
eq "$(range_low)" "" "range_low empty on first run"

# touches_nix: rev1..rev2 added mod.nix -> hit.
touches_nix "$rev1" "$rev2" && pass "touches_nix detects .nix" || die "touches_nix detects .nix"

# touches_nix: empty low (first run) -> treat as changed (hit).
touches_nix "" "$rev2" && pass "touches_nix first-run is hit" || die "touches_nix first-run is hit"

# touches_nix: fleet.json is a Nix INPUT (modules/system/fleet.nix reads it with
# fromJSON; modules/home/ssh.nix renders ~/.ssh/config host blocks from it), so a
# manifest-only pull must rebuild — otherwise adding a fleet member never reaches
# any NixOS host and converge writes ok + advances converged-rev anyway.
echo '{"machines":{}}' > "$repo/fleet.json"; git -C "$repo" add .; git -C "$repo" commit -qm cfleet
revf="$(git -C "$repo" rev-parse HEAD)"
touches_nix "$rev2" "$revf" && pass "touches_nix detects fleet.json" || die "touches_nix detects fleet.json"

# touches_linux: only provisioning-relevant paths (the linux provisioner / its
# version inputs) count — a content-only pull must NOT trigger a reprovision.
echo doc > "$repo/docs.md"; git -C "$repo" add .; git -C "$repo" commit -qm c3
rev3="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/provision"; echo x > "$repo/provision/linux.sh"
git -C "$repo" add .; git -C "$repo" commit -qm c4
rev4="$(git -C "$repo" rev-parse HEAD)"
touches_linux "$rev2" "$rev3" && die "touches_linux false-positive on non-provisioning change" || pass "touches_linux ignores content-only change"
touches_linux "$rev3" "$rev4" && pass "touches_linux detects provision/linux.sh" || die "touches_linux detects provision/linux.sh"
touches_linux "" "$rev4" && pass "touches_linux first-run is hit" || die "touches_linux first-run is hit"

# touches_linux: the tier library and the manifest helpers are on the provisioning
# path too (provision/linux.sh only drives them) — a tiers-only pull MUST reprovision,
# or converge writes ok + advances converged-rev and never applies it.
mkdir -p "$repo/provision/lib"
echo x > "$repo/provision/lib/tiers.sh"; git -C "$repo" add .; git -C "$repo" commit -qm c5
rev5="$(git -C "$repo" rev-parse HEAD)"
touches_linux "$rev4" "$rev5" && pass "touches_linux detects provision/lib/tiers.sh" || die "touches_linux detects provision/lib/tiers.sh"
echo y > "$repo/provision/lib/fleet.sh"; git -C "$repo" add .; git -C "$repo" commit -qm c6
rev6="$(git -C "$repo" rev-parse HEAD)"
touches_linux "$rev5" "$rev6" && pass "touches_linux detects provision/lib/fleet.sh" || die "touches_linux detects provision/lib/fleet.sh"

# provision/fleet-authorized-keys counts on BOTH tiers, and is asserted last so
# its commit stays outside the ranges the assertions above depend on.
#   nixos — it is the literal path in modules/system/ssh-server.nix's
#     users.users.me.openssh.authorizedKeys.keyFiles, so the trust is baked at
#     build time and only takes effect after a rebuild.
#   linux — tier_fleet_ssh merges it into ~/.ssh/authorized_keys.
# Same silent-skip shape as fleet.json: enrolling a new member's key would
# otherwise write ok, advance converged-rev, and never be applied — leaving the
# newly-added box permanently unable to SSH into latitude or hub.
echo 'ssh-ed25519 AAAA test@x' > "$repo/provision/fleet-authorized-keys"
git -C "$repo" add .; git -C "$repo" commit -qm ckeys
revk="$(git -C "$repo" rev-parse HEAD)"
touches_nix "$rev6" "$revk" && pass "touches_nix detects fleet-authorized-keys" || die "touches_nix detects fleet-authorized-keys"
touches_linux "$rev6" "$revk" && pass "touches_linux detects fleet-authorized-keys" || die "touches_linux detects fleet-authorized-keys"

# touches_macos: the Darwin driver's gate. Same shared inputs as touches_linux
# (both run provision/lib/tiers.sh) — only the driver path differs, so each gate
# must fire on its OWN driver and ignore the other's. Asserted against the ranges
# built above: rev3..rev4 added provision/linux.sh, rev4..rev5 added tiers.sh.
touches_macos "$rev3" "$rev4" && die "touches_macos false-positive on provision/linux.sh" || pass "touches_macos ignores the linux driver"
touches_linux "$rev6" "$revk" && pass "touches_linux detects fleet-authorized-keys (shared)" || die "touches_linux detects fleet-authorized-keys (shared)"
touches_macos "$rev4" "$rev5" && pass "touches_macos detects provision/lib/tiers.sh (shared)" || die "touches_macos detects provision/lib/tiers.sh (shared)"
touches_macos "$rev2" "$rev3" && die "touches_macos false-positive on content-only change" || pass "touches_macos ignores content-only change"
touches_macos "" "$rev4" && pass "touches_macos first-run is hit" || die "touches_macos first-run is hit"
echo x > "$repo/provision/macos.sh"; git -C "$repo" add .; git -C "$repo" commit -qm cmac
revm="$(git -C "$repo" rev-parse HEAD)"
touches_macos "$revk" "$revm" && pass "touches_macos detects provision/macos.sh" || die "touches_macos detects provision/macos.sh"
touches_linux "$revk" "$revm" && die "touches_linux false-positive on provision/macos.sh" || pass "touches_linux ignores the darwin driver"

# box_class: the OS routing itself, previously untested — which is how Darwin
# stayed in the `linux` catch-all and made every convergence on the Mac run the
# apt driver. Shadow `uname` to drive the arms, and point the NixOS probe at a
# path that does not exist so the test result does not depend on the box it runs
# on. Both overrides are undone straight after.
_real_nixos_marker="$NIXOS_MARKER"
NIXOS_MARKER="$tmp/definitely-not-nixos"
uname() { printf '%s\n' "$_fake_uname"; }
_fake_uname=Darwin      ; eq "$(box_class)" darwin  "box_class: Darwin -> darwin (not the linux catch-all)"
_fake_uname=Linux       ; eq "$(box_class)" linux   "box_class: Linux -> linux"
_fake_uname=MINGW64_NT-10.0; eq "$(box_class)" windows "box_class: MINGW -> windows"
_fake_uname=MSYS_NT-10.0; eq "$(box_class)" windows "box_class: MSYS -> windows"
_fake_uname=FreeBSD     ; eq "$(box_class)" linux   "box_class: an unknown OS still falls back to linux"
NIXOS_MARKER="$tmp/is-nixos"; : > "$NIXOS_MARKER"
_fake_uname=Darwin      ; eq "$(box_class)" nixos   "box_class: the NixOS marker wins over uname"
unset -f uname
NIXOS_MARKER="$_real_nixos_marker"

# on_main_primary: true on main in primary checkout.
on_main_primary && pass "on_main_primary true on main" || die "on_main_primary true on main"

# write_status ok: writes both files; converged-rev is the bare SHA.
write_status "$rev2" ok "test-ok"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status ok sets converged-rev"
grep -q '^status=ok$' "$repo/.machines/last-converge" && pass "last-converge status=ok" || die "last-converge status=ok"

# after ok write, range_low returns rev2.
eq "$(range_low)" "$rev2" "range_low reads converged-rev"

# write_status fail: updates last-converge but NOT converged-rev (retry next time).
write_status "$rev2" fail "boom"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status fail leaves converged-rev"
grep -q '^status=fail$' "$repo/.machines/last-converge" && pass "last-converge status=fail" || die "last-converge status=fail"

# ensure_git_safe: marks REPO safe in the converging user's GLOBAL git config so
# a privileged converge (root/SYSTEM) on a user-owned checkout doesn't hit git's
# "dubious ownership" fatal and silently skip. Isolate HOME so --global writes to
# the throwaway tree, not the test runner's real ~/.gitconfig.
# Isolate HOME *and* XDG_CONFIG_HOME: git --global honours $XDG_CONFIG_HOME/git/
# config when set, so a leaked XDG (e.g. a read-only NixOS ~/.config) would defeat
# the HOME override and hijack the write.
_oldhome="$HOME"; _oldxdg="${XDG_CONFIG_HOME:-}"
export HOME="$tmp/fakehome"; mkdir -p "$HOME"; unset XDG_CONFIG_HOME
ensure_git_safe
eq "$(git config --global --get-all safe.directory 2>/dev/null)" "$repo" "ensure_git_safe marks REPO safe in global config"
ensure_git_safe   # second call must not accumulate a duplicate
eq "$(git config --global --get-all safe.directory 2>/dev/null | grep -c .)" "1" "ensure_git_safe is idempotent (no dup)"
export HOME="$_oldhome"; [ -n "$_oldxdg" ] && export XDG_CONFIG_HOME="$_oldxdg"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
