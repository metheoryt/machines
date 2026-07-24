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

# box_class: nixos | windows | linux (NixOS wins; then uname).
box_class() {
  if [ -e /etc/NIXOS ]; then echo nixos; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
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

# touches_nix <low> <high>: 0 if any *.nix / flake.nix / flake.lock in range.
touches_nix() {
  changed_paths "$1" "$2" | grep -qE '(\.nix$|(^|/)flake\.(nix|lock)$)'
}

# touches_linux <low> <high>: 0 if any provisioning-relevant path changed in
# range — the linux provisioner itself or the inputs it acts on. A content-only
# pull (docs, memory, other-OS scripts) needs no reprovision; the agent config
# is relinked by the post-merge hook's job 1, so agents/** alone does NOT count.
touches_linux() {
  changed_paths "$1" "$2" | grep -qE '(^provision/linux\.sh$|^provision/fleet-selfpull\.sh$|^pkgs/gortex\.nix$|^agents/bootstrap\.sh$)'
}

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
      if [ -n "$low" ] && ! touches_nix "$low" "$high"; then
        write_status "$high" ok "nixos: no *.nix/flake change — config already live via symlinks"
        exit 0
      fi
      if nixos-rebuild switch --flake "$REPO#$(hostname)"; then
        write_status "$high" ok "nixos-rebuild switch"
      else
        write_status "$high" fail "nixos-rebuild switch failed (see journalctl -u machines-converge)"
      fi ;;
    windows)
      if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO/provision/windows.ps1"; then
        write_status "$high" ok "provision/windows.ps1"
      else
        write_status "$high" fail "provision/windows.ps1 failed"
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
