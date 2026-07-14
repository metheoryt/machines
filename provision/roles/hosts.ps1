# provision/roles/hosts.ps1 - the `hosts` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleHosts.
#
# hosts = fleet-wide name resolution via a marker-delimited managed block in the
# system hosts file, generated from fleet.json tailnet IPs. NixOS owns this via
# networking.hosts, so this executor only writes on Windows. Target path is
# overridable via FLEET_HOSTS_FILE (for testing without admin). Writing the real
# system hosts file requires an elevated (admin) shell.

$script:FleetHostsBegin = '# BEGIN fleet hosts (managed by provision - do not edit)'
$script:FleetHostsEnd   = '# END fleet hosts'

function Get-FleetHostsBlock {
    $machines = (Get-FleetManifest).machines
    $body = foreach ($p in ($machines.PSObject.Properties | Sort-Object Name)) {
        '{0}   {1}' -f $p.Value.tailnet.ip, $p.Name
    }
    @($script:FleetHostsBegin) + @($body) + @($script:FleetHostsEnd)
}

function Invoke-RoleHosts {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  hosts: owned by networking.hosts on nixos - applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  hosts: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $target = if ($env:FLEET_HOSTS_FILE) { $env:FLEET_HOSTS_FILE } `
              else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $block = Get-FleetHostsBlock

    if ($Mode -ne 'apply') {
        Write-Host "  hosts: would write this block to ${target}:"
        $block | ForEach-Object { "    $_" }
        return
    }

    $existing = @()
    if (Test-Path -LiteralPath $target) { $existing = @(Get-Content -LiteralPath $target) }

    $kept = New-Object System.Collections.Generic.List[string]
    $inblk = $false
    foreach ($ln in $existing) {
        if ($ln -eq $script:FleetHostsBegin) { $inblk = $true; continue }
        if ($ln -eq $script:FleetHostsEnd)   { $inblk = $false; continue }
        if (-not $inblk) { $kept.Add($ln) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }

    $out = @($kept) + @('') + $block
    Set-Content -LiteralPath $target -Value $out -Encoding ascii
    Write-Host "  hosts: wrote fleet block to $target"
}
