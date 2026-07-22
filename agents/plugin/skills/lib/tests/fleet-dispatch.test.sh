#!/usr/bin/env bash
# Unit tests for fleet-dispatch.sh — mocks ssh on $SSH, asserts on the argv the
# mock receives and on stdin round-tripping. No real network.
set -u
exec </dev/null   # so a missing `</dev/null` in fd_probe would hang → visible fail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fleet-dispatch.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

source "$SCRIPT"

# Mock ssh: records the flattened remote command (last args) to $LOG, models a
# PowerShell/Windows box (bare `true` fails; a bash/`&`-wrapped command works),
# and for fd_run echoes back "<remote-cmd>||<stdin>" so we can assert both.
LOG="$(mktemp)"
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  printf '%s\t%s\n' "$alias" "$remote" >> "$LOG"
  # Probe branch: remote command contains `-c true` (both linux & windows probes).
  case "$remote" in
    *"-c true"*)
      # winbox models Windows: a probe that never invokes bash fails; a Git-Bash
      # (`&`/`bash.exe`) or `bash`-wrapped probe passes.
      case "$remote" in
        *bash.exe*|bash\ *) : ;;                 # bash reached → ok
        *) [ "$alias" = winbox ] && return 1 ;;  # winbox: no bash → unreachable
      esac
      return 0 ;;
  esac
  # Work branch: echo remote-cmd + whatever arrived on stdin.
  local in; in="$(cat)"
  printf '%s||%s\n' "$remote" "$in"
}
SSH="mock_ssh"

# fd_probe linux → uses `bash -c true`
: > "$LOG"; fd_probe latitude nixos && pass "probe linux ok" || die "probe linux failed"
grep -q $'latitude\tbash -c true' "$LOG" && pass "probe linux uses bash -c true" \
  || die "probe linux argv: $(cat "$LOG")"

# fd_probe windows → uses the Git Bash program path via `&`
: > "$LOG"; fd_probe desktop windows && pass "probe windows ok" || die "probe windows failed"
grep -q 'Git\\bin\\bash.exe" -c true' "$LOG" && pass "probe windows uses Git Bash" \
  || die "probe windows argv: $(cat "$LOG")"

# winbox: bare-true probe fails, bash-wrapped passes (regression guard).
fd_probe winbox windows && pass "winbox reachable via bash probe" || die "winbox probe should pass"

# fd_run linux → `bash -s` with args; stdin forwarded verbatim.
out="$(printf 'SCRIPT-BODY' | fd_run latitude nixos target-arg)"
[ "$out" = 'bash -s target-arg||SCRIPT-BODY' ] && pass "fd_run linux argv+stdin" \
  || die "fd_run linux -> '$out'"

# fd_run windows → Git Bash `-s -- <args>`; stdin forwarded verbatim.
out="$(printf 'SCRIPT-BODY' | fd_run desktop windows target-arg)"
case "$out" in
  *'Git\bin\bash.exe" -s -- "target-arg" }||SCRIPT-BODY') pass "fd_run windows argv+stdin" ;;
  *) die "fd_run windows -> '$out'" ;;
esac

# --- fd_wsl_hosts: mock `wsl.exe -l -q` + per-distro marker reads. ---
# Distro list: two distros. Ubuntu-26.04 opts in (fleet:true), Ubuntu-24.04 does not.
mock_ssh_wsl() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  case "$remote" in
    *"-l -q"*)
      # Model Windows UTF-16-ish noise: NULs + CR interspersed.
      printf 'U\000b\000u\000n\000t\000u\000-\0002\0006\000.\0000\0004\000\r\000\n'
      printf 'U\000b\000u\000n\000t\000u\000-\0002\0004\000.\0000\0004\000\r\000\n'
      ;;
    *Ubuntu-26.04*fleet.local.json*|*Ubuntu-26.04*)
      printf '{"self":{"nickname":"desktop-ubuntu26","fleet":true,"platform":"linux"}}' ;;
    *Ubuntu-24.04*)
      printf '{"self":{"nickname":"scratch","fleet":false,"platform":"linux"}}' ;;
  esac
}
SSH="mock_ssh_wsl"
got="$(fd_wsl_hosts desktop windows)"
[ "$got" = "desktop-ubuntu26" ] && pass "fd_wsl_hosts opt-in only" || die "fd_wsl_hosts -> '$got'"
# non-windows returns nothing
got="$(fd_wsl_hosts latitude nixos)"
[ -z "$got" ] && pass "fd_wsl_hosts skips non-windows" || die "fd_wsl_hosts non-windows -> '$got'"
SSH="mock_ssh"   # restore for any later cases

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
