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

# Role executors (each defines Invoke-Role<Name>). Optional — absent dir is fine.
Get-ChildItem -Path (Join-Path $PSScriptRoot 'roles') -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { . $_.FullName }

# role name -> executor scriptblock. A map avoids function-name mangling for
# hyphenated roles (e.g. a future 'mesh-member').
$RoleExecutors = @{
    'agents'      = { param($Mode, $Platform, $Machine) Invoke-RoleAgents     -Mode $Mode -Platform $Platform -Machine $Machine }
    'dotfiles'    = { param($Mode, $Platform, $Machine) Invoke-RoleDotfiles   -Mode $Mode -Platform $Platform -Machine $Machine }
    'repos'       = { param($Mode, $Platform, $Machine) Invoke-RoleRepos      -Mode $Mode -Platform $Platform -Machine $Machine }
    'mesh-member' = { param($Mode, $Platform, $Machine) Invoke-RoleMeshMember -Mode $Mode -Platform $Platform -Machine $Machine }
    'mesh-hub'    = { param($Mode, $Platform, $Machine) Invoke-RoleMeshHub    -Mode $Mode -Platform $Platform -Machine $Machine }
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
if (-not $Machine) { Write-Error "no machine selected"; exit 2 }

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
        if ($mode -eq 'apply') {
            Write-Host "  x $role - apply: not yet implemented (skipped)"
        } else {
            Write-Host "  * $role - plan: would converge via the $platform executor for '$role'"
        }
    }
}

exit $rc
