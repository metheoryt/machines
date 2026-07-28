# provision/lib/fleet-ssh-config.ps1 — render + merge the fleet SSH client block
# on a WINDOWS-NATIVE member. Dot-source me; or run with -SelfTest.
#
# Why this exists at all: provision/windows.ps1 step 7 only ever configured the
# SERVER side (sshd, administrators_authorized_keys, firewall), so the Windows
# members had no ~/.ssh/config fleet block. `ssh latitude` there fell through to
# the local username and failed with `methe@latitude: Permission denied`, which
# took fd_run — and so /ship's fleet-pull and kb-refresh's fleet-gather — with it.
#
# Why not reuse provision/ssh-wsl.sh's renderer: it is jq-based, and Git Bash on
# these boxes has no jq (verified on server, 2026-07-29). PowerShell parses JSON
# natively, so the port costs less than shipping jq to every Windows box.
#
# Deliberately kept to two pure functions plus a self-test, so the logic is
# exercisable without touching $HOME:
#   Render-FleetSshConfig  fleet.json text -> the stanzas
#   Merge-FleetSshConfig   existing config + marked block -> new content
#
# Contract parity with ssh-wsl.sh's renderer, including the 2026-07-29 fix:
# EVERY block carries a User line. Omitting it to mean "the default" is only
# correct where the local user happens to match, which is exactly what broke here.
#
# One deliberate divergence: IdentityFile. ssh-wsl.sh hardcodes ~/.ssh/id_fleet;
# the Windows boxes' fleet key is ~/.ssh/id_ed25519 (that is the key latitude
# trusts). So the path is a parameter with a Windows-appropriate default rather
# than a constant.

param([switch]$SelfTest)

Set-StrictMode -Version Latest

$script:FleetSshMarkerBegin = '# >>> fleet-ssh (managed by windows.ps1) >>>'
$script:FleetSshMarkerEnd   = '# <<< fleet-ssh <<<'

function Get-FleetSshMarkers {
    [PSCustomObject]@{ Begin = $script:FleetSshMarkerBegin; End = $script:FleetSshMarkerEnd }
}

# Render-FleetSshConfig: fleet.json content -> stanza text (no markers).
# HostName only when the member declares ssh.host (the hub). User always.
# Trailing wildcard block last, so a *.gg.ez MagicDNS name still resolves to the
# right user and key even for a member absent from the manifest.
function Render-FleetSshConfig {
    param(
        [Parameter(Mandatory = $true)][string]$FleetJson,
        [string]$IdentityFile = '~/.ssh/id_ed25519'
    )

    $fleet = $FleetJson | ConvertFrom-Json
    # Probe via PSObject rather than `-not $fleet.machines`: Set-StrictMode Latest
    # THROWS on reading a property that does not exist, so the direct test would
    # raise PropertyNotFoundException instead of reporting a malformed manifest.
    if (($fleet.PSObject.Properties.Name -notcontains 'machines') -or (-not $fleet.machines)) {
        throw 'fleet.json has no .machines object'
    }

    $blocks = New-Object System.Collections.Generic.List[string]

    # PSCustomObject preserves JSON property order, so output order matches the
    # manifest — which keeps the rendered block diff-stable across runs.
    foreach ($entry in $fleet.machines.PSObject.Properties) {
        $name = $entry.Name
        $m    = $entry.Value

        $sshNode = $null
        if ($m.PSObject.Properties.Name -contains 'ssh') { $sshNode = $m.ssh }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Host $name")

        if ($sshNode -and ($sshNode.PSObject.Properties.Name -contains 'host') -and $sshNode.host) {
            $lines.Add("  HostName $($sshNode.host)")
        }

        $user = 'me'
        if ($sshNode -and ($sshNode.PSObject.Properties.Name -contains 'user') -and $sshNode.user) {
            $user = $sshNode.user
        }
        $lines.Add("  User $user")

        $lines.Add("  IdentityFile $IdentityFile")
        $lines.Add('  StrictHostKeyChecking accept-new')

        $blocks.Add(($lines -join "`n"))
    }

    $blocks.Add(("Host *.gg.ez`n  User me`n  IdentityFile $IdentityFile`n  StrictHostKeyChecking accept-new"))

    return ($blocks -join "`n`n")
}

# Merge-FleetSshConfig: drop any prior marked span (markers inclusive), keep
# everything else verbatim, append the block exactly once separated by one blank
# line. Idempotent by construction: merge(merge(x)) == merge(x).
function Merge-FleetSshConfig {
    param(
        [string]$Existing = '',
        [Parameter(Mandatory = $true)][string]$Block
    )

    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in ($Existing -split "`r?`n")) {
        if ($line -eq $script:FleetSshMarkerBegin) { $skip = $true;  continue }
        if ($line -eq $script:FleetSshMarkerEnd)   { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }

    # Trim trailing blanks so repeated merges cannot accrete blank lines.
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -match '^\s*$') { $kept.RemoveAt($kept.Count - 1) }

    if ($kept.Count -eq 0) { return $Block }
    return (($kept -join "`n") + "`n`n" + $Block)
}

# Build the marked block for a rendered stanza set.
function New-FleetSshBlock {
    param([Parameter(Mandatory = $true)][string]$Stanzas)
    return "$script:FleetSshMarkerBegin`n$Stanzas`n$script:FleetSshMarkerEnd"
}

# ── Self-test ─────────────────────────────────────────────────────────────────
# `pwsh -File provision/lib/fleet-ssh-config.ps1 -SelfTest` (or powershell.exe).
# Pure — touches no files. Exits non-zero on the first failure.
if ($SelfTest) {
    $failures = 0
    function T($ok, $what) {
        if ($ok) { Write-Host "  PASS $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
    }

    $fixture = @'
{ "machines": {
    "latitude": { "platform": "debian",  "tailnet": { "ip": "100.64.0.8" } },
    "server":   { "platform": "windows", "ssh": { "user": "methe" } },
    "hub":      { "platform": "debian",  "ssh": { "user": "debian", "host": "cyphy.kz" } }
} }
'@

    $r = Render-FleetSshConfig -FleetJson $fixture -IdentityFile '~/.ssh/id_ed25519'

    T ($r -match '(?m)^Host latitude$')                  'latitude block present'
    T ($r -match '(?m)^  HostName cyphy\.kz$')           'hub gets HostName'
    T ((([regex]::Matches($r, '(?m)^  HostName ')).Count) -eq 1) 'only the hub gets a HostName'
    # The regression this file exists for: a member with no ssh.user must still
    # get an explicit `User me`, because the local user here is not `me`.
    T ((([regex]::Matches($r, '(?m)^  User ')).Count) -eq 4)     'every block + wildcard carries User'
    T ($r -match '(?m)^  User methe$')                   'server -> User methe'
    T ($r -match '(?m)^  User debian$')                  'hub -> User debian'
    T ((([regex]::Matches($r, '(?m)^  User me$')).Count) -eq 2)  'latitude and wildcard -> User me'
    T ((([regex]::Matches($r, '(?m)^  IdentityFile ~/\.ssh/id_ed25519$')).Count) -eq 4) 'IdentityFile on every block'
    T ((([regex]::Matches($r, '(?m)^  StrictHostKeyChecking accept-new$')).Count) -eq 4) 'StrictHostKeyChecking on every block'
    T ($r -match '(?m)^Host \*\.gg\.ez$')                'wildcard block present'
    T ($r.TrimEnd().EndsWith('StrictHostKeyChecking accept-new')) 'wildcard block is last'

    # Merge: existing content survives, block lands once, and re-merging is a no-op.
    $existing = "Host github.com`n    User git`n    IdentityFile ~/.ssh/id_ed25519_gh"
    $block    = New-FleetSshBlock -Stanzas $r
    $once     = Merge-FleetSshConfig -Existing $existing -Block $block
    $twice    = Merge-FleetSshConfig -Existing $once     -Block $block

    T ($once -match '(?m)^Host github\.com$')            'merge keeps the pre-existing github.com block'
    T ($once -match '(?m)^    IdentityFile ~/\.ssh/id_ed25519_gh$') 'merge keeps its IdentityFile verbatim'
    T ((([regex]::Matches($once, [regex]::Escape($script:FleetSshMarkerBegin))).Count) -eq 1) 'exactly one begin marker'
    T ($once -eq $twice)                                 'merge is idempotent'
    T ((Merge-FleetSshConfig -Existing '' -Block $block) -eq $block) 'empty existing config yields just the block'

    if ($failures -gt 0) { Write-Host "FAILURES: $failures"; exit 1 }
    Write-Host 'ALL PASS'
    exit 0
}
