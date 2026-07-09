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
            # Parity with the posix side: the fetched conf must actually carry a
            # PrivateKey before we install it. A keyless conf is a hub/fetch fault.
            if ($conf -notmatch '(?m)^\s*PrivateKey\s*=') {
                Write-Warning "  mesh-member: fetched conf had no PrivateKey — not writing $confPath."
                return
            }
            New-Item -ItemType Directory -Force (Split-Path $confPath) | Out-Null
            # Create the file EMPTY and lock its ACL BEFORE the key is written, so
            # the key is never briefly world-readable (C:\ProgramData inherits
            # Users:Read). Grant this user (R,W — AmneziaVPN GUI imports as this
            # user) + Administrators (F); *S-1-5-32-544 = BUILTIN\Administrators.
            # Mirrors the posix `install -m 600 /dev/null` create-then-write order.
            New-Item -ItemType File -Path $confPath -Force | Out-Null
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            icacls $confPath /inheritance:r /grant:r "*${me}:(R,W)" "*S-1-5-32-544:(F)" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Remove-Item $confPath -Force -ErrorAction SilentlyContinue
                throw "mesh-member: could not restrict $confPath ACL — removed it (never leave an unprotected key). Write it by hand and lock its permissions."
            }
            Set-Content -Path $confPath -Value $conf -NoNewline
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
