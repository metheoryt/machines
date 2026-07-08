# Fleet Provisioner — Phase 4: `repos` role executor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `repos` the fleet's third real role executor — a **pure wrap** of the existing `provision/repos.sh` behind the Phase 2 dispatcher (dry-run preview + per-role apply confirm), exactly like `agents`, except `repos` is **not** a NixOS no-op.

**Architecture:** Add two per-platform executors under `provision/roles/` (`repos.sh` → `role_repos`, `repos.ps1` → `Invoke-RoleRepos`) that execute `provision/repos.sh` with **no group args** (default = all groups), `DRY_RUN=1` for dry-run. Register `repos` in `provision.ps1`'s `$RoleExecutors` map. `provision.sh` needs **no change** (its Phase 2 `roles/*.sh` loop + generic `role_<name>` dispatch already picks up `role_repos`). `provision/repos.sh` is **unchanged**.

**Tech Stack:** bash + Git Bash; PowerShell 7; `gh` + `fzf` (runtime prereqs of `repos.sh`, not installed by the executor); `just`. Verified on WSL Ubuntu-26.04 and this Windows box (g614jv, pwsh + Git Bash).

**Design spec:** `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase4-repos-executor-design.md`.

## Global Constraints

- **This is glue/config, not unit-testable app code.** "Tests" are `bash -n`, `pwsh` parse, and **smoke runs** with exact expected output — never pytest-style units (matches the parent spec and the Phase 1–3 plans).
- **Pure wrap:** `provision/repos.sh` is NOT edited. The executors only invoke it (`bash "$repo/provision/repos.sh"` / `DRY_RUN=1 bash …`) with no positional args, so it defaults to all three groups (`my pure cyphy671`).
- **`repos` is NOT a NixOS no-op** (unlike `agents`/`dotfiles`). `role_repos` runs `repos.sh` on `nixos|wsl|debian`; only truly-unknown platforms skip. Cloning working repos isn't home-manager-managed.
- **Dry-run is accepted as non-inert:** `DRY_RUN=1 repos.sh` still queries `gh` (network) and transiently switches gh's active account (restored to `metheoryt` at the end); it clones nothing. Smokes therefore touch the live network/gh **when `gh` is installed**; when `gh` is absent, `repos.sh` warns and still exits 0 — smokes pass either way.
- **No auto-install** of `gh`/`fzf` — `repos.sh` degrades gracefully (warn + clone nothing). Prereqs are Runbook-documented.
- **Per-role apply confirm** is inherited from the Phase 2 dispatcher — Phase 4 adds no new confirm logic.
- **Commit frequently**, one task per commit. End every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **`*.sh` are pinned to LF** by `.gitattributes` (repo is `core.autocrlf=true`); new `.sh` files inherit it. Run bash smokes from WSL.
- **`-NonInteractive` hazard:** the PowerShell tool runs `-NonInteractive`, so `Read-Host` throws — drive any ps1 confirm-gate smoke via **Git Bash piped stdin** (`printf 'n\n…' | pwsh -NoProfile -File …`), NOT the PowerShell tool (Phase 2 gotcha).

## File Structure

- `provision/roles/repos.sh` — **new**. `role_repos <mode> <platform> <machine>`. Runs `provision/repos.sh` on nixos/wsl/debian; skips unknown platforms.
- `provision/roles/repos.ps1` — **new**. `Invoke-RoleRepos -Mode -Platform -Machine`. windows → run `repos.sh` under Git Bash; non-windows → skip.
- `provision/provision.ps1` — **modify** (one `$RoleExecutors` map entry).
- `provision/provision.sh` — **unchanged** (verified by smoke, not edited).
- `provision/repos.sh` — **unchanged** (wrapped as-is).

`fleet.json`, `provision/lib/*`, `provision/roles/{agents,dotfiles}.*`, `dotfiles/*`, and the `just provision` recipe are unchanged.

Reference (matching patterns to follow): `provision/roles/agents.sh` and `provision/roles/agents.ps1` — the `repos` executors are structurally the same wrap, minus the nixos no-op.

---

## Task 1: `provision/roles/repos.sh` — posix executor

**Files:**
- Create: `provision/roles/repos.sh`

**Interfaces:**
- Consumes: `provision/repos.sh` (existing, unchanged) via `bash "$repo/provision/repos.sh"`.
- Produces: `role_repos <mode> <platform> <machine>` — sourced by `provision.sh` (Task 3 verifies dispatch). `mode` ∈ {`dry-run`,`apply`}. nixos|wsl|debian ⇒ run `repos.sh` (`DRY_RUN=1` for dry-run), no group args; other ⇒ skip, return 0.

- [ ] **Step 1: Write the executor.**

```bash
# provision/roles/repos.sh — the `repos` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_repos.
#
# repos = your working repos cloned into the per-account home-dir layout by
# provision/repos.sh (host-agnostic; DRY_RUN-capable; interactive fzf select on
# apply). Wrapped here UNCHANGED. Unlike agents/dotfiles this is NOT a nixos
# no-op — cloning working repos is imperative and not home-manager-managed, so
# repos.sh runs on nixos too.

# role_repos <mode> <platform> <machine>
#   mode: dry-run | apply
role_repos() {
    local mode="$1" platform="$2" machine="$3"
    # repo root = two levels up from provision/roles/ .
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local script="$repo/provision/repos.sh"

    case "$platform" in
        nixos|wsl|debian)
            if [ ! -f "$script" ]; then
                echo "  repos: repos.sh not found at $script — is this repo cloned here?" >&2
                return 1
            fi
            # No group args => repos.sh defaults to all groups (my pure cyphy671);
            # interactive fzf select (apply) / dry-run listing is the per-box filter.
            if [ "$mode" = "apply" ]; then
                bash "$script"
            else
                DRY_RUN=1 bash "$script"
            fi
            ;;
        *)
            echo "  repos: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
```

- [ ] **Step 2: Syntax check.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash -n provision/roles/repos.sh && echo syntax-ok'`
Expected: `syntax-ok`.

- [ ] **Step 3: Smoke — unknown platform skips, return 0 (no repos.sh invoked).**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && source provision/roles/repos.sh && role_repos dry-run macos somebox; echo "exit=$?"'`
Expected: one line `  repos: no posix executor for platform 'macos' (skipped).`, then `exit=0`.

- [ ] **Step 4: Smoke — debian-branch direct call runs repos.sh in dry-run, clones NOTHING, exits 0.** No repos-role box is debian/wsl, so call the executor directly (as Phase 3 did for dotfiles). `repos.sh` dry-run clones nothing by construction; if `gh` is present it lists clonable repos, if absent it warns — either way exit 0.

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  source provision/roles/repos.sh
  role_repos dry-run debian testbox >/tmp/repos.out 2>&1; echo "exit=$?"
  grep -q "dry-run — nothing changed" /tmp/repos.out && echo "dry-run-marker-ok"
  # No clone commands were actually executed (dry-run prints "[dry-run] git clone" at most, never runs it):
  grep -Eq "^\s*git clone" /tmp/repos.out && echo "UNEXPECTED-REAL-CLONE" || echo "no-real-clone-ok"'
```
Expected: `exit=0`; `dry-run-marker-ok` (repos.sh prints `Done. (dry-run — nothing changed)`); `no-real-clone-ok`.

- [ ] **Step 5: Commit.**

```bash
git add provision/roles/repos.sh
git commit -m "fleet: add posix repos role executor (provision/roles/repos.sh)

role_repos wraps provision/repos.sh UNCHANGED: nixos/wsl/debian run it
(DRY_RUN=1 for dry-run), no group args (default = all groups; interactive fzf
select is the filter). NOT a nixos no-op — repo cloning isn't home-manager
managed. Third real role->executor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `provision/roles/repos.ps1` — windows executor

**Files:**
- Create: `provision/roles/repos.ps1`

**Interfaces:**
- Consumes: `provision/repos.sh` (existing, unchanged) run under Git Bash.
- Produces: `Invoke-RoleRepos -Mode <dry-run|apply> -Platform <p> -Machine <m>` — dot-sourced by `provision.ps1` (Task 3). windows ⇒ run `repos.sh` under Git Bash (`DRY_RUN` env toggled), throws on non-zero; non-windows ⇒ skip line.

- [ ] **Step 1: Write the executor.** (Near-verbatim copy of `Invoke-RoleAgents`, pointing at `repos.sh`, with no nixos special-case since repos is not a nixos no-op.)

```powershell
# provision/roles/repos.ps1 — the `repos` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleRepos.
#
# repos = your working repos cloned into the per-account home-dir layout by
# provision/repos.sh, run under Git Bash on Windows (repos.sh is a bash script).
# Wrapped UNCHANGED; interactive fzf select happens inside repos.sh on apply.

function Invoke-RoleRepos {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  repos: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    # repo root = two levels up from provision/roles/ . Forward-slash for Git Bash.
    $repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script = (Join-Path $repo 'provision/repos.sh') -replace '\\', '/'

    $bash = 'C:/Program Files/Git/bin/bash.exe'
    if (-not (Test-Path $bash)) {
        $cmd = Get-Command bash -ErrorAction SilentlyContinue
        if ($cmd) { $bash = $cmd.Source }
        else { Write-Warning "  repos: Git Bash not found (looked at 'C:/Program Files/Git/bin/bash.exe'). Install Git for Windows."; return }
    }
    if (-not (Test-Path $script)) { Write-Warning "  repos: repos.sh not found at $script"; return }

    if ($Mode -eq 'apply') { $env:DRY_RUN = $null } else { $env:DRY_RUN = '1' }
    try {
        & $bash $script
        if ($LASTEXITCODE -ne 0) { throw "repos.sh exited $LASTEXITCODE" }
    } finally {
        Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Parse check.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/roles/repos.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 3: Smoke — non-windows platform skips.**

Run (Windows pwsh): `pwsh -NoProfile -Command ". ./provision/roles/repos.ps1; Invoke-RoleRepos -Mode dry-run -Platform nixos -Machine latitude5520"`
Expected: one line `  repos: no Windows executor for platform 'nixos' (skipped).`

- [ ] **Step 4: Smoke — windows dry-run drives repos.sh under Git Bash, clones nothing.** Runs `DRY_RUN=1 repos.sh` on this box; if `gh` is present it lists clonable repos, if absent it warns — either way `repos.sh` ends with the dry-run marker and the function returns without throwing.

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command ". ./provision/roles/repos.ps1; Invoke-RoleRepos -Mode dry-run -Platform windows -Machine g614jv" 2>&1 |
  Tee-Object -Variable out | Out-Null
if ($out -match 'dry-run — nothing changed') { 'dry-run-marker-ok' } else { $out }
```
Expected: `dry-run-marker-ok`. (No real `git clone` runs; no throw.)

- [ ] **Step 5: Commit.**

```bash
git add provision/roles/repos.ps1
git commit -m "fleet: add windows repos role executor (provision/roles/repos.ps1)

Invoke-RoleRepos runs provision/repos.sh under Git Bash (DRY_RUN env toggled for
dry-run), throws on non-zero so the dispatcher flags it. Near-verbatim of the
agents ps1 wrap; non-windows = skip. repos.sh is wrapped UNCHANGED.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: register `repos` in `provision.ps1` + verify both launchers dispatch

**Files:**
- Modify: `provision/provision.ps1`
- (Verify only, no edit: `provision/provision.sh`)

**Interfaces:**
- Consumes: `Invoke-RoleRepos` (Task 2), `role_repos` (Task 1).
- Produces: both launchers dispatch the `repos` role through its executor under dry-run and the per-role apply confirm.

- [ ] **Step 1: Add the `repos` map entry in `provision.ps1`.** Find the `$RoleExecutors` map (contains `agents` + `dotfiles` after Phase 3):

```powershell
$RoleExecutors = @{
    'agents'   = { param($Mode, $Platform, $Machine) Invoke-RoleAgents   -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles' = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

Replace with (add the `repos` line; keep alignment):

```powershell
$RoleExecutors = @{
    'agents'   = { param($Mode, $Platform, $Machine) Invoke-RoleAgents   -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles' = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles -Mode $Mode -Platform $Platform -Machine $Machine }
    'repos'    = { param($Mode, $Platform, $Machine) Invoke-RoleRepos    -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

- [ ] **Step 2: Parse check `provision.ps1`.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/provision.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 3: Smoke — `provision.sh` auto-dispatches repos (NO edit needed), nixos box.** Confirms the Phase 2 generic dispatch picks up `role_repos`. Because nixos is now a run branch, this executes `DRY_RUN=1 repos.sh` in WSL (clones nothing; lists via gh, or warns if gh absent).

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  bash provision/provision.sh --machine latitude5520 >/tmp/pv.out 2>&1; echo "exit=$?"
  grep -q "▸ repos — plan:" /tmp/pv.out && echo "repos-dispatched-ok"
  grep -Eq "^\s*git clone" /tmp/pv.out && echo "UNEXPECTED-REAL-CLONE" || echo "no-real-clone-ok"'
```
Expected: `exit=0`; `repos-dispatched-ok` (dispatched through the executor, not the generic stub); `no-real-clone-ok`.

- [ ] **Step 4: Smoke — `provision.ps1` g614jv dry-run: agents + dotfiles + repos all preview.**

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command "./provision/provision.ps1 -Machine g614jv 2>&1 | Select-String 'agents - plan','dotfiles - plan','repos - plan'"
```
Expected: three lines — `> agents - plan:`, `> dotfiles - plan:`, `> repos - plan:` (repos dispatched via the map to the real executor).

- [ ] **Step 5: Smoke — ps1 apply-confirm gate for repos, answer "n" ⇒ skipped, rc=0.** Driven through Git Bash so `Read-Host` reads piped stdin (the PowerShell tool's `-NonInteractive` mode makes `Read-Host` throw — Phase 2 gotcha). Three executor-backed roles now (agents, dotfiles, repos) ⇒ three `n`s.

Run (Git Bash / Bash tool):
```bash
cd /c/Users/methe/machines
printf 'n\nn\nn\n' | pwsh -NoProfile -File ./provision/provision.ps1 -Machine g614jv -Apply
echo "rc=$?"
```
Expected: `agents`, `dotfiles`, and `repos` each show a `> <role> - preview:` block then `- <role> skipped.`; `rc=0`.

- [ ] **Step 6: Commit.**

```bash
git add provision/provision.ps1
git commit -m "fleet: dispatch repos role executor (provision.ps1 map entry)

Register 'repos' -> Invoke-RoleRepos in \$RoleExecutors. provision.sh needs no
change — its Phase 2 roles/*.sh loop + generic role_<name> dispatch already
pick up role_repos (verified by smoke). Third real role wired end-to-end.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Runbook (real-box validation — not fully session-verifiable here)

Real cloning needs `gh` (authenticated for every needed account: `metheoryt`,
`cyphy671`), `fzf` (for interactive selection), and the SSH aliases
(`github.com`, `github-cyphy`) configured on the box. Missing `gh`/`fzf` ⇒ the
role lists nothing / clones nothing and still exits 0.

- **Windows real apply (`g614jv`):** `provision.ps1 -Machine g614jv -Apply` from a
  **real terminal** (Windows Terminal / pwsh), answer `y` at the `repos` gate →
  per group, `fzf` multi-select the absent repos (TAB mark, ENTER clone, ESC none);
  legacy `~/gh/` clones are migrated into `~/my`, `~/cyphy671` first. The `pure`
  (work) group appears but is ignorable on this personal box.
- **NixOS real apply (`latitude5520`, `g16`):** `provision.sh --machine <m> --apply`
  from a real terminal, answer `y` → same interactive select on native Linux.
- **Boxes without the role (`vps`, `methe-server`):** `repos` is not in their
  `fleet.json` roles, so no repos step runs there — nothing to validate.

## Self-Review

- **Spec coverage:** §3 pure-wrap → Tasks 1/2 (no repos.sh edit); §4.1 posix executor (nixos/wsl/debian run, unknown skip) → Task 1; §4.2 windows executor (Git Bash, throws on non-zero, non-windows skip) → Task 2; §4.3 provision.ps1 map entry + provision.sh unchanged → Task 3; §7 testing discipline → each task's smokes; §8 Runbook (gh/fzf prereqs, interactive apply) → Runbook section; §9 out-of-scope (no repos.sh edit / no fleet.json repo_groups / no auto-install) → honored, no task. §2 no-args-default and non-inert dry-run are exercised in Task 1 Step 4 / Task 2 Step 4 / Task 3 Step 3.
- **Placeholder scan:** none — every step has literal code or an exact command + expected output. The gh/network dependency of dry-run is explicitly handled (smoke passes whether gh is present or absent, via the `dry-run — nothing changed` marker + `no-real-clone` check, not a gh-presence assumption).
- **Type/name consistency:** `role_repos` (Task 1) matches `provision.sh`'s `role_${role//-/_}` dispatch (unchanged Phase 2 code); `Invoke-RoleRepos` (Task 2) matches the `$RoleExecutors['repos']` scriptblock (Task 3). Modes are the literal strings `dry-run`/`apply` everywhere, matching the Phase 2 dispatcher contract. `repos.sh`'s dry-run end marker `Done. (dry-run — nothing changed)` (from `provision/repos.sh` line 120) is matched exactly in the smokes.
- **Stdin/`-NonInteractive` hazard handled:** Task 3 Step 5 drives the ps1 confirm gate via Git Bash piped stdin (carried forward from Phase 2/3), not the PowerShell tool.
- **Mutation safety:** every session smoke uses dry-run (or answers `n` at the gate), and `repos.sh` dry-run clones nothing by construction — verified by the `no-real-clone` grep, not just trust. Real interactive clones are Runbook-only.
```
