# provision/roles/dotfiles.ps1 — the `dotfiles` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleDotfiles.
#
# dotfiles = cross-platform home config managed by chezmoi, sourced from
# machines/dotfiles/ (stateless --source mode; updates via `git pull`).

function Invoke-RoleDotfiles {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  dotfiles: owned by home-manager on nixos — applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  dotfiles: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $src  = Join-Path $repo 'dotfiles'
    if (-not (Test-Path $src)) { Write-Warning "  dotfiles: chezmoi source not found at $src"; return }

    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        if ($Mode -eq 'apply') {
            Write-Host "  dotfiles: installing chezmoi (winget twpayne.chezmoi) ..."
            winget install --id twpayne.chezmoi -e --source winget --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "chezmoi install failed (winget exit $LASTEXITCODE)" }
            if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
                throw "chezmoi installed but not on PATH in this shell — re-run in a fresh shell."
            }
        } else {
            Write-Host "  ~ would install chezmoi (winget twpayne.chezmoi)"
            return
        }
    }

    if ($Mode -eq 'apply') {
        & chezmoi apply --source $src
        if ($LASTEXITCODE -ne 0) { throw "chezmoi apply exited $LASTEXITCODE" }
    } else {
        & chezmoi diff --source $src
    }
}
