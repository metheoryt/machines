# Fleet Provisioner — Phase 1: Manifest + Dispatcher Skeleton — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the single front door's skeleton — a committed `fleet.json` manifest plus per-platform launchers that detect/select the current machine, resolve its roles, and print a dry-run *plan* of what each role would do. No role is *applied* yet; apply-executors arrive in Phases 2–5.

**Architecture:** One JSON manifest (`fleet.json`) is the single source of truth for "who exists and what roles they carry." A thin launcher per platform — `provision.sh` (WSL/Linux/nixos), `provision.ps1` (Windows) — reads it through shared library code (`lib/fleet.sh` via `jq`, `lib/Fleet.psm1` via native `ConvertFrom-Json`), detects the host, offers an interactive confirm/select, then runs the uniform loop: **for each role → print its plan**. Nothing bootstrap-dependent: bash uses `jq` (present on WSL/nixos), Windows uses PowerShell's native JSON.

**Tech Stack:** JSON; bash + `jq`; PowerShell 7 (`ConvertFrom-Json`, `pwsh`); `just`; NixOS `builtins.fromJSON` (Phase 3, not here).

## Global Constraints

- **Manifest format is JSON** (`fleet.json`) — read natively everywhere: PowerShell `ConvertFrom-Json`, bash `jq`, Nix `builtins.fromJSON`. Never TOML (no native Windows parser on a fresh box).
- **Identity is per-OS-install**, matched by `detect.hostname` == the box's `hostname`. One physical box may be several machines (dual-boot + WSL).
- **Machine layer only.** No service deployment (Immich/Caddy/etc.). Those stay the `~/my/vps` repo's job.
- **Four platforms:** `nixos`, `windows`, `wsl`, `debian` (the VPS). Every role's executor is platform-specific.
- **Phase 1 applies nothing.** Every "executor" is a *plan string* only. `--apply` is accepted but, for every role, prints `apply: not yet implemented (Phase N)` and exits non-zero if invoked. This keeps the skeleton safe to run anywhere.
- **This is glue/config, not unit-testable app code.** "Tests" are: `jq` / `ConvertFrom-Json` parse, `bash -n`, `pwsh -NoProfile` parse, and **smoke runs** asserting correct host detection + role listing. Do NOT invent pytest-style unit tests.
- **Commit frequently**, one task per commit. End every commit message with the fleet's `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer (match repo convention).

## File Structure

- `fleet.json` — **new**, repo root. The manifest (machines → platform, mesh, roles, detect). Read by all launchers now and the flake in Phase 3.
- `provision/lib/fleet.sh` — **new**. Shared bash: locate + parse the manifest (`jq`), detect host, list roles/platform. Sourced by `provision.sh` and the `just` recipe.
- `provision/lib/Fleet.psm1` — **new**. Shared PowerShell module: same surface via `ConvertFrom-Json`. Imported by `provision.ps1`.
- `provision/provision.sh` — **new**. WSL/Linux/nixos launcher: detect → confirm/select → dry-run plan loop.
- `provision/provision.ps1` — **new**. Windows launcher: same flow in PowerShell.
- `justfile` — **modify**. Add a `provision` recipe (the nixos-side entry point → `provision.sh`).

Role→executor mapping lives in the shared libs as a plain lookup for now (Phase 1 only needs the *plan string*); a richer role system is a later phase.

---

## Task 1: The `fleet.json` manifest

**Files:**
- Create: `fleet.json`

**Interfaces:**
- Produces: the manifest object `{ "machines": { "<name>": { platform, mesh:{ip,role}, roles:[...], detect:{hostname} } } }` consumed by Tasks 2–6.

- [ ] **Step 1: Write the manifest.** Hostnames are the real values verified 2026-07-08 (`hostname` on each box; homeserver reports `methe-server`, the VPS reports `27608`).

```json
{
  "machines": {
    "latitude5520": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.8", "role": "member" },
      "roles": ["base", "mesh-member", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client"],
      "detect": { "hostname": "latitude5520" }
    },
    "g16": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.6", "role": "member" },
      "roles": ["base", "mesh-member", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client"],
      "detect": { "hostname": "g16" }
    },
    "g614jv": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.6", "role": "member" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "g614jv" }
    },
    "homeserver": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.2", "role": "member" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client"],
      "detect": { "hostname": "methe-server" }
    },
    "vps": {
      "platform": "debian",
      "mesh": { "ip": "10.0.0.1", "role": "hub" },
      "roles": ["base", "mesh-hub", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
  }
}
```

- [ ] **Step 2: Validate it parses (jq).**

Run: `jq -e '.machines | keys' fleet.json`
Expected: prints the 5 machine names, exit 0.

- [ ] **Step 3: Validate every machine has the required keys.**

Run:
```bash
jq -e '.machines | to_entries | all(.value | has("platform") and has("roles") and has("detect"))' fleet.json
```
Expected: `true`, exit 0.

- [ ] **Step 4: Commit.**

```bash
git add fleet.json
git commit -m "fleet: add fleet.json manifest (machines, platforms, roles, detect)"
```

---

## Task 2: Shared bash library `provision/lib/fleet.sh`

**Files:**
- Create: `provision/lib/fleet.sh`
- Test: inline smoke (Step 2/6 below)

**Interfaces:**
- Consumes: `fleet.json` (Task 1).
- Produces (sourced functions, used by Tasks 4 & 6):
  - `fleet_manifest_path` → echoes absolute path to `fleet.json`.
  - `fleet_machines` → echoes machine names, one per line.
  - `fleet_detect` → echoes the machine name whose `detect.hostname` equals `$(hostname)`, or empty + return 1.
  - `fleet_platform <machine>` → echoes that machine's `platform`.
  - `fleet_roles <machine>` → echoes its roles, one per line.

- [ ] **Step 1: Write the library.**

```bash
# provision/lib/fleet.sh — shared manifest helpers (source me; do not execute).
# Requires: jq. Consumers: provision.sh, the `just provision` recipe.

# Repo root = two levels up from this file (provision/lib/ -> repo).
_fleet_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

fleet_manifest_path() { echo "$(_fleet_lib_dir)/../../fleet.json"; }

fleet_machines() {
    jq -r '.machines | keys[]' "$(fleet_manifest_path)"
}

# Echo the machine whose detect.hostname matches this box; return 1 if none.
fleet_detect() {
    local h; h="$(hostname)"
    local m
    m="$(jq -r --arg h "$h" \
        '.machines | to_entries[] | select(.value.detect.hostname == $h) | .key' \
        "$(fleet_manifest_path)")"
    if [ -z "$m" ]; then return 1; fi
    echo "$m"
}

fleet_platform() {
    jq -r --arg m "$1" '.machines[$m].platform' "$(fleet_manifest_path)"
}

fleet_roles() {
    jq -r --arg m "$1" '.machines[$m].roles[]' "$(fleet_manifest_path)"
}
```

- [ ] **Step 2: Syntax check.**

Run: `bash -n provision/lib/fleet.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Smoke — machines list.**

Run: `bash -c 'source provision/lib/fleet.sh; fleet_machines'`
Expected: 5 lines (`latitude5520 g16 g614jv homeserver vps`, order per jq).

- [ ] **Step 4: Smoke — roles lookup.**

Run: `bash -c 'source provision/lib/fleet.sh; fleet_roles homeserver'`
Expected: includes `backup-hub` and `ssh-server`.

- [ ] **Step 5: Smoke — platform lookup.**

Run: `bash -c 'source provision/lib/fleet.sh; fleet_platform vps'`
Expected: `debian`.

- [ ] **Step 6: Smoke — detect returns empty+1 on an unknown host** (this box may or may not be in the manifest; assert the contract, not a specific name).

Run: `bash -c 'source provision/lib/fleet.sh; HOSTNAME_OVERRIDE=nope; hostname() { echo nonexistent-host; }; export -f hostname; fleet_detect; echo "rc=$?"'`
Expected: prints only `rc=1` (empty machine, return 1).

- [ ] **Step 7: Commit.**

```bash
git add provision/lib/fleet.sh
git commit -m "fleet: add shared bash manifest lib (detect/platform/roles)"
```

---

## Task 3: Shared PowerShell module `provision/lib/Fleet.psm1`

**Files:**
- Create: `provision/lib/Fleet.psm1`

**Interfaces:**
- Consumes: `fleet.json` (Task 1).
- Produces (exported functions, used by Task 5), mirroring Task 2:
  - `Get-FleetManifest` → parsed object (hashtable/PSCustomObject).
  - `Get-FleetMachines` → machine name strings.
  - `Get-FleetDetected` → the machine name matching `$env:COMPUTERNAME` (case-insensitive), or `$null`.
  - `Get-FleetPlatform -Machine <name>` → platform string.
  - `Get-FleetRoles -Machine <name>` → role strings.

- [ ] **Step 1: Write the module.**

```powershell
# provision/lib/Fleet.psm1 — shared manifest helpers for Windows.
# Uses native ConvertFrom-Json (no jq needed). Imported by provision.ps1.

function Get-FleetManifestPath {
    Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'fleet.json'
}

function Get-FleetManifest {
    Get-Content -Raw (Get-FleetManifestPath) | ConvertFrom-Json
}

function Get-FleetMachines {
    (Get-FleetManifest).machines.PSObject.Properties.Name
}

function Get-FleetDetected {
    $host_ = $env:COMPUTERNAME
    $machines = (Get-FleetManifest).machines
    foreach ($p in $machines.PSObject.Properties) {
        if ($p.Value.detect.hostname -ieq $host_) { return $p.Name }
    }
    return $null
}

function Get-FleetPlatform {
    param([Parameter(Mandatory)] [string] $Machine)
    (Get-FleetManifest).machines.$Machine.platform
}

function Get-FleetRoles {
    param([Parameter(Mandatory)] [string] $Machine)
    (Get-FleetManifest).machines.$Machine.roles
}

Export-ModuleMember -Function Get-FleetManifest, Get-FleetMachines, `
    Get-FleetDetected, Get-FleetPlatform, Get-FleetRoles
```

- [ ] **Step 2: Parse check (no execution of side effects).**

Run: `pwsh -NoProfile -Command "$null = [scriptblock]::Create((Get-Content -Raw provision/lib/Fleet.psm1)); 'ok'"`
Expected: `ok` (parses without syntax error).

- [ ] **Step 3: Smoke — import + machines.**

Run: `pwsh -NoProfile -Command "Import-Module ./provision/lib/Fleet.psm1; Get-FleetMachines"`
Expected: the 5 machine names.

- [ ] **Step 4: Smoke — roles + platform.**

Run: `pwsh -NoProfile -Command "Import-Module ./provision/lib/Fleet.psm1; Get-FleetPlatform -Machine vps; (Get-FleetRoles -Machine homeserver) -join ','"`
Expected: `debian` then a list containing `backup-hub`.

- [ ] **Step 5: Commit.**

```bash
git add provision/lib/Fleet.psm1
git commit -m "fleet: add shared PowerShell manifest module (Windows)"
```

---

## Task 4: The bash launcher `provision/provision.sh`

**Files:**
- Create: `provision/provision.sh`

**Interfaces:**
- Consumes: `provision/lib/fleet.sh` (Task 2).
- Produces: an executable that prints the resolved machine + a per-role dry-run plan. Flags: `--dry-run` (default), `--apply` (Phase-1 stub), `--machine <name>` (skip detection).

- [ ] **Step 1: Write the launcher.**

```bash
#!/usr/bin/env bash
# provision/provision.sh — fleet front door (WSL / Linux / nixos).
# Phase 1: detect/select the machine and PRINT the plan. Applies nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision/lib/fleet.sh
source "$HERE/lib/fleet.sh"

MODE="dry-run"; MACHINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --apply)   MODE="apply" ;;
        --machine) MACHINE="${2:-}"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Resolve the machine: explicit --machine, else detect, else prompt to pick.
if [ -z "$MACHINE" ]; then
    if MACHINE="$(fleet_detect)"; then
        echo "▸ Detected this host as: $MACHINE"
    else
        echo "! Could not auto-detect this host ($(hostname)). Choose one:" >&2
        select m in $(fleet_machines); do MACHINE="$m"; break; done
    fi
fi
if [ -z "$MACHINE" ]; then echo "no machine selected" >&2; exit 2; fi

platform="$(fleet_platform "$MACHINE")"
echo "▸ Machine: $MACHINE   platform: $platform   mode: $MODE"
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

- [ ] **Step 2: Make executable + syntax check.**

Run: `chmod +x provision/provision.sh && bash -n provision/provision.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Smoke — explicit machine, dry-run plan.**

Run: `bash provision/provision.sh --machine homeserver`
Expected: prints `Machine: homeserver  platform: windows  mode: dry-run` and a `• backup-hub — plan: ...` line, exit 0.

- [ ] **Step 4: Smoke — apply is a safe stub.**

Run: `bash provision/provision.sh --machine vps --apply; echo "rc=$?"`
Expected: prints `✗ base — apply: not yet implemented ...` lines and `rc=1`.

- [ ] **Step 5: Commit.**

```bash
git add provision/provision.sh
git commit -m "fleet: add provision.sh launcher (detect/select + dry-run plan)"
```

---

## Task 5: The PowerShell launcher `provision/provision.ps1`

**Files:**
- Create: `provision/provision.ps1`

**Interfaces:**
- Consumes: `provision/lib/Fleet.psm1` (Task 3).
- Produces: the Windows front door, same behavior/flags as Task 4 (`-DryRun` default, `-Apply` stub, `-Machine <name>`).

- [ ] **Step 1: Write the launcher.**

```powershell
#!/usr/bin/env pwsh
# provision/provision.ps1 — fleet front door (Windows).
# Phase 1: detect/select the machine and PRINT the plan. Applies nothing.
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $Machine
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Fleet.psm1') -Force

$mode = if ($Apply) { 'apply' } else { 'dry-run' }

if (-not $Machine) {
    $Machine = Get-FleetDetected
    if ($Machine) {
        Write-Host "> Detected this host as: $Machine"
    } else {
        Write-Warning "Could not auto-detect this host ($env:COMPUTERNAME). Choose one:"
        $all = @(Get-FleetMachines)
        for ($i = 0; $i -lt $all.Count; $i++) { Write-Host "  [$i] $($all[$i])" }
        $sel = Read-Host "index"
        $Machine = $all[[int]$sel]
    }
}
if (-not $Machine) { Write-Error "no machine selected"; exit 2 }

$platform = Get-FleetPlatform -Machine $Machine
Write-Host "> Machine: $Machine   platform: $platform   mode: $mode"
Write-Host "> Roles:"
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

- [ ] **Step 2: Parse check.**

Run: `pwsh -NoProfile -Command "$null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./provision/provision.ps1),[ref]$null,[ref]$null); 'ok'"`
Expected: `ok`, no parse errors.

- [ ] **Step 3: Smoke — explicit machine, dry-run.**

Run: `pwsh -NoProfile -File ./provision/provision.ps1 -Machine homeserver`
Expected: prints `Machine: homeserver   platform: windows   mode: dry-run` and a `* backup-hub - plan: ...` line.

- [ ] **Step 4: Smoke — apply stub exits non-zero.**

Run: `pwsh -NoProfile -File ./provision/provision.ps1 -Machine g614jv -Apply; "rc=$LASTEXITCODE"`
Expected: `x base - apply: not yet implemented ...` lines and `rc=1`.

- [ ] **Step 5: Commit.**

```bash
git add provision/provision.ps1
git commit -m "fleet: add provision.ps1 launcher (Windows detect/select + dry-run plan)"
```

---

## Task 6: The `just provision` recipe (nixos entry point)

**Files:**
- Modify: `justfile` (add one recipe near the other provisioning/utility recipes)

**Interfaces:**
- Consumes: `provision/provision.sh` (Task 4).
- Produces: `just provision` and `just provision --apply` on the NixOS boxes.

- [ ] **Step 1: Add the recipe.** Append after the existing recipes (match the file's style — it already uses `set windows-shell` + bash recipes). Add:

```just
# Fleet front door: detect this machine and show its provisioning plan.
# Pass extra args through, e.g. `just provision --machine vps` or `--apply`.
provision *ARGS:
    bash {{justfile_directory()}}/provision/provision.sh {{ARGS}}
```

- [ ] **Step 2: Validate the recipe parses and lists.**

Run: `just --list | grep -A0 provision`
Expected: shows the `provision` recipe with its doc comment.

- [ ] **Step 3: Smoke — runs the launcher through just.**

Run: `just provision --machine latitude5520`
Expected: prints `Machine: latitude5520   platform: nixos   mode: dry-run` and the role plan lines.

- [ ] **Step 4: Commit.**

```bash
git add justfile
git commit -m "fleet: add `just provision` recipe (nixos entry to the front door)"
```

---

## Runbook (post-merge validation on real boxes — not session-verifiable here)

- **On each box, confirm detection:** run `provision.sh` (nixos/WSL) or `provision.ps1` (Windows) with **no args** and verify it auto-detects the right machine name (i.e. `detect.hostname` matches `hostname`/`$env:COMPUTERNAME`). If a box reports a different hostname than the manifest lists, update its `detect.hostname` in `fleet.json`.
- **WSL note:** a WSL distro is its own machine; add a `wsl` entry to `fleet.json` with its `hostname` once one exists (none enumerated yet).

## Self-Review

- **Spec coverage (Phase 1 scope):** manifest as JSON single-source (Task 1) ✓; per-platform native reads — jq/bash (Task 2), ConvertFrom-Json (Task 3) ✓; identity by `detect.hostname` + interactive select (Tasks 2–5) ✓; uniform detect→resolve→plan loop (Tasks 4–5) ✓; four platforms carried incl. `debian` (Task 1) ✓; per-platform launchers incl. nixos `just` entry (Tasks 4–6) ✓; "applies nothing in Phase 1" enforced by the `--apply` stub (Tasks 4–5) ✓. Deferred to later phases (correctly out of Phase 1): chezmoi adoption, NixOS import generation, mesh reconcile, agenix, backup/restore — no task here, by design.
- **Placeholder scan:** no TODO/TBD; every step has concrete code or an exact command + expected output. The only "confirm on the box" items are real runtime values (hostnames), isolated to the Runbook, not plan steps.
- **Type/name consistency:** bash `fleet_detect/fleet_platform/fleet_roles/fleet_machines` (Task 2) are the exact names sourced in Tasks 4 & 6; PowerShell `Get-FleetDetected/Get-FleetPlatform/Get-FleetRoles/Get-FleetMachines` (Task 3) match Task 5. Flag names align across launchers (`--machine`/`-Machine`, `--apply`/`-Apply`). Manifest keys (`platform`, `mesh`, `roles`, `detect.hostname`) are read identically in every consumer.
