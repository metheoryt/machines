# Fleet Provisioner — Phase 3: `dotfiles` role executor (chezmoi) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `dotfiles` the fleet's second real role executor — chezmoi (in stateless `--source` mode over an in-repo source) manages a minimal seed (`~/.gitconfig`), wired behind the existing dispatcher with dry-run preview + per-role confirm, exactly like `agents`.

**Architecture:** Add an in-repo chezmoi source `machines/dotfiles/` with one templated file (`dot_gitconfig.tmpl`). Add per-platform executors under `provision/roles/` (`dotfiles.sh` for nixos/wsl/debian, `dotfiles.ps1` for windows) that auto-install chezmoi on apply, `chezmoi diff` for dry-run, `chezmoi apply` for apply. `provision.sh` needs **no change** (its Phase 2 `roles/*.sh` loop + generic `role_<name>` dispatch already pick up `role_dotfiles`); `provision.ps1` gets one new `$RoleExecutors` map entry.

**Tech Stack:** chezmoi (stateless `--source` mode, built-in `.chezmoi.os` templating); bash + `jq`; PowerShell 7; Git Bash; `just`. Verified on WSL Ubuntu-26.04 (bash+jq, chezmoi via official installer) and this Windows box (g614jv, pwsh + Git Bash; winget present, chezmoi absent).

**Design spec:** `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md`.

## Global Constraints

- **This is glue/config, not unit-testable app code.** "Tests" are `bash -n`, `pwsh` parse, and **smoke runs** with exact expected output — never pytest-style units (matches the parent spec and the Phase 1/2 plans).
- **chezmoi runs stateless:** every invocation passes `--source "$repo/dotfiles"`; no `chezmoi init`, no `~/.config/chezmoi` config file, no chezmoi-managed git. Updates come from `git pull` on `machines`.
- **NixOS `dotfiles` is a deliberate no-op** — print the home-manager-owned skip line; never run chezmoi there.
- **chezmoi auto-install is apply-only:** dry-run with chezmoi absent prints `~ would install chezmoi` and mutates nothing (installs nothing, diffs nothing). Apply installs via `get.chezmoi.io` → `~/.local/bin` (posix) or `winget twpayne.chezmoi` (windows).
- **Tracked template is a tooling-independent universal core.** Machine-/OS-/tooling-specific git settings (delta pager, `credential.credentialStore=dpapi`, git-lfs filter, work email) live in untracked `~/.gitconfig.local`, included last so they override. Never commit those to the template.
- **age secrets are OUT of scope** for Phase 3 (deferred to the secrets phase).
- **Per-role apply confirm** is inherited from the Phase 2 dispatcher — Phase 3 adds no new confirm logic.
- **Commit frequently**, one task per commit. End every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **`*.sh` are pinned to LF** by `.gitattributes` (repo is `core.autocrlf=true`); new `.sh` files inherit it. Run bash smokes from WSL (jq + chezmoi present); Git Bash on Windows lacks jq.

## File Structure

- `dotfiles/dot_gitconfig.tmpl` — **new**. chezmoi source for `~/.gitconfig` (templated). The universal core.
- `provision/roles/dotfiles.sh` — **new**. `role_dotfiles <mode> <platform> <machine>` + `_dotfiles_ensure_chezmoi`.
- `provision/roles/dotfiles.ps1` — **new**. `Invoke-RoleDotfiles -Mode -Platform -Machine`.
- `provision/provision.ps1` — **modify** (one map entry).
- `provision/provision.sh` — **unchanged** (verified by smoke, not edited).

`fleet.json`, `provision/lib/*`, `provision/roles/agents.*`, `agents/bootstrap.sh`, and the `just provision` recipe are unchanged.

---

## Task 1: `dotfiles/dot_gitconfig.tmpl` — the chezmoi source seed

**Files:**
- Create: `dotfiles/dot_gitconfig.tmpl`

**Interfaces:**
- Produces: an in-repo chezmoi source dir (`dotfiles/`) with a templated `~/.gitconfig`. Consumed by the executors (Tasks 2 & 3) via `--source`.

- [ ] **Step 1: Write the template.** Create `dotfiles/dot_gitconfig.tmpl` (chezmoi decodes `dot_` → leading `.`, `.tmpl` → templated):

```gitconfig
# ~/.gitconfig — managed by chezmoi (fleet-wide, tooling-independent core).
# Source: machines/dotfiles/dot_gitconfig.tmpl.
# Machine-/OS-/tooling-specific settings (work email, credential helper, delta
# pager, git-lfs filter, …) go in ~/.gitconfig.local (untracked), included last
# so they override. See the Runbook for this box's ~/.gitconfig.local seed.

[user]
	name = Maxim
	email = metheoryt@gmail.com

[init]
	defaultBranch = main

[merge]
	conflictStyle = zdiff3

[core]
	autocrlf = {{ if eq .chezmoi.os "windows" }}true{{ else }}input{{ end }}

[include]
	path = ~/.gitconfig.local
```

- [ ] **Step 2: Structure sanity check (no chezmoi needed).** Confirm the file has the universal stanzas and the OS-templated `autocrlf`, and does NOT leak the machine-specific settings.

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  f=dotfiles/dot_gitconfig.tmpl
  grep -q "email = metheoryt@gmail.com" "$f" && echo "user-ok"
  grep -q "conflictStyle = zdiff3" "$f" && echo "merge-ok"
  grep -q "autocrlf = {{ if eq .chezmoi.os \"windows\" }}true{{ else }}input{{ end }}" "$f" && echo "autocrlf-tmpl-ok"
  grep -q "path = ~/.gitconfig.local" "$f" && echo "include-ok"
  grep -Eq "delta|dpapi|filter \"lfs\"" "$f" && echo "LEAK: machine-specific in template" || echo "no-leak-ok"'
```
Expected: `user-ok`, `merge-ok`, `autocrlf-tmpl-ok`, `include-ok`, `no-leak-ok`.

- [ ] **Step 3: Commit.**

```bash
git add dotfiles/dot_gitconfig.tmpl
git commit -m "dotfiles: add chezmoi source seed (dot_gitconfig.tmpl)

Universal, tooling-independent git config core; OS-templated autocrlf; machine
specifics deferred to ~/.gitconfig.local via [include]. First file of the
in-repo chezmoi source (machines/dotfiles/).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `provision/roles/dotfiles.sh` — posix executor

**Files:**
- Create: `provision/roles/dotfiles.sh`

**Interfaces:**
- Consumes: `dotfiles/dot_gitconfig.tmpl` (Task 1) via `--source`.
- Produces: `role_dotfiles <mode> <platform> <machine>` — sourced by `provision.sh` (Task 4 verifies dispatch). `mode` ∈ {`dry-run`,`apply`}. nixos ⇒ skip line, return 0; wsl|debian ⇒ ensure chezmoi (apply installs, dry-run reports), then `chezmoi diff` (dry-run) / `chezmoi apply` (apply); other ⇒ skip, return 0. Also defines helper `_dotfiles_ensure_chezmoi <mode>`.

- [ ] **Step 1: Write the executor.**

```bash
# provision/roles/dotfiles.sh — the `dotfiles` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_dotfiles.
#
# dotfiles = cross-platform home config managed by chezmoi, sourced from
# machines/dotfiles/ (stateless --source mode; updates come via `git pull`, not
# `chezmoi update`). On nixos it is owned by home-manager, so the dispatcher
# must NOT run chezmoi there.

# _dotfiles_ensure_chezmoi <mode>: returns 0 if chezmoi is usable afterward.
# apply: install via get.chezmoi.io -> ~/.local/bin if missing. dry-run: if
# missing, print "would install" and return 1 (nothing to diff yet).
_dotfiles_ensure_chezmoi() {
    local mode="$1"
    command -v chezmoi >/dev/null 2>&1 && return 0
    if [ "$mode" = apply ]; then
        if ! command -v curl >/dev/null 2>&1; then
            echo "  dotfiles: chezmoi + curl both missing — cannot install chezmoi." >&2
            return 1
        fi
        echo "  dotfiles: installing chezmoi -> ~/.local/bin ..."
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" || return 1
        export PATH="$HOME/.local/bin:$PATH"
        command -v chezmoi >/dev/null 2>&1
        return
    fi
    echo "  ~ would install chezmoi (get.chezmoi.io -> ~/.local/bin)"
    return 1
}

# role_dotfiles <mode> <platform> <machine>
#   mode: dry-run | apply
role_dotfiles() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local src="$repo/dotfiles"

    case "$platform" in
        nixos)
            echo "  dotfiles: owned by home-manager on nixos — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian)
            if [ ! -d "$src" ]; then
                echo "  dotfiles: chezmoi source not found at $src — is this repo cloned here?" >&2
                return 1
            fi
            if ! _dotfiles_ensure_chezmoi "$mode"; then
                # dry-run + chezmoi absent already reported "would install"; nothing to diff.
                [ "$mode" = apply ] && return 1 || return 0
            fi
            if [ "$mode" = apply ]; then
                chezmoi apply --source "$src"
            else
                chezmoi diff --source "$src"
            fi
            ;;
        *)
            echo "  dotfiles: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
```

- [ ] **Step 2: Syntax check.**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash -n provision/roles/dotfiles.sh && echo syntax-ok'`
Expected: `syntax-ok`.

- [ ] **Step 3: Smoke — nixos no-op (no chezmoi invoked).**

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && source provision/roles/dotfiles.sh && role_dotfiles dry-run nixos latitude5520; echo "exit=$?"'`
Expected: one line containing `owned by home-manager on nixos`, `exit=0`.

- [ ] **Step 4: Smoke — dry-run with chezmoi ABSENT reports "would install", mutates nothing.** Scrub chezmoi from PATH and point HOME at a temp dir.

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  t=$(mktemp -d); h=$(mktemp -d)
  # PATH without any chezmoi; HOME redirected so nothing touches real config.
  env -i HOME="$h" PATH=/usr/bin:/bin bash -c "cd /mnt/c/Users/methe/machines; source provision/roles/dotfiles.sh; role_dotfiles dry-run debian vps" >/tmp/d.out 2>&1
  echo "exit=$?"; grep -q "would install chezmoi" /tmp/d.out && echo "would-install-ok"
  echo "files in home: $(find "$h" -type f | wc -l)"
  rm -rf "$t" "$h"'
```
Expected: `would-install-ok`; `files in home: 0` (nothing written).

- [ ] **Step 5: Install chezmoi in WSL for the real diff/apply smokes.** (One-time test setup; validates the same installer the executor uses.)

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'command -v chezmoi >/dev/null 2>&1 && { echo "already: $(chezmoi --version | head -1)"; exit 0; }
  command -v curl >/dev/null 2>&1 || { echo "curl missing — install curl in WSL first"; exit 1; }
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  "$HOME/.local/bin/chezmoi" --version | head -1'
```
Expected: a `chezmoi version …` line. (If this fails on network/curl, chezmoi diff/apply verification moves to the Runbook; the executor logic is still covered by Steps 3–4 and parse checks.)

- [ ] **Step 6: Smoke — template renders correctly (autocrlf=input on linux).**

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  export PATH="$HOME/.local/bin:$PATH"
  chezmoi execute-template < dotfiles/dot_gitconfig.tmpl >/tmp/rendered.gitconfig
  grep -q "autocrlf = input" /tmp/rendered.gitconfig && echo "autocrlf-linux-ok"
  grep -q "email = metheoryt@gmail.com" /tmp/rendered.gitconfig && echo "user-ok"
  grep -q "{{" /tmp/rendered.gitconfig && echo "UNRENDERED-TEMPLATE" || echo "fully-rendered-ok"'
```
Expected: `autocrlf-linux-ok`, `user-ok`, `fully-rendered-ok`.

- [ ] **Step 7: Smoke — dry-run diff (chezmoi present) shows the pending gitconfig, writes nothing; apply then writes it; converged re-run is empty.** HOME redirected to a temp dir so dest + chezmoi state are hermetic.

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  export PATH="$HOME/.local/bin:$PATH"
  h=$(mktemp -d)
  echo "== dry-run diff =="
  HOME="$h" bash -c "source provision/roles/dotfiles.sh; role_dotfiles dry-run debian vps" >/tmp/df.out 2>&1
  echo "gitconfig after dry-run: $([ -e "$h/.gitconfig" ] && echo EXISTS || echo none)"
  grep -q "gitconfig" /tmp/df.out && echo "diff-mentions-gitconfig-ok"
  echo "== apply =="
  HOME="$h" bash -c "source provision/roles/dotfiles.sh; role_dotfiles apply debian vps" >/tmp/ap.out 2>&1
  echo "gitconfig after apply: $([ -e "$h/.gitconfig" ] && echo EXISTS || echo none)"
  grep -q "autocrlf = input" "$h/.gitconfig" && echo "applied-content-ok"
  echo "== converged re-run =="
  HOME="$h" bash -c "source provision/roles/dotfiles.sh; role_dotfiles dry-run debian vps" >/tmp/df2.out 2>&1
  if [ -s /tmp/df2.out ]; then echo "re-run diff NONEMPTY:"; cat /tmp/df2.out; else echo "converged-empty-diff-ok"; fi
  rm -rf "$h"'
```
Expected: `gitconfig after dry-run: none`; `diff-mentions-gitconfig-ok`; `gitconfig after apply: EXISTS`; `applied-content-ok`; `converged-empty-diff-ok`.

- [ ] **Step 8: Commit.**

```bash
git add provision/roles/dotfiles.sh
git commit -m "fleet: add posix dotfiles role executor (provision/roles/dotfiles.sh)

role_dotfiles: nixos no-op (home-manager owns it); wsl/debian ensure chezmoi
(apply installs via get.chezmoi.io, dry-run reports 'would install') then
chezmoi diff/apply --source. Second real role->executor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `provision/roles/dotfiles.ps1` — windows executor

**Files:**
- Create: `provision/roles/dotfiles.ps1`

**Interfaces:**
- Consumes: `dotfiles/dot_gitconfig.tmpl` (Task 1) via `--source`.
- Produces: `Invoke-RoleDotfiles -Mode <dry-run|apply> -Platform <p> -Machine <m>` — dot-sourced by `provision.ps1` (Task 4). windows ⇒ ensure chezmoi (apply: `winget twpayne.chezmoi`, throws on failure; dry-run: report), then `chezmoi diff`/`apply --source`, throws on apply non-zero; nixos ⇒ skip line; other ⇒ skip line.

- [ ] **Step 1: Write the executor.**

```powershell
# provision/roles/dotfiles.ps1 — the `dotfiles` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleDotfiles.
#
# dotfiles = cross-platform home config managed by chezmoi, sourced from
# machines/dotfiles/ (stateless --source mode; updates via `git pull`).

function Invoke-RoleDotfiles {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  dotfiles: owned by home-manager on nixos — applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  dotfiles: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $src  = Join-Path $repo 'dotfiles'
    if (-not (Test-Path $src)) { Write-Warning "  dotfiles: chezmoi source not found at $src"; return }

    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        if ($Mode -eq 'apply') {
            Write-Host "  dotfiles: installing chezmoi (winget twpayne.chezmoi) ..."
            winget install --id twpayne.chezmoi -e --source winget --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "chezmoi install failed (winget exit $LASTEXITCODE)" }
            if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
                throw "chezmoi installed but not on PATH in this shell — re-run in a fresh shell."
            }
        } else {
            Write-Host "  ~ would install chezmoi (winget twpayne.chezmoi)"
            return
        }
    }

    if ($Mode -eq 'apply') {
        & chezmoi apply --source $src
        if ($LASTEXITCODE -ne 0) { throw "chezmoi apply exited $LASTEXITCODE" }
    } else {
        & chezmoi diff --source $src
    }
}
```

- [ ] **Step 2: Parse check.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/roles/dotfiles.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 3: Smoke — nixos no-op.**

Run (Windows pwsh): `pwsh -NoProfile -Command ". ./provision/roles/dotfiles.ps1; Invoke-RoleDotfiles -Mode dry-run -Platform nixos -Machine latitude5520"`
Expected: one line containing `owned by home-manager on nixos`.

- [ ] **Step 4: Smoke — windows dry-run with chezmoi ABSENT reports "would install", mutates nothing.** (chezmoi is not installed on g614jv.)

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command ". ./provision/roles/dotfiles.ps1; Invoke-RoleDotfiles -Mode dry-run -Platform windows -Machine g614jv"
```
Expected: one line `  ~ would install chezmoi (winget twpayne.chezmoi)`. (No winget invocation, no file writes.)

- [ ] **Step 5: Commit.**

```bash
git add provision/roles/dotfiles.ps1
git commit -m "fleet: add windows dotfiles role executor (provision/roles/dotfiles.ps1)

Invoke-RoleDotfiles ensures chezmoi (apply: winget twpayne.chezmoi; dry-run:
reports 'would install'), then chezmoi diff/apply --source; throws on apply
failure so the dispatcher flags it. nixos/other = skip.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: register `dotfiles` in `provision.ps1` + verify both launchers dispatch

**Files:**
- Modify: `provision/provision.ps1`
- (Verify only, no edit: `provision/provision.sh`)

**Interfaces:**
- Consumes: `Invoke-RoleDotfiles` (Task 3), `role_dotfiles` (Task 2).
- Produces: both launchers dispatch the `dotfiles` role through its executor under dry-run and the per-role apply confirm.

- [ ] **Step 1: Add the `dotfiles` map entry in `provision.ps1`.** Find the `$RoleExecutors` map (added in Phase 2):

```powershell
$RoleExecutors = @{
    'agents' = { param($Mode, $Platform, $Machine) Invoke-RoleAgents -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

Replace with:

```powershell
$RoleExecutors = @{
    'agents'   = { param($Mode, $Platform, $Machine) Invoke-RoleAgents   -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles' = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles -Mode $Mode -Platform $Platform -Machine $Machine }
}
```

- [ ] **Step 2: Parse check `provision.ps1`.**

Run (Windows pwsh): `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/provision.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`.

- [ ] **Step 3: Smoke — `provision.sh` auto-dispatches dotfiles (NO edit needed), nixos box.** Confirms the Phase 2 generic dispatch picks up `role_dotfiles`.

Run (WSL): `wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines && bash provision/provision.sh --machine latitude5520 2>&1 | grep -A1 "dotfiles"'`
Expected: a `▸ dotfiles — plan:` line followed by `dotfiles: owned by home-manager on nixos …` (dispatched through the executor, not the generic stub).

- [ ] **Step 4: Smoke — `provision.sh` debian box drives the real dotfiles executor.** (chezmoi present in WSL from Task 2 Step 5; HOME redirected.)

Run (WSL):
```bash
wsl -d Ubuntu-26.04 -e bash -lc 'cd /mnt/c/Users/methe/machines
  export PATH="$HOME/.local/bin:$PATH"; h=$(mktemp -d)
  HOME="$h" bash provision/provision.sh --machine vps >/tmp/pv.out 2>&1
  echo "exit=$?"; grep -q "▸ dotfiles — plan:" /tmp/pv.out && echo "dotfiles-dispatched-ok"
  echo "gitconfig written: $([ -e "$h/.gitconfig" ] && echo yes || echo no)"
  rm -rf "$h"'
```
Expected: `exit=0`; `dotfiles-dispatched-ok`; `gitconfig written: no` (dry-run mutates nothing).

- [ ] **Step 5: Smoke — `provision.ps1` g614jv dry-run: agents + dotfiles both preview.**

Run (Windows pwsh):
```powershell
pwsh -NoProfile -Command "./provision/provision.ps1 -Machine g614jv 2>&1 | Select-String 'dotfiles','would install chezmoi'"
```
Expected: a `> dotfiles - plan:` line and a `~ would install chezmoi` line (dotfiles dispatched via the map to the real executor).

- [ ] **Step 6: Smoke — ps1 apply-confirm gate for dotfiles, answer "n" ⇒ skipped, rc=0.** Driven through Git Bash so `Read-Host` reads piped stdin (the PowerShell tool's `-NonInteractive` mode makes `Read-Host` throw — Phase 2 gotcha).

Run (Git Bash / Bash tool):
```bash
cd /c/Users/methe/machines
printf 'n\nn\n' | pwsh -NoProfile -File ./provision/provision.ps1 -Machine g614jv -Apply
echo "rc=$?"
```
Expected: both `agents` and `dotfiles` show a `> <role> - preview:` block then `- <role> skipped.`; `rc=0`. (Two `n`s: one per executor-backed role.)

- [ ] **Step 7: Commit.**

```bash
git add provision/provision.ps1
git commit -m "fleet: dispatch dotfiles role executor (provision.ps1 map entry)

Register 'dotfiles' -> Invoke-RoleDotfiles in \$RoleExecutors. provision.sh
needs no change — its Phase 2 roles/*.sh loop + generic role_<name> dispatch
already pick up role_dotfiles (verified by smoke).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Runbook (real-box validation — not fully session-verifiable here)

Real `~/.gitconfig` on the Windows boxes and the VPS holds machine-specifics that the tracked template intentionally omits. **Before the first real apply on a box, seed its `~/.gitconfig.local`** so `chezmoi apply` doesn't drop them. For **g614jv** (this box), that content is:

```gitconfig
# ~/.gitconfig.local — machine-specific, NOT tracked by chezmoi.
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
[credential]
	credentialStore = dpapi
[filter "lfs"]
	required = true
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
```

(homeserver: same minus git-lfs if absent. vps: only what that box actually needs — likely none of delta/dpapi.)

- **Windows real apply (`g614jv`, `homeserver`):** `provision.ps1 -Machine <m> -Apply`, answer `y` at the dotfiles gate → chezmoi auto-installs via winget (may require a fresh shell for PATH), then `~/.gitconfig` is (re)written from the template; confirm `git config --global --list` still shows delta/credential (from `~/.gitconfig.local`) and `autocrlf=true`.
- **Debian real apply (`vps`):** after `git pull` on the VPS, `provision.sh --machine vps --apply`, answer `y` → chezmoi installs via `get.chezmoi.io`, `~/.gitconfig` rendered with `autocrlf=input`.
- **nixos (`latitude5520`/`g16`):** `provision.sh` (no args) shows the `dotfiles` home-manager-owned skip and applies nothing for that role.

## Self-Review

- **Spec coverage:** §2 source-in-repo + git-config seed → Task 1; §3 stateless `--source` (diff/apply) → Tasks 2/3; §2 auto-install-on-apply → `_dotfiles_ensure_chezmoi` (Task 2) + winget block (Task 3); §4 executors (nixos no-op / non-Nix chezmoi) → Tasks 2/3; §4 provision.sh unchanged + provision.ps1 map entry → Task 4; §6 testing discipline → each task's smokes + Runbook; §2 age-deferred / `~/.dotfiles`-retired → out of scope, no task (correct). §5 platform coverage (nixos no-op, windows/debian chezmoi) exercised across Tasks 2–4.
- **Placeholder scan:** none — every step has literal code or an exact command + expected output. Network-dependent chezmoi install (Task 2 Step 5) is called out with a Runbook fallback, not left vague.
- **Type/name consistency:** `role_dotfiles` (Task 2) matches `provision.sh`'s `role_${role//-/_}` dispatch (unchanged Phase 2 code); `Invoke-RoleDotfiles` (Task 3) matches the `$RoleExecutors['dotfiles']` scriptblock (Task 4). `_dotfiles_ensure_chezmoi` is defined and called only within Task 2. Modes are the literal strings `dry-run`/`apply` everywhere, matching the Phase 2 dispatcher contract.
- **Stdin/`-NonInteractive` hazard handled:** Task 4 Step 6 drives the ps1 confirm gate via Git Bash piped stdin (carried forward from Phase 2), not the PowerShell tool.
- **Mutation safety:** every session smoke redirects `HOME` (posix) or relies on chezmoi absence (windows) so no real `~/.gitconfig` is touched; real applies are Runbook-only and gated on seeding `~/.gitconfig.local` first.
