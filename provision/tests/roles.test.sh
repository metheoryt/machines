#!/usr/bin/env bash
# Unit tests for the posix role executors (provision/roles/*.sh).
#
# The one failure mode worth guarding: every executor ends its platform `case`
# with a `*)` arm that prints "no posix executor for platform '<p>'" and
# returns 0. A platform missing from the enumerated arms therefore provisions
# NOTHING and still reports success — silent, green, and wrong. These tests
# assert each role reaches a real arm for the platform it is named with —
# `darwin` (the Mac, `air`) for the roles air carries, `debian` for the two
# backup roles, which only latitude carries.
#
# Dry-run only: no writes, no network beyond what the dry-run bodies already do.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES="$HERE/../roles"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
# Assert the skip arm was NOT taken.
not_skipped() {
  local role="$1" out="$2"
  case "$out" in
    *"no posix executor for platform"*) die "$role: hit the skip arm — $out" ;;
    *) pass "$role: reaches a real executor" ;;
  esac
}

# Source EVERY executor, not a hand-listed set. The list was hardcoded and that
# is a false-green generator: a role file this test forgot leaves its function
# undefined, `role_backup_client …` emits "command not found" into `2>&1`, that
# string does not match the skip pattern, and `not_skipped` PASSES. Globbing
# means a new executor is covered the day it lands; `defined` below is what turns
# a missing one into a failure instead of a pass.
# shellcheck source=/dev/null
for f in "$ROLES"/*.sh; do source "$f"; done

defined() {
  declare -F "$1" >/dev/null && pass "$1 is defined after sourcing" \
    || die "$1 is NOT defined — provision.sh would fall through to PLANNED_ROLES"
}
# Assert the skip arm WAS taken, for the arms where skipping is the decision.
skipped() {
  local role="$1" out="$2"
  case "$out" in
    *"no posix executor for platform"*) pass "$role: hits the skip arm on purpose" ;;
    *) die "$role: expected the skip arm, got — $out" ;;
  esac
}

not_skipped "role_agents"   "$(role_agents   dry-run darwin air 2>&1)"
not_skipped "role_dotfiles" "$(role_dotfiles dry-run darwin air 2>&1)"
not_skipped "role_repos"    "$(role_repos    dry-run darwin air 2>&1)"

# Regression guard on the arms that already worked, so grouping darwin in does
# not accidentally move nixos/debian into the skip arm.
not_skipped "role_repos(nixos)"    "$(role_repos    dry-run nixos latitude 2>&1)"
not_skipped "role_dotfiles(debian)" "$(role_dotfiles dry-run debian hub 2>&1)"

# nixos DOES deliberately skip agents — home-manager owns the profile there.
# That is a real arm, not the fallthrough, and must keep saying so.
case "$(role_agents dry-run nixos latitude 2>&1)" in
  *"owned by home-manager"*) pass "role_agents: nixos still defers to home-manager" ;;
  *) die "role_agents: nixos arm changed" ;;
esac

# dotfiles is the OPPOSITE as of spec 2026-07-28: the bare-repo engine has no
# collision with home-manager (a path is shared XOR host-local, so home-manager
# -owned paths simply never sit on main), so nixos reaches a REAL arm now. The
# old "owned by home-manager on nixos" skip would silently leave latitude with
# no sync timer and no branch checked out.
not_skipped "role_dotfiles(nixos)" "$(role_dotfiles dry-run nixos latitude 2>&1)"
case "$(role_dotfiles dry-run nixos latitude 2>&1)" in
  *"owned by home-manager"*) die "role_dotfiles: nixos still defers to home-manager — spec 2026-07-28 retires that skip" ;;
  *) pass "role_dotfiles: nixos no longer defers to home-manager" ;;
esac


# ── The backup roles (landed 2026-09-01, deleted from PLANNED_ROLES in the same
#    change — see provision/tests/fleet-profile.test.sh for that half) ─────────

defined role_backup_client
defined role_backup_hub

# latitude is the machine that carries both. debian is its platform.
not_skipped "role_backup_client(debian)" "$(role_backup_client dry-run debian latitude 2>&1)"
not_skipped "role_backup_hub(debian)"    "$(role_backup_hub    dry-run debian latitude 2>&1)"

# A DECLARED-BUT-UNCONFIGURED CLIENT IS A SKIP THAT EXITS 0. `hub` carries
# backup-client with no backup/hub/ directory: the offsite copy is unbuilt. That
# must stay visible and must not turn --apply red — the opposite of a role with
# no executor at all, which exits 1 by design.
out="$(role_backup_client dry-run debian hub 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "role_backup_client: missing profile dir returns 0" \
  || die "role_backup_client: missing profile dir returned $rc"
case "$out" in
  *"no profile dir for hub (skipped)"*) pass "role_backup_client: names the machine it skipped" ;;
  *) die "role_backup_client: missing-dir message changed — $out" ;;
esac

# windows hits the fallthrough TODAY and the comment there says it is a known
# hole, not a decision: `desktop`'s client actually runs inside the WSL distro,
# which provision.sh dispatches no roles to. Pinned so that when Task 5 resolves
# it, this line has to be edited deliberately rather than silently drifting.
skipped "role_backup_client(windows)" "$(role_backup_client dry-run windows desktop 2>&1)"

# backup-hub's fallthrough IS a decision: a USB drive by UUID, a container and a
# port on one box do not generalise. Asserted as intended behaviour so nobody
# "fixes" it into a pretend-portable arm.
skipped "role_backup_hub(darwin)" "$(role_backup_hub dry-run darwin air 2>&1)"

# backup-client, by contrast, is portable in principle — the profile dir is the
# only host-specific part — so darwin must reach a real arm.
not_skipped "role_backup_client(darwin)" "$(role_backup_client dry-run darwin air 2>&1)"

# A DRY RUN MUST WRITE NOTHING, and `resticprofile schedule` has no dry-run of
# its own — it writes systemd units. So the preview can only print the command.
# Tripwire: shadow resticprofile/sudo/systemctl with shims that record being
# called, then assert the marker is absent. Reading the output for "would run"
# proves the message; only this proves the silence.
tw="$(mktemp -d)"; trap 'rm -rf "$tw"' EXIT
mkdir -p "$tw/bin"
for b in resticprofile sudo systemctl; do
  printf '#!/bin/sh\necho "%s $*" >> "$TRIPWIRE"\n' "$b" > "$tw/bin/$b"
  chmod +x "$tw/bin/$b"
done
TRIPWIRE="$tw/fired"
out="$(PATH="$tw/bin:$PATH" TRIPWIRE="$TRIPWIRE" role_backup_client dry-run debian latitude 2>&1)"
[ -e "$TRIPWIRE" ] && die "role_backup_client: dry-run EXECUTED $(cat "$TRIPWIRE")" \
  || pass "role_backup_client: dry-run runs nothing"
case "$out" in
  *"would run: bash "*install-tasks.sh) pass "role_backup_client: dry-run prints the command" ;;
  *) die "role_backup_client: dry-run did not print the command — $out" ;;
esac

# Same for the hub: its apply arm ASSERTS (mountpoint, container, port), none of
# which exist on the box this suite is usually run from. The dry run must
# therefore assert nothing and still exit 0.
out="$(PATH="$tw/bin:$PATH" TRIPWIRE="$TRIPWIRE" role_backup_hub dry-run debian latitude 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "role_backup_hub: dry-run exits 0 off-host" \
  || die "role_backup_hub: dry-run exits $rc off-host — it must not assert"
[ -e "$TRIPWIRE" ] && die "role_backup_hub: dry-run EXECUTED $(cat "$TRIPWIRE")" \
  || pass "role_backup_hub: dry-run runs nothing"

# THE SELFCHECK MUST REFUSE TO RUN AS NON-ROOT, exit 2. Its repo dir is
# drwx------ root:root, so as any other user checks 2 and 8 report MISSING /
# none-found on a healthy hub -- two confident FAILs that mean "I could not read
# this". Exit 2 keeps "could not check" distinct from the 1 a real failure gives.
# Skipped when the suite itself runs as root, since then the guard does not fire
# and the whole selfcheck would execute against a live hub.
sc="$HERE/../../hosts/latitude/debian/restic-hub-selfcheck.sh"
if [ "$(id -u)" -eq 0 ]; then
  pass "restic-hub-selfcheck root guard (skipped — suite is running as root)"
elif [ ! -f "$sc" ]; then
  die "restic-hub-selfcheck.sh missing — role_backup_hub would skip on latitude"
else
  out="$(bash "$sc" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] && pass "restic-hub-selfcheck: non-root exits 2, not 1" \
    || die "restic-hub-selfcheck: non-root exited $rc — a permission failure must not read as a check failure"
  case "$out" in
    *"must run as root"*) pass "restic-hub-selfcheck: names the reason" ;;
    *) die "restic-hub-selfcheck: non-root message changed — $out" ;;
  esac
fi

# Each profile dir must carry the install script the executor calls. The
# executor keys its SKIP on the directory but its ACTION on the script, so a dir
# with no script is a loud failure by design — this asserts the shipped dirs are
# not in that state.
for d in "$HERE"/../../backup/*/; do
  case "$d" in *_retired-*) continue ;; esac
  n="$(basename "$d")"
  [ -f "$d/install-tasks.sh" ] && pass "backup/$n ships install-tasks.sh" \
    || die "backup/$n has no install-tasks.sh — role_backup_client would fail on it"
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
