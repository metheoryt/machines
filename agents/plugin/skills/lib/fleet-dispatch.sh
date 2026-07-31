#!/usr/bin/env bash
# fleet-dispatch.sh — platform-aware remote-bash dispatch for fleet tools.
# Sourced by fleet-pull.sh (/ship) and fleet-gather.sh (kb-refresh). Sourcing has
# no side effects. Test override: SSH (the ssh command; default "ssh").
#
# Why this exists: an `ssh <windows-member> bash …` lands in C:\Windows\System32\
# bash.exe — the WSL default-distro launcher (first on PATH over Git Bash) — so
# the remote script runs inside WSL and pulls the WSL clone, never the Windows
# clone. Launching Git Bash explicitly through PowerShell's call operator (&)
# runs the SAME generic remote script against the Windows-native clone
# ($HOME=/c/Users/<winuser>).

: "${SSH:=ssh}"
: "${MAGICDNS_SUFFIX:=gg.ez}"

# _fd_wsl_split <parent:distro> — echoes "<parent> <distro>".
# The distro name may not contain ':'; wsl.exe forbids it.
_fd_wsl_split() {
  printf '%s %s\n' "${1%%:*}" "${1#*:}"
}

# Git Bash program path — user-independent, safe to hardcode. Two install roots.
FLEET_GITBASH='C:\Program Files\Git\bin\bash.exe'
FLEET_GITBASH_X86='C:\Program Files (x86)\Git\bin\bash.exe'

# _fd_win_call <bash-args...> — PowerShell fragment that runs Git Bash (falling
# back to the x86 path) with the given argv. Emitted as ONE remote command string.
_fd_win_call() {
  local args="$*"
  # If the 64-bit path is absent, PowerShell's `&` on the x86 path takes over.
  printf 'if (Test-Path "%s") { & "%s" %s } else { & "%s" %s }' \
    "$FLEET_GITBASH" "$FLEET_GITBASH" "$args" \
    "$FLEET_GITBASH_X86" "$args"
}

# fd_probe <alias> <platform> — 0 if the member answers a bash invocation.
# `</dev/null` is load-bearing: real ssh drains its stdin, which for a caller
# iterating a member list on fd's stdin would swallow the rest of the list.
fd_probe() {
  local alias="$1" platform="$2"
  case "$platform" in
    windows) $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" "$(_fd_win_call -c true)" </dev/null 2>/dev/null ;;
    wsl)
      local parent distro
      read -r parent distro < <(_fd_wsl_split "$alias")
      # Double-quote $distro: this string is parsed by a remote shell that is
      # PowerShell (per _fd_win_call, the parent is always platform:windows) —
      # double quotes group arguments in both PowerShell and cmd.exe, single
      # quotes only in PowerShell — so a distro name containing a space (WSL
      # permits it, e.g. "Docker Desktop") still reaches wsl.exe -d as one arg.
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$parent" \
        "wsl.exe -d \"$distro\" -- bash -c true" </dev/null 2>/dev/null ;;
    *)       $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -c true </dev/null 2>/dev/null ;;
  esac
}

# fd_run <alias> <platform> [arg...] — pipe the script on THIS function's stdin
# to the member's bash with positional args ($1..). Echoes remote stdout.
fd_run() {
  local alias="$1" platform="$2"; shift 2
  local q a parent distro
  case "$platform" in
    windows)
      # `--` ends bash option parsing so the args become $1.. (not options).
      q="-s --"
      for a in "$@"; do q="$q \"$a\""; done
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" "$(_fd_win_call "$q")" 2>/dev/null
      ;;
    wsl)
      # No tailnet node of its own: reach it as `wsl.exe -d <distro>` through
      # the Windows parent. Same shape fd_wsl_hosts already uses to discover it.
      # $distro is double-quoted for the same reason as in fd_probe above: the
      # parent's shell is PowerShell, and double quotes group arguments there
      # (and in cmd.exe) so a space in the distro name stays one argument.
      read -r parent distro < <(_fd_wsl_split "$alias")
      q="-s --"
      for a in "$@"; do q="$q \"$a\""; done
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$parent" \
        "wsl.exe -d \"$distro\" -- bash $q" 2>/dev/null
      ;;
    *)
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -s -- "$@" 2>/dev/null
      ;;
  esac
}

# fd_wsl_hosts <alias> <platform> — for a windows member, echo one TSV row per
# self-declared (fleet:true) WSL distro:
#
#   <nickname>\t<target>\t<platform>
#
# dispatch=direct (default, and the only mode before 2026-08-01) → the distro
# owns the tailnet node: target is <nickname>.<MAGICDNS_SUFFIX>, platform linux.
# dispatch=parent → no node of its own: target is <alias>:<distro-name>,
# platform wsl, reached by fd_run's wsl branch.
#
# Callers pass target+platform straight to fd_probe/fd_run and use nickname for
# display and host-id lookup. They must NOT append the MagicDNS suffix — that
# happens here, because only here is it known whether the distro has a node.
fd_wsl_hosts() {
  local alias="$1" platform="$2"
  [ "$platform" = windows ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local distros d marker nick mode
  distros="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" 'wsl.exe -l -q' </dev/null 2>/dev/null \
    | tr -d '\000\r')"
  printf '%s\n' "$distros" | while IFS= read -r d; do
    d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$d" ] || continue
    # Double-quote $d for the same reason as fd_probe/fd_run's wsl branches:
    # the remote shell here is PowerShell, where double quotes (unlike single
    # quotes) group arguments, so a distro name with a space survives intact.
    marker="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" \
      "wsl.exe -d \"$d\" -- bash -lc 'cat \$HOME/machines/fleet.local.json 2>/dev/null'" </dev/null 2>/dev/null \
      | tr -d '\000\r')"
    [ -n "$marker" ] || continue
    printf '%s' "$marker" | jq -e '.self.fleet == true' >/dev/null 2>&1 || continue
    nick="$(printf '%s' "$marker" | jq -r '.self.nickname // empty')"
    [ -n "$nick" ] || continue
    mode="$(printf '%s' "$marker" | jq -r '.self.dispatch // "direct"')"
    if [ "$mode" = parent ]; then
      printf '%s\t%s:%s\twsl\n' "$nick" "$alias" "$d"
    else
      printf '%s\t%s%s\tlinux\n' "$nick" "$nick" "${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}"
    fi
  done
}
