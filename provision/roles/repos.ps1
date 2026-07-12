# provision/roles/repos.ps1 — the `repos` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleRepos.
#
# repos = your working repos cloned into the per-account home-dir layout by
# provision/repos.sh, run under Git Bash on Windows (repos.sh is a bash script).
# Wrapped UNCHANGED; interactive fzf select happens inside repos.sh on apply.

function Invoke-RoleRepos {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  repos: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    # repo root = two levels up from provision/roles/ . Forward-slash for Git Bash.
    $repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script = (Join-Path $repo 'provision/repos.sh') -replace '\\', '/'

    $bash = 'C:/Program Files/Git/bin/bash.exe'
    if (-not (Test-Path $bash)) {
        $cmd = Get-Command bash -ErrorAction SilentlyContinue
        if ($cmd) { $bash = $cmd.Source }
        else { Write-Warning "  repos: Git Bash not found (looked at 'C:/Program Files/Git/bin/bash.exe'). Install Git for Windows."; return }
    }
    if (-not (Test-Path $script)) { Write-Warning "  repos: repos.sh not found at $script"; return }

    if ($Mode -eq 'apply') { $env:DRY_RUN = $null } else { $env:DRY_RUN = '1' }
    try {
        & $bash $script
        if ($LASTEXITCODE -ne 0) { throw "repos.sh exited $LASTEXITCODE" }
    } finally {
        Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
    }
}
