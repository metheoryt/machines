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
                         on Windows). Personal profile always; -Postfix <name>
                         adds a secondary profile (e.g. -Postfix pure) too.
    6. machine-local   - if a backup is found (auto-discovered on ANY drive
                         letter, or via -BackupRoot), restore ONLY the
                         non-symlinked bits (.credentials.json,
                         settings.local.json, projects\) into .claude/.codex.
                         The symlinked trees are left alone.

  Idempotent. Re-run any time - each step detects "already done" and skips.

  Usage (normal PowerShell - it elevates itself only for Developer Mode):
      .\provision\windows.ps1                                # auto-discovers the backup on any drive + restores creds/history
      .\provision\windows.ps1 -BackupRoot H:\backup          # or point it at a specific <L>:\backup
      .\provision\windows.ps1 -Postfix pure                  # + ~/.claude-pure profile
      .\provision\windows.ps1 -Force                         # overwrite existing creds/settings.local

  ASCII-only on purpose (runs under Windows PowerShell 5.1 on a fresh box).
#>
[CmdletBinding()]
param(
    [string]$RepoDir,                    # repo clone; default: this script's repo root
    [string]$BackupRoot,                 # explicit <L>:\backup; omitted => auto-discover on any drive
    [string]$Postfix,                    # also bootstrap ~/.claude-<Postfix> (e.g. "pure")
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
function Find-BackupRoot {
    # Scan every lettered volume for <L>:\backup - the SSD often remaps to a
    # different letter after a reinstall (e.g. it came back as H: in 2026-07), so
    # never assume one. Marker: the runbook copy, or the logs\/repos\ structure
    # backup.ps1 produces. Returns the matching root(s); the caller decides.
    $found = @()
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Sort-Object DriveLetter)) {
        $root = "$($v.DriveLetter):\backup"
        $isBackup = (Test-Path (Join-Path $root 'windows-reinstall-runbook.md')) -or
                    (Test-Path (Join-Path $root 'logs')) -or (Test-Path (Join-Path $root 'repos'))
        if ((Test-Path $root) -and $isBackup) { $found += $root }
    }
    $found
}

# ---- Resolve the repo root (this script lives in <repo>\provision) ----
if (-not $RepoDir) {
    $guess = Resolve-Path (Join-Path $PSScriptRoot '..') -ErrorAction SilentlyContinue
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

# ---- 2. Git + Git Bash + Python ----------------------------------------------
Step "2. Git + Git Bash + Python"
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

# Python (real, non-Store) - kb-refresh's distill.py and agents/statusline-command.sh
# need a python that Git Bash can exec. The Microsoft Store python/python3/py aliases
# under ...\WindowsApps are execve-hostile from Git Bash ("Permission denied") AND
# can't be gated by `Have` (the stub satisfies Get-Command), so probe for a real
# python.org exe under %LOCALAPPDATA%\Programs\Python and install via `--source winget`
# (avoids the Store PythonManager) when absent. A real install lands ahead of the Store
# alias on PATH, which is what makes `python`/`py` resolve for distill (verified on the
# desktop box, where distill works via the probe's python3->python fallback).
$pyReal = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
          Select-Object -First 1
if ($pyReal) {
    Info "python: $(& $pyReal.FullName --version 2>&1)"
} elseif (Have winget) {
    Warn "real python not found (only Store stubs) - installing via winget..."
    winget install --id Python.Python.3.14 -e --source winget --accept-source-agreements --accept-package-agreements --silent
    winget install --id Python.Launcher   -e --source winget --accept-source-agreements --accept-package-agreements --silent
    Update-PathFromRegistry
} else {
    Warn "python missing and winget unavailable - install Python 3 from https://python.org, then re-run (kb-refresh distill needs it)."
}

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
if ($Postfix) { Invoke-Bootstrap "CLAUDE_CONFIG_DIR=`"`$HOME/.claude-$Postfix`"" $Postfix }

# ---- 6. Restore machine-local bits (auto-discovers the backup; -BackupRoot overrides) ----
Step "6. Machine-local restore"
if (-not $BackupRoot) {
    $hits = @(Find-BackupRoot)
    if ($hits.Count -eq 1) {
        $BackupRoot = $hits[0]; Info "auto-discovered backup on any drive: $BackupRoot"
    } elseif ($hits.Count -gt 1) {
        Warn "multiple backups found ($($hits -join ', ')) - pass -BackupRoot <L>:\backup to pick one."
    }
}
if (-not $BackupRoot) {
    Info "no backup given or auto-discovered - skipped. Pass -BackupRoot <L>:\backup to restore .credentials.json / settings.local.json / projects\."
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

# ---- 7. OpenSSH server (agent/human SSH into this box over tailnet+LAN) ------
Step "7. OpenSSH server"
$isAdmin7 = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin7) { throw "Step 7 (OpenSSH server) needs an elevated session. Re-run provision\windows.ps1 from an elevated PowerShell (see hosts\g16\windows\windows-reinstall-runbook.md)." }
# 7a. Ensure the OpenSSH.Server capability is present. The '~~~~0.0.1.0' suffix
#     is a FIXED Windows-capability identifier, not a version to bump.
$sshCap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
          Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if ($sshCap -and $sshCap.State -eq 'Installed') {
    Info "OpenSSH.Server already installed."
} else {
    Warn "installing OpenSSH.Server capability..."
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}
# 7b. Service: start now + start on boot.
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Info "sshd: $((Get-Service sshd).Status), startup Automatic."

# 7c. Default shell = PowerShell, so an agent's commands land somewhere
#     scriptable rather than cmd.exe. Idempotent (rewrite each run).
$pwshExe = (Get-Command powershell.exe).Source
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value $pwshExe -PropertyType String -Force | Out-Null
Info "default shell: $pwshExe"

# 7d. Authorized keys. For an admin user, OpenSSH on Windows reads
#     ProgramData\ssh\administrators_authorized_keys and REFUSES it unless the
#     ACL is locked to Administrators/SYSTEM. Rewrite + re-ACL each run.
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$srcKeys   = Join-Path $RepoDir 'provision\fleet-authorized-keys'
if (Test-Path $srcKeys) {
    # Strip comment/blank lines; write with no BOM (sshd rejects a BOM).
    $keyLines = Get-Content $srcKeys | Where-Object { $_ -and ($_ -notmatch '^\s*#') }
    [System.IO.File]::WriteAllLines($adminKeys, $keyLines, (New-Object System.Text.UTF8Encoding($false)))
    # Use well-known SIDs, not English group names: on a non-English Windows
    # (e.g. the ru-locale homeserver) 'Administrators' does not resolve, icacls
    # fails to lock the ACL, and OpenSSH then REFUSES the file. *S-1-5-32-544 =
    # Administrators, *S-1-5-18 = SYSTEM (locale-independent).
    icacls $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Warn "icacls failed to lock administrators_authorized_keys ACL (exit $LASTEXITCODE) - OpenSSH will reject it."
    } else {
        Info "wrote $($keyLines.Count) key(s) to administrators_authorized_keys (ACL locked)."
    }
} else {
    Warn "provision\fleet-authorized-keys not found - skipped authorized_keys."
}

# 7e. Firewall: inbound 22 from the tailnet + LAN only (never the open internet).
#     CONVERGE, don't create-if-absent: a box may already carry a stale rule from
#     a prior (AWG-era) run, so remove any prior rule (the old name + this one)
#     then recreate. Create-if-absent would silently leave the old scope in place.
$fwRule = 'OpenSSH-Server-Tailnet-LAN'
foreach ($old in @('OpenSSH-Server-Mesh-LAN', $fwRule)) {
    Get-NetFirewallRule -Name $old -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
New-NetFirewallRule -Name $fwRule -DisplayName 'OpenSSH Server (tailnet+LAN)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
    -RemoteAddress @('100.64.0.0/10','192.168.8.0/24') | Out-Null
Info "firewall rule '$fwRule' set (22 from 100.64.0.0/10, 192.168.8.0/24)."
# Neutralize the default 'allow 22 from Any' rule the capability install adds
# (Windows Firewall unions allow-rules, so the scoped rule above restricts
# nothing while this one is enabled). Idempotent.
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Info "disabled default 'OpenSSH-Server-In-TCP' (Any) rule; only tailnet+LAN remains."

# 7f. Key-only auth (parity with the NixOS spokes' PasswordAuthentication=false).
$sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
if (Test-Path $sshdConfig) {
    $cfg = Get-Content $sshdConfig -Raw
    foreach ($kv in @(@('PasswordAuthentication','no'), @('KbdInteractiveAuthentication','no'))) {
        $key = $kv[0]; $val = $kv[1]
        if ($cfg -match "(?im)^\s*#?\s*$key\b.*$") {
            $cfg = [regex]::Replace($cfg, "(?im)^\s*#?\s*$key\b.*$", "$key $val")
        } else {
            $cfg = $cfg.TrimEnd() + "`r`n$key $val`r`n"
        }
    }
    [System.IO.File]::WriteAllText($sshdConfig, $cfg, (New-Object System.Text.UTF8Encoding($false)))
    Restart-Service sshd
    Info "sshd_config: PasswordAuthentication no, KbdInteractiveAuthentication no (restarted)."
} else {
    Warn "sshd_config not found at $sshdConfig - skipped auth hardening."
}

Warn "Reachable over the tailnet only while this box has joined the Headscale tailnet (tailscale0 up, address in 100.64.0.0/10) - verify separately."

# ---- 8. Fleet convergence tasks (spec 2026-07-21) ----------------------------
# Two idempotent (-Force) Scheduled Tasks:
#   1. machines-converge - SYSTEM task, on-demand only (fired by the post-merge
#      hook via `schtasks /run /tn machines-converge`). Runs scripts/converge.sh
#      under Git Bash with SYSTEM privilege so it gets admin rights WITHOUT
#      granting the pulling user elevation.
#   2. fleet-selfpull - repeating ~10-min task (Trigger B). Its pull fires the
#      post-merge hook, which in turn fires machines-converge. Runs as the user.
Step "8. Fleet convergence tasks"
$convergeScript = Join-Path $RepoDir 'scripts\converge.sh'
if (-not (Test-Path $convergeScript)) {
    Warn "scripts\converge.sh not found under $RepoDir - skipping convergence task registration."
} else {
    # (1) machines-converge - SYSTEM, no trigger (on-demand).
    $convAction = New-ScheduledTaskAction -Execute $GitBash `
        -Argument "-lc `"'$repoUnix/scripts/converge.sh'`""
    $convPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $convSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'machines-converge' -Action $convAction `
        -Principal $convPrincipal -Settings $convSettings -Force | Out-Null
    Info "registered 'machines-converge' (SYSTEM, on-demand)."

    # (2) fleet-selfpull - every 10 min, as the interactive user, with jitter.
    # converge re-runs this whole script under the SYSTEM machines-converge task.
    # There $env:USERNAME is the machine account, which S4U cannot map
    # (ERROR_NONE_MAPPED, 0x80070534): the registration then throws and fails the
    # entire converge. So resolve the real console user when running as SYSTEM;
    # if there is none (headless converge), leave any task the interactive install
    # already created in place rather than aborting.
    $runningAsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($runningAsSystem) {
        # DOMAIN\user of the console session, or $null when nobody is logged on.
        $pullUser = (Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue).UserName
    } else {
        $pullUser = $env:USERNAME
    }
    if (-not $pullUser) {
        if (Get-ScheduledTask -TaskName 'fleet-selfpull' -EA SilentlyContinue) {
            Info "fleet-selfpull already registered; headless SYSTEM run, no console user - leaving it."
        } else {
            Warn "fleet-selfpull not registered and no interactive user to own it - run provision\windows.ps1 once from your normal login to create it."
        }
    } else {
        $selfpullPs1 = Join-Path $RepoDir 'provision\fleet-selfpull.ps1'
        $pullAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$selfpullPs1`""
        $pullTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 10)
        # [TimeSpan]::MaxValue serializes to P99999999DT23H59M59S, which
        # Register-ScheduledTask rejects as "incorrectly formatted or out of range".
        # An empty Duration means "repeat indefinitely" and registers cleanly.
        $pullTrigger.Repetition.Duration = ''
        $pullTrigger.RandomDelay = 'PT2M'   # jitter so boxes don't hit GitHub together
        $pullSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 9)
        $pullPrincipal = New-ScheduledTaskPrincipal -UserId $pullUser -LogonType S4U -RunLevel Limited
        # Defense-in-depth: a residual principal hiccup must warn, not brick converge.
        try {
            Register-ScheduledTask -TaskName 'fleet-selfpull' -Action $pullAction -Trigger $pullTrigger `
                -Settings $pullSettings -Principal $pullPrincipal -Force | Out-Null
            Info "registered 'fleet-selfpull' (every 10 min, jittered) as $pullUser."
        } catch {
            Warn "fleet-selfpull registration failed for '$pullUser': $($_.Exception.Message) - leaving any existing task."
        }
    }
}

# ---- Done --------------------------------------------------------------------
Write-Host "`n=== agent environment ready ===" -ForegroundColor Green
Info "Verify: claude --version ; ls ~\.claude (CLAUDE.md, settings.json, skills\cyphy should be symlinks into $RepoDir\agents)."
if (-not (Have claude)) { Warn "Open a NEW terminal so PATH picks up claude, then run: claude" }
