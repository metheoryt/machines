#!/usr/bin/env bash
# Unit tests for the posix role executors (provision/roles/*.sh).
#
# The one failure mode worth guarding: every executor ends its platform `case`
# with a `*)` arm that prints "no posix executor for platform '<p>'" and
# returns 0. A platform missing from the enumerated arms therefore provisions
# NOTHING and still reports success — silent, green, and wrong. These tests
# assert each role reaches a real arm for `darwin` (the Mac, `air`).
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
    *"no posix executor for platform"*) die "$role: darwin hit the skip arm — $out" ;;
    *) pass "$role: darwin reaches a real executor" ;;
  esac
}

# shellcheck source=/dev/null
for f in "$ROLES"/agents.sh "$ROLES"/dotfiles.sh "$ROLES"/repos.sh; do source "$f"; done

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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
