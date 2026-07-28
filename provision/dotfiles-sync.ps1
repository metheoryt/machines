<#
.SYNOPSIS
  Dotfiles sync tick for Windows. Mirror of provision/dotfiles-sync.sh.
.DESCRIPTION
  ~/.dotfiles is a bare repo whose work-tree is $HOME. Pushes and merges
  origin/main in on every tick; commits tracked changes to this machine's branch
  once they have settled. The merge runs only after
  `git merge-tree --write-tree` proves the merge is conflict-free. The work-tree
  is a live home directory; a conflicted merge would write <<<<<<< markers into
  files the user needs to fix it. Registered as a ~10-min Scheduled Task by
  provision/windows.ps1.

  Exit 0 for every normal outcome including conflict and failed push. Exit 1
  only for a hard stop that needs a human (wrong branch, merge in progress).
#>
param(
    [string] $GitDir    = $(if ($env:DOTFILES_GIT_DIR)    { $env:DOTFILES_GIT_DIR }    else { Join-Path $HOME '.dotfiles' }),
    [string] $WorkTree  = $(if ($env:DOTFILES_WORK_TREE)  { $env:DOTFILES_WORK_TREE }  else { $HOME }),
    [string] $StateDir  = $(if ($env:DOTFILES_STATE_DIR)  { $env:DOTFILES_STATE_DIR }  else { Join-Path $HOME '.local\state\dotfiles-sync' })
)
$ErrorActionPreference = 'Continue'
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10' }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { exit 0 }                       # git absent: not enrolled, not an error
if (-not (Test-Path -LiteralPath $GitDir)) { exit 0 }

function Df { & $git --git-dir=$GitDir --work-tree=$WorkTree @args }

# 0. Lock. New-Item -ItemType Directory is atomic and fails if it exists, which
#    is the same primitive the posix side's mkdir fallback uses.
$lock = Join-Path $StateDir 'lock.d'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
if (Test-Path -LiteralPath $lock) {
    # A lock older than 30 minutes is stale: the timer fires every 10 and the
    # work takes seconds. Sweep rather than wedge forever after a hard kill.
    if ((Get-Item $lock).LastWriteTime -lt (Get-Date).AddMinutes(-30)) {
        Remove-Item -LiteralPath $lock -Force -Recurse -EA SilentlyContinue
    } else { exit 0 }
}
try { New-Item -ItemType Directory -Path $lock -EA Stop | Out-Null } catch { exit 0 }

try {
    # 1. Guard.
    $branchFile = Join-Path $StateDir 'branch'
    if (-not (Test-Path -LiteralPath $branchFile)) { exit 0 }
    $expected = (Get-Content -LiteralPath $branchFile -Raw).Trim()
    if (-not $expected) { exit 0 }

    foreach ($p in @('MERGE_HEAD','rebase-merge','rebase-apply')) {
        if (Test-Path -LiteralPath (Join-Path $GitDir $p)) {
            Write-Error "dotfiles-sync: a merge or rebase is in progress - resolve it by hand"; exit 1
        }
    }
    $head = (Df rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($head -ne $expected) {
        Write-Error "dotfiles-sync: HEAD is '$head', expected '$expected' - committing nothing"; exit 1
    }

    # 2. Commit -- but only once the tracked diff has SETTLED. Mirror of the .sh
    #    twin's sync_should_commit; see its comment for why this is a debounce
    #    and not a daily gate (this script commits BEFORE it merges, and
    #    merge-tree preflights committed trees only, so a long gate lets the
    #    real merge at step 6 refuse silently).
    $pend   = Join-Path $StateDir 'pending.hash'
    $since  = Join-Path $StateDir 'pending.since'
    $maxAge = if ($env:DOTFILES_SYNC_MAX_AGE) { [int]$env:DOTFILES_SYNC_MAX_AGE } else { 7200 }
    $doCommit = $false

    if ($env:DOTFILES_SYNC_FORCE) {
        $doCommit = $true
    } else {
        Df diff --cached --quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $doCommit = $true          # staged by hand: explicit intent, never debounced
        } else {
            Df diff --quiet | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Remove-Item -LiteralPath $pend,$since -Force -EA SilentlyContinue
            } else {
                # Hash, never store: tracked files include .netrc and
                # .aws/credentials, and StateDir must not hold a second copy.
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $txt = (Df diff | Out-String)
                $cur = [BitConverter]::ToString(
                           $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))
                       ).Replace('-','')
                $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                # `since` is written only on the clean -> dirty transition, so a
                # diff that keeps changing does not keep resetting the valve.
                if (-not (Test-Path -LiteralPath $since)) {
                    Set-Content -LiteralPath $since -Value $now
                }
                $t0 = 0
                [void][int]::TryParse((Get-Content -LiteralPath $since -Raw).Trim(), [ref]$t0)
                if ($t0 -le 0) { $t0 = $now }
                if (($now - $t0) -ge $maxAge) {
                    $doCommit = $true              # valve
                } else {
                    $prev = if (Test-Path -LiteralPath $pend) {
                        (Get-Content -LiteralPath $pend -Raw).Trim()
                    } else { '' }
                    Set-Content -LiteralPath $pend -Value $cur
                    if ($prev -and $prev -eq $cur) { $doCommit = $true }
                }
            }
        }
    }

    if ($doCommit) {
        # Tracked modifications and deletions ONLY. Never -A.
        Df add -u | Out-Null
        Df diff --cached --quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $names = @(Df diff --cached --name-only)
            $shown = ($names | Select-Object -First 5) -join ' '
            if ($names.Count -gt 5) { $shown = "$shown ... (+$($names.Count - 5))" }
            Df commit -q -m "auto($expected): $shown" | Out-Null
        }
        Remove-Item -LiteralPath $pend,$since -Force -EA SilentlyContinue
    }

    # 3. Push. Offline / expired token is non-fatal; next tick retries.
    Df push -q origin $expected 2>$null | Out-Null

    # 4. Fetch. EXPLICIT REFSPEC, deliberately: `git clone --bare` configures no
    #    remote.origin.fetch, so a bare dotfiles repo has NO refs/remotes/origin/*
    #    and a plain `fetch origin main` lands in FETCH_HEAD only -- every later
    #    mention of origin/main would then fail to resolve and the merge step
    #    would silently no-op forever.
    Df fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 0 }

    # 5. Preflight. merge-tree --write-tree needs git 2.38+; below that floor,
    #    commit and push only -- never attempt an unpreflighted merge.
    $v = ((& $git --version) -split ' ')[2] -split '\.'
    $ok = ([int]$v[0] -gt 2) -or ([int]$v[0] -eq 2 -and [int]$v[1] -ge 38)
    if (-not $ok) {
        Write-Warning "dotfiles-sync: git $($v -join '.') lacks 'merge-tree --write-tree' (needs 2.38+) - skipping merge"
        exit 0
    }
    $marker = Join-Path $StateDir 'conflict'
    Df merge-tree --write-tree $expected origin/main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Set-Content -LiteralPath $marker -Value @(
            "conflict merging origin/main into $expected"
            "detected: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            "resolve by hand, then the next tick clears this file:"
            "  git --git-dir=$GitDir --work-tree=$WorkTree merge origin/main"
        )
        Write-Warning "dotfiles-sync: origin/main conflicts with $expected - `$HOME untouched; see $marker"
        exit 0
    }
    Remove-Item -LiteralPath $marker -Force -EA SilentlyContinue

    # 6. Merge. Preflight was clean, so this cannot conflict.
    Df merge -q --no-edit --ff origin/main 2>$null | Out-Null
    exit 0
}
finally { Remove-Item -LiteralPath $lock -Force -Recurse -EA SilentlyContinue }
