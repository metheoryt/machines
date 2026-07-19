<#
  Windows reinstall - internet bootstrap for the restore flow.

  Run on a freshly reinstalled Windows (elevated PowerShell recommended, so the
  restore's icacls / WSL / robocopy steps behave). One-liner:

      irm https://raw.githubusercontent.com/metheoryt/machines/main/hosts/desktop/windows/install.ps1 | iex

  It ensures git is present, clones the `machines` repo, and hands off to
  restore.ps1 (discover backup -> select -> verify -> guided restore).

  NON-DESTRUCTIVE: it installs git (if missing) and clones one public repo.
  Nothing on disk is modified beyond that. The actual restore is a separate,
  dry-run-by-default step you drive from restore.ps1.

  Prereq: the GitHub `nix -> machines` rename (runbook Phase 4.0) is done, so the
  clone resolves under the new name. Clones over HTTPS on purpose - a fresh box
  has no SSH key yet (the keys live inside the backup).
#>
[CmdletBinding()]
param(
    [string]$RepoUrl = 'https://github.com/metheoryt/machines.git',
    [string]$Branch  = 'main',
    [string]$Dest    = "$env:USERPROFILE\GitHub\machines"
)
$ErrorActionPreference = 'Stop'

function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Update-PathFromRegistry {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

Write-Host "=== machines - restore bootstrap ===" -ForegroundColor Cyan

$admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) {
    Write-Host "  NOTE: not elevated. The restore's icacls / WSL / robocopy steps work best" -ForegroundColor Yellow
    Write-Host "        from an elevated PowerShell. Consider re-running as Administrator." -ForegroundColor Yellow
}

# 1. Ensure git
if (-not (Have git)) {
    Write-Host "git not found - installing via winget..." -ForegroundColor Yellow
    if (-not (Have winget)) { throw "winget not available. Install Git (https://git-scm.com) manually, then re-run." }
    winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements --silent
    Update-PathFromRegistry
    if (-not (Have git) -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $env:Path += ';C:\Program Files\Git\cmd' }
    if (-not (Have git)) { throw "git still not on PATH after install. Open a NEW PowerShell and re-run the one-liner." }
}
Write-Host "  git: $(git --version)"

# 2. Clone (or update) the machines repo
if (Test-Path (Join-Path $Dest '.git')) {
    Write-Host "Repo already present at $Dest - pulling latest..." -ForegroundColor Yellow
    git -C $Dest pull --ff-only
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    Write-Host "Cloning $RepoUrl -> $Dest"
    git clone --branch $Branch $RepoUrl $Dest
}

# 3. Hand off to restore.ps1
$restore = Join-Path $Dest 'hosts\g16\windows\restore.ps1'
if (-not (Test-Path $restore)) { throw "restore.ps1 not found at $restore (unexpected repo layout)." }
Write-Host "`nRepo ready. Handing off to restore.ps1 (dry run - it writes nothing until you pass -Go)...`n" -ForegroundColor Cyan
& $restore

# 4. Tell the operator how to run the real restore. The dry run above changed
#    nothing on disk; restore.ps1 only writes when invoked directly with -Go.
Write-Host "`n=== NEXT STEP: that was a DRY RUN - nothing was written ===" -ForegroundColor Green
Write-Host "Review the plan above. When ready to actually restore, run:`n" -ForegroundColor Green
Write-Host "    & '$restore' -Go" -ForegroundColor Cyan
Write-Host "`n(add -Force to allow overwriting a non-empty .ssh / existing repos.)" -ForegroundColor DarkGray
