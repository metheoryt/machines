# provision/roles/backup-client.ps1 — the `backup-client` role executor (Windows).
# Dot-sourced by provision.ps1. Defines Invoke-RoleBackupClient.
#
# The Windows-native half of the design in the plan's Task 5: Windows and each
# WSL distro on it are SEPARATE boxes with separate things to lose, so each gets
# its own client and its own backup/<identity>/. This side handles the Windows
# member (`desktop`, `g15`); the distros install themselves through step 6 of
# provision-wsl.sh, using provision/backup-client.sh. Neither reaches across the
# machine boundary.
#
# THE PER-DIR CONTRACT IS install-tasks.ps1, and it is a separate file from the
# posix install-tasks.sh for the same reason latitude's and desktop-wsl's .sh
# files differ from each other: the SCOPE decision cannot be made here. On posix
# it is sudo-or-not (system vs user systemd units); on Windows `resticprofile
# schedule` writes Task Scheduler entries and wants an elevated shell. That
# belongs next to the config that declares the schedule, not in this executor.
#
# UNVERIFIED. Nothing here has run on desktop or g15 yet — there is no
# backup/desktop/ or backup/g15/ to run it against, deliberately (choosing what
# is irreplaceable on a box nobody has inventoried is real work, not a default).
# The retired backup/_retired-homeserver/install-tasks.bat ends in `pause`, which
# says the old Windows client was launched by hand in a console and never by a
# provisioner. Treat the apply arm as untested until it is run.

function Invoke-RoleBackupClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )

    $repo   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $dir    = Join-Path $repo "backup/$Machine"
    $script = Join-Path $dir 'install-tasks.ps1'

    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        # A DECLARED-BUT-UNCONFIGURED CLIENT IS A SKIP, NOT A FAILURE — same
        # contract as the posix side, so a half-built client stays visible
        # without turning a provision run red.
        Write-Host "  backup-client: no profile dir for $Machine (skipped)"
        Write-Host "                 expected $dir"
        return
    }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        # Config with no way to install it. Loud, because there is nothing
        # sensible to guess — see the scope note in the header.
        throw "backup-client: $dir exists but has no install-tasks.ps1"
    }

    $missing = @()
    foreach ($b in 'restic', 'resticprofile') {
        if (-not (Get-Command $b -ErrorAction SilentlyContinue)) { $missing += $b }
    }

    if ($Mode -ne 'apply') {
        # DRY RUN WRITES NOTHING. `resticprofile schedule` creates Task Scheduler
        # entries and has no dry-run of its own, so the preview can only print.
        Write-Host "  backup-client: identity $Machine, profile dir $dir"
        if ($missing.Count) {
            Write-Host "  backup-client: would install $($missing -join ' ')"
        } else {
            Write-Host "  backup-client: restic + resticprofile present"
        }
        Write-Host "  backup-client: would run: $script"
        return
    }

    if ($missing.Count) {
        Write-Host "  backup-client: installing $($missing -join ' ')..."
        # winget, --scope=Machine — the same installer the fleet already ships.
        & (Join-Path $repo 'backup/restic-install.bat')
        if ($LASTEXITCODE -ne 0) { throw "backup-client: restic-install.bat exited $LASTEXITCODE" }
    }

    # Elevation is the install script's business, not this executor's — it is
    # part of the same scope decision. Warn rather than refuse, so a box that
    # schedules per-user tasks is not blocked by a check written for per-machine
    # ones.
    $admin = ([Security.Principal.WindowsPrincipal] `
              [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host "  backup-client: note — not elevated; a machine-scope Task"
        Write-Host "                 Scheduler entry needs an admin shell."
    }

    & $script
    if ($LASTEXITCODE -ne 0) { throw "backup-client: $script exited $LASTEXITCODE" }
}
