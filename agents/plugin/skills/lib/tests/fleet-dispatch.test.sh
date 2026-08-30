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

# Pin local-parent detection OFF for every case below. This suite runs on real
# WSL boxes, where fd_local_parent would otherwise read fleet.local.json, decide
# "desktop is my parent", take the interop branch and write nothing to $LOG —
# failing the ssh-argv assertions for reasons that have nothing to do with them.
# Empty-but-set is the documented off switch; unset would re-enable detection.
FLEET_LOCAL_PARENT=""

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
[ "$out" = 'bash -s -- target-arg||SCRIPT-BODY' ] && pass "fd_run linux argv+stdin" \
  || die "fd_run linux -> '$out'"

# fd_run windows → Git Bash `-s -- <args>`; stdin forwarded verbatim.
out="$(printf 'SCRIPT-BODY' | fd_run desktop windows target-arg)"
case "$out" in
  *'Git\bin\bash.exe" -s -- "target-arg" }||SCRIPT-BODY') pass "fd_run windows argv+stdin" ;;
  *) die "fd_run windows -> '$out'" ;;
esac

# darwin is a POSIX-SSH member: it must take the SAME arm as nixos/debian, never
# the Windows Git-Bash-through-PowerShell path. A `bash.exe` here would mean the
# Mac was misclassified as a Windows box and every dispatch to it would fail.
: > "$LOG"; fd_probe air darwin && pass "probe darwin ok" || die "probe darwin failed"
grep -q $'air\tbash -c true' "$LOG" && pass "probe darwin uses bash -c true" \
  || die "probe darwin argv: $(cat "$LOG")"
grep -q 'bash.exe' "$LOG" && die "probe darwin must not use the Git Bash path" \
  || pass "probe darwin avoids the Git Bash path"

out="$(printf 'SCRIPT-BODY' | fd_run air darwin target-arg)"
[ "$out" = 'bash -s -- target-arg||SCRIPT-BODY' ] && pass "fd_run darwin argv+stdin" \
  || die "fd_run darwin -> '$out'"

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
[ "$got" = $'desktop-ubuntu26\tdesktop-ubuntu26.gg.ez\tlinux' ] && pass "fd_wsl_hosts opt-in only" || die "fd_wsl_hosts -> '$got'"
# non-windows returns nothing
got="$(fd_wsl_hosts latitude nixos)"
[ -z "$got" ] && pass "fd_wsl_hosts skips non-windows" || die "fd_wsl_hosts non-windows -> '$got'"
got="$(fd_wsl_hosts air darwin)"
[ -z "$got" ] && pass "fd_wsl_hosts skips darwin" || die "fd_wsl_hosts darwin -> '$got'"
SSH="mock_ssh"   # restore for any later cases

# ── parent-routed WSL dispatch (spec 2026-08-01) ──────────────────────────────
# A distro with no tailnet node is reached as `wsl.exe -d <distro>` through its
# Windows parent. The mechanism is the one fd_wsl_hosts already uses to discover
# distros, verified end to end on 2026-08-01.
#
# nickname and distro name differ throughout these tests on purpose: fd_run
# feeds the DISTRO name into wsl.exe -d, and a fixture that reuses the same
# string for both cannot catch a nickname/distro-name mix-up.

: > "$LOG"
fd_probe 'desktop:Ubuntu-Pure' wsl && pass "probe wsl ok" || die "probe wsl failed"
grep -q $'desktop\twsl.exe -d "Ubuntu-Pure" -- bash -c true' "$LOG" \
  && pass 'probe wsl targets the parent with wsl.exe -d "<distro>"' \
  || die "probe wsl argv: $(cat "$LOG")"

# fd_run must pipe the script through and pass positional args after `--`.
out="$(printf 'echo hi\n' | fd_run 'desktop:Ubuntu-Pure' wsl ALPHA BETA)"
case "$out" in
  *'wsl.exe -d "Ubuntu-Pure" -- bash -s -- "ALPHA" "BETA"'*)
    pass 'run wsl builds wsl.exe -d "<distro>" … bash -s -- args' ;;
  *) die "run wsl remote cmd: $out" ;;
esac
case "$out" in
  *'||echo hi'*) pass "run wsl round-trips stdin" ;;
  *) die "run wsl stdin lost: $out" ;;
esac

# A distro name containing a space (Windows permits it, e.g. "Docker Desktop")
# must survive as ONE argument to wsl.exe -d — the property the double-quoting
# fix (2026-08-01) guards against regressing.
: > "$LOG"
fd_probe 'desktop:Docker Desktop' wsl && pass "probe wsl (spaced distro) ok" \
  || die "probe wsl (spaced distro) failed"
grep -q $'desktop\twsl.exe -d "Docker Desktop" -- bash -c true' "$LOG" \
  && pass "probe wsl keeps a spaced distro name as one argument" \
  || die "probe wsl (spaced distro) argv: $(cat "$LOG")"

out="$(printf 'echo hi\n' | fd_run 'desktop:Docker Desktop' wsl ALPHA)"
case "$out" in
  *'wsl.exe -d "Docker Desktop" -- bash -s -- "ALPHA"'*)
    pass "run wsl (spaced distro) keeps distro name as one argument" ;;
  *) die "run wsl (spaced distro) remote cmd: $out" ;;
esac

# ── fd_wsl_hosts emits nickname/target/platform ───────────────────────────────
# The parent-routed distro's nickname ("desktop-pure") and its actual WSL
# distro name ("Ubuntu-Pure") are deliberately DIFFERENT strings here: fd_run
# feeds the distro name into wsl.exe -d, and the two identifiers are set
# independently in reality, so a fixture that reuses one string for both can't
# catch a <alias>:<nickname> vs <alias>:<distro-name> mix-up.
mock_ssh_dispatch() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  case "$remote" in
    *'wsl.exe -l -q'*) printf 'desktop-wsl\nUbuntu-Pure\n' ;;
    *desktop-wsl*)  printf '{"self":{"nickname":"desktop-wsl","fleet":true,"platform":"linux","dispatch":"direct"}}\n' ;;
    *Ubuntu-Pure*) printf '{"self":{"nickname":"desktop-pure","fleet":true,"platform":"linux","dispatch":"parent"}}\n' ;;
  esac
}
SSH="mock_ssh_dispatch"
MAGICDNS_SUFFIX="gg.ez"

rows="$(fd_wsl_hosts desktop windows)"

echo "$rows" | grep -q $'^desktop-wsl\tdesktop-wsl.gg.ez\tlinux$' \
  && pass "direct distro → tailnet FQDN, platform linux" \
  || die "direct row wrong: $rows"

echo "$rows" | grep -q $'^desktop-pure\tdesktop:Ubuntu-Pure\twsl$' \
  && pass "parent distro → parent:DISTRO-name (not nickname), platform wsl" \
  || die "parent row wrong: $rows"

# The property that actually matters: the spaced-name fix must hold end to
# end, fd_wsl_hosts's target round-tripped through fd_run's wsl branch, not
# just in an isolated fd_probe/fd_run call.
mock_ssh_spaced() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  case "$remote" in
    *'wsl.exe -l -q'*) printf 'Docker Desktop\n' ;;
    *'fleet.local.json'*)
      printf '{"self":{"nickname":"desktop-docker","fleet":true,"platform":"linux","dispatch":"parent"}}\n' ;;
    *)
      local in; in="$(cat)"
      printf '%s||%s\n' "$remote" "$in" ;;
  esac
}
SSH="mock_ssh_spaced"
rows="$(fd_wsl_hosts desktop windows)"
echo "$rows" | grep -q $'^desktop-docker\tdesktop:Docker Desktop\twsl$' \
  && pass "fd_wsl_hosts: spaced distro name in parent target" \
  || die "fd_wsl_hosts spaced-distro row wrong: $rows"

target="$(printf '%s' "$rows" | cut -f2)"
out="$(printf 'echo hi\n' | fd_run "$target" wsl)"
case "$out" in
  *'wsl.exe -d "Docker Desktop" -- bash -s --'*)
    pass "fd_wsl_hosts → fd_run: spaced distro name survives round trip" ;;
  *) die "fd_wsl_hosts → fd_run round trip: $out" ;;
esac

# A file with no dispatch key predates the field and must behave as before.
mock_ssh_legacy() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  case "$*" in
    *'wsl.exe -l -q'*) printf 'legacy-distro\n' ;;
    *) printf '{"self":{"nickname":"legacy-distro","fleet":true,"platform":"linux"}}\n' ;;
  esac
}
SSH="mock_ssh_legacy"
rows="$(fd_wsl_hosts desktop windows)"
echo "$rows" | grep -q $'^legacy-distro\tlegacy-distro.gg.ez\tlinux$' \
  && pass "missing dispatch key defaults to direct" \
  || die "legacy row wrong: $rows"

SSH="mock_ssh"   # restore for any later cases

# ── local-parent dispatch (2026-08-30) ───────────────────────────────────────
# A WSL distro cannot ssh to its OWN Windows host's tailnet node, so a dispatch
# to that one member goes through WSL interop instead. Which member it is comes
# from fleet.local.json's self.parent, never from a hostname or a failed probe.

mock_local_bash() {
  printf '%s' "LOCALBASH $*" >> "$LOG"
  local in; in="$(cat 2>/dev/null)"
  printf 'LOCALBASH %s||%s\n' "$*" "$in"
}
FLEET_LOCAL_BASH="mock_local_bash"
FLEET_LOCAL_PARENT="desktop"

: > "$LOG"; fd_probe desktop windows >/dev/null && pass "probe local parent ok" \
  || die "probe local parent failed"
grep -q 'LOCALBASH -c true' "$LOG" && pass "probe local parent uses local Git Bash" \
  || die "probe local parent argv: $(cat "$LOG")"
grep -q 'bash.exe" -c true' "$LOG" && die "probe local parent must not go over ssh" \
  || pass "probe local parent avoids ssh"

out="$(printf 'SCRIPT-BODY' | fd_run desktop windows target-arg)"
[ "$out" = 'LOCALBASH -s -- target-arg||SCRIPT-BODY' ] \
  && pass "fd_run local parent argv+stdin" || die "fd_run local parent -> '$out'"

# The property that makes declaring the parent worth it: the OTHER Windows
# member still goes over ssh. Inferring the parent from a failed probe would
# run the script against the LOCAL Windows clone and report it as g15.
: > "$LOG"; fd_probe g15 windows && pass "probe non-parent windows ok" \
  || die "probe non-parent windows failed"
grep -q 'Git\\bin\\bash.exe" -c true' "$LOG" \
  && pass "a non-parent Windows member still dispatches over ssh" \
  || die "non-parent windows argv: $(cat "$LOG")"
grep -q 'LOCALBASH' "$LOG" && die "non-parent windows must not use local Git Bash" \
  || pass "non-parent windows avoids local Git Bash"

# fd_local_parent reads self.parent, and treats its absence as "no parent".
unset FLEET_LOCAL_PARENT
FLEET_LOCAL_JSON="$(mktemp)"
# The WSL gate is the binfmt_misc interop handler, not $WSL_DISTRO_NAME — sshd
# does not set the latter, so a /ship run started over ssh into the distro read
# it empty and fell back to the network (found live on g15-wsl, 2026-08-30).
FLEET_WSL_INTEROP="$(mktemp)"
printf '{"self":{"nickname":"desktop-wsl","fleet":true,"parent":"desktop"}}' > "$FLEET_LOCAL_JSON"
[ "$(fd_local_parent)" = desktop ] && pass "fd_local_parent reads self.parent" \
  || die "fd_local_parent -> '$(fd_local_parent)'"
printf '{"self":{"nickname":"desktop-wsl","fleet":true}}' > "$FLEET_LOCAL_JSON"
[ -z "$(fd_local_parent)" ] && pass "fd_local_parent: no parent key → empty" \
  || die "fd_local_parent (no key) -> '$(fd_local_parent)'"
printf '{"self":{"nickname":"desktop-wsl","fleet":true,"parent":"desktop"}}' > "$FLEET_LOCAL_JSON"
rm -f "$FLEET_WSL_INTEROP"
[ -z "$(fd_local_parent)" ] && pass "fd_local_parent: no interop handler → empty" \
  || die "fd_local_parent (non-WSL) -> '$(fd_local_parent)'"
rm -f "$FLEET_LOCAL_JSON"
FLEET_LOCAL_PARENT=""   # restore the off switch for any later cases

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
