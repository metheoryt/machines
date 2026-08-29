# provision/roles/dotfiles.ps1 — the `dotfiles` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleDotfiles.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.4
#
# dotfiles = the private metheoryt/dotfiles repo, bare-repo technique: ~/.dotfiles
# is a bare git repo whose work-tree is $HOME. No chezmoi, no render step.
#
# The 10-min sync Scheduled Task is registered by provision/windows.ps1, not
# here -- it needs the interactive-user principal that windows.ps1 resolves.

function Invoke-RoleDotfiles {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  dotfiles: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $remote = if ($env:DOTFILES_REMOTE) { $env:DOTFILES_REMOTE } else { 'git@github.com:metheoryt/dotfiles.git' }
    $gitDir = Join-Path $HOME '.dotfiles'
    $state  = Join-Path $HOME '.local\state\dotfiles-sync'
    # $Machine IS the logical fleet name: provision.ps1 either takes it as an
    # argument or resolves it via Get-FleetDetected, which returns the
    # fleet.json KEY ($p.Name), not the OS hostname it matched on.
    # Verified against provision/lib/Fleet.psm1:16-23.
    $branch = $Machine

    if ($Mode -eq 'dry-run') {
        Write-Host "  ~ would clone $remote (bare) -> $gitDir"
        Write-Host "  ~ would check out branch '$branch' (creating it from main if absent)"
        Write-Host "  ~ would record the branch at $state\branch"
        return
    }

    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { throw "dotfiles: git not found on PATH" }

    # 0. Never let a remote call sit at an interactive prompt. Same trap as the
    # posix side (provision/roles/dotfiles.sh, which carries the full note): on a
    # box whose known_hosts has no github.com entry -- every freshly provisioned
    # box -- ssh asks the operator to confirm the host key, provisioning has no
    # console to answer it, and the run HANGS rather than failing. Windows
    # OpenSSH prompts identically, so this side needs it too.
    #
    # BatchMode=yes turns a prompt into an exit code; StrictHostKeyChecking=accept-new
    # is what still lets a FIRST-time key through unattended (a CHANGED key hard-fails).
    # Both, or the outcome is broken in one direction or the other.
    #
    # These are process-scoped: PowerShell has no function-scoped environment, so
    # unlike the posix side they persist for the rest of the run. That is
    # acceptable -- every later git call here wants the same posture -- but it is
    # the reason a caller's own GIT_SSH_COMMAND is honoured rather than replaced.
    if (-not $env:GIT_SSH_COMMAND) {
        $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10'
    }
    $env:GIT_TERMINAL_PROMPT = '0'

    # 1. Clone the bare repo if absent.
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Write-Host "  dotfiles: cloning $remote -> $gitDir ..."
        & $git clone --quiet --bare $remote $gitDir
        if ($LASTEXITCODE -ne 0) {
            throw ("dotfiles: clone failed. Under BatchMode ssh never prompts, so this is one of: " +
                   "this box's key is not registered for the private repo; github's host key CHANGED " +
                   "(accept-new does not accept a swap); or the remote is unreachable. " +
                   "Reproduce with: ssh -o BatchMode=yes -T git@github.com")
        }
    }
    function Df { & $git --git-dir=$gitDir --work-tree=$HOME @args }
    Df config status.showUntrackedFiles no | Out-Null
    # `git clone --bare` sets NO remote.origin.fetch, so a bare clone has no
    # refs/remotes/origin/* at all and every origin/main / origin/<branch>
    # reference below -- and in the sync task -- fails to resolve. Idempotent.
    Df config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' | Out-Null

    # 2. Check out this host's branch, creating it from main if it does not exist.
    #
    # THE CHECKOUT MUST BE GUARDED, same as the posix side: git refuses it when
    # an untracked file already occupies a tracked path, which is the normal
    # case on a box that has been in use. Unguarded, HEAD stays on the clone's
    # default and the sync task then refuses every tick silently.
    Df fetch --quiet origin 2>$null | Out-Null
    Df rev-parse --verify --quiet "refs/heads/$branch" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Df checkout --quiet $branch | Out-Null
    } else {
        Df rev-parse --verify --quiet "refs/remotes/origin/$branch" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Df checkout --quiet -b $branch --track "origin/$branch" | Out-Null
        } else {
            Write-Host "  dotfiles: branch '$branch' does not exist - creating it from origin/main."
            Df checkout --quiet -b $branch origin/main | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Df push --quiet -u origin $branch | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  dotfiles: could not push the new branch - it stays local until the next sync tick."
                }
            }
        }
    }
    $head = (Df rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($head -ne $branch) {
        throw ("dotfiles: HEAD is '$head', not '$branch'. The checkout was refused - untracked " +
               "files in `$HOME already occupy tracked paths (git named them above). Back each " +
               "one up, delete it, and re-run. Not recording the branch: a sync task on the " +
               "wrong branch refuses every tick silently.")
    }

    # 3. Record the branch for the sync task. The task must not resolve fleet
    #    identity itself; it reads this file and refuses if HEAD disagrees.
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $state 'branch') -Value $branch -NoNewline

    Write-Host "  dotfiles: $gitDir on branch '$branch'."
}
