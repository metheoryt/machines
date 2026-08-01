#!/usr/bin/env sh
# scripts/converge.sh — apply the pulled `machines` state on THIS box after a
# ff-pull. Fired by the OS-tier trigger (non-nix: agents/git-hooks/post-merge;
# NixOS: machines-converge.path). Idempotent, privileged (root / SYSTEM),
# detached from the pull. Owns ALL os-routing policy + the self-gates.
#
# NEVER writes a tracked file — only .machines/ (gitignored) — or it would trip
# the clean-tree gate and disable future auto-pulls. See the design spec §2/§5.
#
# Testable: `CONVERGE_LIB_ONLY=1 . converge.sh` loads the helpers without running.
set -u

# ${BASH_SOURCE:-$0}: plain `sh` execution has no BASH_SOURCE, so this is just
# $0 there; under bash `source` (as converge.test.sh does, to load the copy it
# put in a throwaway repo) $0 stays the *sourcing* script, but BASH_SOURCE[0]
# is the sourced file — this is what lets REPO resolve to the right checkout
# in both modes.
REPO="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")/.." && pwd)" || exit 0   # scripts/ -> repo root
[ -n "$REPO" ] || exit 0
STATE="$REPO/.machines"
CONVERGED_REV="$STATE/converged-rev"
STATUS_FILE="$STATE/last-converge"

log() { printf 'converge: %s\n' "$*"; }

# box_class: nixos | windows | darwin | linux (NixOS wins; then uname).
#
# Darwin got its own arm on 2026-08-01. It used to fall through the catch-all to
# `linux`, so every convergence on the Mac ran provision/linux.sh — an apt-based
# driver that aborts on Darwin at its first precondition. air pulled cleanly and
# then failed to apply the pull, every time, since it joined the fleet: the box
# looked enrolled (fleet.json member, self-pull running, git up to date) while
# nothing the repo shipped ever took effect on it. A catch-all that maps an
# unrecognized OS onto a specific provisioner cannot fail safe — it fails loud on
# a good day and silently wrong on a bad one.
#
# NIXOS_MARKER is a test seam (mirrors CONVERGE_LIB_ONLY): the probe is a real
# path, so converge.test.sh cannot exercise the uname arms on a NixOS box without
# it.
NIXOS_MARKER="${NIXOS_MARKER:-/etc/NIXOS}"
box_class() {
  if [ -e "$NIXOS_MARKER" ]; then echo nixos; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    Darwin) echo darwin ;;
    *) echo linux ;;
  esac
}

# on_main_primary: succeed iff primary worktree (git-dir == common-dir) AND main.
on_main_primary() {
  [ "$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" \
    = "$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" ] || return 1
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || return 1
}

# range_low: last successfully-converged rev, or empty (first run = whole tree).
range_low() { [ -f "$CONVERGED_REV" ] && cat "$CONVERGED_REV" || true; }

# changed_paths <low> <high>: changed tracked paths; all tracked when low empty.
changed_paths() {
  if [ -n "$1" ]; then
    git -C "$REPO" diff --name-only "$1" "$2" 2>/dev/null
  else
    git -C "$REPO" ls-files 2>/dev/null
  fi
}

# touches_nix is GONE (2026-08-01), with the NixOS tree it gated. Its regex is
# preserved in the `nixos-final` tag if a Nix host is ever reintroduced.
#
# It took a live bug with it, so read this before trusting the gate below.
# touches_nix was the ONLY place `fleet.json` counted as a reprovision trigger,
# on the reasoning that it is a Nix input (fleet.nix read it with fromJSON,
# ssh.nix rendered every ~/.ssh/config host block from it). But fleet.json is
# just as much an input to the POSIX provisioner — tier_fleet_ssh renders the
# same host blocks from the same file — and `_touches_driver` never listed it.
# So while NixOS existed the trigger worked on exactly one box, and the day
# latitude became Debian it worked on none: adding a fleet member changed
# fleet.json, matched nothing, wrote ok, advanced converged-rev, and the new
# member never appeared in any box's ~/.ssh/config. A permanent silent skip —
# the precise failure the original comment was written to prevent, relocated
# rather than fixed. fleet.json is now in the driver gate where it belongs.

# touches_linux <low> <high>: 0 if any provisioning-relevant path changed in
# range — the linux provisioner itself or the inputs it acts on. A content-only
# pull (docs, memory, other-OS scripts) needs no reprovision; the agent config
# is relinked by the post-merge hook's job 1, so agents/** alone does NOT count.
# provision/linux.sh is only the DRIVER: the tier bodies live in
# provision/lib/tiers.sh and the profile resolution in provision/lib/fleet.sh, so
# both count too — otherwise a tiers-only pull matches nothing, converge writes
# ok, advances converged-rev, and the change is never applied on any linux box.
# provision/fleet-authorized-keys counts as well: tier_fleet_ssh merges it into
# ~/.ssh/authorized_keys, so a key-only pull must reprovision or the box never
# accepts the newly-enrolled member.
# touches_macos is the same gate for the Darwin driver, and the shared inputs are
# genuinely shared: provision/macos.sh runs the SAME tier bodies out of
# provision/lib/tiers.sh with the same profile resolution, self-pull, fleet trust,
# pinned gortex and agent bootstrap. Only the driver path differs, so the two
# gates are one function with the driver injected — a duplicated regex here would
# drift the moment a new shared input is added to one and not the other.
# fleet.json and provision/gortex.version are both here deliberately: the first
# because tier_fleet_ssh renders ~/.ssh/config from it (see the touches_nix note
# above for the bug that taught us), the second because tier_gortex installs the
# version it pins and a bump that never reprovisions never lands.
_touches_driver() {
  changed_paths "$2" "$3" | grep -qE "^($1|fleet\.json|provision/lib/tiers\.sh|provision/lib/fleet\.sh|provision/fleet-selfpull\.sh|provision/fleet-authorized-keys|provision/gortex\.version|agents/bootstrap\.sh)\$"
}
touches_linux() { _touches_driver 'provision/linux\.sh' "$1" "$2"; }
touches_macos() { _touches_driver 'provision/macos\.sh' "$1" "$2"; }

# write_status <rev> <ok|fail> <reason>: record outcome; advance converged-rev
# only on ok (a failure retries the same range on the next fire).
write_status() {
  mkdir -p "$STATE"
  printf 'rev=%s\nstatus=%s\ntimestamp=%s\nreason=%s\n' \
    "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" > "$STATUS_FILE"
  [ "$2" = ok ] && printf '%s\n' "$1" > "$CONVERGED_REV"
  return 0
}

# ensure_git_safe: git refuses to operate on a repo owned by another user
# ("dubious ownership") — exactly the case here, where this privileged converge
# (root / SYSTEM) runs against the user-owned checkout. Left unhandled, every git
# query below fails and converge silently skips (on_main_primary sees an empty
# branch != main). Mark the repo safe in the converging user's GLOBAL git config
# BEFORE the first git call; --replace-all keeps it idempotent (no duplicate
# accumulation across runs). This mirrors machines-converge.nix's ExecStartPre
# for the non-NixOS (Windows / bare-Linux) triggers, which have no such pre-hook.
# On Windows, git compares against the mixed drive-letter path (C:/Users/…), not
# the MSYS /c/… form $REPO carries, so translate via cygpath -m when present.
ensure_git_safe() {
  safe="$REPO"
  command -v cygpath >/dev/null 2>&1 && safe="$(cygpath -m "$REPO" 2>/dev/null || echo "$REPO")"
  git config --global --replace-all safe.directory "$safe" 2>/dev/null || true
}

converge_main() {
  ensure_git_safe
  on_main_primary || { log "skip: not primary-worktree-on-main"; exit 0; }
  low="$(range_low)"
  high="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" || { log "no HEAD"; exit 0; }
  class="$(box_class)"
  log "class=$class range=${low:-<first>}..$high"
  cd "$REPO" || { log "cannot cd $REPO"; exit 0; }
  case "$class" in
    nixos)
      # The flake this used to run was deleted 2026-08-01 (tag nixos-final); no
      # Nix host remains. The class is still DETECTED rather than folded into
      # `linux` on purpose: a NixOS box classed `linux` would run
      # provision/linux.sh, an apt driver that aborts on its first precondition,
      # which is the fail-loud-on-a-good-day / silently-wrong-on-a-bad-one trap
      # the darwin arm above was added to close. So refuse, explicitly, and
      # record it as a FAILURE — converged-rev must not advance past a pull this
      # box never applied.
      write_status "$high" fail "nixos: no flake in this repo since 2026-08-01 (tag nixos-final) — reprovision this box or restore the tree"
      ;;
    windows)
      if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO/provision/windows.ps1"; then
        write_status "$high" ok "provision/windows.ps1"
      else
        write_status "$high" fail "provision/windows.ps1 failed"
      fi ;;
    darwin)
      if [ -n "$low" ] && ! touches_macos "$low" "$high"; then
        write_status "$high" ok "darwin: no provisioning-relevant change — agent config already relinked by post-merge hook"
        exit 0
      fi
      # macos.sh is idempotent and needs no root (Homebrew refuses sudo and owns
      # its own prefix), so it is safe unattended. Its one interactive tier,
      # tier_brew_cask, degrades rather than hangs: an already-installed cask is a
      # no-op, and a missing one fails its sudo against the hook's </dev/null and
      # warns. A warning does not fail the driver, so it cannot wedge convergence.
      if bash "$REPO/provision/macos.sh"; then
        write_status "$high" ok "provision/macos.sh"
      else
        write_status "$high" fail "provision/macos.sh failed"
      fi ;;
    linux)
      if [ -n "$low" ] && ! touches_linux "$low" "$high"; then
        write_status "$high" ok "linux: no provisioning-relevant change — agent config already relinked by post-merge hook"
        exit 0
      fi
      if bash "$REPO/provision/linux.sh"; then
        write_status "$high" ok "provision/linux.sh"
      else
        write_status "$high" fail "provision/linux.sh failed"
      fi ;;
    *) log "unknown box class"; exit 0 ;;
  esac
}

[ -n "${CONVERGE_LIB_ONLY:-}" ] || converge_main
