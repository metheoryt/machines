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
