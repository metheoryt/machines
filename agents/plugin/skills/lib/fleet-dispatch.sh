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
    *)       $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -c true </dev/null 2>/dev/null ;;
  esac
}

# fd_run <alias> <platform> [arg...] — pipe the script on THIS function's stdin
# to the member's bash with positional args ($1..). Echoes remote stdout.
fd_run() {
  local alias="$1" platform="$2"; shift 2
  case "$platform" in
    windows)
      # `--` ends bash option parsing so the args become $1.. (not options).
      local q="-s --"; local a
      for a in "$@"; do q="$q \"$a\""; done
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" "$(_fd_win_call "$q")" 2>/dev/null
      ;;
    *)
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -s -- "$@" 2>/dev/null
      ;;
  esac
}

# fd_wsl_hosts <alias> <platform> — for a windows member, echo the tailnet
# nickname of each WSL distro that self-declares fleet:true in
# $HOME/machines/fleet.local.json. One per line. Empty for non-windows members.
#
# `wsl -l -q` historically emits UTF-16LE with NULs + CRLF — strip \000 and \r
# before parsing. The per-distro marker read runs the distro's OWN bash so it
# expands its $HOME (single-quoted so neither PowerShell nor the local shell
# eats it); the exact remote quoting is confirmed by the live discovery task.
fd_wsl_hosts() {
  local alias="$1" platform="$2"
  [ "$platform" = windows ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local distros d marker
  distros="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" 'wsl.exe -l -q' </dev/null 2>/dev/null \
    | tr -d '\000\r')"
  printf '%s\n' "$distros" | while IFS= read -r d; do
    d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$d" ] || continue
    marker="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" \
      "wsl.exe -d $d -- bash -lc 'cat \$HOME/machines/fleet.local.json 2>/dev/null'" </dev/null 2>/dev/null \
      | tr -d '\000\r')"
    [ -n "$marker" ] || continue
    printf '%s' "$marker" | jq -e '.self.fleet == true' >/dev/null 2>&1 || continue
    printf '%s' "$marker" | jq -r '.self.nickname // empty'
  done
}
