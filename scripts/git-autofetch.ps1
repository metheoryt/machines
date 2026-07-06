<#
.SYNOPSIS
  Fetch refs (no pull) for every git repo under the given roots.

.DESCRIPTION
  The Windows counterpart of modules/system/git-autofetch.nix. Registered as a
  Scheduled Task that runs every ~10 minutes (see "Register" below). It only
  refreshes remote-tracking refs, so `git status` / the shell prompt can show
  "behind by N" without anyone fetching first. It NEVER pulls/merges/rebases and
  never touches a working tree — the actual pull is left to you / the agent.

  Safety: never blocks on an auth prompt (GIT_TERMINAL_PROMPT=0 + ssh BatchMode),
  prunes heavy vendored trees, and stops descending once a repo is found.

.PARAMETER Roots
  Directories scanned (up to -MaxDepth) for git repos. Default: this repo's own
  checkout (wherever it's cloned) + %USERPROFILE%\GitHub.

.PARAMETER MaxDepth
  How deep under each root to look for a repo. Default: 4.

.EXAMPLE
  # Register the Scheduled Task (run once, from the machines repo root):
  $ps1 = (Resolve-Path .\scripts\git-autofetch.ps1).Path
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
      -RepetitionInterval (New-TimeSpan -Minutes 10) `
      -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
      -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit (New-TimeSpan -Minutes 9)
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
  Register-ScheduledTask -TaskName 'git-autofetch' -Action $action -Trigger $trigger `
      -Settings $settings -Principal $principal -Force
#>
param(
    [string[]] $Roots = @("$env:USERPROFILE\GitHub"),
    [int] $MaxDepth = 4
)

$ErrorActionPreference = 'Continue'

# Always include the repo THIS script ships in, so the machines checkout is
# fetched wherever it lives (~\machines, ~\GitHub\machines, anywhere) — not just
# under the conventional ~\GitHub fleet root. $PSScriptRoot = <repo>\scripts.
$repoRoot = Split-Path $PSScriptRoot -Parent
if ($repoRoot -and ($Roots -notcontains $repoRoot)) { $Roots += $repoRoot }

# Never block on a credential / host-key prompt — skip unreachable repos silently.
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $env:GIT_SSH_COMMAND) {
    $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10'
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Write-Error 'git not found on PATH'; exit 1 }
$gitExe = $git.Source

# Breadth-first scan that prunes heavy dirs and stops descending into a repo
# once its .git is found (so we never crawl a repo's own history / node_modules).
function Find-GitRepos {
    param([string] $Root, [int] $MaxDepth)
    $results = New-Object System.Collections.Generic.List[string]
    $skip = @('node_modules', '.cache', '.direnv', '.git')
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $item.Path '.git')) {
            $results.Add($item.Path)   # it's a repo
            continue                   # don't descend into it
        }
        if ($item.Depth -ge $MaxDepth) { continue }
        Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name } |
            ForEach-Object { $queue.Enqueue([pscustomobject]@{ Path = $_.FullName; Depth = $item.Depth + 1 }) }
    }
    return $results
}

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($repo in (Find-GitRepos -Root $root -MaxDepth $MaxDepth)) {
        & $gitExe -C $repo fetch --all --prune --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Output "fetch failed/skipped: $repo" }
    }
}
