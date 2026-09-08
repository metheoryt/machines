#!/usr/bin/env bash
# Unit tests for the provision/linux.sh tier driver + provision/lib/tiers.sh.
# No root, no network: exercises profile resolution and the dry-run tier list.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../linux.sh"
TIERS="$HERE/../lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qE "$2" && die "$3" || pass "$3"; }
# CODE lines only — drops comments. Use it for any assertion that a construct is
# ABSENT: a tier that documents the wrong way to do something contains the wrong
# way as prose, so a `hasnt` over the raw body fires on the explanation. That has
# now bitten in two suites (here and tailscale-wsl.test.sh) and cost four wrong
# assertions between them. `has` is usually fine raw; `hasnt` usually is not.
code(){ printf '%s\n' "$1" | grep -vE '^[[:space:]]*#'; }

MACDRIVER="$HERE/../macos.sh"

plan()    { MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE="$1" bash "$DRIVER" 2>&1; }
macplan() { MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE="$1" bash "$MACDRIVER" 2>&1; }

ws="$(plan workstation)"
hub="$(plan hub)"
srv="$(plan server)"
mac="$(macplan workstation)"

# Profile banner names the resolution source.
has "$ws" 'profile: workstation \(from MACHINES_PROFILE\)' "banner reports env-var source"

# Both profiles start with apt_min and include the CORE agent-config tier.
has "$ws"  '^tier_apt_min$'       "workstation runs tier_apt_min"
has "$hub" '^tier_apt_min$'       "hub runs tier_apt_min"
has "$ws"  '^tier_agents_config$' "workstation runs tier_agents_config"
has "$hub" '^tier_agents_config$' "hub runs tier_agents_config"
eq "$(printf '%s\n' "$hub" | grep -c '^tier_apt_min$')" "1" "hub runs tier_apt_min exactly once"

# workstation keeps today's full set, in today's order.
eq "$(printf '%s\n' "$ws" | grep '^tier_' | tr '\n' ' ')" \
   "tier_apt_min tier_apt_dev tier_docker tier_battery_limit tier_lid_ignore tier_agents_config tier_git_base tier_gortex tier_agent_clis claude tier_shell_init tier_autofetch tier_ssh_accounts tier_selfpull tier_ssh_trust tier_dotfiles " \
   "workstation tier list and order"

# hub is lean: no dev apt layer, no gortex.
hasnt "$hub" '^tier_apt_dev$' "hub omits tier_apt_dev"
hasnt "$hub" '^tier_gortex$'  "hub omits tier_gortex"

# HAZARD GUARD: ssh_accounts would overwrite hub's ~/.ssh/config with
# IdentitiesOnly on an unregistered key and kill its only GitHub auth.
hasnt "$hub" '^tier_ssh_accounts$' "hub NEVER runs tier_ssh_accounts"

# hub pins fleet-selfpull to ~/machines so ~/vps never auto-pulls.
has "$hub" '^tier_selfpull %h/machines$' "hub pins FLEET_ROOTS to %h/machines"
has "$ws"  '^tier_selfpull$'             "workstation leaves FLEET_ROOTS default"
has "$hub" '^tier_shell_init --no-fish$' "hub skips the fish config"

# ── server: the always-on services box (latitude, post-NixOS) ─────────────────
# It is workstation MINUS the code-graph and secondary-agent tiers — NOT the hub
# tier, which is lean only because the hub is a 960MB VPS.
eq "$(printf '%s\n' "$srv" | grep '^tier_' | tr '\n' ' ')" \
   "tier_sudo_nopasswd tier_apt_min tier_apt_dev tier_statusboard tier_battery_limit tier_lid_ignore tier_rapl_read tier_agents_config tier_git_base tier_agent_clis claude tier_shell_init tier_autofetch tier_ssh_accounts tier_selfpull tier_gortex_autoupdate tier_ssh_trust tier_dotfiles " \
   "server tier list and order"

# sudo_nopasswd is server-ONLY and must run first: every later privileged tier then
# takes linux.sh's `sudo -n` path rather than needing a human at a TTY. It stays off
# a laptop someone carries, and off hub (whose provider already set it up).
has "$srv" '^tier_sudo_nopasswd$'      "server runs tier_sudo_nopasswd"
eq "$(printf '%s\n' "$srv" | grep '^tier_' | head -1)" 'tier_sudo_nopasswd' \
   "server runs tier_sudo_nopasswd FIRST"
hasnt "$ws"  '^tier_sudo_nopasswd$'    "workstation NEVER grants passwordless sudo"
hasnt "$hub" '^tier_sudo_nopasswd$'    "hub NEVER grants passwordless sudo"
hasnt "$mac" '^tier_sudo_nopasswd$'    "macOS NEVER grants passwordless sudo"

hasnt "$srv" '^tier_gortex$'           "server omits tier_gortex (no indexed checkouts to serve)"

# gortex_autoupdate is the fleet's ONE gortex-pin writer. Single-writer is not a
# preference here: two boxes bumping in the same window compute the same new pin,
# produce two different commits of it, and the loser's push is rejected
# non-fast-forward — leaving a stranded commit to unwind by hand. So a `has` on
# any second profile is a real fleet bug, which is what these three hasnts pin.
has   "$srv" '^tier_gortex_autoupdate$' "server publishes the gortex pin bump"
hasnt "$ws"  '^tier_gortex_autoupdate$' "workstation never writes the gortex pin (single writer)"
hasnt "$hub" '^tier_gortex_autoupdate$' "hub never writes the gortex pin (single writer)"
hasnt "$mac" '^tier_gortex_autoupdate$' "macOS never writes the gortex pin (single writer)"
# It lands on the profile that OMITS tier_gortex, so the publisher must not also
# be an installer — a body that reached ~/.local/bin or the release tarball would
# make the always-on box quietly self-update off-pin, which is the exact drift the
# pin exists to prevent.
gbody="$(awk '/^tier_gortex_autoupdate\(\)/,/^}/' "$TIERS")"
hasnt "$gbody" 'local/bin'          "tier_gortex_autoupdate installs no binary"
hasnt "$gbody" 'releases/download'  "tier_gortex_autoupdate downloads no release asset"
has   "$gbody" 'OnUnitActiveSec=1w' "tier_gortex_autoupdate schedules weekly (the cadence IS the blast radius)"
srv_gau="$(printf '%s\n' "$srv" | grep -n '^tier_gortex_autoupdate$' | cut -d: -f1)"
srv_acct="$(printf '%s\n' "$srv" | grep -n '^tier_ssh_accounts$' | cut -d: -f1)"
[ "$srv_acct" -lt "$srv_gau" ] \
  && pass "server runs ssh_accounts BEFORE gortex_autoupdate (the push needs a key)" \
  || die "server must run ssh_accounts before gortex_autoupdate"
has   "$srv" '^tier_apt_dev$'          "server KEEPS the dev apt layer (gh, fish, starship)"
has   "$srv" '^tier_shell_init$'       "server keeps fish (no --no-fish, unlike hub)"
has   "$srv" '^tier_ssh_accounts$'     "server wires the GitHub account aliases"
has   "$srv" '^tier_selfpull$'         "server leaves FLEET_ROOTS default (\$HOME + \$HOME/my)"
# statusboard is the physical-display box only: a kiosk compositor on a laptop
# someone carries, on a 960MB VPS, or on a mac is pure weight.
has   "$srv" '^tier_statusboard$'      "server installs the status-board packages"
hasnt "$ws"  '^tier_statusboard$'      "workstation omits the status-board packages"
hasnt "$hub" '^tier_statusboard$'      "hub omits the status-board packages"
hasnt "$mac" '^tier_statusboard$'      "macOS omits the status-board packages"
# ── docker: workstation ONLY ──────────────────────────────────────────────────
# The engine belongs on the box someone develops on. It is off `server` for a
# specific reason rather than by omission: latitude's docker-ce predates the
# tier and runs immich, and while the tier never upgrades (so it would be inert
# there today), putting it in that list would make a future engine install a
# side effect of an unattended converge on the services box. Off `hub` because
# a 960MB VPS runs no containers. Off macOS because the engine there is Docker
# Desktop, a cask, with no dockerd to apt-install.
# Behaviour is pinned by provision/tests/docker-tier.test.sh; this is placement.
has   "$ws"  '^tier_docker$' "workstation installs the docker engine"
hasnt "$srv" '^tier_docker$' "server does NOT install docker (latitude's engine predates the tier)"
hasnt "$hub" '^tier_docker$' "hub omits docker (960MB VPS)"
hasnt "$mac" '^tier_docker$' "macOS omits docker (the engine there is a cask)"
# It rides with the apt layer it extends, and must stay after tier_apt_min:
# that tier is what installs curl and ca-certificates, which the suite probe and
# the key fetch both need.
ws_min="$(printf '%s\n' "$ws" | grep -n '^tier_apt_min$' | cut -d: -f1)"
ws_dock="$(printf '%s\n' "$ws" | grep -n '^tier_docker$' | cut -d: -f1)"
[ "$ws_min" -lt "$ws_dock" ] \
  && pass "workstation runs apt_min BEFORE docker (curl + ca-certificates)" \
  || die "tier_docker must run after tier_apt_min — it needs curl and ca-certificates"
# Packages only — the tier must never take a VT from the login prompt. That is the
# deliberate `statusboard.sh --install` / `statusboard-gui.sh --install`.
body="$(awk '/^tier_statusboard\(\)/,/^}/' "$TIERS")"
hasnt "$body" 'systemctl'   "tier_statusboard touches no units"
hasnt "$body" 'profile.d'   "tier_statusboard writes no profile hook"
has   "$body" 'cage'        "tier_statusboard installs the kiosk compositor"
has   "$body" 'foot'        "tier_statusboard installs the terminal emulator"
has   "$body" 'btop'        "tier_statusboard installs btop"
# polkitd is the escape hatch, not a nicety: cage's VT switch goes through logind's
# polkit-gated Seat.SwitchTo, and with no polkit installed Ctrl-Alt-Fn is denied and
# the kiosk traps the box's only console behind the network.
has   "$body" 'polkitd'     "tier_statusboard installs polkitd (VT-switch escape hatch)"
has   "$body" 'fonts-jetbrains-mono' "tier_statusboard installs the chart font"
has   "$body" 'PRIV'        "tier_statusboard honours the no-root warn-and-skip contract"
# smartmontools is the ONLY route to a temperature on a USB-attached drive: the
# kernel's drivetemp hwmon covers native SATA and nothing behind a USB-SATA bridge
# gets a hwmon node. Without it the disk block's temperature column is dashes.
has   "$body" 'smartmontools' "tier_statusboard installs smartmontools (USB drive temperatures)"

# battery_limit's reason for existing is the mode write: the retired NixOS module
# set the threshold alone and the EC ignored it.
#
# It is on BOTH posix profiles since 2026-09-08, and the rule is MAINS, not
# profile: latitude (server) and g15 (workstation) both live on AC, so both cap
# the cell. `air` is excluded by being darwin — macos.sh has its own list — and
# NOT by its profile, which is why the `mac` assertion below is the one that
# actually protects the carried laptop. Flip these two and you have said
# something about hardware you did not mean.
has   "$srv" '^tier_battery_limit$'      "server installs the battery charge limit"
has   "$ws"  '^tier_battery_limit$'      "workstation installs it too (g15 is mains-bound)"
hasnt "$hub" '^tier_battery_limit$'      "hub omits the battery charge limit"
hasnt "$mac" '^tier_battery_limit$'      "macOS omits it — air is carried"
# Body extraction runs to the NEXT tier definition, not to the first column-0 `}`.
# The range form the other four still use silently truncates a tier that defines a
# nested shell function, which tier_battery_limit's emitted script now does
# (charge_mode): five unrelated assertions in this block went red at once and none
# of them was about a regression. If another tier grows a nested function, give it
# this form too — do NOT indent the function's brace to placate the awk.
# …then trimmed back to the LAST column-0 `}` in that span, which is the tier's
# own closing brace. Without the trim the span runs on into the next tier's
# leading comment block, and an assertion here could pass on text that belongs to
# a different tier — a false green, which is worse than the truncation it fixes.
bbody="$(awk '/^tier_battery_limit\(\)/{f=1} f&&/^tier_[a-z_]+\(\) *\{/&&!/^tier_battery_limit/{exit} f' "$TIERS" \
  | awk '{a[NR]=$0} /^}$/{last=NR} END{for(i=1;i<=last;i++) print a[i]}')"
has "$bbody" 'charge_types'  "tier_battery_limit writes charge_types, not just the threshold"
has "$bbody" 'Custom'        "tier_battery_limit selects the EC's Custom charge mode"
has "$bbody" 'charge_control_end_threshold' "tier_battery_limit writes the ceiling"
has "$bbody" 'charge_control_start_threshold' "tier_battery_limit makes room below the ceiling"
# The floor is the other half of the setting: a low one makes an always-plugged
# cell cycle down and back instead of holding steady.
has "$bbody" 'CHARGE_START' "tier_battery_limit exposes the charge floor as a knob"
has "$bbody" 'DEFAULT_START=80' "tier_battery_limit defaults the floor just under the ceiling"
# Floor to its minimum before the ceiling write, real floor after: the EC wants
# start below end, so writing them in a fixed order only works if the floor is out
# of the way first.
eq "$(printf '%s\n' "$bbody" | grep -c "> \"\$b/charge_control_start_threshold\"")" '2' \
  "tier_battery_limit writes the floor twice — out of the way, then for real"
# The EC clamps inside a successful write, so a silent difference between what was
# asked and what landed is the failure mode worth naming.
has "$bbody" 'the EC applied' "tier_battery_limit reports a ceiling the EC clamped"

# ── the report line must survive hardware that exposes only the ceiling ───────
# g513ie (ASUS asus-wmi) has charge_control_end_threshold and nothing else: no
# start threshold, no charge_types. Measured 2026-09-08, after the cap went on.
# The mode column read charge_types inline and was wrong twice — the shell's own
# redirection error leaked past `2>/dev/null` (a redirection is processed before
# the command's stderr redirect applies), and `|| echo n/a` never fired because
# `||` binds to the last command of the pipeline, which succeeds on empty input.
# Result: an error line in the journal on every boot and resume of a unit that
# exits 0, plus an empty mode column instead of the n/a it meant to print.
has "$bbody" 'charge_mode' "tier_battery_limit reads charge_types through a guarded helper"
# Two ways this assertion was wrong before it worked, both worth naming because
# `hasnt` invites them: written as `< "$b/charge_types"` the `$` is a regex
# end-of-line anchor, so it could never fire (a mutation putting the inline
# redirect straight back passed clean); and over the raw body it fires on the
# helper's own comment, which quotes the bad form to explain it. Anchored, and
# over code only.
hasnt "$(code "$bbody")" '< "\$b/charge_types"' \
  "tier_battery_limit never redirects from charge_types inline (the shell leaks that error)"
mbody="$(printf '%s\n' "$bbody" | awk '/^charge_mode\(\)/,/^}/')"
has "$mbody" '\-r "\$1/charge_types"' "charge_mode tests readability before reading"
has "$mbody" 'n/a' "charge_mode falls back to n/a"
eq "$(printf '%s\n' "$mbody" | grep -c 'n/a')" '2' \
   "charge_mode's n/a is reachable on BOTH arms — absent file and empty file"

# The emitted script is #!/bin/sh, so the helper must be POSIX: no `local`, and
# it has to parse under dash, which is what /bin/sh is on Debian and Ubuntu.
hasnt "$mbody" 'local ' "charge_mode uses no bashism (the emitted script is #!/bin/sh)"

has "$bbody" 'PRIV'          "tier_battery_limit honours the no-root warn-and-skip contract"
# The no-battery path must report and return 0, never fail a provision run on a
# desktop or a VPS.
has "$bbody" 'skipping the charge limit' "tier_battery_limit skips hardware with no threshold"
has "$bbody" 'suspend.target'  "tier_battery_limit re-applies on resume, not only at boot"
# /etc/default is the human's knob; a re-provision must not clobber a hand-set
# CHARGE_UPTO.
has "$bbody" '\[ ! -f /etc/default/charge-upto \]' \
  "tier_battery_limit writes /etc/default/charge-upto only when absent"
# The mode has to be written AFTER the ceiling it governs, or the EC applies
# Custom against the OLD threshold and the new one only takes effect next boot.
end_ln="$(printf '%s\n' "$bbody" | grep -n "> \"\$b/charge_control_end_threshold\"" | head -1 | cut -d: -f1)"
mode_ln="$(printf '%s\n' "$bbody" | grep -n "> \"\$b/charge_types\"" | head -1 | cut -d: -f1)"
if [ -n "$end_ln" ] && [ -n "$mode_ln" ] && [ "$end_ln" -lt "$mode_ln" ]; then
  pass "tier_battery_limit writes the ceiling before switching the EC to Custom"
else
  die "tier_battery_limit writes the ceiling before switching the EC to Custom (end=$end_ln mode=$mode_ln)"
fi

# ── lid_ignore: a mains-bound laptop must not suspend when its lid shuts ─────
# Same axis as battery_limit — mains, not profile — so the same four assertions,
# and the `mac` one is again the load-bearing half: macOS has no logind at all,
# so a lid policy there would be different code, not this tier in a second list.
has   "$srv" '^tier_lid_ignore$'  "server ignores the lid switch (it drops immich otherwise)"
has   "$ws"  '^tier_lid_ignore$'  "workstation ignores it too (g15 is mains-bound)"
hasnt "$hub" '^tier_lid_ignore$'  "hub omits it — a VPS has no lid"
hasnt "$mac" '^tier_lid_ignore$'  "macOS omits it — no logind, and air is carried"

lbody="$(awk '/^tier_lid_ignore\(\)/,/^}/' "$TIERS")"
has "$lbody" 'HandleLidSwitch=ignore' "tier_lid_ignore ignores a lid close on battery"
has "$lbody" 'HandleLidSwitchExternalPower=ignore' \
  "tier_lid_ignore ignores a lid close on AC — the case that actually applies here"
# THE DECISION, not a detail: latitude masks sleep/suspend/hibernate.target by
# hand because a services host must never sleep at all. This tier must NOT, or a
# box someone sits at loses the GNOME suspend menu and `systemctl suspend` too.
# Over code only — the tier's own comment explains the masking it declines to do.
hasnt "$(code "$lbody")" 'systemctl mask' \
  "tier_lid_ignore masks no sleep target — a deliberate suspend stays available"
hasnt "$(code "$lbody")" 'restart systemd-logind' \
  "tier_lid_ignore reloads logind, never restarts it (a restart can take the session)"
has "$lbody" 'reload systemd-logind' "tier_lid_ignore applies the policy without a reboot"
# The gate is the hardware, so a lidless box (WSL distro, VPS) is a no-op rather
# than a platform check that has to be kept in sync with the fleet.
has "$lbody" '/proc/acpi/button/lid' "tier_lid_ignore gates on the lid device itself"
has "$lbody" 'PRIV'  "tier_lid_ignore honours the no-root warn-and-skip contract"

# rapl_read is server-only, and it is the one tier here that widens a permission the
# kernel deliberately tightened — so the guards on HOW MUCH it widens are the point
# of these assertions, not decoration.
has   "$srv" '^tier_rapl_read$'      "server installs the RAPL read permission"
hasnt "$ws"  '^tier_rapl_read$'      "workstation omits the RAPL read permission"
hasnt "$hub" '^tier_rapl_read$'      "hub omits the RAPL read permission"
hasnt "$mac" '^tier_rapl_read$'      "macOS omits the RAPL read permission"
# TWO slices, because the negative assertions below would otherwise be satisfied by
# the comment that EXPLAINS what the tier refuses to do. rbody spans the section
# header (where the reasoning lives); rcode is the executable part alone, and is what
# "never writes 0444" has to be asserted against.
rbody="$(awk '/^# ── SERVER: let the status board read/,/^}/' "$TIERS")"
rcode="$(awk '/^tier_rapl_read\(\)/,/^}/' "$TIERS")"
# Group-scoped, never world-readable: 0444 would hand the PLATYPUS side channel to
# every uid on the box, including ones with no route to root. The zero-new-capability
# argument in the tier's comment is only true of the group form.
has   "$rcode" '0440'   "tier_rapl_read grants group read, not world read"
has   "$rcode" 'chgrp'  "tier_rapl_read scopes the widened attribute to a group"
hasnt "$rcode" '0444'   "tier_rapl_read never makes the energy counter world-readable"
hasnt "$rcode" '0644'   "tier_rapl_read never makes the energy counter writable"
# Parent domains only. intel-rapl:0:0 (core) and intel-rapl:0:1 (uncore) match the
# same glob and the board never reads them, so they stay at 0400.
has   "$rcode" '\*:\*:\*' "tier_rapl_read skips the RAPL subdomains"
# sysfs modes are properties of a live kernel object: a reboot or an intel_rapl_msr
# reload resets them, so a one-time chmod would silently stop working.
has   "$rcode" 'suspend.target' "tier_rapl_read re-applies on resume, not only at boot"
has   "$rcode" 'PRIV'   "tier_rapl_read honours the no-root warn-and-skip contract"
has   "$rcode" 'skipping the power-draw reader' \
  "tier_rapl_read skips hardware with no RAPL domain"
# The security decision has to be readable where it is made, not only in a commit
# message — this tier is the one a future reader will question.
has   "$rbody" 'PLATYPUS' "tier_rapl_read names the side channel it is widening"

# ORDER GUARD: the dotfiles bare-repo checkout is REFUSED when an untracked file
# already sits at a tracked path, so tier_dotfiles must stay last — after
# ssh_accounts, which generates the key its private-repo clone needs.
eq "$(printf '%s\n' "$srv" | grep -c '^tier_dotfiles$')" "1" "server runs tier_dotfiles once"
eq "$(printf '%s\n' "$srv" | grep '^tier_' | tail -1)" "tier_dotfiles" "server runs tier_dotfiles LAST"
srv_accounts="$(printf '%s\n' "$srv" | grep -n '^tier_ssh_accounts$' | cut -d: -f1)"
srv_dotfiles="$(printf '%s\n' "$srv" | grep -n '^tier_dotfiles$' | cut -d: -f1)"
[ "$srv_accounts" -lt "$srv_dotfiles" ] \
  && pass "server runs ssh_accounts BEFORE dotfiles (the clone needs a key)" \
  || die "server must run ssh_accounts before dotfiles"

# Resolution precedence 2 and 3: no env override, so the driver must read
# fleet.json by OS hostname, and fall back to workstation for an unknown box.
# Stub `hostname` on PATH (keep the real binaries the driver needs).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
stub_host() { printf '#!/bin/sh\necho %s\n' "$1" > "$tmp/bin/hostname"; chmod +x "$tmp/bin/hostname"; }
plan_host() { stub_host "$1"; MACHINES_TIERS_DRY_RUN=1 PATH="$tmp/bin:$PATH" bash "$DRIVER" 2>&1; }

has "$(plan_host 27608)" 'profile: hub \(from fleet.json\)' "hostname 27608 resolves to hub via fleet.json"
has "$(plan_host wsl-scratch)" 'profile: workstation \(default\)' "unknown hostname defaults to workstation"
# latitude keeps OS hostname latitude5520 across the NixOS→Debian reinstall
# PRECISELY so this resolves; a renamed box would fall through to workstation and
# silently install the dev layer it no longer wants.
has "$(plan_host latitude5520)" 'profile: server \(from fleet.json\)' "hostname latitude5520 resolves to server via fleet.json"

# Library sources inert.
out="$(TIERS_LIB_ONLY=1 bash -c 'source "$1"; declare -F tier_apt_min >/dev/null && echo LOADED' _ "$TIERS")"
eq "$out" "LOADED" "TIERS_LIB_ONLY sources without side effects"

# The generated fleet-selfpull unit MUST carry KillMode=process: the pull fires
# post-merge, which backgrounds converge.sh inside this unit's cgroup, and the
# default control-group kill reaps it ~3s later when the oneshot finishes —
# Trigger B then pulls forever and never applies anything.
grep -q 'KillMode=process' "$TIERS" \
  && pass "fleet-selfpull unit sets KillMode=process" \
  || die "fleet-selfpull unit sets KillMode=process"

# ── provision/macos.sh — the darwin tier driver ───────────────────────────────
# The dry-run path is deliberately BEFORE the Darwin precondition in both
# drivers, so the tier list is inspectable from this NixOS box. That is what
# makes these assertions possible at all; if someone moves the precondition
# above the dry-run exit, every case below starts failing with "targets macOS".
eq "$(printf '%s\n' "$mac" | grep '^tier_' | tr '\n' ' ')" \
   "tier_brew_min tier_brew_dev tier_brew_cask tier_agents_config tier_git_base tier_gortex tier_agent_clis claude tier_shell_init tier_autofetch tier_ssh_accounts tier_fleet_ssh tier_selfpull tier_ssh_trust tier_dotfiles_sync " \
   "macos workstation tier list and order"

# ── The sync TIMER must be reachable from the DRIVER, on every box ───────────
# Review item 8. Convergence runs the driver (linux.sh / macos.sh); it never runs
# provision.sh's role dispatcher. On linux workstation/server that is harmless:
# their lists end in tier_dotfiles, which calls role_dotfiles, which calls
# tier_dotfiles_sync — so the timer is re-asserted every converge. macOS and hub
# had NEITHER, so their timer was installed once by a hand-run role and never
# maintained again; air's LaunchAgent went untouched across three reprovisions.
#
# The fix is tier_dotfiles_SYNC, not tier_dotfiles, and the distinction is the
# whole point. tier_dotfiles performs the bare-repo CHECKOUT — enrolling the box
# — and the 2026-07-28 spec deliberately keeps that behind the dispatcher's
# `Apply dotfiles? [y/N]` gate on every fleet.json member (see the strip_pkg note
# below, which is why macos.sh has no tier_dotfiles). tier_dotfiles_sync only
# writes a scheduler unit pointing at an absolute script path: idempotent, no
# checkout, nothing to consent to. So the timer converges without the enrollment
# gate being pre-empted.
# tier_dotfiles passed a LITERAL `wsl` as role_dotfiles' platform argument. It
# was harmless only by luck: the role uses that argument once, as a gate
# (`nixos|wsl|debian|darwin`), and every box reaching the tier happened to be
# inside the accepted set. It was still a lie in the one place a reader checks
# what platform the code thinks it is on — and the tier is NOT WSL-only despite
# its comment: linux.sh's workstation and server lists both end in tier_dotfiles,
# so latitude (debian) reached it with `wsl` on every converge.
dbody="$(awk '/^tier_dotfiles\(\)/,/^}/' "$TIERS")"
hasnt "$dbody" 'role_dotfiles apply wsl' "tier_dotfiles no longer hardcodes the platform as wsl"
has   "$dbody" '_is_darwin'               "tier_dotfiles resolves darwin"
has   "$dbody" 'WSL_DISTRO_NAME'          "tier_dotfiles resolves a WSL distro"

has   "$mac" '^tier_dotfiles_sync$' "macos converges the dotfiles sync timer"
has   "$hub" '^tier_dotfiles_sync$' "hub converges the dotfiles sync timer"
# The linux workstation/server lists must NOT gain it: they reach it through
# tier_dotfiles already, and a second call would reinstall the unit twice per run.
hasnt "$ws"  '^tier_dotfiles_sync$' "workstation reaches the sync timer via tier_dotfiles, not directly"
hasnt "$srv" '^tier_dotfiles_sync$' "server reaches the sync timer via tier_dotfiles, not directly"
# And the enrollment tier stays off the boxes whose gate it would pre-empt.
hasnt "$mac" '^tier_dotfiles$'      "macos still never enrolls at tier time"
hasnt "$hub" '^tier_dotfiles$'      "hub still never enrolls at tier time"

# tier_fleet_ssh is darwin-only ON PURPOSE. NixOS gets its fleet client config
# from modules/home/ssh.nix and a WSL distro from provision/ssh-wsl.sh; only
# macOS has neither. Adding it to the linux list would fight ssh-wsl.sh over the
# same marked span in ~/.ssh/config.
hasnt "$ws" '^tier_fleet_ssh$' "linux does not run tier_fleet_ssh"
has   "$mac" '^tier_fleet_ssh$' "macos runs tier_fleet_ssh"

# Both tiers write ~/.ssh/config, each inside its OWN marker pair, and each
# preserves everything outside its markers — so the two blocks coexist and the
# order is not load-bearing for correctness. Pinned anyway: the guarantee that
# matters is that BOTH markers survive a full run, and a future edit that made
# either tier rewrite the file wholesale would silently drop the other's block.
# The distinct marker strings are what makes coexistence work — assert they
# differ, which is the actual invariant.
_m_accounts='# >>> machines-bootstrap ssh accounts >>>'
_m_fleet='# >>> fleet-ssh (managed by ssh-wsl.sh) >>>'
[ "$_m_accounts" != "$_m_fleet" ] \
  && pass "ssh_accounts and fleet_ssh use distinct config markers" \
  || die "ssh_accounts and fleet_ssh share a marker — they would clobber each other"
grep -qF "$_m_accounts" "$TIERS" \
  && pass "ssh_accounts marker unchanged in tiers.sh" \
  || die "ssh_accounts marker changed — update this test and re-check coexistence"
grep -qF "CONFIG_MARKER_BEGIN=\"$_m_fleet\"" "$HERE/../ssh-wsl.sh" \
  && pass "fleet_ssh marker unchanged in ssh-wsl.sh" \
  || die "ssh-wsl.sh CONFIG_MARKER_BEGIN changed — tier_fleet_ssh reuses it"

# The apt/brew swap is the ONLY package-manager difference: darwin must never
# reach an apt tier, and linux must never reach a brew one.
hasnt "$mac" '^tier_apt_'  "macos never runs an apt tier"
hasnt "$ws"  '^tier_brew_' "linux never runs a brew tier"

# Beyond that swap the two lists must stay identical — that is the payoff of
# sharing tiers.sh. Compare with the package tiers stripped out; a drift here
# means a tier was added to one driver and forgotten in the other.
# tier_fleet_ssh is excluded too — darwin-only by design, justified above.
#
# tier_dotfiles is the second sanctioned exception (spec 2026-07-28): linux-only
# ON PURPOSE. It exists solely for SELF-DECLARED WSL hosts, which carry a
# fleet.local.json instead of a fleet.json entry and therefore never reach a role
# executor at all — the tier list is their only path in. Every macOS fleet member
# IS in fleet.json and reaches role_dotfiles through the dispatcher, behind its
# `Apply dotfiles? [y/N]` gate. Adding it to macos.sh would enroll the box at
# tier time, which provision-mac.sh runs BEFORE roles — pre-empting that gate.
#
# tier_brew_cask is the third exception, and the least interesting one: Homebrew
# Cask ships macOS .app bundles, so there is no Linux counterpart to forget.
#
# tier_dotfiles_sync is the fourth, and it is the MIRROR of the second rather
# than a new idea: both drivers converge the sync timer, but they reach it by
# different routes. Linux gets there through tier_dotfiles (which macOS must not
# have, per the exception above); macOS therefore lists tier_dotfiles_sync
# directly. Same timer, same script, one entry each — so the two lists are still
# equivalent, just not textually equal. Asserted positively above.
#
# tier_docker is the fifth, and it is a package-manager exception like the first:
# the Linux engine is dockerd out of Docker's apt repo, and macOS has no dockerd
# to install at all — the engine there is Docker Desktop, a cask. Adding it to
# tier_brew_cask to keep the lists textually equal would change what installs on
# air, which is a different decision from this one.
#
# tier_battery_limit is the sixth, added 2026-09-08, and it is the one exception
# that is about the HARDWARE rather than the packaging. The cap is for a box that
# lives on mains: latitude and g15 do, so both posix profiles carry it; `air` is
# a laptop that gets carried, so macos.sh does not. Two things make this a real
# exception rather than the drift this assertion hunts for — the omission is the
# decision (owner, 2026-09-08), and the tier could not be shared anyway, since it
# writes `charge_control_*` and `charge_types` under /sys, which macOS has not
# got. A macOS charge cap would be different code, not this tier in a second
# list.
#
# tier_lid_ignore is the seventh, added 2026-09-08, and it is the second hardware
# exception — the same mains axis as battery_limit. It writes a systemd-logind
# drop-in, and macOS has no logind: the equivalent there is `pmset`/`caffeinate`,
# i.e. different code rather than this tier in a second list. `air` gets no lid
# policy on purpose anyway, being the laptop that is carried.
strip_pkg() { printf '%s\n' "$1" | grep '^tier_' | grep -vE '^tier_((apt|brew)_(min|dev)|brew_cask|fleet_ssh|dotfiles|dotfiles_sync|docker|battery_limit|lid_ignore)$' | tr '\n' ' '; }
eq "$(strip_pkg "$mac")" "$(strip_pkg "$ws")" \
   "macos and linux workstation lists match once the package tiers are removed"

# macos.sh has no hub arm — the hub is a Debian VPS. Asking for it must fail
# loudly, not silently provision a workstation.
macplan hub >/dev/null 2>&1 && die "macos hub profile should be rejected" \
  || pass "macos rejects the hub profile"

# tiers.sh must stay sourceable without running anything, from the darwin side
# too (the driver sources it only after its preconditions pass).
has "$(TIERS_LIB_ONLY=1 bash -c 'source "$1"; echo SOURCED-OK' _ "$TIERS" 2>&1)" \
    'SOURCED-OK' "tiers.sh sources cleanly with the darwin additions"

# The per-host-memory-stub guard is GONE ON PURPOSE (2026-07-28). It required a
# committed agents/hosts/<detect.hostname>.md for every fleet.json machine,
# because agents/bootstrap.sh used to SEED a missing one inside the repo — which
# left the tree dirty and permanently disabled fleet-selfpull's clean-tree gate on
# that box. bootstrap no longer seeds anything: per-host memory is a real file at
# ~/.claude/host-memory.md tracked on that machine's dotfiles branch, so there is
# no repo path to be missing and no way for a new host to dirty this tree.
#
# Do NOT reinstate this loop against agents/hosts/ — that directory no longer
# exists. The equivalent property now lives in agents/tests/bootstrap.test.sh
# Case 1, which asserts bootstrap seeds and links nothing for that path.

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
