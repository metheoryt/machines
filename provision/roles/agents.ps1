# provision/roles/agents.ps1 — the `agents` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleAgents.
#
# agents = the synced Claude/Codex config produced by agents/bootstrap.sh,
# run under Git Bash on Windows (bootstrap.sh is a bash script).

function Invoke-RoleAgents {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  agents: owned by home-manager — applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  agents: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    # repo root = two levels up from provision/roles/ . Forward-slash for Git Bash.
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $boot = (Join-Path $repo 'agents/bootstrap.sh') -replace '\\', '/'

    $bash = 'C:/Program Files/Git/bin/bash.exe'
    if (-not (Test-Path $bash)) {
        $cmd = Get-Command bash -ErrorAction SilentlyContinue
        if ($cmd) { $bash = $cmd.Source }
        else { Write-Warning "  agents: Git Bash not found (looked at 'C:/Program Files/Git/bin/bash.exe'). Install Git for Windows."; return }
    }
    if (-not (Test-Path $boot)) { Write-Warning "  agents: bootstrap.sh not found at $boot"; return }

    if ($Mode -eq 'apply') { $env:DRY_RUN = $null } else { $env:DRY_RUN = '1' }
    try {
        & $bash $boot
        if ($LASTEXITCODE -ne 0) { throw "bootstrap.sh exited $LASTEXITCODE" }
    } finally {
        Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
    }
}
