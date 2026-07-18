# Fleet SSH-over-tailnet + retire AWG mesh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-home the fleet's keys-only sshd onto the Headscale tailnet via a new `fleet.sshServer` NixOS module + a converging `windows.ps1` firewall, and retire the AmneziaWG *mesh* from the repo (keeping the AmneziaVPN client and the VPS VPN server).

**Architecture:** A dedicated `modules/system/ssh-server.nix` owns the SSH-server role (sshd + tailnet/LAN firewall + key trust), decoupled from the deleted `mesh-vpn.nix`. The former mesh params file is slimmed to fleet machine records only; `ssh.nix` keys the hub off `ssh.host`. `fleet.json`, the provisioner, and Windows are scrubbed of the AWG mesh.

**Tech Stack:** NixOS modules (Nix), Home Manager, PowerShell (`windows.ps1`), POSIX sh provisioner, `fleet.json`.

## Global Constraints

- Keys-only everywhere: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`. Never enable password auth.
- Single committed trust file (public keys only), no per-host key duplication. After Task 1 its path is `provision/fleet-authorized-keys`.
- No public-interface SSH exposure. Port 22 scoped to `tailscale0` + LAN `192.168.8.0/24` (NixOS) / `100.64.0.0/10` + `192.168.8.0/24` (Windows).
- Tailnet constants: interface `tailscale0`, CGNAT `100.64.0.0/10`, MagicDNS suffix `gg.ez`, control server `https://cc.cyphy.kz`.
- **Keep untouched:** AmneziaVPN *client* (latitude `me.nix` wrapper + `AmneziaVPN.service`; Windows winget `Amnezia.AmneziaWG` / `AmneziaVPN.AmneziaVPN`), the VPS AWG VPN server, and the `base.nix` LTS kernel pin (only its AWG comment sentence is removed).
- latitude is the **sole NixOS host** with a config in this repo; the module must be reusable but do **not** fabricate a g16 NixOS config.
- Repo workflow: work on `main`, commit per task. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Verification gates available in-session (no sudo): `just quick` (fast Nix syntax), `nix flake check` (full eval), `nix run nixpkgs#shellcheck -- <files>`. The Bash tool runs on latitude; `nixos-rebuild switch` and the Windows `windows.ps1` run are **user-executed** (see final verification).

## File map

- **Create:** `modules/system/ssh-server.nix` (the `fleet.sshServer` role).
- **Rename:** `modules/system/mesh-vpn-params.nix` → `modules/system/fleet.nix`; `provision/mesh-authorized-keys` → `provision/fleet-authorized-keys`.
- **Delete:** `modules/system/mesh-vpn.nix`; `provision/lib/mesh.sh`, `provision/lib/Mesh.psm1`, `provision/lib/mesh.test.sh`, `provision/roles/mesh-member.sh`, `provision/roles/mesh-member.ps1`, `provision/roles/mesh-hub.sh`, `provision/roles/mesh-hub.ps1`.
- **Modify:** `hosts/latitude/nixos/configuration.nix`, `modules/home/ssh.nix`, `fleet.json`, `provision/provision.ps1`, `provision/windows.ps1`, `modules/system/base.nix`, `docs/fleet-roadmap.md`, `.claude/memory/project.md`.

**Verified facts (do not re-derive):** `provision/lib/fleet.sh` and `provision/lib/Fleet.psm1` have **zero** `mesh` references — safe to drop `mesh` from `fleet.json`. This is a normal git repo (not the dotfiles bare repo), so the renamed trust file is trackable with **no** `.gitignore` change. `provision/provision.sh` auto-sources `roles/*.sh` (deleting the files is enough on the posix side); only `provision.ps1` has explicit `mesh-member`/`mesh-hub` dispatch entries (lines 22–23).

---

### Task 1: Rename the trust file and all its references

**Files:**
- Rename: `provision/mesh-authorized-keys` → `provision/fleet-authorized-keys`
- Modify: `modules/system/mesh-vpn.nix:88`, `provision/windows.ps1:234`

**Interfaces:**
- Produces: the committed trust file at path `provision/fleet-authorized-keys`, consumed by Task 2 (`ssh-server.nix`) and Task 6 (`windows.ps1`).

- [ ] **Step 1: Rename the tracked file**

Run:
```bash
git mv provision/mesh-authorized-keys provision/fleet-authorized-keys
```

- [ ] **Step 2: Update the (soon-to-be-deleted) mesh-vpn.nix reference so no dangling path remains**

In `modules/system/mesh-vpn.nix`, change the `keyFiles` line:
```nix
    users.users.me.openssh.authorizedKeys.keyFiles = [
      ../../provision/fleet-authorized-keys
    ];
```

- [ ] **Step 3: Update the Windows script reference**

In `provision/windows.ps1`, change the `$srcKeys` assignment (near line 234):
```powershell
    $srcKeys   = Join-Path $RepoDir 'provision\fleet-authorized-keys'
```

- [ ] **Step 4: Verify no reference to the old name survives**

Run:
```bash
grep -rIn --exclude-dir=.git "mesh-authorized-keys" . | grep -vE "docs/superpowers/(specs|plans|handoffs)/|\.claude/memory/"
```
Expected: no output (the only remaining mentions are in specs/plans/handoffs and memory, updated in Task 7).

- [ ] **Step 5: Verify the flake still evaluates**

Run: `just quick`
Expected: passes (no syntax errors).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(provision): rename mesh-authorized-keys -> fleet-authorized-keys

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Add the `fleet.sshServer` module and enable it on latitude

**Files:**
- Create: `modules/system/ssh-server.nix`
- Modify: `hosts/latitude/nixos/configuration.nix` (imports + enable)

**Interfaces:**
- Produces: the NixOS option `fleet.sshServer.enable` (bool). When true: keys-only sshd, port 22 on `tailscale0` + LAN, trust from `provision/fleet-authorized-keys`.
- Consumes: `provision/fleet-authorized-keys` (Task 1).

Note: `mesh-vpn.nix` still exists here but is `mkIf false` on latitude, so it contributes nothing — no conflict with the new module. It is deleted in Task 3.

- [ ] **Step 1: Create the module**

Create `modules/system/ssh-server.nix`:
```nix
# modules/system/ssh-server.nix
#
# Fleet SSH-server role: keys-only sshd reachable over the Headscale tailnet
# (tailscale0 / 100.64.0.0/10) and the home LAN, never the public interface.
# Decoupled from the (retired) AmneziaWG mesh — this is the single owner of the
# fleet's SSH-server role on NixOS. Trust comes from one committed public-keys
# file shared by all fleet hosts.
#
# Design: docs/superpowers/specs/2026-07-17-fleet-ssh-tailnet-retire-awg-design.md
{
  config,
  lib,
  ...
}: let
  cfg = config.fleet.sshServer;
in {
  options.fleet.sshServer = {
    enable = lib.mkEnableOption "keys-only sshd reachable over the tailnet + LAN";
  };

  config = lib.mkIf cfg.enable {
    # Keys-only sshd; we scope the firewall ourselves (openFirewall = false).
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    # Tailnet: allow 22 on the tailscale0 interface. Bound to the actual tailnet
    # iface (Tailscale crypto + Headscale ACLs are the source auth); tighter than
    # a source-CIDR. iptables matches -i tailscale0 at packet time, so it is safe
    # even before tailscaled brings the interface up.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22];

    # LAN: allow 22 only from the home subnet. Uses the iptables escape hatch
    # (extraCommands) rather than extraInputRules — the latter requires
    # networking.nftables.enable, a fleet-wide backend flip that can disrupt
    # Docker. Source-CIDR scoped, so it's independent of the wlan/eth name.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s 192.168.8.0/24 --dport 22 -j nixos-fw-accept
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -p tcp -s 192.168.8.0/24 --dport 22 -j nixos-fw-accept || true
    '';

    # Trust: one committed public-keys file (public keys only), shared by all
    # fleet hosts. No per-host key duplication.
    users.users.me.openssh.authorizedKeys.keyFiles = [
      ../../provision/fleet-authorized-keys
    ];

    # Host-key pinning is a follow-up: no host has an ssh_host_ed25519_key.pub
    # collected yet. Once collected, add e.g.
    #   programs.ssh.knownHosts.latitude = {
    #     hostNames = [ "latitude" "100.64.0.2" ];
    #     publicKey = "ssh-ed25519 AAAA... root@latitude";
    #   };
    # Until then clients fall through to StrictHostKeyChecking=accept-new.
  };
}
```

- [ ] **Step 2: Import the module and enable it on latitude**

In `hosts/latitude/nixos/configuration.nix`, add to the `imports` list (below the existing `mesh-vpn.nix` line for now):
```nix
    ../../../modules/system/ssh-server.nix
```
And add, near the tailscale block (e.g. just above `services.tailscale.enable = true;`):
```nix
  # Keys-only sshd reachable over the tailnet + LAN (fleet SSH-server role).
  fleet.sshServer.enable = true;
```

- [ ] **Step 3: Verify the flake evaluates with sshd now enabled**

Run: `nix flake check`
Expected: passes. (This confirms `fleet.sshServer` + the tailscale0 firewall option resolve and there is no clash with the still-present, disabled `mesh-vpn.nix`.)

- [ ] **Step 4: Commit**

```bash
git add modules/system/ssh-server.nix hosts/latitude/nixos/configuration.nix
git commit -m "feat(nixos): fleet.sshServer role — keys-only sshd over the tailnet

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Delete mesh-vpn.nix, slim params → fleet.nix, refactor ssh.nix

**Files:**
- Delete: `modules/system/mesh-vpn.nix`
- Rename: `modules/system/mesh-vpn-params.nix` → `modules/system/fleet.nix`
- Modify: `modules/system/fleet.nix` (strip to machine records), `modules/home/ssh.nix` (import + hub key logic), `hosts/latitude/nixos/configuration.nix` (drop mesh import + `fleet.meshVpn` block)

**Interfaces:**
- Consumes: `fleet.json` machine records.
- Produces: `modules/system/fleet.nix` exporting `machines` (attrset from `fleet.json`); consumed by `modules/home/ssh.nix`.

This task is atomic: deleting `mesh-vpn.nix` removes the `fleet.meshVpn` option, so latitude's `fleet.meshVpn` block must go in the same commit, and `ssh.nix`'s import must switch to `fleet.nix` in the same commit.

- [ ] **Step 1: Delete the mesh module and rename the params file**

Run:
```bash
git rm modules/system/mesh-vpn.nix
git mv modules/system/mesh-vpn-params.nix modules/system/fleet.nix
```

- [ ] **Step 2: Strip `fleet.nix` to machine records only**

Replace the entire contents of `modules/system/fleet.nix` with:
```nix
# modules/system/fleet.nix
#
# Fleet machine records — the single source of truth is the repo-root fleet.json.
# Plain data (imported by modules/home/ssh.nix), NOT a NixOS module.
#
# The former AmneziaWG mesh constants (vpsPublicKey / port / endpoint /
# obfuscation and the derived mesh-IP map) were removed when the AWG mesh was
# retired from the repo (2026-07-17). Only the fleet records remain, consumed by
# the ssh.nix client-config generator.
let
  fleet = builtins.fromJSON (builtins.readFile ../../fleet.json);
in {
  inherit (fleet) machines;
}
```

- [ ] **Step 3: Refactor `modules/home/ssh.nix`**

Change the import (line ~26) from:
```nix
  params = import ../system/mesh-vpn-params.nix;
```
to:
```nix
  params = import ../system/fleet.nix;
```

Change `mkBlock` so the hub's `HostName` is keyed off `ssh.host` presence instead of `mesh.role`:
```nix
  mkBlock = _name: m:
    (
      if (m.ssh.host or null) != null
      then {HostName = m.ssh.host;} # hub → cyphy.kz: SSH must not depend on the transport it hosts
      else {} # MagicDNS resolves the bare name fleet-wide
    )
    // (
      if (m.ssh.user or "me") != "me"
      then {User = m.ssh.user;}
      else {}
    )
    // {StrictHostKeyChecking = "accept-new";};
```

Also update the header comment: replace the `mesh-vpn-params.nix` mentions with `fleet.nix`, and the sentence about `params.endpoint` with "the hub's HostName comes from its `fleet.json` `ssh.host` (cyphy.kz)".

- [ ] **Step 4: Remove the mesh import and `fleet.meshVpn` block from latitude**

In `hosts/latitude/nixos/configuration.nix`:
- Delete the imports line `../../../modules/system/mesh-vpn.nix`.
- Delete the entire `fleet.meshVpn = { enable = false; address = "10.0.0.8/32"; };` block **and** its preceding `# AmneziaWG mesh spoke — DISABLED ...` comment paragraph (the block spanning roughly lines 78–87).

Leave the AmneziaVPN client bits (`systemd.packages = [pkgs.amnezia-vpn];` and `systemd.services.AmneziaVPN.wantedBy`) untouched.

- [ ] **Step 5: Verify nothing else references the removed params**

Run:
```bash
grep -rIn --exclude-dir=.git -E "mesh-vpn-params|fleet\.meshVpn|params\.(endpoint|obfuscation|hosts|vpsPublicKey|port)" . | grep -vE "docs/superpowers/(specs|plans|handoffs)/|\.claude/memory/"
```
Expected: no output.

- [ ] **Step 6: Verify full eval (SSH client config + fleet.nix + sshd)**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(nixos): retire mesh-vpn module; fleet.nix records + ssh.nix hub key

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Scrub the AWG mesh from `fleet.json`

**Files:**
- Modify: `fleet.json`

**Interfaces:**
- Consumes: nothing new.
- Produces: `fleet.json` with each machine's `mesh` block removed and `mesh-member`/`mesh-hub` dropped from every `roles` array. `machines.<h>.ssh` and `.tailnet` are unchanged — Task 3's `ssh.nix` depends on `ssh.host` being present only on the hub.

- [ ] **Step 1: Rewrite `fleet.json` without the mesh data**

Replace the entire contents of `fleet.json` with:
```json
{
  "machines": {
    "latitude": {
      "platform": "nixos",
      "tailnet": { "ip": "100.64.0.2" },
      "roles": ["base", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client"],
      "detect": { "hostname": "latitude5520" }
    },
    "desktop": {
      "platform": "windows",
      "tailnet": { "ip": "100.64.0.4" },
      "ssh": { "user": "methe" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "g614jv" }
    },
    "server": {
      "platform": "windows",
      "tailnet": { "ip": "100.64.0.3" },
      "ssh": { "user": "methe" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client"],
      "detect": { "hostname": "methe-server" }
    },
    "hub": {
      "platform": "debian",
      "tailnet": { "ip": "100.64.0.1" },
      "ssh": { "user": "debian", "host": "cyphy.kz" },
      "roles": ["base", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
  }
}
```

- [ ] **Step 2: Verify it is valid JSON and mesh is gone**

Run:
```bash
jq -e '.machines | to_entries | all(.value | (has("mesh")|not) and (.roles | index("mesh-member") == null) and (.roles | index("mesh-hub") == null))' fleet.json
```
Expected: `true`.

- [ ] **Step 3: Verify the SSH client config still evaluates (hub HostName intact)**

Run: `nix flake check`
Expected: passes. (Confirms `ssh.nix` still produces the hub block from `ssh.host` after `mesh` removal.)

- [ ] **Step 4: Commit**

```bash
git add fleet.json
git commit -m "chore(fleet): drop AWG mesh blocks + mesh roles from fleet.json

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Delete the provisioner's AWG-mesh pieces

**Files:**
- Delete: `provision/lib/mesh.sh`, `provision/lib/Mesh.psm1`, `provision/lib/mesh.test.sh`, `provision/roles/mesh-member.sh`, `provision/roles/mesh-member.ps1`, `provision/roles/mesh-hub.sh`, `provision/roles/mesh-hub.ps1`
- Modify: `provision/provision.ps1` (remove the two mesh dispatch entries)

**Interfaces:**
- Consumes: nothing.
- Produces: a provisioner with no AWG-mesh roles. `provision.sh` auto-sources `roles/*.sh`, so file removal suffices posix-side; `provision.ps1`'s `$RoleExecutors` map loses its two mesh entries.

- [ ] **Step 1: Delete the mesh provisioner files**

Run:
```bash
git rm provision/lib/mesh.sh provision/lib/Mesh.psm1 provision/lib/mesh.test.sh \
       provision/roles/mesh-member.sh provision/roles/mesh-member.ps1 \
       provision/roles/mesh-hub.sh provision/roles/mesh-hub.ps1
```

- [ ] **Step 2: Remove the mesh dispatch entries from `provision.ps1`**

In `provision/provision.ps1`, delete these two lines from the `$RoleExecutors` map (lines ~22–23):
```powershell
    'mesh-member' = { param($Mode, $Platform, $Machine) Invoke-RoleMeshMember -Mode $Mode -Platform $Platform -Machine $Machine }
    'mesh-hub'    = { param($Mode, $Platform, $Machine) Invoke-RoleMeshHub    -Mode $Mode -Platform $Platform -Machine $Machine }
}
```
(Leave the closing `}` — i.e. the map ends after the `repos` entry. Also update the comment above the map that references "a future 'mesh-member'" to drop that example, e.g.: `# A map avoids function-name mangling for hyphenated role names.`)

- [ ] **Step 3: Verify no lingering references to the deleted mesh roles/libs**

Run:
```bash
grep -rIn --exclude-dir=.git -E "Invoke-RoleMesh|Mesh\.psm1|lib/mesh\.sh|roles/mesh-" provision
```
Expected: no output.

- [ ] **Step 4: Shellcheck the touched posix scripts and confirm provision.sh still parses**

Run:
```bash
nix run nixpkgs#shellcheck -- provision/provision.sh provision/lib/fleet.sh
bash -n provision/provision.sh
```
Expected: shellcheck clean (no new errors), `bash -n` exits 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(provision): remove AWG mesh roles/libs + dispatch entries

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Converge the Windows SSH firewall onto the tailnet

**Files:**
- Modify: `provision/windows.ps1` (step 7 header comment ~line 202; step 7e firewall block ~lines 253–269; trailing warning ~line 290)

**Interfaces:**
- Consumes: nothing.
- Produces: `windows.ps1` that scopes 22 to `100.64.0.0/10` + `192.168.8.0/24` and **converges** the rule on re-run (removes any stale `OpenSSH-Server-Mesh-LAN` + recreates as `OpenSSH-Server-Tailnet-LAN`). This is the critical fix for `desktop`, which already carries the old AWG-scoped rule from a prior run.

- [ ] **Step 1: Update the step-7 header comment**

In `provision/windows.ps1`, change the step-7 section header comment (near line 202) from:
```powershell
# ---- 7. OpenSSH server (agent/human SSH into this box over mesh+LAN) --------
```
to:
```powershell
# ---- 7. OpenSSH server (agent/human SSH into this box over tailnet+LAN) ------
```

- [ ] **Step 2: Replace the step-7e firewall block**

Replace the entire `# 7e. Firewall ...` block (from the `$fwRule = 'OpenSSH-Server-Mesh-LAN'` line through the `Info "disabled default ..."` line) with:
```powershell
# 7e. Firewall: inbound 22 from the tailnet + LAN only (never the open internet).
#     CONVERGE, don't create-if-absent: a box may already carry a stale rule from
#     a prior (AWG-era) run, so remove any prior rule (the old name + this one)
#     then recreate. Create-if-absent would silently leave the old scope in place.
$fwRule = 'OpenSSH-Server-Tailnet-LAN'
foreach ($old in @('OpenSSH-Server-Mesh-LAN', $fwRule)) {
    Get-NetFirewallRule -Name $old -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
New-NetFirewallRule -Name $fwRule -DisplayName 'OpenSSH Server (tailnet+LAN)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
    -RemoteAddress @('100.64.0.0/10','192.168.8.0/24') | Out-Null
Info "firewall rule '$fwRule' set (22 from 100.64.0.0/10, 192.168.8.0/24)."
# Neutralize the default 'allow 22 from Any' rule the capability install adds
# (Windows Firewall unions allow-rules, so the scoped rule above restricts
# nothing while this one is enabled). Idempotent.
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Info "disabled default 'OpenSSH-Server-In-TCP' (Any) rule; only tailnet+LAN remains."
```

- [ ] **Step 3: Update the trailing reachability warning**

Replace the trailing warning (near line 290):
```powershell
Warn "Reachable over the mesh only while this box's AmneziaWG tunnel is up (autostart on boot) and its AllowedIPs covers 10.0.0.0/24 - verify separately."
```
with:
```powershell
Warn "Reachable over the tailnet only while this box has joined the Headscale tailnet (tailscale0 up, address in 100.64.0.0/10) - verify separately."
```

- [ ] **Step 4: Verify the intended strings are present and the AWG ones gone**

Run:
```bash
grep -n "OpenSSH-Server-Tailnet-LAN\|100.64.0.0/10\|Remove-NetFirewallRule" provision/windows.ps1
grep -n "10.0.0.0/24\|OpenSSH-Server-Mesh-LAN'\|AmneziaWG tunnel" provision/windows.ps1 | grep -v "'OpenSSH-Server-Mesh-LAN'," | grep -v "@('OpenSSH-Server-Mesh-LAN'" || echo "  (no stray AWG scope remains)"
```
Expected: first grep shows the new rule name, the CGNAT range, and the removal call; second grep shows no remaining `10.0.0.0/24` / AWG-tunnel wording (the only `OpenSSH-Server-Mesh-LAN` mention left is inside the removal loop). (`windows.ps1` runs only on Windows/Administrator, so behavior is user-verified in the final step, not here.)

- [ ] **Step 5: Commit**

```bash
git add provision/windows.ps1
git commit -m "fix(windows): scope sshd firewall to the tailnet; converge on re-run

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Clean up the base.nix comment and refresh docs/memory

**Files:**
- Modify: `modules/system/base.nix` (kernel comment), `docs/fleet-roadmap.md`, `.claude/memory/project.md`

**Interfaces:**
- Consumes: nothing. Documentation-only; no behavior change.

- [ ] **Step 1: Trim the AWG sentence from the base.nix kernel comment**

In `modules/system/base.nix`, replace the `kernelPackages` comment block (lines ~19–23) with:
```nix
    # LTS kernel (nixpkgs default). Kept off linuxPackages_latest as the safer
    # track for the NVIDIA driver (see CLAUDE.md); the AWG mesh that formerly also
    # required it has been retired.
    kernelPackages = pkgs.linuxPackages;
```

- [ ] **Step 2: Record the retirement in the fleet roadmap**

In `docs/fleet-roadmap.md`, update the AWG mentions to reflect that the mesh is now retired from this repo. Add a dated line under the appropriate section, e.g.:
```markdown
- **2026-07-17 — AWG mesh retired from the repo.** SSH re-homed onto the tailnet
  via `fleet.sshServer` (NixOS) + converged `windows.ps1` firewall. Deleted:
  `mesh-vpn.nix`, mesh params, `fleet.json` mesh blocks, provisioner mesh
  roles/libs. Kept: the AmneziaVPN client + the VPS AWG VPN server.
```
And adjust the per-host table notes that say "AWG spoke disabled" / "AWG still running beside it" to note the mesh wiring is now gone from the repo (the running-beside-it note on g614jv can stay as an operational fact, but flag that the repo no longer provisions it).

- [ ] **Step 3: Record the retirement in project memory**

In `.claude/memory/project.md`, under the "Fleet network" / Headscale-migration section, append one bullet:
```markdown
- **AWG mesh retired from the machines repo (2026-07-17).** SSH-server role moved
  to `modules/system/ssh-server.nix` (`fleet.sshServer`, keys-only sshd on
  `tailscale0` + LAN). Deleted `mesh-vpn.nix`, slimmed params → `fleet.nix`
  (machine records only), dropped `mesh` blocks + `mesh-member`/`mesh-hub` roles
  from `fleet.json`, removed provisioner mesh roles/libs, renamed the trust file
  → `provision/fleet-authorized-keys`, converged `windows.ps1` firewall onto
  `100.64.0.0/10`. Kept: AmneziaVPN client (latitude + Windows winget) and the
  VPS AWG VPN server for RU relatives.
```
Leave the older AWG history bullets as-is (they are the historical record).

- [ ] **Step 4: Verify the flake still evaluates after the comment change**

Run: `just quick`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add modules/system/base.nix docs/fleet-roadmap.md .claude/memory/project.md
git commit -m "docs: record AWG-mesh retirement; trim base.nix kernel comment

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Final verification (user-executed — not self-verifiable in-session)

The Bash tool runs on latitude and cannot `sudo nixos-rebuild` non-interactively; Windows changes need Administrator. After all tasks:

1. **In-session (no sudo):** `nix flake check` passes and `git push`.
2. **latitude:** `cd ~/machines && just switch` (user runs; `!`-prefix for visible output).
3. **desktop and server:** re-run `provision\windows.ps1` from an **elevated** PowerShell.
4. **From the WSL box / any tailnet node:**
   - `ssh -o BatchMode=yes latitude true` → succeeds
   - `ssh -o BatchMode=yes desktop true` → succeeds
   - `ssh -o BatchMode=yes server true` → succeeds
5. No regression to existing LAN / other SSH access.
```

## Self-review notes

- **Spec coverage:** A=Task 2; B: delete mesh-vpn/rename params/ssh.nix=Task 3, fleet.json=Task 4, provisioner=Task 5, trust-file rename=Task 1, base.nix+docs=Task 7; C=Task 6. All covered.
- **`.gitignore`:** the spec's "add a `!` allow-line" step was **dropped** — verified this is a normal git repo where the renamed file is trackable with no change (`git check-ignore` reports not-ignored). Noted in the file map.
- **Ordering:** each task leaves the flake evaluable — Task 1 keeps `mesh-vpn.nix`'s path valid; Task 2 adds the enabled module beside the disabled mesh module (no clash); Task 3 removes both the module and its consumer/option in one commit; Task 4 removes `fleet.json` mesh only after `ssh.nix` stopped reading it.
