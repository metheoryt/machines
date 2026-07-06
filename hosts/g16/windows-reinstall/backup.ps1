<#
  Windows reinstall — backup script
  Copies everything worth preserving to this USB SSD (R:) before a clean Windows reinstall.
  NON-DESTRUCTIVE: reads from C:/WSL, writes only under $Dst. Nothing on the source is deleted.
  Idempotent: big archives are skipped if already present, so a re-run resumes.

  Windows GitHub repos are copied IN FULL (incl. .git — stashes, uncommitted, unpushed all
  preserved), minus .venv/node_modules/caches. Nothing is pushed. WSL-side repos ride along
  inside the full WSL export.

  Canonical location: machines repo, hosts/g16/windows-reinstall/ (this file). It is version-
  controlled and pushed, so it survives the wipe — after reinstall, `git clone` machines to get
  it back. The run also drops a standalone copy on the SSD (R:\windows-reinstall\backup.ps1).

  Usage (from an ELEVATED PowerShell, so WSL/robocopy behave):
      cd <your machines checkout>\hosts\g16\windows-reinstall   # wherever you cloned it
      .\backup.ps1                 # do the backup
      .\backup.ps1 -WhatIf         # dry run: print what it would do

  After it finishes: do the VERIFY gate in the runbook, and make the SECOND copy of
  R:\backup\secrets off this SSD, BEFORE wiping.
#>
[CmdletBinding()]
param(
    # WRITE target for the backup (pre-wipe, where you know the letter). Not
    # auto-detected on purpose - picking a write destination is a footgun. The
    # RESTORE side (restore.ps1 / bootstrap-agents.ps1) auto-discovers the backup
    # on any letter, so it doesn't matter which letter the SSD gets later.
    [string]$DriveLetter = 'R',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$Dst   = "${DriveLetter}:\backup"
$results = [System.Collections.Generic.List[object]]::new()

function Step {
    param([string]$Name, [scriptblock]$Body, [switch]$Critical)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    if ($WhatIf) { Write-Host "  [WhatIf] would run: $Name" -ForegroundColor DarkGray; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $sw.Stop()
        $results.Add([pscustomobject]@{ Step=$Name; Status='OK'; Seconds=[int]$sw.Elapsed.TotalSeconds })
        Write-Host "  OK ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $results.Add([pscustomobject]@{ Step=$Name; Status='FAIL'; Seconds=[int]$sw.Elapsed.TotalSeconds })
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($Critical) { Write-Host "  Critical step failed — stopping." -ForegroundColor Red; throw }
    }
}

# ---------- Preflight ----------
Write-Host "Preflight checks..." -ForegroundColor Yellow
$part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
if ($part.DiskNumber -eq 0) { throw "SAFETY STOP: $DriveLetter is on Disk 0 (the disk to be wiped). Aborting." }
$disk = Get-Disk -Number $part.DiskNumber
Write-Host "  Target $DriveLetter -> Disk $($part.DiskNumber) [$($disk.FriendlyName)] $($disk.BusType)"
$freeGB = [math]::Round((Get-Volume -DriveLetter $DriveLetter).SizeRemaining/1GB,1)
Write-Host "  Free space: $freeGB GB"
if ($freeGB -lt 80) { throw "Only $freeGB GB free on $DriveLetter — need ~80 GB. Aborting." }

# WSL distros to back up: every installed distro EXCEPT the docker-desktop plumbing.
# Remove any distros you don't want BEFORE running — whatever remains here is exported.
$env:WSL_UTF8 = '1'
$wslDistros = @(
    (wsl --list --quiet) -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^docker-desktop' }
)
Write-Host "  WSL distros to back up: $(if ($wslDistros) { $wslDistros -join ', ' } else { '(none found)' })"

# Folder structure
$dirs = 'inventory','wsl','home','repos','Downloads','OneDrive','GoogleDrive','Obsidian','secrets','logs'
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $Dst $d) | Out-Null }

$log = Join-Path $Dst "logs\backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
if (-not $WhatIf) { Start-Transcript -Path $log -Append | Out-Null }
Write-Host "Logging to $log`n"

# ---------- 1. Inventory ----------
Step 'Inventory (winget / WSL packages)' {
    # Point-in-time snapshot of what's actually installed — for DIFFING against the
    # curated keeper list, not for restore. The importable source of truth is the
    # version-controlled hosts/g16/windows-reinstall/winget-packages.json in the repo
    # (curated: dropped apps removed, Store/forgotten apps added). After a backup,
    # diff this snapshot against that file and fold in anything new you want to keep.
    winget export -o "$Dst\inventory\winget-packages-snapshot.json" --disable-interactivity | Out-Null
    winget list --disable-interactivity | Out-File "$Dst\inventory\winget-list-full.txt" -Encoding utf8
    foreach ($d in $wslDistros) {
        $safe = $d -replace '[^\w.-]','_'
        wsl -d $d -- bash -c "dpkg --get-selections"        | Out-File "$Dst\inventory\wsl-apt-selections-$safe.txt" -Encoding utf8
        wsl -d $d -- bash -c "apt-mark showmanual 2>/dev/null" | Out-File "$Dst\inventory\wsl-apt-manual-$safe.txt"    -Encoding utf8
        wsl -d $d -- bash -c "npm -g ls --depth=0 2>/dev/null; pipx list --short 2>/dev/null; uv tool list 2>/dev/null" | Out-File "$Dst\inventory\wsl-global-tools-$safe.txt" -Encoding utf8
    }
}

# ---------- 2. WSL secrets (tiny, irreplaceable) ----------
Step 'WSL secrets (.ssh/.gnupg/.gitconfig, per distro)' -Critical {
    foreach ($d in $wslDistros) {
        $safe = $d -replace '[^\w.-]','_'
        try {
            wsl -d $d -- bash -c "tar cf /tmp/wsl-secrets.tar -C `$HOME .ssh .gnupg .gitconfig 2>/dev/null; echo ok" | Out-Null
            $src = "\\wsl.localhost\$d\tmp\wsl-secrets.tar"
            if (Test-Path $src) {
                Copy-Item $src "$Dst\secrets\wsl-secrets-$safe.tar" -Force
                Write-Host "  $d -> secrets\wsl-secrets-$safe.tar"
            } else {
                Write-Host "  $d -> no secrets tar produced (skipped)" -ForegroundColor Yellow
            }
            wsl -d $d -- bash -c "rm -f /tmp/wsl-secrets.tar"
        } catch {
            Write-Host "  $d -> secrets extraction failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # Windows SSH keys alongside
    Copy-Item "C:\Users\methe\.ssh\*" "$Dst\secrets\" -Force -ErrorAction SilentlyContinue
}

# (qaz-law DB intentionally NOT backed up — recreatable by re-ingesting after reinstall.)

# ---------- 3. WSL full export ----------
Step 'WSL export (full distros)' -Critical {
    wsl --shutdown
    foreach ($d in $wslDistros) {
        $safe = $d -replace '[^\w.-]','_'
        $wslTar = "$Dst\wsl\$safe.tar"
        if ((Test-Path $wslTar) -and (Get-Item $wslTar).Length -gt 1GB) { Write-Host "  $d already present, skipping"; continue }
        Write-Host "  exporting $d -> wsl\$safe.tar"
        wsl --export $d $wslTar
    }
}

# ---------- 5. Windows configs & data ----------
$rc = '/E','/R:1','/W:1','/NP','/NFL','/NDL','/MT:8'
Step 'Windows config — ALL dotfiles/dirs (except big caches & dropped apps)' {
    # Inclusive sweep: back up every .* item in the profile so no config is missed.
    # Blocklist = big recreatable caches + configs for apps we're dropping.
    $blocklist = '.cache','.lmstudio','.vscode','.codeium','.windsurf','.zcode',
                 '.zed_server','.openclaude','.openclaude.json','.marvin','.junie',
                 '.gortex','.boto','.gsutil','.gemini','.k8slens','.docker'
    Get-ChildItem $env:USERPROFILE -Force |
        Where-Object { $_.Name -like '.*' -and $_.Name -notin $blocklist } |
        ForEach-Object {
            if ($_.PSIsContainer) {
                # /XJ = don't follow junctions/dir-symlinks. .claude & .codex contain symlinks into the
                # machines repo (agent config, source of truth = the machines repo, backed up separately in 1a);
                # /XJ keeps us from duplicating those trees. Machine-local real files still copy.
                robocopy $_.FullName "$Dst\home\$($_.Name)" @rc /XJ /XD node_modules .venv | Out-Null
            } else {
                Copy-Item $_.FullName "$Dst\home\" -Force -ErrorAction SilentlyContinue
            }
        }
    Copy-Item "C:\Users\methe\AGENTS.md" "$Dst\home\" -Force -ErrorAction SilentlyContinue
    # robocopy exit codes 0-7 are success; treat >=8 as error
    if ($LASTEXITCODE -ge 8) { throw "robocopy config error $LASTEXITCODE" }
}

Step 'Downloads + GoogleDrive' {
    robocopy "C:\Users\methe\Downloads"   "$Dst\Downloads"   @rc | Out-Null
    robocopy "C:\Users\methe\GoogleDrive" "$Dst\GoogleDrive" @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy data error $LASTEXITCODE" }
}

# OneDrive sync is BROKEN here — so we do NOT trust the cloud and copy the local folder
# directly. Guard: an online-only stub is content that is NOT on disk; a broken sync engine
# can't hydrate it, so robocopy would back up a 0-byte placeholder. Detect + flag loudly
# instead of silently shipping a partial backup.
Step 'OneDrive (broken sync — direct local copy, stub-guarded)' -Critical {
    $od = if ($env:OneDrive) { $env:OneDrive } else { 'C:\Users\methe\OneDrive' }
    if (-not (Test-Path $od)) { throw "OneDrive folder not found at $od" }
    $stubs = Get-ChildItem $od -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::Offline) -or ($_.Attributes.value__ -band 0x400000) }
    if ($stubs) {
        $csv = "$Dst\OneDrive-STUBS-NOT-ON-DISK.csv"
        $stubs | Select-Object FullName, Length | Export-Csv $csv -NoTypeInformation
        Write-Host "  *** WARNING: $($stubs.Count) online-only file(s) are NOT on disk ***" -ForegroundColor Red
        Write-Host "  These can't be captured by copying. List: $csv" -ForegroundColor Red
        Write-Host "  Recover them from the OneDrive web UI (onedrive.live.com) BEFORE wiping." -ForegroundColor Red
    } else {
        Write-Host "  0 online-only stubs — the local copy is complete ($($od))."
    }
    robocopy $od "$Dst\OneDrive" @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy OneDrive error $LASTEXITCODE" }
}

Step 'RustDesk config (ID, private key, saved peers, servers)' {
    # Lives in %APPDATA%\RustDesk\config — NOT swept by the dotfile pass (that only
    # covers the profile root). config\ holds the device identity + saved peers; log\ is noise.
    $rd = "$env:APPDATA\RustDesk\config"
    if (Test-Path $rd) {
        robocopy $rd "$Dst\home\AppData\RustDesk\config" @rc | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy rustdesk error $LASTEXITCODE" }
    } else { Write-Host "  no RustDesk config found" }
}

Step 'App configs (Terminal, PowerToys, NCALayer, AIMP, Telegram tdata)' {
    # Windows Terminal — profiles/schemes/keybinds (Store app, under Packages\...\LocalState)
    $wt = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue
    foreach ($p in $wt) {
        $ls = Join-Path $p.FullName 'LocalState'
        if (Test-Path $ls) { robocopy $ls "$Dst\home\AppData\WindowsTerminal\$($p.Name)" settings.json state.json @rc | Out-Null }
    }
    # PowerToys settings (FancyZones layouts, keyboard remaps, env vars, etc.) — small
    if (Test-Path "$env:LOCALAPPDATA\Microsoft\PowerToys") {
        robocopy "$env:LOCALAPPDATA\Microsoft\PowerToys" "$Dst\home\AppData\Local\PowerToys" @rc /XD Updates | Out-Null
    }
    # NCALayer (kept app): keep the cert (.der) + settings; skip bundled jre/caches
    if (Test-Path "$env:APPDATA\NCALayer") {
        robocopy "$env:APPDATA\NCALayer" "$Dst\home\AppData\NCALayer" @rc /XD jre bundles ncalayer-cache | Out-Null
    }
    # AIMP: playlists (PLS), library, custom genres/moods, skins, AIMP.ini — the music curation
    if (Test-Path "$env:APPDATA\AIMP") {
        robocopy "$env:APPDATA\AIMP" "$Dst\home\AppData\AIMP" @rc | Out-Null
    }
    # Telegram tdata — so AyuGram can import the session/drafts on the fresh install
    if (Test-Path "$env:APPDATA\Telegram Desktop") {
        robocopy "$env:APPDATA\Telegram Desktop" "$Dst\home\AppData\Telegram Desktop" @rc | Out-Null
    }
    if ($LASTEXITCODE -ge 8) { throw "robocopy app-config error $LASTEXITCODE" }
}

Step 'System settings (Wi-Fi profiles + user env vars)' {
    # Wi-Fi SSIDs + passwords (cleartext) -> secrets\ (rides the mandatory off-SSD 2nd copy)
    New-Item -ItemType Directory -Force -Path "$Dst\secrets\wifi" | Out-Null
    netsh wlan export profile key=clear folder="$Dst\secrets\wifi" | Out-Null
    # User environment variables incl. custom PATH additions
    reg export "HKCU\Environment" "$Dst\inventory\hkcu-environment.reg" /y | Out-Null
}

Step 'Obsidian vault(s)' {
    $cfg = "$env:APPDATA\obsidian\obsidian.json"
    if (Test-Path $cfg) {
        $vaults = (Get-Content $cfg -Raw | ConvertFrom-Json).vaults
        foreach ($v in $vaults.PSObject.Properties.Value) {
            if (Test-Path $v.path) {
                $name = Split-Path $v.path -Leaf
                robocopy $v.path "$Dst\Obsidian\$name" @rc | Out-Null
            }
        }
    } else { Write-Host "  no obsidian.json found" }
}

# ---------- 6. Repo folder copies — ALL Windows repos, full incl .git, minus .venv/caches ----------
Step 'Repo copies (all Windows GitHub repos, full incl .git, minus .venv/caches)' {
    $repoExclude = '.venv','node_modules','__pycache__','.mypy_cache','.pytest_cache','.ruff_cache'
    $repos = Get-ChildItem (Join-Path $env:USERPROFILE 'GitHub') -Directory -Force | Where-Object { Test-Path (Join-Path $_.FullName '.git') }
    foreach ($r in $repos) {
        Write-Host "  $($r.Name)"
        robocopy $r.FullName "$Dst\repos\$($r.Name)" @rc /XD $repoExclude | Out-Null
    }
    if ($LASTEXITCODE -ge 8) { throw "robocopy repos error $LASTEXITCODE" }
}

# ---------- 7. Copy runbook + this script onto the SSD ----------
# Both live in the machines repo alongside this script; the repos step already backs up the whole
# machines repo, but we also drop standalone copies at the SSD root so the runbook is readable
# without digging into repos\machines\hosts\g16\ (and before repos are restored).
Step 'Copy runbook + script to SSD' {
    Copy-Item "$PSScriptRoot\windows-reinstall-runbook.md" "$Dst\" -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path "$Dst\..\windows-reinstall" | Out-Null
    Copy-Item $PSCommandPath "$Dst\..\windows-reinstall\backup.ps1" -Force -ErrorAction SilentlyContinue
}

# ---------- Summary ----------
if (-not $WhatIf) { Stop-Transcript | Out-Null }
Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
$results | Format-Table -AutoSize
Write-Host "Backup root: $Dst"
Get-ChildItem $Dst -Directory | ForEach-Object {
    $sz = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    "  {0,-14} {1,8:N1} GB" -f $_.Name, ($sz/1GB)
}
Write-Host "`nNEXT (do BEFORE wiping):" -ForegroundColor Yellow
Write-Host "  1. VERIFY: open files from $Dst; check tar sizes; 'git ls-remote' shows pushed commits."
Write-Host "  2. Make a SECOND copy of $Dst\secrets off this SSD (methe-server / email) — GPG keys are unrecoverable."
Write-Host "  3. Only then proceed to Phase 3 (wipe)."
if ($results.Status -contains 'FAIL') { Write-Host "`n*** Some steps FAILED — review above before trusting the backup. ***" -ForegroundColor Red }
