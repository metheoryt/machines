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

# Is this a member of the manifest? The Windows counterpart of fleet_has_machine.
# Without it, `-Machine typo` resolves platform $null, Get-FleetRoles returns
# $null, `foreach` over $null iterates ZERO times, and the run exits 0 -- printed
# no roles, provisioned nothing, reported success. Exactly the hole the posix
# front door closed on 2026-08-01, still open here until 2026-09-02.
# `-contains` on the property-name array is an exact, whole-element match, so no
# prefix of a real machine name can slip through.
function Test-FleetMachine {
    param([string] $Machine)
    if (-not $Machine) { return $false }
    return [bool]((Get-FleetManifest).machines.PSObject.Properties.Name -contains $Machine)
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
    Get-FleetDetected, Test-FleetMachine, Get-FleetPlatform, Get-FleetRoles
