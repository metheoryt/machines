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
