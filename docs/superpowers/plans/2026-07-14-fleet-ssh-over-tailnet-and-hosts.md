# Fleet SSH-over-tailnet + name resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repoint fleet SSH aliases off the dead AmneziaWG `10.0.0.x` IPs onto the tailnet (`100.64.0.x`), and give every fleet box name-based resolution of every other box without a DNS resolver.

**Architecture:** `fleet.json` gains a parallel `tailnet` block per machine (the AWG `mesh` block is left untouched). `modules/home/ssh.nix` reads `m.tailnet.ip` for its `HostName`. A new `modules/system/fleet-hosts.nix` generates NixOS `networking.hosts` from the same source. A new cross-platform `hosts` provisioner role writes a marker-delimited managed block into the system hosts file on Windows/Debian (no-op on NixOS, which the Nix module owns).

**Tech Stack:** Nix (NixOS + home-manager), Bash + jq, PowerShell 5.1/7, the existing `provision/` role dispatcher.

**Spec:** `docs/superpowers/specs/2026-07-14-fleet-ssh-over-tailnet-and-hosts-design.md`

## Global Constraints

Every task's requirements implicitly include these:

- **Do NOT touch `mesh.ip` or the AWG params** in `fleet.json`/`mesh-vpn-params.nix` — the VPS still runs AWG for relatives and reads them.
- **Tailnet IPs (verbatim):** `vps` = `100.64.0.1`, `latitude5520` = `100.64.0.2`, `homeserver` = `100.64.0.3`, `g614jv` = `100.64.0.4`.
- **Hub SSH stays public:** the machine with `mesh.role == "hub"` (vps) keeps `HostName = cyphy.kz` — never its tailnet IP.
- **Raw IPs, not MagicDNS names**, everywhere.
- **Managed-block markers are ASCII-only** (`- ` not `— `): they are written into system hosts files. Exact markers, identical across `hosts.sh` and `hosts.ps1`:
  - begin: `# BEGIN fleet hosts (managed by provision - do not edit)`
  - end: `# END fleet hosts`
- **New `.ps1` content is ASCII-only** (avoids the PS 5.1 cp1252 em-dash misparse; project memory 2026-07-12). Save it with a UTF-8 BOM to match the sibling provision PS files.
- **Executors honor `DRY_RUN` semantics** (dry-run mutates nothing) and support a **`FLEET_HOSTS_FILE` override** (env var) for the target path, defaulting to the real system hosts file — this makes them testable without root/admin.
- **Lint gates run on commit** (flake pre-commit hooks): Nix must pass `alejandra`/`deadnix`/`statix`; shell must pass `shellcheck --severity=warning`. Format Nix with `alejandra` before committing.
- **`jq` is required** for the posix executor (as in the existing libs).

**Where verification runs.** This repo lives on a Windows box; Nix is not installed here.
- `nix eval` / `nix flake check` steps run **on a Nix box** — `latitude5520`, or any `bash`+`nix` shell (WSL) for the cheap `nix eval` checks. Full `nix flake check` (builds the toplevel) is the latitude5520 real-box gate.
- Bash/`jq` executor smoke runs in **WSL or any bash+jq shell**.
- PowerShell executor smoke runs in **this Windows session**; the `Read-Host` confirm-gate cannot run under the `-NonInteractive` PowerShell tool, so drive it with `echo n | pwsh -File ...` from the Bash (Git Bash) tool, exactly as prior provisioner phases did.

---

## Stage 1 — Declarative (Nix). Fully verifiable by `nix eval` / `nix flake check`.

### Task 1: Add `tailnet.ip` to every machine in `fleet.json`

**Files:**
- Modify: `fleet.json`

**Interfaces:**
- Produces: `.machines.<name>.tailnet.ip` (string) for all four machines — consumed by Tasks 2, 3, 4, 5.

- [ ] **Step 1: Add the `tailnet` block to each machine**

Edit `fleet.json` so each machine gains a `tailnet` object beside its existing `mesh` object. Leave `mesh` exactly as-is. Result:

```json
{
  "machines": {
    "latitude5520": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.8", "role": "member", "peerName": "nix-lat5520" },
      "tailnet": { "ip": "100.64.0.2" },
      "roles": ["base", "mesh-member", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client"],
      "detect": { "hostname": "latitude5520" }
    },
    "g614jv": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.6", "role": "member", "peerName": "me-g614jv" },
      "tailnet": { "ip": "100.64.0.4" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "g614jv" }
    },
    "homeserver": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.2", "role": "member", "peerName": "wg0-homeserver" },
      "tailnet": { "ip": "100.64.0.3" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client"],
      "detect": { "hostname": "methe-server" }
    },
    "vps": {
      "platform": "debian",
      "mesh": { "ip": "10.0.0.1", "role": "hub", "managePeers": "/home/debian/vps/vps/manage-peers.sh" },
      "tailnet": { "ip": "100.64.0.1" },
      "ssh": { "user": "debian", "host": "cyphy.kz" },
      "roles": ["base", "mesh-hub", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
  }
}
```

- [ ] **Step 2: Verify the JSON is valid and every machine has a tailnet IP**

Run (WSL / any bash+jq shell, or PowerShell as noted):

```bash
jq -e '.machines | to_entries | all(.value.tailnet.ip | test("^100\\.64\\.0\\."))' fleet.json
```

Expected: prints `true` and exits 0. (If `jq` is unavailable, in PowerShell: `Get-Content -Raw fleet.json | ConvertFrom-Json` succeeds without error and `(... ).machines.homeserver.tailnet.ip` is `100.64.0.3`.)

- [ ] **Step 3: Confirm `mesh.ip` is untouched**

Run:

```bash
jq -r '.machines | to_entries[] | "\(.key) mesh=\(.value.mesh.ip) tailnet=\(.value.tailnet.ip)"' fleet.json
```

Expected: mesh IPs still `10.0.0.{8,6,2,1}`; tailnet IPs `100.64.0.{2,4,3,1}`.

- [ ] **Step 4: Commit**

```bash
git add fleet.json
git commit -m "feat(fleet): add tailnet.ip to every machine in fleet.json"
```

---

### Task 2: Repoint `ssh.nix` HostName to the tailnet IP

**Files:**
- Modify: `modules/home/ssh.nix:9-12` (header comment) and `:23-30` (`mkBlock`)

**Interfaces:**
- Consumes: `params.machines.<name>.tailnet.ip` (Task 1), `params.machines.<name>.mesh.role`, `params.endpoint`.
- Produces: `programs.ssh.settings.<name>.HostName` = the tailnet IP for members, `cyphy.kz` for the hub.

- [ ] **Step 1: (on a Nix box) Capture current behavior — the bug**

Run (latitude5520 or a WSL nix shell):

```bash
nix eval --raw '.#homeConfigurations."me@latitude5520".config.programs.ssh.settings.homeserver.HostName'
```

Expected (current, wrong): `10.0.0.2` — the dead AWG IP. This is what we're fixing.

- [ ] **Step 2: Change the `HostName` line in `mkBlock`**

In `modules/home/ssh.nix`, replace:

```nix
    HostName =
      if m.mesh.role == "hub"
      then params.endpoint # e.g. cyphy.kz — never the 10.0.0.1 mesh IP
      else params.hosts.${name};
```

with:

```nix
    HostName =
      if m.mesh.role == "hub"
      then params.endpoint # e.g. cyphy.kz — hub SSH must not depend on the transport it hosts
      else m.tailnet.ip; # tailnet IP; was the dead AWG params.hosts.${name}
```

- [ ] **Step 3: Update the header comment**

In `modules/home/ssh.nix`, replace the paragraph at lines 8-12 (the one starting `# The per-host blocks are GENERATED ...`) with:

```nix
# The per-host blocks are GENERATED from fleet.json (via mesh-vpn-params.nix) —
# one block per fleet member, so adding/removing a machine or changing its IP is
# a one-line fleet.json edit. HostName keys on mesh.role: the hub (vps) points at
# its public domain (cyphy.kz) so managing it never depends on the tunnel/tailnet
# it hosts; every other member points at its TAILNET IP (fleet.json tailnet.ip).
# The old AmneziaWG mesh IPs (mesh.ip) are no longer used for SSH — the fleet's
# SSH transport is the Headscale tailnet.
```

- [ ] **Step 4: Format**

Run (any nix shell) — or skip and let the pre-commit hook do it, then re-stage:

```bash
alejandra modules/home/ssh.nix
```

- [ ] **Step 5: (on a Nix box) Verify member points at tailnet, hub stays public**

```bash
nix eval --raw '.#homeConfigurations."me@latitude5520".config.programs.ssh.settings.homeserver.HostName'  # -> 100.64.0.3
nix eval --raw '.#homeConfigurations."me@latitude5520".config.programs.ssh.settings.g614jv.HostName'       # -> 100.64.0.4
nix eval --raw '.#homeConfigurations."me@latitude5520".config.programs.ssh.settings.vps.HostName'          # -> cyphy.kz
```

Expected: `100.64.0.3`, `100.64.0.4`, `cyphy.kz` respectively.

- [ ] **Step 6: Commit**

```bash
git add modules/home/ssh.nix
git commit -m "feat(ssh): generate fleet SSH HostNames from tailnet IPs, not AWG"
```

---

### Task 3: Generate NixOS `networking.hosts` from the fleet manifest

**Files:**
- Create: `modules/system/fleet-hosts.nix`
- Modify: `hosts/latitude5520/nixos/configuration.nix:12-16` (imports list)

**Interfaces:**
- Consumes: `mesh-vpn-params.nix` `machines` (each with `.tailnet.ip`) — from Task 1.
- Produces: `networking.hosts` = `{ "100.64.0.1" = ["vps"]; ... }` on any NixOS host importing this module.

- [ ] **Step 1: Create the module**

Create `modules/system/fleet-hosts.nix`:

```nix
# modules/system/fleet-hosts.nix
#
# Generates networking.hosts (static /etc/hosts entries) for the whole fleet from
# fleet.json's tailnet IPs, so every NixOS box resolves `homeserver`, `vps`,
# `g614jv`, `latitude5520` by name over the tailnet — no DNS/MagicDNS resolver
# needed. The Windows/Debian equivalent is the `hosts` provisioner role. Reuses
# the single fromJSON site in mesh-vpn-params.nix (its `machines`), so a box's IP
# is still changed in exactly one place (fleet.json).
#
# Design: docs/superpowers/specs/2026-07-14-fleet-ssh-over-tailnet-and-hosts-design.md
_: let
  params = import ./mesh-vpn-params.nix;
in {
  networking.hosts = builtins.listToAttrs (
    map (name: {
      name = params.machines.${name}.tailnet.ip; # IP is the attr key
      value = [name]; # the hostname(s) for that IP
    }) (builtins.attrNames params.machines)
  );
}
```

- [ ] **Step 2: Import it in latitude5520's config**

In `hosts/latitude5520/nixos/configuration.nix`, add the module to the `# System modules` group of `imports` (after `mesh-vpn.nix`):

```nix
    ../../../modules/system/mesh-vpn.nix
    ../../../modules/system/fleet-hosts.nix
```

- [ ] **Step 3: Format**

```bash
alejandra modules/system/fleet-hosts.nix
```

- [ ] **Step 4: (on a Nix box) Verify the generated map**

```bash
nix eval --json '.#nixosConfigurations.latitude5520.config.networking.hosts'
```

Expected JSON contains: `"100.64.0.1":["vps"]`, `"100.64.0.2":["latitude5520"]`, `"100.64.0.3":["homeserver"]`, `"100.64.0.4":["g614jv"]`. (Other unrelated entries from base modules may also appear — that's fine.)

- [ ] **Step 5: (latitude5520 real-box gate) Full flake check**

```bash
nix flake check
```

Expected: `all checks passed` (builds `nixos-latitude5520` toplevel + `home-latitude5520` — the NixOS-HM and standalone-home contexts — plus pre-commit). This is the Stage 1 acceptance gate; if it can't run in-session, record it as a latitude5520 runbook item.

- [ ] **Step 6: Commit**

```bash
git add modules/system/fleet-hosts.nix hosts/latitude5520/nixos/configuration.nix
git commit -m "feat(fleet): generate NixOS networking.hosts from fleet tailnet IPs"
```

---

## Stage 2 — Cross-platform `hosts` role executor. Verifiable by dry-run smoke; apply is real-box.

### Task 4: `hosts` posix executor — `provision/roles/hosts.sh`

**Files:**
- Create: `provision/roles/hosts.sh`

**Interfaces:**
- Consumes: `fleet_manifest_path` (from `provision/lib/fleet.sh`, sourced by `provision.sh` before roles); `fleet.json` `.machines.<name>.tailnet.ip`; env `DRY_RUN` semantics via the `mode` arg; env `FLEET_HOSTS_FILE` override.
- Produces: `role_hosts <mode> <platform> <machine>` — dispatched automatically by `provision.sh` (generic `role_<name>` lookup; no `provision.sh` edit).

- [ ] **Step 1: Write the executor**

Create `provision/roles/hosts.sh`:

```bash
# provision/roles/hosts.sh — the `hosts` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_hosts.
#
# hosts = fleet-wide name resolution via a marker-delimited managed block in the
# system hosts file (/etc/hosts), generated from fleet.json tailnet IPs. On nixos
# it is owned by modules/system/fleet-hosts.nix (networking.hosts), so the
# dispatcher must NOT touch /etc/hosts there. Target path is overridable via
# FLEET_HOSTS_FILE (for testing without root).
# shellcheck shell=bash

_HOSTS_BEGIN="# BEGIN fleet hosts (managed by provision - do not edit)"
_HOSTS_END="# END fleet hosts"

# Emit the managed block (markers + one "ip   name" line per machine, sorted).
_hosts_block() {
    printf '%s\n' "$_HOSTS_BEGIN"
    jq -r '.machines | to_entries | sort_by(.key)[] | "\(.value.tailnet.ip)   \(.key)"' \
        "$(fleet_manifest_path)"
    printf '%s' "$_HOSTS_END"
}

# Echo <file> with any existing managed block removed AND trailing blank lines
# trimmed (so repeated applies converge byte-for-byte).
_hosts_without_block() {
    awk -v b="$_HOSTS_BEGIN" -v e="$_HOSTS_END" '
        $0==b {inblk=1; next}
        $0==e {inblk=0; next}
        !inblk {lines[++n]=$0}
        END {
            while (n>0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i=1;i<=n;i++) print lines[i]
        }
    ' "$1"
}

# role_hosts <mode> <platform> <machine>
#   mode: dry-run | apply
role_hosts() {
    # shellcheck disable=SC2034  # machine: kept for role-signature parity
    local mode="$1" platform="$2" machine="$3"
    case "$platform" in
        nixos)
            echo "  hosts: owned by networking.hosts on nixos — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian) ;; # proceed
        *)
            echo "  hosts: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac

    local target="${FLEET_HOSTS_FILE:-/etc/hosts}"
    local block; block="$(_hosts_block)"

    if [ "$mode" = apply ]; then
        local tmp; tmp="$(mktemp)"
        { _hosts_without_block "$target"; printf '\n%s\n' "$block"; } > "$tmp"
        if [ -w "$target" ]; then
            cat "$tmp" > "$target"
        else
            sudo cp "$tmp" "$target"
        fi
        rm -f "$tmp"
        echo "  hosts: wrote fleet block to $target"
    else
        echo "  hosts: would write this block to $target:"
        printf '%s\n' "$block" | sed 's/^/    /'
    fi
}
```

- [ ] **Step 2: Lint**

Run:

```bash
shellcheck --severity=warning provision/roles/hosts.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Smoke — dry-run mutates nothing and prints the block**

Run (WSL / bash+jq shell, from the repo root):

```bash
source provision/lib/fleet.sh
source provision/roles/hosts.sh
role_hosts dry-run debian vps
role_hosts dry-run nixos latitude5520
```

Expected: the debian call prints `would write this block to /etc/hosts:` followed by the four `100.64.0.x   <name>` lines between the ASCII markers; the nixos call prints the `owned by networking.hosts` skip line. `/etc/hosts` is not modified.

- [ ] **Step 4: Smoke — apply is idempotent (against a temp target)**

Run:

```bash
tmp=$(mktemp); printf '127.0.0.1\tlocalhost\n' > "$tmp"
FLEET_HOSTS_FILE="$tmp" role_hosts apply debian vps
cp "$tmp" "$tmp.1"
FLEET_HOSTS_FILE="$tmp" role_hosts apply debian vps
diff "$tmp" "$tmp.1" && echo "IDEMPOTENT OK"
grep -c '100.64.0' "$tmp"   # -> 4 (block written once, not duplicated)
cat "$tmp"; rm -f "$tmp" "$tmp.1"
```

Expected: `IDEMPOTENT OK`, the count is `4`, the original `127.0.0.1 localhost` line is preserved above one managed block.

- [ ] **Step 5: Commit**

```bash
git add provision/roles/hosts.sh
git commit -m "feat(provision): add hosts role executor (posix) for fleet name resolution"
```

---

### Task 5: `hosts` PowerShell executor + wiring — `provision/roles/hosts.ps1`

**Files:**
- Create: `provision/roles/hosts.ps1` (ASCII-only content; save with UTF-8 BOM)
- Modify: `provision/provision.ps1:18-24` (`$RoleExecutors` map)

**Interfaces:**
- Consumes: `Get-FleetManifest` (from `provision/lib/Fleet.psm1`, imported by `provision.ps1`); `.machines.<name>.tailnet.ip`; env `FLEET_HOSTS_FILE` override.
- Produces: `Invoke-RoleHosts -Mode <m> -Platform <p> -Machine <n>`, registered under key `'hosts'` in `$RoleExecutors`.

- [ ] **Step 1: Write the executor**

Create `provision/roles/hosts.ps1` (ASCII only — no em-dashes; save with a UTF-8 BOM to match the sibling provision PS files):

```powershell
# provision/roles/hosts.ps1 - the `hosts` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleHosts.
#
# hosts = fleet-wide name resolution via a marker-delimited managed block in the
# system hosts file, generated from fleet.json tailnet IPs. NixOS owns this via
# networking.hosts, so this executor only writes on Windows. Target path is
# overridable via FLEET_HOSTS_FILE (for testing without admin). Writing the real
# system hosts file requires an elevated (admin) shell.

$script:FleetHostsBegin = '# BEGIN fleet hosts (managed by provision - do not edit)'
$script:FleetHostsEnd   = '# END fleet hosts'

function Get-FleetHostsBlock {
    $machines = (Get-FleetManifest).machines
    $body = foreach ($p in ($machines.PSObject.Properties | Sort-Object Name)) {
        '{0}   {1}' -f $p.Value.tailnet.ip, $p.Name
    }
    @($script:FleetHostsBegin) + @($body) + @($script:FleetHostsEnd)
}

function Invoke-RoleHosts {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -eq 'nixos') {
        Write-Host "  hosts: owned by networking.hosts on nixos - applied by 'just switch'; dispatcher skips."
        return
    }
    if ($Platform -ne 'windows') {
        Write-Host "  hosts: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $target = if ($env:FLEET_HOSTS_FILE) { $env:FLEET_HOSTS_FILE } `
              else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
    $block = Get-FleetHostsBlock

    if ($Mode -ne 'apply') {
        Write-Host "  hosts: would write this block to ${target}:"
        $block | ForEach-Object { "    $_" }
        return
    }

    $existing = @()
    if (Test-Path -LiteralPath $target) { $existing = @(Get-Content -LiteralPath $target) }

    $kept = New-Object System.Collections.Generic.List[string]
    $inblk = $false
    foreach ($ln in $existing) {
        if ($ln -eq $script:FleetHostsBegin) { $inblk = $true; continue }
        if ($ln -eq $script:FleetHostsEnd)   { $inblk = $false; continue }
        if (-not $inblk) { $kept.Add($ln) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }

    $out = @($kept) + @('') + $block
    Set-Content -LiteralPath $target -Value $out -Encoding ascii
    Write-Host "  hosts: wrote fleet block to $target"
}
```

- [ ] **Step 2: Register it in the dispatcher**

In `provision/provision.ps1`, add one entry to the `$RoleExecutors` map (after the `mesh-hub` line):

```powershell
    'mesh-hub'    = { param($Mode, $Platform, $Machine) Invoke-RoleMeshHub    -Mode $Mode -Platform $Platform -Machine $Machine }
    'hosts'       = { param($Mode, $Platform, $Machine) Invoke-RoleHosts      -Mode $Mode -Platform $Platform -Machine $Machine }
```

- [ ] **Step 3: Smoke — parse + dry-run mutates nothing (this Windows session)**

Run with the PowerShell tool:

```powershell
Import-Module (Join-Path (Get-Location) 'provision/lib/Fleet.psm1') -Force
. ./provision/roles/hosts.ps1
Invoke-RoleHosts -Mode dry-run -Platform windows -Machine g614jv
Invoke-RoleHosts -Mode dry-run -Platform nixos   -Machine latitude5520
```

Expected: the windows call prints `would write this block to ...\drivers\etc\hosts:` and the four `100.64.0.x   <name>` lines between the ASCII markers; the nixos call prints the skip line. No file is changed.

- [ ] **Step 4: Smoke — apply is idempotent (against a temp target)**

Run with the PowerShell tool:

```powershell
$tmp = New-TemporaryFile
Set-Content -LiteralPath $tmp -Value "127.0.0.1`tlocalhost" -Encoding ascii
$env:FLEET_HOSTS_FILE = $tmp
Invoke-RoleHosts -Mode apply -Platform windows -Machine g614jv
$a = Get-Content -Raw -LiteralPath $tmp
Invoke-RoleHosts -Mode apply -Platform windows -Machine g614jv
$b = Get-Content -Raw -LiteralPath $tmp
if ($a -eq $b) { "IDEMPOTENT OK" } else { "NOT IDEMPOTENT" }
(Select-String -Path $tmp -Pattern '100\.64\.0' -AllMatches).Matches.Count  # -> 4
Get-Content $tmp
Remove-Item $tmp; Remove-Item Env:\FLEET_HOSTS_FILE
```

Expected: `IDEMPOTENT OK`, count `4`, the `127.0.0.1 localhost` line preserved above one managed block.

- [ ] **Step 5: Smoke — full dispatch + confirm-gate skips on "n" (rc=0)**

The `Read-Host` gate needs a real (non-`-NonInteractive`) pwsh, so run from the Bash (Git Bash) tool:

```bash
echo n | pwsh -File provision/provision.ps1 -Apply -Machine g614jv; echo "rc=$?"
```

Expected: the run reaches the `hosts` role, prints its dry-run preview, prompts `Apply hosts? [y/N]`, prints `- hosts skipped.` on the piped `n`, and ends `rc=0`. (Requires `fleet.json` to already list the `hosts` role — if this runs before Task 6, the role still dispatches via the map but only if listed; run this step after Task 6 if needed, or temporarily pass through. It is listed as of Task 6.)

- [ ] **Step 6: Commit**

```bash
git add provision/roles/hosts.ps1 provision/provision.ps1
git commit -m "feat(provision): add hosts role executor (Windows) + dispatcher wiring"
```

---

### Task 6: Enroll the `hosts` role in `fleet.json`

**Files:**
- Modify: `fleet.json` (each machine's `roles` array)

**Interfaces:**
- Consumes: the executors from Tasks 4 & 5 (so the role actually runs, not "not yet implemented").
- Produces: `hosts` in every machine's `roles`, so `provision` dispatches it.

- [ ] **Step 1: Add `"hosts"` to each machine's `roles`**

Append `"hosts"` to the `roles` array of all four machines in `fleet.json`. Final `roles` arrays:

```json
"latitude5520": [..., "backup-client", "hosts"]
"g614jv":       [..., "repos", "hosts"]
"homeserver":   [..., "backup-client", "hosts"]
"vps":          [..., "backup-client", "hosts"]
```

(Add `"hosts"` as the last element of each existing array; do not remove existing roles.)

- [ ] **Step 2: Verify JSON valid + role present**

```bash
jq -e '.machines | to_entries | all(.value.roles | index("hosts"))' fleet.json
```

Expected: `true`, exit 0.

- [ ] **Step 3: Smoke — dispatch shows the hosts role in the plan**

Run (bash+jq shell for posix, or PowerShell tool for Windows):

```bash
bash provision/provision.sh --machine vps 2>&1 | grep -A4 'hosts'
```

Expected: the plan lists a `hosts` role whose preview is the managed-block lines (not `would converge via the ... executor` — that string means the executor wasn't found).

- [ ] **Step 4: Commit**

```bash
git add fleet.json
git commit -m "feat(fleet): enroll the hosts role on every machine"
```

---

## Real-box runbook (post-merge; not session-verifiable)

Run these on the actual boxes after the plan lands and each box has `git pull`ed:

1. **latitude5520 (NixOS):** `just switch` (or `nixos-rebuild switch --flake .#latitude5520`). Then:
   - `getent hosts homeserver` -> `100.64.0.3 homeserver`.
   - `ssh homeserver` and `ssh g614jv` connect over the tailnet; `ssh vps` still uses `cyphy.kz`.
2. **vps (Debian):** as root/sudo, `bash provision/provision.sh --apply --machine vps`, answer `y` at the `hosts` gate. Verify `getent hosts g614jv` -> `100.64.0.4`.
3. **g614jv, homeserver (Windows):** in an **elevated** pwsh, `pwsh -File provision/provision.ps1 -Apply`, answer `y` at the `hosts` gate. Verify `Resolve-DnsName homeserver` / `ping vps` hit `100.64.0.x`. (Writing `C:\Windows\System32\drivers\etc\hosts` needs admin.)
4. **Update `.claude/memory/project.md` and `docs/fleet-roadmap.md`:** tick "Fleet-wide SSH-over-tailnet" done; note the new `tailnet` field, `fleet-hosts.nix`, and the `hosts` role; record the hub `ssh` vs `ping` name divergence.

---

## Self-review notes

- **Spec coverage:** Decision 1/2/3 → Task 2 (+ Global Constraints); Decision 4 (tailnet block) → Task 1; Decision 5 (two mechanisms) → Task 3 (NixOS declarative) + Tasks 4/5 (executor, nixos no-op); Component 1 → Task 2; Component 2 → Task 3; Component 3 → Tasks 4/5/6; hub name quirk → Global Constraints + runbook step 4; verification scope → per-task checks + runbook.
- **Out-of-scope respected:** no task edits `mesh.ip` or AWG params; the dormant AWG Nix module is left in place.
- **Type/name consistency:** `_HOSTS_BEGIN`/`_HOSTS_END` (sh) and `$script:FleetHostsBegin`/`$script:FleetHostsEnd` (ps1) hold identical marker strings; `role_hosts`/`Invoke-RoleHosts` match the dispatcher's `role_<name>` / `$RoleExecutors['hosts']` conventions; `tailnet.ip` is used identically across Nix, jq, and PowerShell readers.
