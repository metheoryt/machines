# provision/roles/mesh-member.ps1 — the `mesh-member` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleMeshMember.
#
# Windows AmneziaWG runs via the AmneziaVPN GUI (no scriptable service). This
# executor fetches THIS box's conf from the VPS hub (Mesh.psm1) only if it is
# not already installed, writes it to C:\ProgramData\amnezia-wg\awg0.conf for
# GUI import, prints import instructions, and verifies the hub is pingable. No
# keygen, no service install.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md

function Invoke-RoleMeshMember {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  mesh-member: no Windows executor for platform '$Platform' (skipped)."
        return
    }
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Mesh.psm1') -Force

    $confPath = 'C:\ProgramData\amnezia-wg\awg0.conf'

    if (Test-Path $confPath) {
        Write-Host "  mesh-member: $confPath present — conf already installed (no fetch)."
    } elseif ($Mode -eq 'apply') {
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            Write-Warning "  mesh-member: ssh.exe not found — install the Windows OpenSSH client. Skipping."
            return
        }
        Write-Host "  mesh-member: $confPath absent — fetching this box's conf from the hub…"
        $conf = Invoke-MeshSshFetch -Machine $Machine
        if ($conf) {
            New-Item -ItemType Directory -Force (Split-Path $confPath) | Out-Null
            Set-Content -Path $confPath -Value $conf -NoNewline
            # Lock the key-bearing conf: C:\ProgramData inherits Users:Read+Write,
            # so a private key would be world-readable. Disable inheritance and
            # grant only THIS user (R,W — the AmneziaVPN GUI imports it as this
            # user) + Administrators (F). Mirrors the posix root:600 install.
            # SIDs, not names, to stay domain/locale-independent
            # (*S-1-5-32-544 = BUILTIN\Administrators).
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            icacls $confPath /inheritance:r /grant:r "*${me}:(R,W)" "*S-1-5-32-544:(F)" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Remove-Item $confPath -Force -ErrorAction SilentlyContinue
                Write-Warning "  mesh-member: could not restrict $confPath ACL — removed it (never leave an unprotected key). Write it by hand and lock its permissions."
                return
            }
            Write-Host "  mesh-member: wrote $confPath (locked: this user + Administrators only)."
            Write-Host "  mesh-member: import it into AmneziaVPN (File -> Import config) and enable the tunnel."
            Write-Host "  mesh-member: REPLACE any existing tunnel for this peer — two tunnels for one IP fight."
        } else {
            Write-MeshManualHint -Machine $Machine
            return
        }
    } else {
        Write-MeshDryRunLine -Machine $Machine -InstallPath $confPath
    }

    if ($Mode -eq 'apply') {
        if (Test-Connection -ComputerName '10.0.0.1' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            Write-Host "  mesh-member: hub 10.0.0.1 reachable. ✓"
        } else {
            Write-Host "  mesh-member: hub 10.0.0.1 not reachable yet — enable the tunnel in AmneziaVPN."
        }
    }
}
