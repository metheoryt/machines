# Fleet Provisioner — Phase 2: `agents` role executor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `agents` role the first executor that actually mutates a box — a real `DRY_RUN` preview plus a per-role confirm gate — establishing the role→executor pattern every later phase reuses.

**Architecture:** Add a `DRY_RUN` mode to the existing `agents/bootstrap.sh` (detection runs, mutation doesn't). Add per-platform executors under `provision/roles/` (`agents.sh` for nixos/wsl/debian, `agents.ps1` for windows). Wire both launchers to dispatch to an executor when one exists (else keep the Phase 1 stub) and, under `--apply`, to preview → confirm per role → apply.

**Tech Stack:** bash + `jq`; PowerShell 7; Git Bash (Windows shells out to `bash.exe`); `just`. Verified on WSL Ubuntu-26.04 (bash+jq) and this Windows box (g614jv, pwsh + Git Bash).

**Design spec:** `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase2-agents-executor-design.md`.

## Global Constraints

- **This is glue/config, not unit-testable app code.** "Tests" are `bash -n`, `pwsh` parse, and **smoke runs** with exact expected output — never pytest-style units (matches the parent spec and the Phase 1 plan).
- **`bootstrap.sh` default behavior must stay byte-for-byte unchanged when `DRY_RUN` is unset.** `just agent-bootstrap`, the git-hook auto-refresh, and NixOS parity depend on it.
- **`DRY_RUN` set (non-empty) = zero mutation:** no `ln`, `mv`, `rm`, `mkdir -p`, no host-stub seeding, no `git config core.hooksPath`, no backup prune. Dry-run always exits 0.
- **NixOS `agents` is a deliberate no-op** — print the home-manager-owned skip line; never invoke `bootstrap.sh` there.
- **Per-role apply confirm** (`Apply <role>? [y/N]`), not one run-wide prompt. Decided 2026-07-08.
- **Commit frequently**, one task per commit. End every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **`*.sh` are pinned to LF** by `.gitattributes` (repo is `core.autocrlf=true`); new `.sh` files inherit it. Run bash smokes from WSL (jq present); Git Bash on Windows lacks jq.

## File Structure

- `agents/bootstrap.sh` — **modify**. Add `DRY_RUN` mode (guards + preview messages + `would_*` counters + dry-run summary).
- `provision/roles/agents.sh` — **new**. `role_agents <mode> <platform> <machine>` (nixos no-op / wsl+debian → bootstrap.sh).
- `provision/roles/agents.ps1` — **new**. `Invoke-RoleAgents -Mode -Platform -Machine` (windows → Git Bash bootstrap.sh).
- `provision/provision.sh` — **modify**. Source `roles/*.sh`; dispatch; per-role apply confirm.
- `provision/provision.ps1` — **modify**. Dot-source `roles/*.ps1`; dispatch via a role→scriptblock map; per-role apply confirm.

`fleet.json`, `provision/lib/fleet.sh`, `provision/lib/Fleet.psm1`, and the `just provision` recipe are unchanged.

---

## Task 1: `DRY_RUN` mode in `agents/bootstrap.sh`

**Files:**
- Modify: `agents/bootstrap.sh`

**Interfaces:**
- Produces: `bootstrap.sh` honoring `DRY_RUN` (non-empty ⇒ preview, no mutation, exit 0). Consumed by Tasks 2 & 3.

- [ ] **Step 1: Add `would_*` counters.** Find the counter init block:

```bash
linked=0
skipped=0
backed=0
failed=0
```

Replace with:

```bash
linked=0
skipped=0
backed=0
failed=0
would_link=0
would_backup=0
```

- [ ] **Step 2: Add a dry-run-aware `_mkdir` helper.** Immediately after the counter block from Step 1, add:

```bash
# In DRY_RUN, create no directories (detection below tolerates missing dirs).
_mkdir() { [ -n "${DRY_RUN:-}" ] || mkdir -p "$@"; }
```

- [ ] **Step 3: Route the top-level `mkdir -p "$CLAUDE_DIR"` through the guard.** This line sits ABOVE the counters (near the top, after `BAK_ROOT=`). Change:

```bash
mkdir -p "$CLAUDE_DIR"
```
to:
```bash
[ -n "${DRY_RUN:-}" ] || mkdir -p "$CLAUDE_DIR"
```

(It is above `_mkdir`'s definition, so inline the guard here.)

- [ ] **Step 4: Replace the remaining `mkdir -p` calls with `_mkdir`.** There are four below the helper — in `link_entries_into` (`mkdir -p "$dest_sub"`), and in the main body (`mkdir -p "$CLAUDE_DIR/memory"`, `mkdir -p "$CLAUDE_DIR/skills"`, and under the Codex block `mkdir -p "$CODEX_DIR"` and `mkdir -p "$CODEX_DIR/memory"`). Change each `mkdir -p` to `_mkdir`. (Leave the two inside `backup_target` and the host-stub seeder — those are handled in Steps 5 and 7.)

- [ ] **Step 5: Make `link()` dry-run aware.** Replace the whole `link()` function with:

```bash
# link <abs-src> <abs-dest>: symlink dest -> src, backing up any real target
# first and restoring it if the symlink can't be created. In DRY_RUN, detect
# and report what WOULD happen without touching anything.
link() {
  local src="$1" dest="$2"
  if [ ! -e "$src" ]; then
    printf '  ! missing in repo, skipping: %s\n' "$src"
    return
  fi
  # Already pointing at the repo file (possibly via a home-manager chain) — skip.
  if [ "$dest" -ef "$src" ]; then
    printf '  = already linked: %s\n' "$dest"
    skipped=$((skipped + 1))
    return
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      printf '  = already linked: %s\n' "$dest"
      skipped=$((skipped + 1))
      return
    fi
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would relink: %s -> %s\n' "$dest" "$src"
      would_link=$((would_link + 1))
      return
    fi
    rm -f "$dest"  # wrong/old symlink target — replace it
  elif [ -e "$dest" ]; then
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would back up + link: %s -> %s\n' "$dest" "$src"
      would_backup=$((would_backup + 1))
      would_link=$((would_link + 1))
      return
    fi
    backup_target "$dest" && backed=$((backed + 1))
  else
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would link: %s -> %s\n' "$dest" "$src"
      would_link=$((would_link + 1))
      return
    fi
  fi
  if ln -s "$src" "$dest" 2>/dev/null && [ -L "$dest" ]; then
    printf '  + linked: %s -> %s\n' "$dest" "$src"
    linked=$((linked + 1))
  else
    rm -f "$dest" 2>/dev/null  # clean up any partial entry
    restore_target "$dest"
    printf '  ✗ could not create symlink: %s\n' "$dest"
    failed=$((failed + 1))
  fi
}
```

- [ ] **Step 6: Guard the host-stub seeder AND its link.** Replace this block:

```bash
HOST_ID="$(host_id)"
host_src="$SRC_DIR/hosts/$HOST_ID.md"
if [ ! -e "$host_src" ]; then
  mkdir -p "$SRC_DIR/hosts"
  {
    printf '# Host: %s\n\n' "$HOST_ID"
    printf '<!--\nPer-host memory + instructions for this machine. Symlinked to\n'
    printf '~/.claude/host-memory.md and imported by ~/.claude/CLAUDE.md, so it loads ONLY\n'
    printf 'when the hostname matches. Tracked in git, synced everywhere, inert on other\n'
    printf 'hosts. Do NOT put secrets here.\n-->\n\n## Notes\n'
  } > "$host_src"
  printf '  + seeded host memory stub: %s\n' "$host_src"
fi
link "$host_src" "$CLAUDE_DIR/host-memory.md"
```

with:

```bash
HOST_ID="$(host_id)"
host_src="$SRC_DIR/hosts/$HOST_ID.md"
if [ ! -e "$host_src" ]; then
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would seed host memory stub: %s\n' "$host_src"
  else
    mkdir -p "$SRC_DIR/hosts"
    {
      printf '# Host: %s\n\n' "$HOST_ID"
      printf '<!--\nPer-host memory + instructions for this machine. Symlinked to\n'
      printf '~/.claude/host-memory.md and imported by ~/.claude/CLAUDE.md, so it loads ONLY\n'
      printf 'when the hostname matches. Tracked in git, synced everywhere, inert on other\n'
      printf 'hosts. Do NOT put secrets here.\n-->\n\n## Notes\n'
    } > "$host_src"
    printf '  + seeded host memory stub: %s\n' "$host_src"
  fi
fi
if [ -n "${DRY_RUN:-}" ] && [ ! -e "$host_src" ]; then
  printf '  ~ would link: %s -> (seeded stub)\n' "$CLAUDE_DIR/host-memory.md"
  would_link=$((would_link + 1))
else
  link "$host_src" "$CLAUDE_DIR/host-memory.md"
fi
```

- [ ] **Step 7: Guard the git-hooks install.** In `install_git_hooks`, replace the final `else` branch that runs `git config`:

```bash
  else
    git -C "$repo" config --local core.hooksPath "$hp" \
      && printf '  + git hooks installed (core.hooksPath -> %s)\n' "$hp"
  fi
```

with:

```bash
  elif [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would install git hooks (core.hooksPath -> %s)\n' "$hp"
  else
    git -C "$repo" config --local core.hooksPath "$hp" \
      && printf '  + git hooks installed (core.hooksPath -> %s)\n' "$hp"
  fi
```

- [ ] **Step 8: Guard the backup prune.** Replace:

```bash
# Prune empty backup dirs left behind by restores (keeps real backups).
[ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null
```

with:

```bash
# Prune empty backup dirs left behind by restores (keeps real backups).
[ -z "${DRY_RUN:-}" ] && [ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null
```

- [ ] **Step 9: Dry-run summary line.** Replace:

```bash
printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
  "$linked" "$skipped" "$backed" "$failed"
```

with:

```bash
if [ -n "${DRY_RUN:-}" ]; then
  printf '\n(dry-run) would-link=%d  would-back-up=%d  already-linked=%d\n' \
    "$would_link" "$would_backup" "$skipped"
else
  printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
    "$linked" "$skipped" "$backed" "$failed"
fi
```

- [ ] **Step 10: Syntax check.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash -n agents/bootstrap.sh && echo syntax-ok'`
Expected: `syntax-ok`.

- [ ] **Step 11: Smoke — dry-run mutates nothing.** Uses a throwaway config dir.

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d); DRY_RUN=1 CLAUDE_CONFIG_DIR="$t" bash agents/bootstrap.sh >/tmp/dry.out 2>&1
  echo "symlinks after dry-run: $(find "$t" -type l | wc -l)"
  grep -c "would link\|would relink\|would back up\|would seed" /tmp/dry.out | sed "s/^/would-lines: /"
  grep "(dry-run)" /tmp/dry.out
  rm -rf "$t"'
```
Expected: `symlinks after dry-run: 0`; `would-lines:` ≥ 1; a `(dry-run) would-link=… would-back-up=… already-linked=…` summary.

- [ ] **Step 12: Smoke — default still links; converged re-run is clean.**

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d)
  CLAUDE_CONFIG_DIR="$t" bash agents/bootstrap.sh >/tmp/apply.out 2>&1
  echo "symlinks after apply: $(find "$t" -type l | wc -l)"
  DRY_RUN=1 CLAUDE_CONFIG_DIR="$t" bash agents/bootstrap.sh >/tmp/dry2.out 2>&1
  grep "(dry-run)" /tmp/dry2.out
  rm -rf "$t"'
```
Expected: `symlinks after apply:` ≥ 1 (default behavior intact); the converged dry-run summary shows `would-link=0  would-back-up=0` (only `already-linked=N`).

Note: the apply run calls `install_git_hooks`, which is idempotent — on this already-bootstrapped repo it prints `= git hooks already installed` and changes nothing. That is expected and touches no file content.

- [ ] **Step 13: Commit.**

```bash
git add agents/bootstrap.sh
git commit -m "agents: add DRY_RUN preview mode to bootstrap.sh

Detection runs, mutation does not (no ln/mv/mkdir/host-stub/git-config).
Default (unset) behavior unchanged. Enables a true dry-run for the fleet
provisioner's agents executor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `provision/roles/agents.sh` — posix executor

**Files:**
- Create: `provision/roles/agents.sh`

**Interfaces:**
- Consumes: `agents/bootstrap.sh` DRY_RUN (Task 1).
- Produces: `role_agents <mode> <platform> <machine>` — sourced by `provision.sh` (Task 4). `mode` ∈ {`dry-run`,`apply`}. nixos ⇒ prints skip, returns 0; wsl|debian ⇒ runs bootstrap (dry-run via `DRY_RUN=1`), returns bootstrap's exit code; other ⇒ prints skip, returns 0.

- [ ] **Step 1: Write the executor.**

```bash
# provision/roles/agents.sh — the `agents` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_agents.
#
# agents = the synced Claude/Codex config produced by agents/bootstrap.sh.
# On nixos it is owned by home-manager (claude.nix/codex.nix) and applied by
# `just switch`, so the dispatcher must NOT run bootstrap.sh there.

# role_agents <mode> <platform> <machine>
#   mode: dry-run | apply
role_agents() {
    local mode="$1" platform="$2" machine="$3"
    # repo root = two levels up from provision/roles/ .
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local boot="$repo/agents/bootstrap.sh"

    case "$platform" in
        nixos)
            echo "  agents: owned by home-manager (claude.nix/codex.nix) — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian)
            if [ ! -f "$boot" ]; then
                echo "  agents: bootstrap.sh not found at $boot — is this repo cloned here?" >&2
                return 1
            fi
            if [ "$mode" = "apply" ]; then
                bash "$boot"
            else
                DRY_RUN=1 bash "$boot"
            fi
            ;;
        *)
            echo "  agents: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
```

- [ ] **Step 2: Syntax check.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash -n provision/roles/agents.sh && echo syntax-ok'`
Expected: `syntax-ok`.

- [ ] **Step 3: Smoke — nixos no-op.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && source provision/roles/agents.sh && role_agents dry-run nixos latitude5520'`
Expected: one line containing `owned by home-manager`, exit 0, and NO bootstrap output.

- [ ] **Step 4: Smoke — debian dry-run runs bootstrap preview, mutates nothing.**

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d); CLAUDE_CONFIG_DIR="$t" bash -c "source provision/roles/agents.sh; role_agents dry-run debian vps" >/tmp/r.out 2>&1
  echo "symlinks: $(find "$t" -type l | wc -l)"; grep -c "(dry-run)" /tmp/r.out | sed "s/^/dryrun-summary: /"; rm -rf "$t"'
```
Expected: `symlinks: 0`; `dryrun-summary: 1`.

- [ ] **Step 5: Commit.**

```bash
git add provision/roles/agents.sh
git commit -m "fleet: add posix agents role executor (provision/roles/agents.sh)

role_agents: nixos no-op (home-manager owns it), wsl/debian run bootstrap.sh
(DRY_RUN=1 for dry-run). First real role->executor for the dispatcher.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `provision/roles/agents.ps1` — windows executor

**Files:**
- Create: `provision/roles/agents.ps1`

**Interfaces:**
- Consumes: `agents/bootstrap.sh` DRY_RUN (Task 1) via Git Bash.
- Produces: `Invoke-RoleAgents -Mode <dry-run|apply> -Platform <p> -Machine <m>` — dot-sourced by `provision.ps1` (Task 5). windows ⇒ runs bootstrap under Git Bash, THROWS on non-zero exit (so the caller can flag failure); nixos ⇒ skip line; other ⇒ skip line. Missing Git Bash / bootstrap ⇒ `Write-Warning` + return (does not hard-crash dry-run).

- [ ] **Step 1: Write the executor.**

```powershell
# provision/roles/agents.ps1 — the `agents` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleAgents.
#
# agents = the synced Claude/Codex config produced by agents/bootstrap.sh,
# run under Git Bash on Windows (bootstrap.sh is a bash script).

function Invoke-RoleAgents {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  agents: owned by home-manager — applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  agents: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    # repo root = two levels up from provision/roles/ . Forward-slash for Git Bash.
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $boot = (Join-Path $repo 'agents/bootstrap.sh') -replace '\\', '/'

    $bash = 'C:/Program Files/Git/bin/bash.exe'
    if (-not (Test-Path $bash)) {
        $cmd = Get-Command bash -ErrorAction SilentlyContinue
        if ($cmd) { $bash = $cmd.Source }
        else { Write-Warning "  agents: Git Bash not found (looked at 'C:/Program Files/Git/bin/bash.exe'). Install Git for Windows."; return }
    }
    if (-not (Test-Path $boot)) { Write-Warning "  agents: bootstrap.sh not found at $boot"; return }

    if ($Mode -eq 'apply') { $env:DRY_RUN = $null } else { $env:DRY_RUN = '1' }
    try {
        & $bash $boot
        if ($LASTEXITCODE -ne 0) { throw "bootstrap.sh exited $LASTEXITCODE" }
    } finally {
        Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Parse check.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/roles/agents.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 3: Smoke — nixos no-op (no Git Bash invoked).**

Run (Windows pwsh): `pwsh -NoProfile -Command ". ./provision/roles/agents.ps1; Invoke-RoleAgents -Mode dry-run -Platform nixos -Machine latitude5520"`
Expected: one line containing `owned by home-manager`.

- [ ] **Step 4: Smoke — windows dry-run runs bootstrap preview, mutates nothing.**

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command "$t=Join-Path $env:TEMP ('agtest_'+$PID); $env:CLAUDE_CONFIG_DIR=$t; . ./provision/roles/agents.ps1; Invoke-RoleAgents -Mode dry-run -Platform windows -Machine g614jv | Out-Null; $n=(Get-ChildItem -Recurse -Force $t -ErrorAction SilentlyContinue | Where-Object { $_.LinkType } | Measure-Object).Count; Write-Output ('symlinks: '+$n); Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue; Remove-Item Env:CLAUDE_CONFIG_DIR"
```
Expected: `symlinks: 0` (dry-run created no links in the temp config dir).

- [ ] **Step 5: Commit.**

```bash
git add provision/roles/agents.ps1
git commit -m "fleet: add windows agents role executor (provision/roles/agents.ps1)

Invoke-RoleAgents runs bootstrap.sh under Git Bash (DRY_RUN for preview),
throws on non-zero exit so the dispatcher flags failures. nixos/other = skip.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: dispatch + per-role apply confirm in `provision/provision.sh`

**Files:**
- Modify: `provision/provision.sh`

**Interfaces:**
- Consumes: `role_agents` from `provision/roles/agents.sh` (Task 2).
- Produces: a launcher that, per role, calls `role_<sanitized-name>` if defined (else the Phase 1 stub); under `--apply`, previews → `Apply <role>? [y/N]` → applies; exits with the worst executor status (0 unless an applied executor failed).

- [ ] **Step 1: Source the role executors.** After the existing `source "$HERE/lib/fleet.sh"` line, add:

```bash
# Role executors (each defines role_<name>). Optional — absent dir is fine.
for _rf in "$HERE"/roles/*.sh; do
    [ -e "$_rf" ] || continue
    # shellcheck source=/dev/null
    source "$_rf"
done
```

- [ ] **Step 2: Replace the role loop + trailing apply-stub.** Replace this whole block (from `echo "▸ Roles:"` through the final `fi`):

```bash
echo "▸ Roles:"
while IFS= read -r role; do
    if [ "$MODE" = "apply" ]; then
        echo "  ✗ $role — apply: not yet implemented (later phase)"
    else
        echo "  • $role — plan: would converge via the $platform executor for '$role'"
    fi
done < <(fleet_roles "$MACHINE")

if [ "$MODE" = "apply" ]; then
    echo "apply is not implemented in Phase 1; run without --apply." >&2
    exit 1
fi
```

with:

```bash
echo "▸ Roles:"
# Read roles into an array first so the confirm `read` below uses the terminal,
# not the role stream (a `while read < <(...)` loop would swallow the answer).
roles=()
while IFS= read -r role; do roles+=("$role"); done < <(fleet_roles "$MACHINE")

rc=0
for role in "${roles[@]}"; do
    fn="role_${role//-/_}"
    if declare -F "$fn" >/dev/null; then
        if [ "$MODE" = "apply" ]; then
            echo "  ▸ $role — preview:"
            "$fn" dry-run "$platform" "$MACHINE"
            printf "  Apply %s? [y/N] " "$role"
            read -r ans
            case "$ans" in
                [yY]|[yY][eE][sS])
                    echo "  ⟳ applying $role…"
                    if "$fn" apply "$platform" "$MACHINE"; then
                        echo "  ✓ $role applied."
                    else
                        echo "  ✗ $role failed." >&2
                        rc=1
                    fi
                    ;;
                *) echo "  – $role skipped." ;;
            esac
        else
            echo "  ▸ $role — plan:"
            "$fn" dry-run "$platform" "$MACHINE"
        fi
    else
        if [ "$MODE" = "apply" ]; then
            echo "  ✗ $role — apply: not yet implemented (skipped)"
        else
            echo "  • $role — plan: would converge via the $platform executor for '$role'"
        fi
    fi
done

exit $rc
```

- [ ] **Step 3: Syntax check.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash -n provision/provision.sh && echo syntax-ok'`
Expected: `syntax-ok`.

- [ ] **Step 4: Smoke — nixos machine: agents no-op, other roles stubbed.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash provision/provision.sh --machine latitude5520'`
Expected: under `agents` a line `owned by home-manager`; other roles print `• <role> — plan: would converge …`; exit 0.

- [ ] **Step 5: Smoke — debian machine: real agents preview, mutates nothing.**

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d); CLAUDE_CONFIG_DIR="$t" bash provision/provision.sh --machine vps >/tmp/p.out 2>&1
  echo "symlinks: $(find "$t" -type l | wc -l)"; grep -c "(dry-run)" /tmp/p.out | sed "s/^/agents-preview: /"; rm -rf "$t"'
```
Expected: `symlinks: 0`; `agents-preview: 1` (the agents executor ran bootstrap dry-run).

- [ ] **Step 6: Smoke — apply confirm gate, answer "n" ⇒ skipped, exit 0.**

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d); printf "n\n" | CLAUDE_CONFIG_DIR="$t" bash provision/provision.sh --machine vps --apply >/tmp/a.out 2>&1
  echo "rc=$?"; echo "symlinks: $(find "$t" -type l | wc -l)"; grep -q "agents skipped\|– agents skipped" /tmp/a.out && echo "skipped-ok"; rm -rf "$t"'
```
Expected: `rc=0`; `symlinks: 0`; `skipped-ok` (agents previewed, then skipped on "n").

- [ ] **Step 7: Commit.**

```bash
git add provision/provision.sh
git commit -m "fleet: dispatch role executors + per-role apply confirm (provision.sh)

Source provision/roles/*.sh; per role call role_<name> if defined, else the
stub. --apply now previews each executor, prompts Apply <role>? [y/N], applies
on yes; exits with the worst executor status. No longer a blanket safe-stub.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: dispatch + per-role apply confirm in `provision/provision.ps1`

**Files:**
- Modify: `provision/provision.ps1`

**Interfaces:**
- Consumes: `Invoke-RoleAgents` from `provision/roles/agents.ps1` (Task 3).
- Produces: the Windows launcher dispatching via a role→scriptblock map; under `-Apply`, previews → `Apply <role>? [y/N]` → applies; exits with the worst executor status.

- [ ] **Step 1: Dot-source the role executors + define the dispatch map.** After the existing `Import-Module (Join-Path $PSScriptRoot 'lib/Fleet.psm1') -Force` line, add:

```powershell
# Role executors (each defines Invoke-Role<Name>). Optional — absent dir is fine.
Get-ChildItem -Path (Join-Path $PSScriptRoot 'roles') -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# role name -> executor scriptblock. A map avoids function-name mangling for
# hyphenated roles (e.g. a future 'mesh-member').
$RoleExecutors = @{
    'agents' = { param($Mode, $Platform, $Machine) Invoke-RoleAgents -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

- [ ] **Step 2: Replace the role loop + trailing apply-stub.** Replace this block (from `foreach ($role in (Get-FleetRoles -Machine $Machine)) {` through the final `}` of the `if ($mode -eq 'apply') { Write-Error … exit 1 }`):

```powershell
foreach ($role in (Get-FleetRoles -Machine $Machine)) {
    if ($mode -eq 'apply') {
        Write-Host "  x $role - apply: not yet implemented (later phase)"
    } else {
        Write-Host "  * $role - plan: would converge via the $platform executor for '$role'"
    }
}

if ($mode -eq 'apply') {
    Write-Error "apply is not implemented in Phase 1; run without -Apply."
    exit 1
}
```

with:

```powershell
$rc = 0
foreach ($role in (Get-FleetRoles -Machine $Machine)) {
    if ($RoleExecutors.ContainsKey($role)) {
        $exec = $RoleExecutors[$role]
        if ($mode -eq 'apply') {
            Write-Host "  > $role - preview:"
            & $exec 'dry-run' $platform $Machine
            $ans = Read-Host "  Apply $role? [y/N]"
            if ($ans -match '^(y|yes)$') {
                Write-Host "  applying $role..."
                try {
                    & $exec 'apply' $platform $Machine
                    Write-Host "  $role applied."
                } catch {
                    Write-Warning "  $role failed: $_"
                    $rc = 1
                }
            } else {
                Write-Host "  - $role skipped."
            }
        } else {
            Write-Host "  > $role - plan:"
            & $exec 'dry-run' $platform $Machine
        }
    } else {
        if ($mode -eq 'apply') {
            Write-Host "  x $role - apply: not yet implemented (skipped)"
        } else {
            Write-Host "  * $role - plan: would converge via the $platform executor for '$role'"
        }
    }
}

exit $rc
```

- [ ] **Step 3: Parse check.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/provision.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 4: Smoke — g614jv dry-run: real agents preview.**

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command "$t=Join-Path $env:TEMP ('p_'+$PID); $env:CLAUDE_CONFIG_DIR=$t; ./provision/provision.ps1 -Machine g614jv | Out-Null; $n=(Get-ChildItem -Recurse -Force $t -ErrorAction SilentlyContinue | Where-Object { $_.LinkType } | Measure-Object).Count; Write-Output ('symlinks: '+$n); Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue; Remove-Item Env:CLAUDE_CONFIG_DIR"
```
Expected: `symlinks: 0` (agents previewed via Git Bash dry-run; nothing created).

- [ ] **Step 5: Smoke — apply confirm gate, answer "n" ⇒ skipped, exit 0.**

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command "$t=Join-Path $env:TEMP ('pa_'+$PID); $env:CLAUDE_CONFIG_DIR=$t; 'n' | ./provision/provision.ps1 -Machine g614jv -Apply; Write-Output ('rc='+$LASTEXITCODE); $n=(Get-ChildItem -Recurse -Force $t -ErrorAction SilentlyContinue | Where-Object { $_.LinkType } | Measure-Object).Count; Write-Output ('symlinks: '+$n); Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue; Remove-Item Env:CLAUDE_CONFIG_DIR"
```
Expected: a `> agents - preview:` block, then `- agents skipped.`, `rc=0`, `symlinks: 0`.

- [ ] **Step 6: Commit.**

```bash
git add provision/provision.ps1
git commit -m "fleet: dispatch role executors + per-role apply confirm (provision.ps1)

Dot-source provision/roles/*.ps1; dispatch via a role->scriptblock map; -Apply
previews each executor, prompts Apply <role>? [y/N], applies on yes; exits with
the worst executor status.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Runbook (real-box validation — not session-verifiable here)

- **Windows real apply (`g614jv`, `homeserver`):** `provision.ps1 -Machine <m> -Apply`, answer `y` at the agents gate → confirm `~/.claude` links are (re)created (needs Developer Mode / admin for symlinks, per bootstrap.sh's own warning).
- **Debian real apply (`vps`):** after `git pull` on the VPS, `provision.sh --machine vps --apply`, answer `y` → agents config linked. (Requires the `machines` repo cloned on the VPS.)
- **nixos:** confirm `provision.sh` (no args) on `latitude5520`/`g16` shows the `agents` home-manager-owned skip and applies nothing for that role.

## Self-Review

- **Spec coverage:** §3 DRY_RUN → Task 1; §4 executors → Tasks 2 (posix, incl. nixos no-op + wsl/debian) & 3 (windows); §5 dispatcher wiring + per-role apply confirm → Tasks 4 & 5; §6 smoke tests → each task's smoke steps + the Runbook for real-box items. §7 file list matches Tasks 1–5 exactly.
- **Placeholder scan:** none — every step has literal code or an exact command + expected output. Real-box-only checks are isolated to the Runbook, not plan steps.
- **Type/name consistency:** `role_agents` (Task 2) is the exact name `provision.sh` dispatches via `role_${role//-/_}` (Task 4); `Invoke-RoleAgents` (Task 3) matches the `$RoleExecutors['agents']` scriptblock (Task 5). `DRY_RUN` env contract (Task 1) is set identically by both executors (Tasks 2/3). Modes are the literal strings `dry-run`/`apply` everywhere.
- **Stdin hazard handled:** Task 4 reads roles into an array before the confirm `read` so the answer comes from the terminal, not the role stream (called out inline).
