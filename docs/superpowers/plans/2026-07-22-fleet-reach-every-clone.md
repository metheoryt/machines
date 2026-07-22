# Fleet: reach & update every host's `machines` clone via `/ship` (Windows + WSL) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/ship` (and kb-refresh) pull the `machines` clone on *every* fleet host — the Windows-native clone on each Windows box AND every self-declared WSL distro — not just whichever clone `bash -s` happens to land in.

**Architecture:** Extract a platform-aware remote-bash dispatch primitive (`fleet-dispatch.sh`) that both `fleet-pull.sh` and `fleet-gather.sh` source. On `platform: windows` members it launches Git Bash through PowerShell's call operator (`&`) so the remote script runs against the Windows-native clone; on Linux members it stays `bash -s`. The same helper enumerates a Windows member's WSL distros (`wsl -l -q`), reads each distro's gitignored `fleet.local.json` self-declaration, and returns the tailnet nickname of any distro that opts in — which the orchestrator then reaches directly by MagicDNS name. WSL distros are never committed to `fleet.json`; they self-declare and the Windows parent discovers them live.

**Tech Stack:** POSIX/bash shell scripts, `jq`, OpenSSH over a Headscale tailnet (MagicDNS suffix `gg.ez`), Windows OpenSSH (PowerShell default shell) + Git Bash, WSL2, Nix/Home-Manager (`ssh.nix`), `just`.

## Global Constraints

Every task's requirements implicitly include these (copied verbatim from the spec):

- **Canonical clone path is `$HOME/machines`** on every host (Windows Git Bash `$HOME=/c/Users/methe`, WSL `$HOME=/home/me`). No `~/.machines` rename in this plan.
- **No frozen usernames.** Windows user is `methe`, WSL user is `me` — never hardcode either in a path; use `$HOME`-relative paths on the remote side.
- **WSL distros are never added to `fleet.json`.** They self-declare in a gitignored `$HOME/machines/fleet.local.json`; the Windows parent enumerates them.
- **Git Bash program path is user-independent:** `C:\Program Files\Git\bin\bash.exe` (fall back to `C:\Program Files (x86)\Git\bin\bash.exe`). Safe to hardcode both candidates.
- **MagicDNS suffix is `gg.ez`;** a WSL host's `<nickname>` node name makes `<nickname>.gg.ez` reachable fleet-wide.
- **Every remote run is non-destructive and skip-if-unsafe** — the existing FF-only / skip-if-dirty / skip-if-diverged contract of `fleet-pull.sh` is preserved unchanged.
- **The `machines` repo is located by canonical path first, root-scan fallback second;** the `/mnt/c/Users/*/` cross-filesystem root is removed. Other fleet-sync repos keep the root scan.
- **Windows/WSL behavior can only be verified live** on the `desktop` box (hostname `g614jv`). Nix-evaluable changes are checkable on `latitude`. Shell logic is unit-tested with mocked `ssh`/`wsl`/`jq` on any box.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `agents/plugin/skills/lib/fleet-dispatch.sh` (new) | Platform-aware dispatch primitive: `fd_probe`, `fd_run`, `fd_wsl_hosts`. Pure/sourceable; test override `SSH`. | 1, 5 |
| `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh` (new) | Unit tests for the helper (mocked `ssh`/`wsl`). | 1, 5 |
| `agents/plugin/skills/ship/fleet-pull.sh` (modify) | Source the helper; canonical-path-first + drop `/mnt/c`; Windows Git-Bash dispatch; WSL discovery + direct pull. | 2, 5 |
| `agents/plugin/skills/ship/tests/fleet-pull.test.sh` (modify) | Extend: canonical-path fixture, `/mnt/c` gone, Windows dispatch, WSL discovery. | 2, 5 |
| `.gitignore` (modify) | Ignore `fleet.local.json`. | 3 |
| `provision/fleet-local.sh` (new) | Write `$HOME/machines/fleet.local.json` self-declaration (idempotent). | 3 |
| `provision/tests/fleet-local.test.sh` (new) | Unit test the marker writer. | 3 |
| `provision/linux.sh` (modify) | New ssh-server step: merge `fleet-authorized-keys` → `~/.ssh/authorized_keys`. | 6 |
| `provision/provision-wsl.sh` (new) | Orchestrate `tailscale-wsl.sh → ssh-wsl.sh → linux.sh` + self-declaration for a WSL distro. | 7 |
| `justfile` (modify) | `provision-wsl <nickname>` recipe. | 7 |
| `modules/home/ssh.nix` (modify) | `Host *.gg.ez` wildcard block (User `me`, fleet IdentityFile). | 8 |
| `provision/ssh-wsl.sh` (modify) | Emit the same `Host *.gg.ez` wildcard in its rendered fleet block. | 8 |
| `agents/plugin/skills/kb-refresh/fleet-gather.sh` (modify) | Retrofit all dispatch sites onto the shared helper + WSL discovery. | 9 |
| `agents/memory/global.md`, `AGENTS.md`, `provision/README.md`, `.claude/memory/project.md` (modify) | Doc/memory updates to the new model. | 10 |

---

## Phase 1 — Dispatch primitive + canonical-path fix (core `/ship`)

### Task 1: Shared dispatch helper `fleet-dispatch.sh` (`fd_probe`, `fd_run`)

**Files:**
- Create: `agents/plugin/skills/lib/fleet-dispatch.sh`
- Test: `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`

**Interfaces:**
- Produces:
  - `FLEET_GITBASH` / `FLEET_GITBASH_X86` — the two candidate Git Bash program paths.
  - `fd_probe <alias> <platform>` — returns 0 if the member answers a bash invocation; drains its own stdin from `/dev/null`.
  - `fd_run <alias> <platform> [arg...]` — pipes the script on **this function's stdin** to the member's bash with positional args (`$1..`), echoes remote stdout. Linux → `bash -s`; Windows → Git Bash via PowerShell `&`.
- Consumes: env `SSH` (default `ssh`), used verbatim as the ssh command (tests override it with a mock).

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`:

```bash
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
  # Probe branch: remote command ends in `true`.
  case "$remote" in
    *true)
      # winbox models Windows: only a Git-Bash `&`-wrapped or `bash -c` probe works.
      if [ "$alias" = winbox ] && [ "${remote#bash }" = "$remote" ] && [ "${remote#\& }" = "$remote" ]; then
        return 1
      fi
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
  *'Git\bin\bash.exe" -s -- "target-arg"||SCRIPT-BODY') pass "fd_run windows argv+stdin" ;;
  *) die "fd_run windows -> '$out'" ;;
esac

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: FAIL — `fleet-dispatch.sh` does not exist yet (`source` errors / functions undefined).

- [ ] **Step 3: Write the helper**

Create `agents/plugin/skills/lib/fleet-dispatch.sh`:

```bash
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
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -s "$@" 2>/dev/null
      ;;
  esac
}
```

> Note on the test's Windows-probe assertion: the mock records the flattened
> remote command; `_fd_win_call -c true` emits a PowerShell `if … & "…bash.exe" -c true …`
> string, so the substring `Git\bin\bash.exe" -c true` is present. The
> `${remote#\& }` guard in the winbox mock still passes because the real Windows
> command begins with `if` — adjust the mock's winbox guard to also accept an
> `if (Test-Path …) { & …` prefix (see Step 4).

- [ ] **Step 4: Align the winbox mock with the real Windows command shape**

The real Windows probe string starts with `if (Test-Path …) { & "…bash.exe" -c true …`, not a bare `& …`. Update the winbox guard in the test so it accepts the real shape (a Windows probe is "OK" when it contains a Git-Bash call; a bare `true` with no bash is the failure case being modeled):

Edit `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`, replace the winbox guard inside `mock_ssh`'s probe branch with:

```bash
      # winbox models Windows: a probe that never invokes bash fails; a Git-Bash
      # (`&`/`bash.exe`) or `bash`-wrapped probe passes.
      case "$remote" in
        *bash.exe*|bash\ *) : ;;                 # bash reached → ok
        *) [ "$alias" = winbox ] && return 1 ;;  # winbox: no bash → unreachable
      esac
      return 0 ;;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add agents/plugin/skills/lib/fleet-dispatch.sh agents/plugin/skills/lib/tests/fleet-dispatch.test.sh
git commit -m "feat(ship): platform-aware fleet dispatch helper (fd_probe/fd_run)"
```

---

### Task 2: `fleet-pull.sh` — source the helper, canonical-path-first, drop `/mnt/c`, Windows dispatch

**Files:**
- Modify: `agents/plugin/skills/ship/fleet-pull.sh`
- Modify: `agents/plugin/skills/ship/tests/fleet-pull.test.sh`

**Interfaces:**
- Consumes: `fd_probe`, `fd_run` from Task 1 (`../../lib/fleet-dispatch.sh`, relative to the ship skill dir).
- Consumes from `fleet.json`: each member's `platform` (already read by `jq` in `main`).
- Produces: `run_member` now takes `<alias> <platform> <target>`; `REMOTE_SCRIPT` locates `machines` by canonical path first.

- [ ] **Step 1: Write the failing test — canonical-path-first + `/mnt/c` removed**

The existing suite (`fleet-pull.test.sh`) already mocks `ssh` via `SSH="mock_ssh"`, runs `REMOTE_SCRIPT` locally with a per-alias `$HOME`, and includes the `winbox` PowerShell guard. Add two assertions near the end (before the final `[ "$fail" -eq 0 ]`):

```bash
# canonical-path-first: a checkout at $HOME/machines is found even though the
# roots list would also scan $HOME/*/. Build one at the canonical path only.
mkdir -p "$tmp/home/canon"
up_canon="$tmp/upstream-canon.git"; git init -q --bare "$up_canon"
mkrepo "$tmp/home/canon/machines"
git -C "$tmp/home/canon/machines" remote set-url origin "$up_canon"
git -C "$tmp/home/canon/machines" push -q origin main
tgt_canon="$(normalize_url "$up_canon")"
got="$(run_member canon linux "$tgt_canon")"
[ "$got" = "OK up-to-date | conv:none" ] && pass "canonical \$HOME/machines found" \
  || die "canon -> '$got' (want OK up-to-date)"

# /mnt/c root removed: REMOTE_SCRIPT must not reference /mnt/c any more.
printf '%s' "$REMOTE_SCRIPT" | grep -q '/mnt/c' \
  && die "REMOTE_SCRIPT still references /mnt/c" || pass "no /mnt/c root in REMOTE_SCRIPT"
```

Also update every existing `run_member <alias> <target>` call in the file to the new 3-arg form `run_member <alias> <platform> <target>` (all current callers are Linux-style checkouts, so pass `linux`):
- `run_member server "$tgt_server"` → `run_member server linux "$tgt_server"`
- `run_member desktop "$absent_target"` → `run_member desktop linux "$absent_target"`
- `run_member latitude "$tgt_lat"` → `run_member latitude linux "$tgt_lat"`
- `run_member hub "$target"` → `run_member hub linux "$target"`
- `run_member desktop "$tgt_div"` → `run_member desktop linux "$tgt_div"`
- `run_member extra "$tgt_uptodate"` → `run_member extra linux "$tgt_uptodate"`
- `run_member winbox "$absent_target"` → `run_member winbox windows "$absent_target"`

For the `winbox` case the mock already models a PowerShell box; with `platform=windows`, `run_member` will call `fd_probe winbox windows` and `fd_run winbox windows …`. The existing `mock_ssh` in this suite must accept the Windows command shape. Update its probe/work branches to mirror the dispatch helper (a `&`/`bash.exe`/`bash -s` command runs the stdin script locally with the alias's `$HOME`):

```bash
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  # Reachability probe: remote command ends in `true`.
  if [ "${remote%true}" != "$remote" ]; then
    cat >/dev/null 2>&1 || true                       # drain stdin like real ssh
    case "$remote" in *bash.exe*|bash\ *) return 0 ;; esac
    [ "$alias" = winbox ] && return 1 || return 0     # winbox: no bash → down
  fi
  # Work call: run REMOTE_SCRIPT (on stdin) with this box's HOME. The script's
  # single positional arg (target) is the LAST token of the flattened command
  # for both `bash -s <target>` and Git Bash `-s -- "<target>"`.
  local target; target="$(printf '%s' "$remote" | awk '{gsub(/"/,"",$NF); print $NF}')"
  HOME="$tmp/home/$alias" bash -s "$target"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `run_member` still takes 2 args and `REMOTE_SCRIPT` still contains `/mnt/c`; the canonical-path assertion and the `/mnt/c` assertion go red (and the 3-arg calls mis-parse).

- [ ] **Step 3: Source the helper and remove `/mnt/c` + add canonical-path-first**

Edit `agents/plugin/skills/ship/fleet-pull.sh`. After the `SSH="${SSH:-ssh}"` line, source the helper (the ship skill dir is `agents/plugin/skills/ship`, so the lib is one dir up):

```bash
# shellcheck source=../lib/fleet-dispatch.sh
. "$SCRIPT_DIR/../lib/fleet-dispatch.sh"
```

In `REMOTE_SCRIPT`, change the roots line to drop `/mnt/c/Users/*/`:

```bash
roots="$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly"
```

And insert a canonical-path-first probe *before* the `for root in $roots` loop:

```bash
found=""
# Canonical path first: machines always lives at $HOME/machines. Only fall back
# to the root scan (for other fleet-sync repos) if the canonical clone is absent
# or has a different origin.
if { [ -d "$HOME/machines/.git" ] || [ -f "$HOME/machines/.git" ]; }; then
  o="$(git -C "$HOME/machines" remote get-url origin 2>/dev/null)" || o=""
  [ -n "$o" ] && [ "$(norm "$o")" = "$target" ] && found="$HOME/machines"
fi
if [ -z "$found" ]; then
  for root in $roots; do
    for d in "$root" "$root"/*; do
      { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || continue
      o="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
      if [ "$(norm "$o")" = "$target" ]; then found="$d"; break 2; fi
    done
  done
fi
```

- [ ] **Step 4: Rework `run_member` and `main` to be platform-aware**

Replace `run_member` with a version that takes `<alias> <platform> <target>` and dispatches via the helper:

```bash
# Reachability probe + remote run for one member. Prints one status token.
run_member() {
  local alias="$1" platform="$2" target="$3"
  if ! fd_probe "$alias" "$platform"; then
    printf 'SKIP unreachable\n'; return 0
  fi
  local res
  res="$(printf '%s' "$REMOTE_SCRIPT" | fd_run "$alias" "$platform" "$target")"
  printf '%s\n' "${res:-SKIP no-output}"
}
```

In `main`, read each member's platform alongside its key and pass it through. Replace the `while read -r m` loop with:

```bash
  local m plat
  while IFS=$'\t' read -r m plat; do
    [ -n "$m" ] || continue
    [ "$m" = "$self" ] && continue
    printf '%-10s %s\n' "$m" "$(run_member "$m" "${plat:-linux}" "$target")"
  done < <(jq -r '.machines | to_entries[] | [.key, (.value.platform // "linux")] | @tsv' "$FLEET_JSON" 2>/dev/null)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: `ALL PASS` (including the new canonical-path and `/mnt/c` assertions, and the reused `winbox` guard).

- [ ] **Step 6: Also run the dispatch helper test (no regression)**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "feat(ship): canonical-path-first + platform-aware dispatch in fleet-pull"
```

---

### Task 3: `fleet.local.json` self-declaration writer + `.gitignore`

**Files:**
- Create: `provision/fleet-local.sh`
- Create: `provision/tests/fleet-local.test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `provision/fleet-local.sh --nickname <name> [--platform <p>] [--repo <dir>]` writes `<repo>/fleet.local.json` = `{"self":{"nickname":"<name>","fleet":true,"platform":"<p>"}}` (default repo `$HOME/machines`, default platform `linux`). Idempotent; overwrites its own `self` block, preserving any other top-level keys if the file already exists.
- Consumes: `jq`.

- [ ] **Step 1: Write the failing test**

Create `provision/tests/fleet-local.test.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fleet-local.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/machines"

# fresh write
bash "$SCRIPT" --nickname desktop-ubuntu26 --platform linux --repo "$tmp/machines"
f="$tmp/machines/fleet.local.json"
[ -f "$f" ] && pass "marker written" || die "no marker file"
[ "$(jq -r '.self.nickname' "$f")" = desktop-ubuntu26 ] && pass "nickname" || die "nickname wrong: $(cat "$f")"
[ "$(jq -r '.self.fleet' "$f")" = true ] && pass "fleet:true" || die "fleet not true"
[ "$(jq -r '.self.platform' "$f")" = linux ] && pass "platform" || die "platform wrong"

# idempotent + preserves other keys
jq '. + {"other":{"k":1}}' "$f" > "$f.new" && mv "$f.new" "$f"
bash "$SCRIPT" --nickname desktop-ubuntu26 --repo "$tmp/machines"
[ "$(jq -r '.other.k' "$f")" = 1 ] && pass "preserves other keys" || die "clobbered other keys: $(cat "$f")"
[ "$(jq -r '.self.nickname' "$f")" = desktop-ubuntu26 ] && pass "re-write nickname stable" || die "nickname changed"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash provision/tests/fleet-local.test.sh`
Expected: FAIL — `provision/fleet-local.sh` does not exist.

- [ ] **Step 3: Write the marker writer**

Create `provision/fleet-local.sh`:

```bash
#!/usr/bin/env bash
# provision/fleet-local.sh — write this host's gitignored self-declaration to
# <repo>/fleet.local.json so the Windows parent's `wsl -l` discovery can find it
# and /ship reaches it by tailnet nickname. WSL distros never go in fleet.json.
# Idempotent: rewrites only the `self` block, preserving other top-level keys.
set -u
have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "fleet-local: jq required" >&2; exit 3; }

nickname=""; platform="linux"; repo="$HOME/machines"
while [ $# -gt 0 ]; do
  case "$1" in
    --nickname) nickname="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --repo)     repo="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$nickname" ] || { echo "fleet-local: --nickname required" >&2; exit 2; }

f="$repo/fleet.local.json"
base='{}'
[ -f "$f" ] && base="$(cat "$f")"
printf '%s' "$base" | jq \
  --arg n "$nickname" --arg p "$platform" \
  '.self = {nickname:$n, fleet:true, platform:$p}' > "$f.tmp" \
  && mv "$f.tmp" "$f"
echo "wrote $f (self.nickname=$nickname, fleet=true, platform=$platform)"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash provision/tests/fleet-local.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Ignore the marker in git**

Edit `.gitignore`, append under a new comment block (after the `/.machines/` block):

```
# Per-host WSL self-declaration for the fleet (provision/fleet-local.sh). A host
# declares itself a fleet member locally without a committed fleet.json entry;
# the Windows parent discovers it via `wsl -l`. Per-host, never synced.
fleet.local.json
```

- [ ] **Step 6: Verify the ignore works**

Run: `touch fleet.local.json && git status --porcelain fleet.local.json && rm fleet.local.json`
Expected: **no output** (the file is ignored, so `git status --porcelain` prints nothing).

- [ ] **Step 7: Commit**

```bash
git add provision/fleet-local.sh provision/tests/fleet-local.test.sh .gitignore
git commit -m "feat(provision): fleet.local.json self-declaration writer + gitignore"
```

---

### Task 4: LIVE smoke test — the dispatch primitive against `desktop`

This task has **no code**. It is the primitive-first live gate the plan is built on: confirm `fd_run` reaches the **Windows-native** clone before anything downstream assumes it. Run from `latitude` (or any Linux fleet box) after Tasks 1–2 are pushed and pulled onto it.

- [ ] **Step 1: Confirm the Windows clone is at the canonical path**

Run: `ssh desktop 'if (Test-Path "$env:USERPROFILE\machines\.git") { "present" } else { "MISSING" }'`
Expected: `present`. If `MISSING`, the Windows clone isn't at `C:\Users\methe\machines` — stop and reconcile with the user (the canonical-path assumption is wrong for this box).

- [ ] **Step 2: Smoke-test `fd_run` end-to-end against the Windows clone**

From the machines repo on the Linux box, run the real dispatch (not a mock):

```bash
cd ~/machines
origin="$(git remote get-url origin)"
target="$(bash -c '. agents/plugin/skills/lib/fleet-dispatch.sh; :'; \
  printf '%s' "$origin" | sed -E "s#^(git@|https://|ssh://git@)##; s#:#/#; s#\.git\$##" | awk -F/ "{\$1=tolower(\$1)}1" OFS=/)"
printf '%s' 'echo "HOME=$HOME"; git -C "$HOME/machines" rev-parse --short HEAD 2>/dev/null || echo NO-REPO' \
  | ( . agents/plugin/skills/lib/fleet-dispatch.sh; fd_run desktop windows )
```

Expected: `HOME=/c/Users/methe` (or the Git Bash home) followed by a short commit hash — i.e. Git Bash ran and saw the **Windows** clone, NOT `HOME=/home/me`. If `HOME=/home/me` appears, the `&` dispatch fell through to WSL — see Step 3.

- [ ] **Step 3: If stdin did not survive the PowerShell `&` layer — apply the fallback**

Symptom: empty output, an error, or `HOME=/home/me`. The fallback replaces stdin-piping with a base64-embedded script (no stdin through PowerShell). In `fleet-dispatch.sh`, change the `windows` branch of `fd_run` to read its stdin, base64 it, and pass a decode-and-run one-liner:

```bash
    windows)
      local script b64; script="$(cat)"
      b64="$(printf '%s' "$script" | base64 | tr -d '\n')"
      local q="-c \"echo $b64 | base64 -d | bash -s -- $*\""
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" "$(_fd_win_call "$q")" 2>/dev/null
      ;;
```

Then re-run the Task 1 helper test (the mock echoes the remote command; update its Windows work-branch assertion to accept the base64 form if you take this branch), re-run Step 2, and note in the commit which form was verified.

- [ ] **Step 4: Run a real `/ship` dry-run pull and read the table**

Run: `~/machines/agents/plugin/skills/ship/fleet-pull.sh "$(git -C ~/machines remote get-url origin)"`
Expected: a `desktop  OK …` or `desktop  OK up-to-date | conv:…` row — the Windows clone was reached. `server` (also Windows) should likewise show `OK …`. Record the exact table in the commit or the task notes.

- [ ] **Step 5: Commit the verified primitive shape (if the fallback changed code)**

```bash
git add agents/plugin/skills/lib/fleet-dispatch.sh agents/plugin/skills/lib/tests/fleet-dispatch.test.sh
git commit -m "fix(ship): verified Windows Git-Bash dispatch form (live: desktop)"
```

If Step 2 passed with no changes, skip this commit and just record the live result.

---

## Phase 2 — WSL discovery

### Task 5: `fd_wsl_hosts` discovery + wire into `fleet-pull.sh`

**Files:**
- Modify: `agents/plugin/skills/lib/fleet-dispatch.sh`
- Modify: `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
- Modify: `agents/plugin/skills/ship/fleet-pull.sh`
- Modify: `agents/plugin/skills/ship/tests/fleet-pull.test.sh`

**Interfaces:**
- Produces: `fd_wsl_hosts <alias> <platform>` — for a `windows` member, echoes the tailnet nickname (one per line) of every WSL distro whose `$HOME/machines/fleet.local.json` has `.self.fleet == true`; empty for non-windows. Strips UTF-16/NUL/CR from `wsl -l -q` output.
- Consumes: env `SSH`, `jq`.

- [ ] **Step 1: Write the failing test (mocked `wsl` enumeration)**

Append to `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`, before the final tally. Extend `mock_ssh` to answer WSL-discovery commands, then assert:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: FAIL — `fd_wsl_hosts` undefined.

- [ ] **Step 3: Implement `fd_wsl_hosts`**

Append to `agents/plugin/skills/lib/fleet-dispatch.sh`:

```bash
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
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Write the failing test — `main` pulls discovered WSL hosts**

In `agents/plugin/skills/ship/tests/fleet-pull.test.sh`, extend the mock so that a windows member (`desktop`) enumerates one opt-in WSL host `wsl-desktop`, and that host has a clean behind-origin checkout at its `$HOME/machines`. Add, after the existing `main()` full-run block:

```bash
# --- WSL discovery: a windows member enumerates an opt-in distro; main() pulls
# it directly by nickname. Build the discovered host's checkout + a mock that
# answers wsl-enumeration for `desktop` and treats `wsl-desktop` as a normal box.
mkdir -p "$tmp/home/wsl-desktop"
up_wsl="$tmp/upstream-wsl.git"; git init -q --bare "$up_wsl"
mkrepo "$tmp/home/wsl-desktop/machines"
git -C "$tmp/home/wsl-desktop/machines" remote set-url origin "$up_wsl"
git -C "$tmp/home/wsl-desktop/machines" push -q origin main
git -C "$tmp/home/wsl-desktop/machines" commit -q --allow-empty -m ahead
git -C "$tmp/home/wsl-desktop/machines" push -q origin main
git -C "$tmp/home/wsl-desktop/machines" reset -q --hard HEAD~1   # 1 behind → OK ff

# Extend mock_ssh: answer wsl enumeration + marker for `desktop`.
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  case "$remote" in
    *"-l -q"*) printf 'wsl-desktop\r\n'; return 0 ;;
    *"wsl.exe -d wsl-desktop"*) printf '{"self":{"nickname":"wsl-desktop","fleet":true,"platform":"linux"}}'; return 0 ;;
  esac
  if [ "${remote%true}" != "$remote" ]; then
    cat >/dev/null 2>&1 || true
    case "$remote" in *bash.exe*|bash\ *) return 0 ;; esac
    [ "$alias" = winbox ] && return 1 || return 0
  fi
  local target; target="$(printf '%s' "$remote" | awk '{gsub(/"/,"",$NF); print $NF}')"
  HOME="$tmp/home/$alias" bash -s "$target"
}

out="$(FLEET_JSON="$FLEET" LOCAL_TAILNET_IP="100.64.0.2" SSH="mock_ssh" \
       main "$up_wsl" 2>/dev/null)"
printf '%s' "$out" | grep -qE '^wsl-desktop .*OK' && pass "WSL host discovered + pulled" \
  || die "WSL host row missing: $out"
```

> The fake `fleet.json` in this suite has no `platform` field, so members default
> to `linux` and no discovery runs for them — add `"platform":"windows"` to the
> `desktop` entry in the suite's inline `FLEET` heredoc so discovery fires there:
> `"desktop": { "platform":"windows", "tailnet": { "ip": "100.64.0.4" } },`

- [ ] **Step 6: Run the test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `main` does not yet discover/pull WSL hosts (`wsl-desktop` row absent).

- [ ] **Step 7: Wire discovery into `main`**

In `agents/plugin/skills/ship/fleet-pull.sh`, inside `main`'s member loop, after printing a windows member's own row, discover and pull its opt-in WSL hosts:

```bash
  local m plat
  while IFS=$'\t' read -r m plat; do
    [ -n "$m" ] || continue
    [ "$m" = "$self" ] && continue
    plat="${plat:-linux}"
    printf '%-10s %s\n' "$m" "$(run_member "$m" "$plat" "$target")"
    if [ "$plat" = windows ]; then
      local w
      while IFS= read -r w; do
        [ -n "$w" ] || continue
        [ "$w" = "$self" ] && continue
        printf '%-10s %s\n' "$w" "$(run_member "$w.gg.ez" linux "$target")"
      done < <(fd_wsl_hosts "$m" "$plat")
    fi
  done < <(jq -r '.machines | to_entries[] | [.key, (.value.platform // "linux")] | @tsv' "$FLEET_JSON" 2>/dev/null)
```

> The discovered host is reached at `<nickname>.gg.ez` (a Linux box → `linux`
> dispatch). The row label is the bare nickname for readability. The test's mock
> keys `wsl-desktop` (no `.gg.ez` suffix in the mock's `$HOME` map) — so in the
> test, strip the suffix when building the label/HOME. To keep the mock simple,
> the mock's work branch already maps `$alias` to `$tmp/home/$alias`; pass the
> label WITHOUT `.gg.ez` to `run_member` in the mock's world. Reconcile by having
> `run_member` receive the bare nickname and letting `fd_run`'s `$SSH` mock map
> it: in the test the alias passed is `wsl-desktop` (bare). In production it must
> be `wsl-desktop.gg.ez`. Resolve this by making the suffix a variable:

Add near the top of `fleet-pull.sh` (after sourcing the helper):

```bash
MAGICDNS_SUFFIX="${MAGICDNS_SUFFIX:-gg.ez}"
```

and build the target alias as `"$w${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}"`. In the test, export `MAGICDNS_SUFFIX=""` in the discovery-run `main` invocation so the alias stays the bare `wsl-desktop` the mock knows:

```bash
out="$(FLEET_JSON="$FLEET" LOCAL_TAILNET_IP="100.64.0.2" SSH="mock_ssh" MAGICDNS_SUFFIX="" \
       main "$up_wsl" 2>/dev/null)"
```

So the loop line becomes:

```bash
        printf '%-10s %s\n' "$w" "$(run_member "$w${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}" linux "$target")"
```

- [ ] **Step 8: Run both test suites to verify they pass**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh && bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: `ALL PASS` from both.

- [ ] **Step 9: Commit**

```bash
git add agents/plugin/skills/lib/fleet-dispatch.sh agents/plugin/skills/lib/tests/fleet-dispatch.test.sh \
        agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "feat(ship): discover + pull opt-in WSL hosts via fleet.local.json"
```

---

### Task 6: `linux.sh` ssh-server step (inbound fleet trust)

**Files:**
- Modify: `provision/linux.sh`

**Interfaces:**
- Consumes: `provision/fleet-authorized-keys` (committed), the merge logic pattern from `ssh-wsl.sh`'s `ssh_wsl_merge_authorized_keys`.
- Produces: `~/.ssh/authorized_keys` on the provisioned box trusts the fleet keys (`0700 ~/.ssh`, `0600` file, dedup, idempotent).

> Rationale: `linux.sh` today installs the selfpull + git-autofetch timers but
> never wires inbound ssh-server trust, so a WSL host provisioned by `linux.sh`
> alone can't be reached by `/ship`. `ssh-wsl.sh` does wire it — but the spec's
> `provision-wsl` chain runs `ssh-wsl.sh` BEFORE `linux.sh`, and a bare
> `linux.sh` re-run (e.g. via selfpull-triggered converge) must not silently drop
> the trust. Making `linux.sh` idempotently ensure the trust closes that gap.

- [ ] **Step 1: Add the ssh-server trust step to `linux.sh`**

Edit `provision/linux.sh`. After the `fleet self-pull timer` block (ends near line 483, before the `── Summary ──` block), insert:

```bash
# ── BEST-EFFORT: inbound fleet SSH trust (ssh-server role) ────────────────────
# Merge provision/fleet-authorized-keys into ~/.ssh/authorized_keys so this box
# accepts inbound fleet logins (mirrors ssh-server.nix keyFiles / windows.ps1
# step 7 / ssh-wsl.sh step 4). Snapshot copy — re-run after a new member joins.
# Idempotent by key body. sshd itself is configured by ssh-wsl.sh (key-only);
# here we only ensure the authorized_keys trust so a bare linux.sh re-run keeps it.
info "Ensuring inbound fleet SSH trust…"
MESH_KEYS="$REPO/provision/fleet-authorized-keys"
if [ ! -f "$MESH_KEYS" ]; then
  warn "provision/fleet-authorized-keys not found — skipped inbound fleet trust"
else
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  AUTHK="$HOME/.ssh/authorized_keys"
  tmp_ak="$(mktemp)"
  # keep existing lines; append each fleet key whose body (2nd field) is absent.
  awk '
    function blank(s){ return s ~ /^[[:space:]]*$/ }
    FNR==NR { if (blank($0)) next; print; if ($1 !~ /^#/ && $2 != "") have[$2]=1; next }
    blank($0) || $1 ~ /^#/ { next }
    $2 != "" && !($2 in have) { print; have[$2]=1 }
  ' "$AUTHK" "$MESH_KEYS" 2>/dev/null > "$tmp_ak" || cat "$MESH_KEYS" > "$tmp_ak"
  if [ -f "$AUTHK" ] && cmp -s "$tmp_ak" "$AUTHK"; then
    ok "authorized_keys already trusts the fleet"
  else
    install -m600 "$tmp_ak" "$AUTHK"
    ok "installed fleet keys → $AUTHK (inbound trust)"
  fi
  rm -f "$tmp_ak"
fi
```

> Note: the `awk` here reads `$AUTHK` first (may not exist — the `2>/dev/null`
> + `|| cat "$MESH_KEYS"` fallback handles a missing file by trusting the fleet
> keys wholesale). This duplicates `ssh_wsl_merge_authorized_keys`'s logic
> inline rather than sourcing `ssh-wsl.sh` (which has `main` side effects on
> source unless `SSH_WSL_LIB_ONLY=1`); inline keeps `linux.sh` self-contained.

- [ ] **Step 2: Verify idempotence with a scratch HOME**

Run:
```bash
tmpH="$(mktemp -d)"; REPO=~/machines HOME="$tmpH" bash -c '
  MESH_KEYS="$REPO/provision/fleet-authorized-keys"; mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  AUTHK="$HOME/.ssh/authorized_keys"
  for i in 1 2; do
    tmp_ak="$(mktemp)"
    awk "function blank(s){return s ~ /^[[:space:]]*\$/} FNR==NR{if(blank(\$0))next;print;if(\$1!~/^#/&&\$2!=\"\")have[\$2]=1;next} blank(\$0)||\$1~/^#/{next} \$2!=\"\"&&!(\$2 in have){print;have[\$2]=1}" "$AUTHK" "$MESH_KEYS" 2>/dev/null > "$tmp_ak" || cat "$MESH_KEYS" > "$tmp_ak"
    install -m600 "$tmp_ak" "$AUTHK"; rm -f "$tmp_ak"
  done
  echo "lines: $(grep -cvE "^\s*(\$|#)" "$AUTHK")  keys-in-source: $(grep -cvE "^\s*(\$|#)" "$MESH_KEYS")"
'; rm -rf "$tmpH"
```
Expected: `lines:` equals `keys-in-source:` (running twice does not duplicate).

- [ ] **Step 3: Commit**

```bash
git add provision/linux.sh
git commit -m "feat(provision): linux.sh ensures inbound fleet SSH trust (idempotent)"
```

---

## Phase 3 — `provision-wsl` command + SSH reachability

### Task 7: `provision-wsl.sh` orchestrator + `just provision-wsl` recipe

**Files:**
- Create: `provision/provision-wsl.sh`
- Modify: `justfile`

**Interfaces:**
- Consumes: `provision/tailscale-wsl.sh` (`--hostname <nickname>`), `provision/ssh-wsl.sh`, `provision/linux.sh`, `provision/fleet-local.sh` (Task 3).
- Produces: `bash provision/provision-wsl.sh <nickname>` runs the full half-provision chain inside the current WSL distro and writes its self-declaration. `just provision-wsl <nickname>` wraps it.

- [ ] **Step 1: Write the orchestrator**

Create `provision/provision-wsl.sh`:

```bash
#!/usr/bin/env bash
# provision/provision-wsl.sh — half-provision THIS WSL distro as a self-declaring,
# ephemeral fleet host (NOT a fleet.json member). Run from inside the distro:
#   bash ~/machines/provision/provision-wsl.sh <nickname>
#
# Chain (spec 2026-07-21 / plan 2026-07-22):
#   1. tailscale-wsl.sh --hostname <nickname>   enroll on the tailnet
#   2. ssh-wsl.sh                                fleet SSH client+server identity
#   3. linux.sh                                  software + timers + inbound trust
#   4. fleet-local.sh --nickname <nickname>      write the self-declaration
#
# The nickname is BOTH the tailnet node name (so <nickname>.gg.ez resolves) and
# the fleet.local.json nickname the Windows parent's `wsl -l` discovery reports.
set -u
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NICK="${1:-}"
[ -n "$NICK" ] || die "usage: provision-wsl.sh <nickname>   (tailnet node name = fleet nickname)"

info "1/4 tailnet enroll as '$NICK'…"
bash "$REPO/provision/tailscale-wsl.sh" --hostname "$NICK" || die "tailscale-wsl.sh failed"

info "2/4 fleet SSH identity (client + server)…"
bash "$REPO/provision/ssh-wsl.sh" || die "ssh-wsl.sh failed"

info "3/4 software + timers + inbound trust…"
bash "$REPO/provision/linux.sh" || die "linux.sh failed"

info "4/4 self-declaration → fleet.local.json…"
bash "$REPO/provision/fleet-local.sh" --nickname "$NICK" --platform linux --repo "$REPO" \
  || die "fleet-local.sh failed"

printf '\n\033[1mProvisioned WSL host '\''%s'\''.\033[0m It self-declares fleet:true and is reachable at %s.gg.ez.\n' "$NICK" "$NICK"
printf 'A /ship from any box will now discover and pull this distro.\n'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x provision/provision-wsl.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Syntax-check the orchestrator**

Run: `bash -n provision/provision-wsl.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Add the `just provision-wsl` recipe**

Edit `justfile`, append after the `provision *ARGS:` recipe (end of file):

```
# Half-provision THIS WSL distro as a self-declaring, ephemeral fleet host.
# <nickname> = tailnet node name (also its fleet.local.json nickname). Run from
# inside the distro. Relative path (not {{flake_dir}}) — same Windows-path reason
# as agent-bootstrap/provision.
provision-wsl nickname:
    bash provision/provision-wsl.sh {{nickname}}
```

- [ ] **Step 5: Verify the recipe parses**

Run: `just --list 2>/dev/null | grep provision-wsl`
Expected: a line containing `provision-wsl nickname`.

- [ ] **Step 6: Commit**

```bash
git add provision/provision-wsl.sh justfile
git commit -m "feat(provision): provision-wsl orchestrator + just recipe"
```

---

### Task 8: `Host *.gg.ez` wildcard SSH block (NixOS + WSL client config)

**Files:**
- Modify: `modules/home/ssh.nix`
- Modify: `provision/ssh-wsl.sh`

**Interfaces:**
- Produces: a wildcard `Host *.gg.ez` block (User `me`, `IdentityFile ~/.ssh/id_fleet`, `StrictHostKeyChecking accept-new`) in both the NixOS-generated and WSL-provisioned `~/.ssh/config`, so any orchestrator reaches any current/future WSL host by MagicDNS name with no per-distro regen. Declared members keep their own per-host blocks (rendered before the wildcard so a specific match wins).

- [ ] **Step 1: Add the wildcard to `ssh.nix`**

Edit `modules/home/ssh.nix`. In the `settings` attrset, add a `"*.gg.ez"` block *before* the `"*"` block (OpenSSH first-match-wins; a specific `Host desktop` block still wins over `*.gg.ez` because per-host blocks come from `mapAttrs` — but `*.gg.ez` must precede the catch-all `*`). Insert into the literal settings map:

```nix
        # Wildcard for self-declared WSL fleet hosts reachable by MagicDNS name
        # (<nickname>.gg.ez). User `me`, fleet key. Declared members keep their
        # own per-host blocks (rendered from fleet.json); the bare-name blocks and
        # this suffix wildcard don't overlap. Precedes "*" so it isn't shadowed.
        "*.gg.ez" = {
          User = "me";
          IdentityFile = "~/.ssh/id_fleet";
          StrictHostKeyChecking = "accept-new";
        };
```

> Placement: put this key between the `mapAttrs` spread and the `"*"` block.
> Because the whole `settings` value is `{ "*" = {...}; } // (mapAttrs …)`,
> add `"*.gg.ez"` into the FIRST literal attrset (alongside `"*"`). Home
> Manager renders `Host` blocks; `*` is emitted last by HM's ordering, and
> `*.gg.ez` is more specific so first-match semantics hold. Verify the rendered
> order in Step 3.

- [ ] **Step 2: Add the wildcard to `ssh-wsl.sh`'s rendered fleet block**

Edit `provision/ssh-wsl.sh`. In `ssh_wsl_render_config`, append the wildcard block after the per-member blocks so `ssh <nickname>.gg.ez` works from inside a WSL distro too. Change the `jq` join to append a trailing wildcard stanza:

```bash
ssh_wsl_render_config() {
  jq -r '
    ( [ .machines | to_entries[] |
      ( [ "Host " + .key ]
        + ( if (.value.ssh.host // null) != null then [ "  HostName " + .value.ssh.host ] else [] end )
        + ( if (.value.ssh.user // "me") != "me" then [ "  User " + .value.ssh.user ] else [] end )
        + [ "  IdentityFile ~/.ssh/id_fleet", "  StrictHostKeyChecking accept-new" ]
      ) | join("\n")
    ] )
    + [ "Host *.gg.ez\n  User me\n  IdentityFile ~/.ssh/id_fleet\n  StrictHostKeyChecking accept-new" ]
    | join("\n\n")
  ' <<<"$1"
}
```

- [ ] **Step 3: Verify the ssh-wsl render includes the wildcard**

Run:
```bash
SSH_WSL_LIB_ONLY=1 bash -c '. provision/ssh-wsl.sh; ssh_wsl_render_config "$(cat fleet.json)"' | grep -A3 'Host \*.gg.ez'
```
Expected: the `Host *.gg.ez` block with `User me`, `IdentityFile ~/.ssh/id_fleet`, `StrictHostKeyChecking accept-new`.

- [ ] **Step 4: Run the existing ssh-wsl unit tests (no regression)**

Run: `bash provision/ssh-wsl.test.sh`
Expected: the suite's pass line (`ALL PASS` or equivalent). If a test asserts the exact rendered block, update its expected string to include the trailing wildcard.

- [ ] **Step 5: Nix-evaluate `ssh.nix` on `latitude`**

Run (on latitude, after pull): `nix build --dry-run '.#nixosConfigurations.latitude.config.home-manager.users.me.home.file.".ssh/config".text' 2>&1 | tail -5` — or simpler, `just quick` / `nix flake check`.
Expected: evaluation succeeds (no Nix error from the new `"*.gg.ez"` key). Confirm the generated config, once switched, contains a `Host *.gg.ez` stanza ahead of `Host *`.

- [ ] **Step 6: Commit**

```bash
git add modules/home/ssh.nix provision/ssh-wsl.sh
git commit -m "feat(ssh): Host *.gg.ez wildcard for self-declared WSL fleet hosts"
```

---

### Task 9: LIVE verify — WSL discovery end-to-end

No code. Run after Phases 1–3 are pushed & pulled, and after the desktop's WSL distro has been re-provisioned with `provision-wsl` (so it has a `fleet.local.json`).

- [ ] **Step 1: Provision the desktop's WSL distro as a fleet host**

On the desktop box, inside the WSL distro:
```
cd ~/machines && git pull --ff-only && just provision-wsl desktop-ubuntu26
```
Expected: the 4-step chain completes; `~/machines/fleet.local.json` exists with `self.fleet=true`, `self.nickname=desktop-ubuntu26`.

- [ ] **Step 2: Confirm the marker is discoverable from a Linux box**

From latitude: `ssh desktop 'wsl.exe -l -q' ` and then
`ssh desktop 'wsl.exe -d Ubuntu-26.04 -- bash -lc "cat \$HOME/machines/fleet.local.json"'`
Expected: the distro list (strip NUL/CR mentally) and the marker JSON. If `$HOME` came back as the Windows path or the marker is empty, the remote quoting needs the nested-quote form — adjust `fd_wsl_hosts`'s marker read here and re-run the helper test.

- [ ] **Step 3: Run `fd_wsl_hosts` live**

From latitude: `( . ~/machines/agents/plugin/skills/lib/fleet-dispatch.sh; fd_wsl_hosts desktop windows )`
Expected: `desktop-ubuntu26`.

- [ ] **Step 4: Full `/ship` fleet-pull shows distinct rows**

From latitude: `~/machines/agents/plugin/skills/ship/fleet-pull.sh "$(git -C ~/machines remote get-url origin)"`
Expected: distinct rows for `desktop` (Windows clone) AND `desktop-ubuntu26` (WSL clone), each `OK …`, plus `server`. Record the table.

- [ ] **Step 5: Note the verified result** (no commit unless Step 2 forced a quoting fix to `fd_wsl_hosts`, in which case commit it with a `fix(ship): live-verified WSL marker read quoting` message).

---

## Phase 4 — kb-refresh retrofit (heavy tail; after core `/ship` is live)

### Task 10: `fleet-gather.sh` onto the shared dispatch + WSL discovery

**Files:**
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh`

**Interfaces:**
- Consumes: `fd_probe`, `fd_run`, `fd_wsl_hosts` from `../../lib/fleet-dispatch.sh` (relative to the kb-refresh skill dir).
- Produces: `fleet-gather.sh` harvests digests from Windows-native clones (via Git Bash) and from discovered WSL hosts.

> This is the largest, least-verifiable retrofit: `fleet-gather.sh` has ~6
> dispatch sites (probe, mkdir, push distiller, seed state, distill, merge-back,
> pull digests — `fleet-gather.sh:124-166`), each nested-quoted `bash -lc "'…'"`,
> and it runs `set -euo pipefail`. It is deliberately sequenced AFTER the core
> `/ship` path lands and is live-verified (Tasks 4, 9), so the primary goal is
> not gated on this. Retrofit one site at a time; the tar-based digest pull and
> the distiller `cat >` push are the trickiest through Git Bash — verify each
> live against `desktop`.

- [ ] **Step 1: Source the helper**

Edit `agents/plugin/skills/kb-refresh/fleet-gather.sh`. After the `FLEET_JSON=` line, add:

```bash
# shellcheck source=../lib/fleet-dispatch.sh
. "$SKILL_DIR/../lib/fleet-dispatch.sh"
```

- [ ] **Step 2: Retrofit the reachability probe + cache-dir mkdir**

Replace the self-exclusion probe and cache-dir mkdir (currently `ssh -n "$alias" bash -lc "'hostname'"` / `bash -lc "'mkdir -p ~/.cache/kb-digests'"`) so Windows members use Git Bash. Because `detect_hosts` already yields `platform` per member, thread it through the run helpers. Use `fd_run` with a heredoc-less inline script:

```bash
    remote_live="$(printf 'hostname' | fd_run "$alias" "$platform" 2>/dev/null || true)"
    ...
    if ! printf 'mkdir -p ~/.cache/kb-digests' | fd_run "$alias" "$platform" >/dev/null 2>&1; then
```

- [ ] **Step 3: Retrofit the distiller push, state seed, distill run, merge-back, digest pull**

Convert each remaining `ssh "$alias" bash -lc "'…'" < file` / `| tar` site to `fd_run "$alias" "$platform"` with the file redirected onto `fd_run`'s stdin, and each `ssh -n … | tar xf -` to `fd_run "$alias" "$platform" <<<'…' | tar xf -`. Keep the remote-distill positional-arg contract (`bash -s -- <hostid> <nroots> …`) — `fd_run` already forwards positional args after platform.

> Each of these five sites is a separate 2–5-min edit; keep them individually
> reviewable. The digest pull (`tar cf -` on the remote → `tar xf -` locally)
> must run through Git Bash on Windows so it reads the Windows clone's cache —
> verify the tar round-trips (Step 5).

- [ ] **Step 4: Add WSL-host harvesting to the gather loop**

After the per-member harvest, for a windows member, iterate `fd_wsl_hosts "$alias" "$platform"` and harvest each `<nickname>.gg.ez` as a normal linux member (same distiller push / distill / pull). Factor the per-host harvest body into a shell function so the member loop and the WSL loop share it.

- [ ] **Step 5: LIVE verify kb-refresh against `desktop`**

Run one kb-refresh gather cycle from latitude (per the kb-refresh SKILL.md invocation). Expected: digests harvested from the Windows clone AND from `desktop-ubuntu26`, no `set -e` abort. Read `~/.cache/kb-digests/manifest.tsv` for distinct host rows.

- [ ] **Step 6: Commit**

```bash
git add agents/plugin/skills/kb-refresh/fleet-gather.sh
git commit -m "feat(kb-refresh): platform-aware dispatch + WSL harvest in fleet-gather"
```

---

## Phase 5 — Docs, memory, final end-to-end `/ship`

### Task 11: Docs & memory updates

**Files:**
- Modify: `agents/memory/global.md`
- Modify: `AGENTS.md`
- Modify: `provision/README.md`
- Modify: `.claude/memory/project.md`

**Interfaces:** none (documentation).

- [ ] **Step 1: Rewrite the stale global-memory bullets**

In `agents/memory/global.md`, find the 2026-07-21 fleet-reachability bullets (the "Windows-native clone must be pulled manually" / "reached by neither mechanism" claims) and replace with the new model: `/ship` reaches every host's `$HOME/machines` clone — Windows-native (via Git Bash dispatch keyed on `platform: windows`) and every self-declared WSL host (discovered via `wsl -l` + `fleet.local.json`, pulled at `<nickname>.gg.ez`). WSL hosts are self-declaring, never in `fleet.json`. Half-provision a WSL host with `just provision-wsl <nickname>`.

- [ ] **Step 2: Update `AGENTS.md`**

In `AGENTS.md` §"Fleet networking / tailnet architecture" and §"Two-layer hostname convention", add: self-declared WSL hosts are first-class fleet hosts that carry a gitignored `fleet.local.json` (nickname + `fleet:true`) and are discovered by their Windows parent; they are reached by `<nickname>.gg.ez`, not by a `fleet.json` entry. Document `provision-wsl` and `fleet-dispatch.sh`.

- [ ] **Step 3: Update `provision/README.md`**

Document the `provision-wsl <nickname>` flow (chain: `tailscale-wsl.sh → ssh-wsl.sh → linux.sh → fleet-local.sh`), the `fleet.local.json` self-declaration, and that `/ship`/kb-refresh now discover WSL hosts automatically.

- [ ] **Step 4: Update `.claude/memory/project.md`**

Add a bullet under the fleet-network heading: dispatch is platform-aware via `agents/plugin/skills/lib/fleet-dispatch.sh`; `/ship` and kb-refresh reach Windows-native + self-declared WSL clones; the `/mnt/c` root was removed and `machines` is located canonical-path-first.

- [ ] **Step 5: Commit**

```bash
git add agents/memory/global.md AGENTS.md provision/README.md .claude/memory/project.md
git commit -m "docs(fleet): reachability model — Windows + self-declared WSL clones"
```

### Task 12: Final end-to-end `/ship`

No code.

- [ ] **Step 1: Run `/ship` for a trivial commit and confirm the whole fleet advances**

Make a trivial no-op commit (or ship the doc commit from Task 11) and run the full `/ship` flow. Expected: the table shows every reachable host advancing to the pushed HEAD — `latitude` (self, skipped), `desktop` (Windows clone), `desktop-ubuntu26` (WSL clone), `server` (Windows clone), `hub` — each `OK …` or a legitimate `SKIP` with a known reason. Read the table verbatim to the user.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Decision 1 (Windows dispatch = Git Bash) → Tasks 1, 2, 4.
- Decision 2 (shared dispatch helper) → Task 1 (+ consumed by 2, 5, 10).
- Decision 3 (selfpull timer unchanged) → no code; `linux.sh` timer left intact (Task 6 adds only the trust step).
- Decision 4 (WSL self-declare, parent enumerates) → Tasks 3, 5, 7.
- Decision 5 (`$HOME/machines` canonical) → Global Constraints; enforced in Tasks 2, 3, 7.
- Decision 6 (multi-clone topology) → Tasks 2, 5 (Windows clone + WSL clones both pulled).
- Decision 7 (canonical path, drop `/mnt/c`, keep root scan for others) → Task 2 (canonical-first + scan-fallback; server-at-`$HOME/my/machines` test stays green).
- Decision 8 (no frozen usernames) → Global Constraints; `$HOME`-relative throughout.
- Design §Membership tiers → Tasks 3 (marker), 5 (discovery).
- Design §Shared dispatch helper → Task 1; live `&`+stdin risk → Task 4 fallback.
- Design §Discovery+pull flow → Task 5.
- Design §Half-provision command → Task 7 (chain), 6 (linux.sh trust), 3 (fleet-local.sh).
- Design §SSH reachability (`Host *.gg.ez`) → Task 8.
- Design §Docs/memory/tests → Task 11 (docs/memory); tests folded into Tasks 1–3, 5, 8; live verification → Tasks 4, 9, 12.

**Placeholder scan:** no TBD/TODO; every code step shows the actual code; live-only tasks (4, 9, 12) are explicitly no-code verification gates with exact commands + expected output.

**Type/name consistency:** `fd_probe`/`fd_run`/`fd_wsl_hosts` signatures match across Tasks 1, 5, 2, 10. `run_member` is `<alias> <platform> <target>` in Task 2 and used that way in Task 5. `FLEET_GITBASH`/`FLEET_GITBASH_X86`/`MAGICDNS_SUFFIX` names are consistent. `fleet-local.sh` flags (`--nickname/--platform/--repo`) match between Tasks 3 and 7.

**Known live-only risks carried forward (not gaps):** the exact PowerShell `&`+stdin form (Task 4 fallback), the `wsl -l -q` encoding + `$HOME` expansion quoting (Tasks 5, 9), and the fleet-gather tar-through-Git-Bash round-trip (Task 10) can only be nailed down on `desktop`. Each is sequenced so a failure is caught before downstream work depends on it.
