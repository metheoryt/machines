#!/usr/bin/env pwsh
# provision/provision.ps1 — fleet front door (Windows).
# Phase 1: detect/select the machine and PRINT the plan. Applies nothing.
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $Machine,
    # Roles with no entry in $RoleExecutors, declared unimplemented ON PURPOSE.
    # The Windows half of provision.sh's PLANNED_ROLES, and it exists for the same
    # reason: a role NOT named here and with no executor makes -Apply exit 1,
    # instead of printing "not yet implemented (skipped)" and reporting success.
    #
    # A PARAMETER, not an environment variable, and that is not a style choice.
    # The posix suite forces the failing arm with MACHINES_PLANNED_ROLES="" --
    # declare nothing, so every executor-less role must fail. On Windows,
    # assigning '' to $env:X REMOVES the variable, so "set but empty" cannot be
    # expressed in the environment at all and the negative arm would be
    # untestable. -PlannedRoles @() says it exactly.
    #
    # A future executor lands by DELETING its name from this default AND adding
    # its $RoleExecutors entry. Leave the name in and the new executor is never
    # demanded of a box that lacks it.
    [string[]] $PlannedRoles = @('base', 'ssh-server')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Fleet.psm1') -Force

# Role executors (each defines Invoke-Role<Name>). Optional — absent dir is fine.
Get-ChildItem -Path (Join-Path $PSScriptRoot 'roles') -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# role name -> executor scriptblock. A map avoids function-name mangling for
# hyphenated roles.
$RoleExecutors = @{
    'agents'      = { param($Mode, $Platform, $Machine) Invoke-RoleAgents     -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles'    = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles   -Mode $Mode -Platform $Platform -Machine $Machine }
    'repos'       = { param($Mode, $Platform, $Machine) Invoke-RoleRepos      -Mode $Mode -Platform $Platform -Machine $Machine }
    # THE MAP ENTRY IS NOT OPTIONAL. A role missing from here falls through to
    # the `else` arm below. Until 2026-09-02 that arm printed "not yet
    # implemented (skipped)" and left $rc at 0 -- provisioned nothing, reported
    # success -- the hole 49497bd had already closed on the posix side. It is
    # closed here now by -PlannedRoles above: an undeclared role with no map
    # entry fails -Apply. So a missing entry is loud rather than silent; it is
    # still a missing entry.
    'backup-client' = { param($Mode, $Platform, $Machine) Invoke-RoleBackupClient -Mode $Mode -Platform $Platform -Machine $Machine }
}

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
# Write-Error is unusable for a guard here: $ErrorActionPreference is 'Stop', so
# it THROWS and the process dies with exit 1 before ever reaching `exit 2` --
# which is what the line below used to do, quietly turning a deliberate exit code
# into a generic failure. Plain stderr, then exit.
function Write-Err([string] $Message) { [Console]::Error.WriteLine($Message) }

if (-not $Machine) { Write-Err "no machine selected"; exit 2 }

# A name that is not in the manifest must fail HERE and loudly. Without this,
# Get-FleetRoles returns $null, `foreach` over $null iterates zero times, and the
# run exits 0 having printed no roles at all. Mirrors provision.sh's
# fleet_has_machine gate, exit code included.
if (-not (Test-FleetMachine -Machine $Machine)) {
    Write-Err "unknown machine: $Machine"
    Write-Err "known machines: $((Get-FleetMachines) -join ' ')"
    exit 2
}

$platform = Get-FleetPlatform -Machine $Machine
Write-Host "> Machine: $Machine   platform: $platform   mode: $mode"
Write-Host "> Roles:"
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
        # Declared-planned or not? -contains is a whole-element match, so a role
        # named 'ssh' cannot match the declaration of 'ssh-server' -- the hazard
        # the posix side has to spell out as a padded substring test.
        if ($PlannedRoles -contains $role) {
            if ($mode -eq 'apply') {
                Write-Host "  - $role - apply: no executor yet (declared); skipped"
            } else {
                Write-Host "  * $role - plan: no executor yet (declared)"
            }
        } else {
            # $rc = 1 under -Apply ONLY. A dry run writes nothing, so it reports
            # loudly and still exits 0; the nonzero status is reserved for "an
            # apply did not do what it said". The message is identical in both
            # modes, so the preview is the warning you get BEFORE the failing run.
            Write-Err "  x $role - no executor, and not declared in -PlannedRoles"
            if ($mode -eq 'apply') { $rc = 1 }
        }
    }
}

exit $rc
