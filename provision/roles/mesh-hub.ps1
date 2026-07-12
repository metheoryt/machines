# provision/roles/mesh-hub.ps1 — the `mesh-hub` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleMeshHub.
#
# The AmneziaWG hub (the VPS) is owned by the sibling ~/my/vps repo. No-op
# pointer (the hub is Debian anyway; this exists for dispatch-map completeness).

function Invoke-RoleMeshHub {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    Write-Host "  mesh-hub: the AmneziaWG hub is owned by the ~/my/vps repo (setup-awg.sh / manage-peers.sh) — not provisioned from here."
}
