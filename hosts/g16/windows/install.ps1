<#
  Windows reinstall - internet bootstrap for the restore flow.

  Run on a freshly reinstalled Windows (elevated PowerShell recommended, so the
  restore's icacls / WSL / robocopy steps behave). One-liner:

      irm https://raw.githubusercontent.com/metheoryt/machines/main/hosts/g16/windows/install.ps1 | iex

  It ensures git is present, clones the `machines` repo, and hands off to
  provision/windows.ps1 (Developer Mode, core.symlinks, Git Bash, Claude Code,
  agents/bootstrap.sh, and the machine-local .claude bits out of a backup).

  RETARGETED 2026-09-09. It handed off to `hosts\g16\windows\restore.ps1`,
  dead twice over: the g16 -> desktop rename (2026-07-20, reverted 2026-09-12
  when the machine went back to `g16`) and restore.ps1's
  deletion (2026-07-31, commit 1080828). So step 3 threw unconditionally and
  steps 1-2 - the only part anyone actually needs from a fresh box - were
  unreachable through the one-liner. provision/windows.ps1 is the live successor
  and says so in its own header ("fills the gap restore.ps1 leaves as a GUIDED
  step"). provision/tests/windows-bootstrap.test.sh now pins the handoff target
  to a path that exists in the tree, so this cannot rot silently again.

  NON-DESTRUCTIVE up to the handoff: it installs git (if missing) and clones one
  public repo. windows.ps1 is itself idempotent and self-elevates only for the
  Developer Mode registry write.

  Clones over HTTPS on purpose - a fresh box has no SSH key yet (the keys live
  inside the backup).
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

# 3. Hand off to the provisioner
$provision = Join-Path $Dest 'provision\windows.ps1'
if (-not (Test-Path $provision)) { throw "windows.ps1 not found at $provision (unexpected repo layout)." }
Write-Host "`nRepo ready. Handing off to provision\windows.ps1...`n" -ForegroundColor Cyan
& $provision

# 4. What this script does NOT do, said out loud rather than left implied.
#    windows.ps1 stands up the agent environment and restores the machine-local
#    .claude bits from a discovered backup. It does not restore repos, .ssh,
#    Downloads or the Obsidian vault - restore.ps1 used to, and it is gone. Those
#    are the guided steps in the runbook, and nothing automates them today.
Write-Host "`n=== Agent environment is up. The rest is still manual ===" -ForegroundColor Green
Write-Host "Repos, .ssh (+ icacls perms), Downloads and the vault are NOT restored by" -ForegroundColor Green
Write-Host "any script - restore.ps1 was deleted 2026-07-31. Follow Phase 4 of:" -ForegroundColor Green
Write-Host "    $Dest\hosts\g16\windows\windows-reinstall-runbook.md" -ForegroundColor Cyan
Write-Host "`nApp list:  winget import ... hosts\g16\windows\winget-packages.json" -ForegroundColor DarkGray
