<#
.SYNOPSIS
  Trigger B for Windows: ff-pull every personal fleet-sync repo under the roots.
.DESCRIPTION
  Mirror of fleet-selfpull.sh. Registered as a ~10-min Scheduled Task by
  provision/windows.ps1. Only ff-pulls on `main`, clean tree, tracked upstream.
  Excludes thepureapp/. The pull fires each repo's post-merge hook (only
  machines has converge.sh -> schtasks machines-converge), so this NEVER
  converges itself. Never blocks on a credential prompt.
#>
param(
    [string[]] $Roots = @("$env:USERPROFILE", "$env:USERPROFILE\my", "$env:USERPROFILE\GitHub"),
    [int] $MaxDepth = 2
)
$ErrorActionPreference = 'Continue'
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10' }
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { Write-Error 'git not found'; exit 1 }

function Get-Repos([string]$Root, [int]$Depth) {
    $out = New-Object System.Collections.Generic.List[string]
    $q = New-Object System.Collections.Generic.Queue[object]
    $q.Enqueue([pscustomobject]@{ P = $Root; D = 0 })
    $skip = @('node_modules', '.cache', '.direnv', '.git')
    while ($q.Count) {
        $i = $q.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $i.P '.git')) { $out.Add($i.P); continue }
        if ($i.D -ge $Depth) { continue }
        Get-ChildItem -LiteralPath $i.P -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name } |
            ForEach-Object { $q.Enqueue([pscustomobject]@{ P = $_.FullName; D = $i.D + 1 }) }
    }
    return $out
}

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($repo in (Get-Repos $root $MaxDepth)) {
        $origin = & $git -C $repo remote get-url origin 2>$null
        if (-not $origin -or $origin -match 'thepureapp/') { continue }
        $branch = & $git -C $repo rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') { continue }
        if (& $git -C $repo status --porcelain 2>$null) { continue }   # dirty
        & $git -C $repo rev-parse '@{u}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }                           # no upstream
        & $git -C $repo pull --ff-only origin main 2>$null | Out-Null
    }
}
