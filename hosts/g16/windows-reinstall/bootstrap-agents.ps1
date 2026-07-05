<#
  Windows reinstall - agent environment bootstrap.

  Fills the gap restore.ps1 leaves as a GUIDED (manual) step: it stands up the
  Claude/Codex agent environment on a fresh Windows box, end to end:

    1. Developer Mode  - enable it (self-elevates via UAC only for this reg write).
                         Native symlinks (ln -s) fail without it, and the whole
                         agent config is symlinks into this repo.
    2. Git + Git Bash  - ensure present (winget). bootstrap.sh runs under Git Bash.
    3. Claude Code     - install the native CLI (irm claude.ai/install.ps1) if missing.
    4. Codex           - best-effort (npm) if npm is present; skipped otherwise.
    5. agents bootstrap- run agents/bootstrap.sh via Git Bash (NOT the WSL bash
                         stub, NOT `just` - the justfile recipe mangles the path
                         on Windows). Personal profile always; -Work adds the
                         work profile too.
    6. machine-local   - if -BackupRoot is given, restore ONLY the non-symlinked
                         bits (.credentials.json, settings.local.json, projects\)
                         into .claude/.codex. The symlinked trees are left alone.

  Idempotent. Re-run any time - each step detects "already done" and skips.

  Usage (normal PowerShell - it elevates itself only for Developer Mode):
      .\bootstrap-agents.ps1
      .\bootstrap-agents.ps1 -BackupRoot R:\backup          # + restore creds/history
      .\bootstrap-agents.ps1 -BackupRoot R:\backup -Work    # + work profile
      .\bootstrap-agents.ps1 -Force                         # overwrite existing creds/settings.local

  ASCII-only on purpose (runs under Windows PowerShell 5.1 on a fresh box).
#>
[CmdletBinding()]
param(
    [string]$RepoDir,                    # repo clone; default: this script's repo root
    [string]$BackupRoot,                 # <L>:\backup - enables the machine-local restore
    [switch]$Work,                       # also bootstrap the ~/.claude-work profile
    [switch]$Force,                      # overwrite existing .credentials.json / settings.local.json
    [switch]$SkipInstall                 # skip the Claude Code / Codex install steps
)
$ErrorActionPreference = 'Stop'

function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "   $msg" }
function Warn($msg) { Write-Host "   $msg" -ForegroundColor Yellow }
function Update-PathFromRegistry {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

# ---- Resolve the repo root (this script lives in <repo>\hosts\g16\windows-reinstall) ----
if (-not $RepoDir) {
    $guess = Resolve-Path (Join-Path $PSScriptRoot '..\..\..') -ErrorAction SilentlyContinue
    $RepoDir = if ($guess) { $guess.Path } else { Join-Path $env:USERPROFILE 'GitHub\machines' }
}
if (-not (Test-Path (Join-Path $RepoDir 'agents\bootstrap.sh'))) {
    throw "agents\bootstrap.sh not found under RepoDir '$RepoDir'. Clone the machines repo first (see install.ps1) or pass -RepoDir."
}
Write-Host "=== machines - agent environment bootstrap ===" -ForegroundColor Cyan
Info "repo: $RepoDir"

# ---- 1. Developer Mode (needed for native symlinks) --------------------------
Step "1. Developer Mode"
$devKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devProp = 'AllowDevelopmentWithoutDevLicense'
$devOn = $false
try {
    $devOn = ((Get-ItemProperty -Path $devKey -Name $devProp -ErrorAction Stop).$devProp -eq 1)
} catch {}
if ($devOn) {
    Info "already enabled."
} else {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    $regArgs = @('add', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock',
                 '/v', $devProp, '/t', 'REG_DWORD', '/d', '1', '/f')
    if ($isAdmin) {
        & reg @regArgs | Out-Null
    } else {
        Warn "not elevated - a UAC prompt will ask to enable Developer Mode."
        Start-Process -FilePath reg -Verb RunAs -Wait -ArgumentList $regArgs
    }
    $devOn = $false
    try { $devOn = ((Get-ItemProperty -Path $devKey -Name $devProp -ErrorAction Stop).$devProp -eq 1) } catch {}
    if ($devOn) { Info "enabled." } else { throw "Developer Mode still off - symlinks will fail. Enable it via Settings > Privacy & security > For developers, then re-run." }
}

# ---- 2. Git + Git Bash -------------------------------------------------------
Step "2. Git + Git Bash"
if (-not (Have git)) {
    if (-not (Have winget)) { throw "git and winget both missing. Install Git (https://git-scm.com), then re-run." }
    Warn "git not found - installing via winget..."
    winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements --silent
    Update-PathFromRegistry
}
# Resolve Git Bash explicitly - the bare `bash` on PATH is the WSL stub, which
# would launch WSL instead of running bootstrap.sh.
$gitBashCands = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
$GitBash = $gitBashCands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $GitBash) { throw "Git Bash (bash.exe) not found under any Git install dir. Reinstall Git for Windows." }
Info "git:  $(git --version)"
Info "bash: $GitBash"

# ---- 3. Claude Code ----------------------------------------------------------
Step "3. Claude Code CLI"
$claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if ($SkipInstall) {
    Info "skipped (-SkipInstall)."
} elseif ((Have claude) -or (Test-Path $claudeExe)) {
    Info "already installed."
} else {
    Warn "claude not found - installing native CLI (irm https://claude.ai/install.ps1 | iex)..."
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
}
# Make sure the native install dir is on this session's PATH.
$localBin = Join-Path $env:USERPROFILE '.local\bin'
if ((Test-Path $localBin) -and ($env:Path -notlike "*$localBin*")) { $env:Path = "$localBin;$env:Path" }

# ---- 4. Codex (best-effort) --------------------------------------------------
Step "4. Codex CLI (optional)"
if ($SkipInstall) {
    Info "skipped (-SkipInstall)."
} elseif (Have codex) {
    Info "already installed."
} elseif (Have npm) {
    Warn "installing @openai/codex via npm..."
    try { npm install -g @openai/codex } catch { Warn "codex install failed (non-fatal): $($_.Exception.Message)" }
} else {
    Info "npm not present - skipping (Codex config is still linked in step 5; install the CLI later if you use it)."
}

# ---- 5. Run the agents bootstrap (Git Bash) ----------------------------------
Step "5. agents/bootstrap.sh"
$repoUnix = ($RepoDir -replace '\\','/')
function Invoke-Bootstrap($envPrefix, $label) {
    Info "bootstrapping $label profile..."
    & $GitBash -lc "cd '$repoUnix' && $envPrefix bash agents/bootstrap.sh"
    if ($LASTEXITCODE -ne 0) { throw "bootstrap.sh failed for $label profile (exit $LASTEXITCODE). See output above." }
}
Invoke-Bootstrap 'env -u CLAUDE_CONFIG_DIR' 'personal'
if ($Work) { Invoke-Bootstrap 'CLAUDE_CONFIG_DIR="$HOME/.claude-work"' 'work' }

# ---- 6. Restore machine-local bits (only with -BackupRoot) -------------------
Step "6. Machine-local restore"
if (-not $BackupRoot) {
    Info "no -BackupRoot given - skipped. Pass -BackupRoot <L>:\backup to restore .credentials.json / settings.local.json / projects\."
} elseif (-not (Test-Path $BackupRoot)) {
    Warn "BackupRoot '$BackupRoot' not found - skipping machine-local restore."
} else {
    # Copy a single file only if absent (or -Force). Never clobbers a fresh login.
    function Restore-LocalFile($src, $dst) {
        if (-not (Test-Path $src)) { return }
        if ((Test-Path $dst) -and (-not $Force)) { Info "keep existing $(Split-Path $dst -Leaf) (pass -Force to overwrite)"; return }
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item $src $dst -Force
        Info "restored $(Split-Path $dst -Leaf)"
    }
    foreach ($p in @('.claude', '.codex')) {
        $srcDir = Join-Path $BackupRoot "home\$p"
        if (-not (Test-Path $srcDir)) { continue }
        $dstDir = Join-Path $env:USERPROFILE $p
        Info "$p :"
        Restore-LocalFile (Join-Path $srcDir '.credentials.json')  (Join-Path $dstDir '.credentials.json')
        Restore-LocalFile (Join-Path $srcDir 'settings.local.json') (Join-Path $dstDir 'settings.local.json')
        $projSrc = Join-Path $srcDir 'projects'
        if (Test-Path $projSrc) {
            Info "merging projects\ (session history)..."
            robocopy $projSrc (Join-Path $dstDir 'projects') /E /R:1 /W:1 /NP /NFL /NDL /MT:8 | Out-Null
            if ($LASTEXITCODE -ge 8) { Warn "robocopy projects\ returned $LASTEXITCODE" }
        }
    }
}

# ---- Done --------------------------------------------------------------------
Write-Host "`n=== agent environment ready ===" -ForegroundColor Green
Info "Verify: claude --version ; ls ~\.claude (CLAUDE.md, settings.json, skills\cyphy should be symlinks into $RepoDir\agents)."
if (-not (Have claude)) { Warn "Open a NEW terminal so PATH picks up claude, then run: claude" }
