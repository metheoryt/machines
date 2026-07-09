# provision/lib/Mesh.psm1 — VPS conf-fetch helper for Windows. Imported by
# provision/roles/mesh-member.ps1. Uses native ConvertFrom-Json + ssh.exe.
#
# Mirrors provision/lib/mesh.sh: SSH the hub's PUBLIC endpoint (built from
# fleet.json), fetch THIS box's OWN peer conf via `show <peer> --conf-only`
# first (no rotation), else `add <peer> <ip> --conf-only`. Add-only, self-only.
# The fetched conf holds a PrivateKey: returned to the caller to install, NEVER
# logged or shown in dry-run.

function Get-MeshManifestPath {
    if ($env:MESH_MANIFEST) { return $env:MESH_MANIFEST }
    Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'fleet.json'
}
function Get-MeshManifest { Get-Content -Raw (Get-MeshManifestPath) | ConvertFrom-Json }
function Get-MeshSsh { if ($env:MESH_SSH) { $env:MESH_SSH } else { 'ssh' } }

function Get-MeshHub {
    $m = (Get-MeshManifest).machines
    foreach ($p in $m.PSObject.Properties) { if ($p.Value.mesh.role -eq 'hub') { return $p.Value } }
    return $null
}
function Get-MeshHubTarget {
    $h = Get-MeshHub
    $user = if ($h.ssh.user) { $h.ssh.user } else { 'me' }
    $host_ = if ($h.ssh.host) { $h.ssh.host } else { $h.mesh.ip }
    "$user@$host_"
}
function Get-MeshHubScript {
    $h = Get-MeshHub
    if ($h.mesh.managePeers) { $h.mesh.managePeers } else { '/home/debian/my/vps/vps/manage-peers.sh' }
}
function Get-MeshPeerName {
    param([Parameter(Mandatory)][string] $Machine)
    $rec = (Get-MeshManifest).machines.$Machine
    if ($rec.mesh.peerName) { $rec.mesh.peerName } else { $Machine }
}
function Get-MeshPeerIp {
    param([Parameter(Mandatory)][string] $Machine)
    (Get-MeshManifest).machines.$Machine.mesh.ip
}

# Fetch this machine's client conf from the hub. Returns the conf string on
# success, $null on failure. show-then-add. Key captured in a var, never logged.
function Invoke-MeshSshFetch {
    param([Parameter(Mandatory)][string] $Machine)
    $ssh = Get-MeshSsh
    $target = Get-MeshHubTarget
    $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine
    $ip = Get-MeshPeerIp -Machine $Machine
    $common = @('-o','BatchMode=yes','-o','ConnectTimeout=10',$target)

    $conf = & $ssh @common "sudo bash '$script' show '$peer' --conf-only" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($conf -join "`n") -match '\[Interface\]') { return ($conf -join "`n") }

    $conf = & $ssh @common "sudo bash '$script' add '$peer' '$ip' --conf-only" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($conf -join "`n") -match '\[Interface\]') { return ($conf -join "`n") }

    return $null
}

function Write-MeshManualHint {
    param([Parameter(Mandatory)][string] $Machine)
    $target = Get-MeshHubTarget; $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine; $ip = Get-MeshPeerIp -Machine $Machine
    Write-Warning "  mesh: could not reach the hub over SSH — skipping (run did NOT fail)."
    Write-Host   "  mesh: to provision '$Machine' by hand, on the VPS ($target) run:"
    Write-Host   "      sudo bash $script show $peer --conf-only     # existing peer"
    Write-Host   "      sudo bash $script add  $peer $ip --conf-only # new peer"
}

function Write-MeshDryRunLine {
    param([Parameter(Mandatory)][string] $Machine, [Parameter(Mandatory)][string] $InstallPath)
    $target = Get-MeshHubTarget; $script = Get-MeshHubScript
    $peer = Get-MeshPeerName -Machine $Machine; $ip = Get-MeshPeerIp -Machine $Machine
    Write-Host "  ~ would ssh $target -> sudo bash $script show $peer --conf-only (else add $peer $ip --conf-only)"
    Write-Host "  ~ would install the fetched conf to $InstallPath (PrivateKey redacted; never shown)"
}

Export-ModuleMember -Function Get-MeshHubTarget, Get-MeshHubScript, Get-MeshPeerName, `
    Get-MeshPeerIp, Invoke-MeshSshFetch, Write-MeshManualHint, Write-MeshDryRunLine
