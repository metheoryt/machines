<#
  Windows reinstall — restore (guided orchestrator). Mirror of backup.ps1.

  Discovers a backup produced by backup.ps1, lets you select one, verifies
  destinations, and restores. GUIDED, not a blind mirror: the safe,
  app-independent items are copied automatically; the nuanced / app-first /
  judgement steps (WSL import, agent-config bootstrap, winget import, app
  configs, cloud reconcile) are PRINTED as exact commands and left for you,
  per the runbook Phase 4.

  DRY RUN BY DEFAULT — it writes nothing until you pass -Go.

  Usage (elevated PowerShell recommended):
      .\restore.ps1                       # discover + verify, write nothing
      .\restore.ps1 -Go                   # perform the AUTOMATIC restores
      .\restore.ps1 -Go -Force            # also overwrite non-empty .ssh / repos (careful)
      .\restore.ps1 -BackupRoot R:\backup # skip discovery, use this backup
#>
[CmdletBinding()]
param(
    [string]$BackupRoot,                 # explicit <L>:\backup; omitted => auto-discover
    [switch]$Go,                         # actually perform the automatic restores
    [switch]$Force,                      # allow overwrite of non-empty .ssh / repos
    [string]$TargetHome = $env:USERPROFILE
)
$ErrorActionPreference = 'Stop'

$rc = '/E','/R:1','/W:1','/NP','/NFL','/NDL','/MT:8'
# Repos that ARE this config repo: the fresh clone (from install.ps1) is
# authoritative, so we don't overlay the backup's copy of it.
$ConfigRepoNames = 'machines','nix'

function Restore-Dir($src, $dst) {
    robocopy $src $dst @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy error $LASTEXITCODE ($src -> $dst)" }
}
function Fix-SshPerms($dst) {
    # Lock .ssh to the current user only (inverse of what the backup preserved).
    icacls $dst /inheritance:r | Out-Null
    icacls $dst /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
    Get-ChildItem $dst -File -ErrorAction SilentlyContinue | ForEach-Object {
        icacls $_.FullName /inheritance:r | Out-Null
        icacls $_.FullName /grant:r "$($env:USERNAME):F" | Out-Null
    }
}
function Dir-Action($dst, [switch]$Sensitive) {
    if (-not (Test-Path $dst)) { return 'create' }
    if (@(Get-ChildItem $dst -Force -ErrorAction SilentlyContinue).Count -eq 0) { return 'create' }
    if ($Sensitive -and -not $Force) { return 'SKIP (exists — pass -Force)' }
    return 'merge'
}

function Get-BackupInfo($root) {
    if (-not (Test-Path $root)) { return $null }
    $newestLog = Get-ChildItem (Join-Path $root 'logs') -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $sizeGB = [math]::Round(((Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum)/1GB, 1)
    [pscustomobject]@{
        Root      = $root
        SizeGB    = $sizeGB
        NewestLog = if ($newestLog) { $newestLog.LastWriteTime } else { $null }
        WslTars   = @(Get-ChildItem (Join-Path $root 'wsl') -Filter '*.tar' -ErrorAction SilentlyContinue | Select-Object -Expand Name)
        Repos     = @(Get-ChildItem (Join-Path $root 'repos') -Directory -ErrorAction SilentlyContinue | Select-Object -Expand Name)
    }
}

function Find-Backups {
    $out = @()
    foreach ($v in (Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)) {
        $root   = "$($v.DriveLetter):\backup"
        $marker = Join-Path $root 'windows-reinstall-runbook.md'
        $struct = (Test-Path (Join-Path $root 'logs')) -or (Test-Path (Join-Path $root 'repos'))
        if ((Test-Path $marker) -or ((Test-Path $root) -and $struct)) {
            $info = Get-BackupInfo $root
            $out += ($info | Add-Member -NotePropertyName Drive -NotePropertyValue $v.DriveLetter -PassThru |
                             Add-Member -NotePropertyName Label -NotePropertyValue $v.FileSystemLabel -PassThru)
        }
    }
    $out
}

# ---------- Select a backup ----------
Write-Host "=== machines — restore (dry run: $([bool](-not $Go))) ===" -ForegroundColor Cyan
Write-Host "Target user home: $TargetHome  (user: $env:USERNAME)`n"

if ($BackupRoot) {
    $sel = Get-BackupInfo $BackupRoot
    if (-not $sel) { throw "BackupRoot '$BackupRoot' not found or not a backup." }
    Write-Host "Using backup: $($sel.Root)"
} else {
    $cands = @(Find-Backups)
    if ($cands.Count -eq 0) {
        throw "No backup found on any drive (looked for <L>:\backup with the runbook marker + repos/logs). Plug in the SSD and re-run, or pass -BackupRoot."
    }
    Write-Host "Found $($cands.Count) backup(s):" -ForegroundColor Green
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        "  [{0}] {1}  label='{2}'  {3} GB  newest log: {4}" -f `
            $i, $c.Root, $c.Label, $c.SizeGB, $(if ($c.NewestLog) { $c.NewestLog } else { '?' })
        "        repos: $($c.Repos -join ', ')"
        "        wsl:   $($c.WslTars -join ', ')"
    }
    if ($cands.Count -eq 1) {
        $sel = $cands[0]
        $ans = Read-Host "`nUse this backup? [Y/n]"
        if ($ans -and $ans -notmatch '^(y|yes)$') { Write-Host "Aborted."; return }
    } else {
        $pick = Read-Host "`nSelect a backup by index [0-$($cands.Count-1)]"
        if ($pick -notmatch '^\d+$' -or [int]$pick -ge $cands.Count) { throw "Invalid selection." }
        $sel = $cands[[int]$pick]
    }
}
$Root = $sel.Root
Write-Host "`nSelected: $Root`n" -ForegroundColor Green

# ---------- Build the AUTOMATIC restore plan (evaluated dry, then executed on -Go) ----------
$plan = [System.Collections.Generic.List[object]]::new()
function Add-Plan($name, $src, $dst, $kind, $note, $action) {
    $plan.Add([pscustomobject]@{ Name=$name; Source=$src; Dest=$dst; Kind=$kind; Note=$note; Action=$action })
}

# Repos (full incl .git) -> ~\GitHub\<name>, except the config repo (fresh clone wins)
foreach ($r in $sel.Repos) {
    $src = Join-Path $Root "repos\$r"
    if ($r -in $ConfigRepoNames) {
        Add-Plan "repo:$r" $src "(skipped)" 'skip' 'config repo — fresh clone is authoritative; backup copy kept on SSD for its stashes' 'SKIP (config repo)'
        continue
    }
    $dst = Join-Path $TargetHome "GitHub\$r"
    Add-Plan "repo:$r" $src $dst 'dir' 'full incl .git (stashes/uncommitted)' (Dir-Action $dst -Sensitive)
}

# .ssh -> ~\.ssh + perms fix
if (Test-Path (Join-Path $Root 'home\.ssh')) {
    $dst = Join-Path $TargetHome '.ssh'
    Add-Plan '.ssh' (Join-Path $Root 'home\.ssh') $dst 'ssh' 'then icacls: current user only' (Dir-Action $dst -Sensitive)
}

# Plain dotfiles/dirs from home\ (exclude agent config + AppData + .ssh, handled elsewhere)
$homeExclude = '.claude','.codex','AppData','.ssh'
Get-ChildItem (Join-Path $Root 'home') -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $homeExclude } |
    ForEach-Object {
        $dst = Join-Path $TargetHome $_.Name
        if ($_.PSIsContainer) {
            Add-Plan "dotdir:$($_.Name)" $_.FullName $dst 'dir' 'config dir' (Dir-Action $dst)
        } else {
            $act = if (Test-Path $dst) { 'overwrite' } else { 'create' }
            Add-Plan "file:$($_.Name)" $_.FullName $dst 'file' 'config/loose file' $act
        }
    }

# User data
if (Test-Path (Join-Path $Root 'Downloads')) {
    $dst = Join-Path $TargetHome 'Downloads'
    Add-Plan 'Downloads' (Join-Path $Root 'Downloads') $dst 'dir' '' (Dir-Action $dst)
}
# Obsidian: only auto-restore vaults that were backed up as a standalone local
# folder. Vaults that live INSIDE a cloud folder (e.g. G:\Мой диск\Obsidian on
# g16) ride along in the cloud copy below — copying them to ~\Obsidian would
# fork them from cloud sync, so those are surfaced as a GUIDED note instead.
foreach ($vault in (Get-ChildItem (Join-Path $Root 'Obsidian') -Directory -ErrorAction SilentlyContinue)) {
    $dst = Join-Path $TargetHome "Obsidian\$($vault.Name)"
    Add-Plan "obsidian:$($vault.Name)" $vault.FullName $dst 'dir' 're-open in Obsidian; move if you prefer another path' (Dir-Action $dst)
}
# Cloud folders -> *-from-backup (NOT the live sync folder — reconcile, don't clobber cloud)
foreach ($cloud in 'OneDrive','GoogleDrive') {
    $src = Join-Path $Root $cloud
    if (Test-Path $src) {
        $dst = Join-Path $TargetHome "$cloud-from-backup"
        Add-Plan $cloud $src $dst 'dir' 'restored beside (not into) live sync — reconcile per runbook 4.7' (Dir-Action $dst)
    }
}

# ---------- Verify gate: print the plan ----------
Write-Host "================ RESTORE PLAN (automatic items) ================" -ForegroundColor Yellow
$plan | Format-Table Name, Action, @{n='Destination';e={$_.Dest}}, Note -AutoSize -Wrap

$stubCsv = Join-Path $Root 'OneDrive-STUBS-NOT-ON-DISK.csv'
if (Test-Path $stubCsv) {
    Write-Host "*** WARNING: this backup has $stubCsv ***" -ForegroundColor Red
    Write-Host "    Some OneDrive files were online-only at backup time and are NOT in the copy." -ForegroundColor Red
    Write-Host "    Recover them from onedrive.live.com; the OneDrive-from-backup folder is incomplete." -ForegroundColor Red
}

# ---------- GUIDED steps (printed, never auto-run) ----------
Write-Host "`n================ GUIDED steps (do these by hand — order matters) ================" -ForegroundColor Yellow
$G = @()
$G += "1. Windows apps (winget):"
$G += "     - Prune the dropped IDs from the JSON first (runbook Appendix B), then:"
$G += "       winget import `"$Root\inventory\winget-packages.json`""
$G += "     - Reinstall non-winget keepers by hand: JetBrains Toolbox -> PyCharm, NCALayer."
$G += ""
$G += "2. Agent config (.claude/.codex) — BOOTSTRAP, don't copy verbatim:"
$G += "     cd $TargetHome\GitHub\machines; just agent-bootstrap   # (+ agent-bootstrap-work if used)"
$G += "   Then restore ONLY machine-local bits from the backup (not the symlinked trees):"
foreach ($p in '.claude','.codex') {
    $mp = Join-Path $Root "home\$p"
    if (Test-Path $mp) {
        $G += "     copy $mp\.credentials.json , settings.local.json , projects\  ->  $TargetHome\$p\"
    }
}
$G += ""
if ($sel.WslTars.Count) {
    $G += "3. WSL:  wsl --install   (reboot if prompted), then per distro:"
    foreach ($t in $sel.WslTars) {
        $name = [IO.Path]::GetFileNameWithoutExtension($t)
        $G += "     wsl --import $name C:\WSL\$name `"$Root\wsl\$t`""
    }
    $G += "   GPG/SSH inside WSL ride along in the tar; loose copies are in $Root\secrets\ if needed."
    $G += ""
}
# App configs — install the app, close it, THEN drop these in
$appMap = @(
    @{ n='Windows Terminal'; s='home\AppData\WindowsTerminal'; d='%LOCALAPPDATA%\Packages\<Terminal pkg>\LocalState\ (settings.json)' }
    @{ n='PowerToys';        s='home\AppData\Local\PowerToys'; d='%LOCALAPPDATA%\Microsoft\PowerToys\' }
    @{ n='NCALayer';         s='home\AppData\NCALayer';        d='%APPDATA%\NCALayer\' }
    @{ n='AIMP';             s='home\AppData\AIMP';            d='%APPDATA%\AIMP\' }
    @{ n='Telegram tdata';   s='home\AppData\Telegram Desktop';d='point AyuGram import at this, or %APPDATA%\Telegram Desktop\' }
    @{ n='RustDesk';         s='home\AppData\RustDesk\config'; d='%APPDATA%\RustDesk\config\ (install, CLOSE it, then copy, then start)' }
)
$present = $appMap | Where-Object { Test-Path (Join-Path $Root $_.s) }
if ($present) {
    $G += "4. App configs — install the app, CLOSE it, then copy back:"
    foreach ($a in $present) { $G += "     $($a.n):  $Root\$($a.s)  ->  $($a.d)" }
    $G += ""
}
$sys = @()
if (Test-Path (Join-Path $Root 'inventory\hkcu-environment.reg')) {
    $sys += "     Env vars (review, don't blind-merge):  reg import `"$Root\inventory\hkcu-environment.reg`""
}
$wifi = @(Get-ChildItem (Join-Path $Root 'secrets\wifi') -Filter '*.xml' -ErrorAction SilentlyContinue)
if ($wifi.Count) {
    $sys += "     Wi-Fi ($($wifi.Count) profiles):  netsh wlan add profile filename=`"$Root\secrets\wifi\<name>.xml`""
}
if ($sys.Count) { $G += "5. System settings:"; $G += $sys; $G += "" }
$G += "6. Docker / qaz-law DB: install Docker Desktop, bring the stack up EMPTY, re-run ingestion (DB was not backed up)."
$G += ""
$G += "7. Cloud: set up OneDrive/Google Drive fresh; reconcile against the *-from-backup folders (runbook Phase 4.7). SSD copy is authoritative."
# Obsidian — vaults may be a standalone folder (auto-restored above) OR live
# inside a cloud folder (this machine: G:\Мой диск\Obsidian). Surface both so a
# cloud-embedded vault is never silently missed.
$obsLocal = @(Get-ChildItem (Join-Path $Root 'Obsidian') -Directory -ErrorAction SilentlyContinue)
$obsCloud = @()
foreach ($cloud in 'GoogleDrive','OneDrive') {
    foreach ($v in (Get-ChildItem (Join-Path $Root "$cloud\Obsidian") -Directory -ErrorAction SilentlyContinue)) {
        $obsCloud += "$cloud\Obsidian\$($v.Name)"
    }
}
if ($obsLocal.Count -or $obsCloud.Count) {
    $G += ""
    $G += "8. Obsidian vaults:"
    if ($obsLocal.Count) {
        $G += "     Standalone vaults were auto-restored to $TargetHome\Obsidian\ — just re-open them in Obsidian."
    }
    if ($obsCloud.Count) {
        $G += "     These vaults live INSIDE a cloud folder, so they return when the cloud re-syncs. Do NOT copy them out (that forks them from sync):"
        foreach ($v in $obsCloud) { $G += "       $Root\$v   (offline safety copy on the SSD)" }
        $G += "     After the cloud folder finishes syncing, re-open each vault in Obsidian from its synced path (e.g. G:\Мой диск\Obsidian\...)."
    }
}
$G | ForEach-Object { Write-Host $_ }

# ---------- Execute (only on -Go) ----------
if (-not $Go) {
    Write-Host "`n--- DRY RUN. Nothing was written. Re-run with -Go to perform the AUTOMATIC items above. ---" -ForegroundColor Cyan
    Write-Host "    (-Force also overwrites non-empty .ssh / repos.)  Guided steps are always manual." -ForegroundColor Cyan
    return
}

$toDo = @($plan | Where-Object { $_.Action -notlike 'SKIP*' })
Write-Host "`nAbout to perform $($toDo.Count) automatic restore action(s) into $TargetHome." -ForegroundColor Yellow
$ok = Read-Host "Proceed? [y/N]"
if ($ok -notmatch '^(y|yes)$') { Write-Host "Aborted — nothing written."; return }

$log = Join-Path $TargetHome "restore-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $log -Append | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
foreach ($item in $toDo) {
    Write-Host "`n=== $($item.Name) -> $($item.Dest) ===" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        switch ($item.Kind) {
            'dir'  { Restore-Dir $item.Source $item.Dest }
            'ssh'  { Restore-Dir $item.Source $item.Dest; Fix-SshPerms $item.Dest }
            'file' { New-Item -ItemType Directory -Force -Path (Split-Path $item.Dest) | Out-Null
                     Copy-Item $item.Source $item.Dest -Force }
        }
        $sw.Stop()
        $results.Add([pscustomobject]@{ Item=$item.Name; Status='OK'; Seconds=[int]$sw.Elapsed.TotalSeconds })
        Write-Host "  OK ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $results.Add([pscustomobject]@{ Item=$item.Name; Status='FAIL'; Seconds=[int]$sw.Elapsed.TotalSeconds })
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}
Stop-Transcript | Out-Null

Write-Host "`n================ RESTORE SUMMARY ================" -ForegroundColor Yellow
$results | Format-Table -AutoSize
Write-Host "Log: $log"
Write-Host "`nAutomatic items done. Now work through the GUIDED steps above (winget, agent bootstrap, WSL import, app configs, cloud reconcile)." -ForegroundColor Yellow
if ($results.Status -contains 'FAIL') { Write-Host "*** Some items FAILED — review above. ***" -ForegroundColor Red }
