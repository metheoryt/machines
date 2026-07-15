# Fleet rename — Layers 2 & 3 (Headscale renames + MagicDNS cleanup) Implementation Plan

> **For agentic workers:** Layer 3's repo tasks use superpowers:subagent-driven-development or executing-plans, task-by-task, with checkbox tracking. Layer 2 is an operational runbook (prod SSH, user-run) — not a code task; execute its steps directly with verification + rollback.

**Goal:** Finish the fleet rename on the live tailnet (Headscale given-names + `gg.ez` MagicDNS suffix), then retire the now-redundant hosts-file machinery and slim SSH config so MagicDNS is the sole resolver.

**Architecture:** Layers 2–3 of `docs/superpowers/specs/2026-07-15-fleet-rename-and-magicdns-adoption-design.md`. Layer 2 mutates live Headscale on the VPS (needs prod SSH auth). Layer 3 edits the machines repo (SDD-executable) plus one hand-edit to this box's real hosts file.

**Tech Stack:** Headscale CLI (VPS/Debian), Tailscale CLI (Windows/NixOS), Nix flakes + home-manager, `fleet.json`, provisioner roles (sh/ps1), git.

## Global Constraints

- **Gating order:** Layer 2 requires **PR #1 (Layer 1) is fine to run independently** (it doesn't depend on repo state). Layer 3 requires **both** PR #1 MERGED **and** Layer 2 live (MagicDNS confirmed the resolver end-to-end) before retiring the hosts fallback.
- **Target given-names → node IDs (verified live 2026-07-15):** `hub`←`cyphy-hub`(node 1), `server`←`homeserver`(node 3), `desktop`←`g614jv`(node 4). Node 2 is already `latitude`; node 5 (`ipheoryt12`, phone) is untouched.
- **`gg.ez` is already committed** to the vps repo (`~/my/vps`, commit `c0fe069`, file `vps/headscale/config.yaml` `base_domain: gg.ez`). Layer 2 DEPLOYS it; it is not re-decided.
- **Prod-auth steps** (SSH writes to the VPS, `systemctl restart headscale`, `headscale nodes rename`) are user-run via `!` or explicit authorization — read-only `headscale`/`tailscale` commands are allowed unattended.
- **No AWG changes.** The VPS still serves AmneziaWG for relatives; touch only Headscale/Tailscale + the machines repo.
- **Layer 3 runs against the POST-merge repo:** after PR #1, the NixOS dir is `hosts/latitude/` (not `hosts/latitude5520/`). All Layer 3 paths below assume that.

---

## Layer 2 — Headscale given-names + `gg.ez` (operational runbook, prod auth)

Run from a box with SSH to the VPS (e.g. homeserver: `ssh debian@cyphy.kz` over the tailnet). All `headscale` commands run **on** the VPS (`ssh debian@cyphy.kz 'sudo headscale …'` or in an interactive session). Do these in order; the `gg.ez` deploy first (suffix change), then the node renames.

### Step L2.1 — Snapshot current state (read-only, unattended-safe)

Run:
```bash
ssh debian@cyphy.kz 'sudo headscale nodes list'
ssh debian@cyphy.kz 'sudo cp -n /etc/headscale/config.yaml /etc/headscale/config.yaml.bak-prerename && sudo grep base_domain /etc/headscale/config.yaml'
```
Expected: node list shows names `cyphy-hub`/`latitude`/`homeserver`/`g614jv`/`ipheoryt12` with IDs 1–5; live `base_domain: fleet.mesh`; a `.bak-prerename` backup now exists (the `-n` makes it a no-clobber one-time snapshot for rollback).

### Step L2.2 — Deploy `gg.ez` (prod write; needs auth)

On the VPS: pull the vps repo and apply its committed Headscale config, then restart.
```bash
ssh debian@cyphy.kz 'cd /home/debian/vps && git pull --ff-only'
ssh debian@cyphy.kz 'sudo cp /home/debian/vps/vps/headscale/config.yaml /etc/headscale/config.yaml && sudo systemctl restart headscale'
ssh debian@cyphy.kz 'sleep 2 && systemctl is-active headscale && sudo headscale nodes list'
```
Expected: `git pull` brings in `c0fe069` (config now says `base_domain: gg.ez`); headscale restarts and `is-active` prints `active`; `nodes list` still shows all 5 nodes (renumbered FQDNs now under `gg.ez`).

**Rollback (if headscale is not `active` or nodes vanish):**
```bash
ssh debian@cyphy.kz 'sudo cp /etc/headscale/config.yaml.bak-prerename /etc/headscale/config.yaml && sudo systemctl restart headscale && systemctl is-active headscale'
```
Then stop and diagnose before proceeding.

### Step L2.3 — Rename the three given-names (prod write; needs auth)

```bash
ssh debian@cyphy.kz 'sudo headscale nodes rename hub    -i 1'
ssh debian@cyphy.kz 'sudo headscale nodes rename server -i 3'
ssh debian@cyphy.kz 'sudo headscale nodes rename desktop -i 4'
ssh debian@cyphy.kz 'sudo headscale nodes list'
```
Expected: `nodes list` now shows `hub`(1), `latitude`(2), `server`(3), `desktop`(4), `ipheoryt12`(5). (If an ID differs from L2.1's snapshot, use the snapshot's actual IDs — never assume.)

### Step L2.4 — Verify MagicDNS end-to-end (read-only, from a joined box)

From homeserver (this box), and ideally each box, confirm the new suffix + names resolve. On Windows:
```bash
"/c/Program Files/Tailscale/tailscale.exe" dns status | grep -i "suffix\|search"
```
Then resolve a couple of names (Windows resolver path):
```powershell
Resolve-DnsName server.gg.ez ; Resolve-DnsName hub.gg.ez ; Resolve-DnsName server
```
Expected: DNS status shows suffix/search-domain `gg.ez`; `server.gg.ez`→`100.64.0.3`, `hub.gg.ez`→`100.64.0.1`, and bare `server` resolves via the search domain. (A client may need a Tailscale reconnect or a minute to pick up the new suffix — `tailscale set` / toggle if stale.)

**Layer 2 acceptance:** `headscale nodes list` = `hub/latitude/server/desktop/ipheoryt12`; MagicDNS suffix `gg.ez`; `<name>.gg.ez` + bare `<name>` resolve fleet-wide. Record the outcome; this gates Layer 3.

---

## Layer 3 — MagicDNS-adoption cleanup (repo tasks + one host-file hand-edit)

**Precondition:** PR #1 merged AND Layer 2 acceptance met. Start Layer 3 on a fresh branch off the updated `main`:
```bash
git switch main && git pull --ff-only && git switch -c feat/fleet-magicdns-cleanup
```

### Task 1: Pin `--accept-dns` declaratively on latitude

**Files:**
- Modify: `hosts/latitude/nixos/configuration.nix` (the `services.tailscale.enable = true;` block)

**Interfaces:**
- Produces: latitude's tailscaled brings up with `--accept-dns` so a rebuild can't silently drop MagicDNS resolution.

- [ ] **Step 1: Determine which mechanism actually persists accept-dns (RUN ON latitude, verify BEFORE writing)**

⚠️ This is the spec's UNVERIFIED item. The NixOS `services.tailscale.extraUpFlags` only take effect if the module runs `tailscale up`, which it does only when `authKeyFile` is set — and latitude joins the tailnet **imperatively** (`tailscale up --login-server …`), so `extraUpFlags` alone may be **inert**. Do NOT blindly prescribe it. First check what the pinned nixpkgs offers and what the box currently reports:
```bash
"/c/Program Files/Tailscale/tailscale.exe" dns status   # (analogous check on latitude: `tailscale dns status` — is accept-dns already ON and durable across reboot?)
nix eval .#nixosConfigurations.latitude.options.services.tailscale --apply builtins.attrNames 2>/dev/null || true
```
Choose the mechanism that actually persists on this nixpkgs:
- **(A) declarative up-flag** — only if the module is (or will be) driven with an `authKeyFile`; then `services.tailscale.extraUpFlags = ["--accept-dns"];`.
- **(B) a oneshot systemd unit** running `tailscale set --accept-dns=true` after `tailscaled.service` — robust regardless of how the box joined, and the safest default given the imperative join.

- [ ] **Step 2: Write the chosen mechanism**

If **(B)** (recommended default), add to `hosts/latitude/nixos/configuration.nix` near the tailscale block (keep `services.tailscale.enable = true;` as-is):
```nix
  # MagicDNS (Headscale gg.ez) is the fleet resolver; ensure accept-dns is ON
  # declaratively so a rebuild/reboot can't silently drop name resolution.
  # latitude joins the tailnet imperatively, so pin it via `tailscale set`
  # rather than extraUpFlags (which only fire on a module-driven `tailscale up`).
  systemd.services.tailscale-accept-dns = {
    description = "Ensure Tailscale accept-dns is enabled";
    after = ["tailscaled.service"];
    wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecStart = "${pkgs.tailscale}/bin/tailscale set --accept-dns=true";
    serviceConfig.RemainAfterExit = true;
  };
```
If **(A)**, instead extend the existing `services.tailscale` block with `extraUpFlags = ["--accept-dns"];` (and the `authKeyFile` that makes it fire).

- [ ] **Step 3: Verify it evaluates + the flag persists (RUN ON latitude)**

```bash
nix flake check
# after a switch (real-box): reboot or restart tailscaled, then:
tailscale dns status | grep -i accept
```
Expected: `nix flake check` green; after activation, `tailscale dns status` reports accept-dns enabled and it survives a `tailscaled` restart.

- [ ] **Step 4: Commit**

```bash
git add hosts/latitude/nixos/configuration.nix
git commit -m "feat(fleet): pin --accept-dns on latitude so MagicDNS survives rebuilds

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: Retire the hosts-file machinery (repo)

**Files:**
- Delete: `modules/system/fleet-hosts.nix`
- Delete: `provision/roles/hosts.sh`, `provision/roles/hosts.ps1`
- Modify: `hosts/latitude/nixos/configuration.nix` (remove the `fleet-hosts.nix` import)
- Modify: `provision/provision.ps1` (remove the `hosts` entry from `$RoleExecutors`)
- Modify: `fleet.json` (remove `"hosts"` from every machine's `roles`)

**Interfaces:**
- Consumes: MagicDNS as the live resolver (Layer 2) — this is what makes the hosts fallback safe to remove.
- Produces: `provision` no longer offers a `hosts` role; NixOS no longer writes `networking.hosts` for the fleet.

- [ ] **Step 1: Remove the NixOS import**

In `hosts/latitude/nixos/configuration.nix`, delete the import line:
```nix
    ../../../modules/system/fleet-hosts.nix
```

- [ ] **Step 2: Delete the module + role executors**

```bash
git rm modules/system/fleet-hosts.nix provision/roles/hosts.sh provision/roles/hosts.ps1
```

- [ ] **Step 3: Remove the ps1 dispatcher entry**

In `provision/provision.ps1`, find the `$RoleExecutors` hashtable and delete the `hosts` line (e.g. `"hosts" = { ... }` / `hosts = 'Invoke-RoleHosts'`). Leave the other role entries intact. (`provision.sh` uses generic `role_<name>` dispatch and needs no edit — with the role gone from `fleet.json` it never dispatches.)

- [ ] **Step 4: Drop the role from the manifest**

In `fleet.json`, remove `"hosts"` from the `roles` array of all four machines (`latitude`, `desktop`, `server`, `hub`). Change nothing else.

- [ ] **Step 5: Verify no dangling references**

```bash
grep -rn "fleet-hosts\|roles/hosts\|Invoke-RoleHosts\|role_hosts\|FLEET_HOSTS" --include=*.nix --include=*.sh --include=*.ps1 --include=*.json . | grep -v "docs/\|.superpowers/"
wsl -e bash -lc 'cd /mnt/c/Users/methe/machines && jq -e ".machines | map(.roles | index(\"hosts\")) | all(. == null)" fleet.json'
```
Expected: first grep prints nothing; the jq prints `true` (no machine still lists `hosts`). (Run jq via WSL — not on Git Bash PATH.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(fleet): retire the hosts-file machinery — MagicDNS is the resolver

Deletes fleet-hosts.nix + the hosts role executors, its provision.ps1 dispatch
entry, its NixOS import, and the role from fleet.json. MagicDNS (Headscale gg.ez,
accept-dns pinned) supersedes the hand-maintained hosts fallback.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3: Slim `ssh.nix` to what MagicDNS can't provide

**Files:**
- Modify: `modules/home/ssh.nix`

**Interfaces:**
- Consumes: MagicDNS resolves `<name>` fleet-wide, so per-box `HostName` blocks are redundant EXCEPT the hub (must stay on `cyphy.kz`) and non-default `User`s.
- Produces: `ssh hub` → `cyphy.kz` (user `debian`); `ssh desktop`/`ssh server` → default MagicDNS name with user `methe`; `ssh latitude` needs no block (name + default user resolve). The `settings."*"` defaults block is preserved.

- [ ] **Step 1: Rewrite the generator to emit only hub-address + non-default users**

In `modules/home/ssh.nix`, change `mkBlock` so it emits a `HostName` ONLY for the hub, and a `User` only when `ssh.user` is set and differs from the default `me`/current user; drop the `HostName = m.tailnet.ip` for non-hub members (MagicDNS supplies it). Keep `StrictHostKeyChecking = "accept-new"` and the `settings."*"` defaults verbatim. Concretely, replace the `mkBlock` body:
```nix
  mkBlock = _name: m: (
    (
      if m.mesh.role == "hub"
      then {HostName = params.endpoint;} # cyphy.kz — hub SSH must not depend on the transport it hosts
      else {} # MagicDNS resolves the bare name fleet-wide
    )
    // (
      if (m.ssh.user or "me") != "me"
      then {User = m.ssh.user;}
      else {}
    )
    // {StrictHostKeyChecking = "accept-new";}
  );
```
Update the header comment to say HostName now comes from MagicDNS (Headscale gg.ez), with the hub as the sole `cyphy.kz` exception.

- [ ] **Step 2: Verify it evaluates + renders the intended blocks (RUN ON latitude)**

```bash
nix eval --json .#homeConfigurations.\"me@latitude\".config.programs.ssh.settings --apply 'x: { hub = x.hub; server = x.server; latitude = x.latitude; }'
```
Expected: `hub` has `HostName = "cyphy.kz"`, `User = "debian"`, `StrictHostKeyChecking`; `server` has `User = "methe"` + `StrictHostKeyChecking`, NO `HostName`; `latitude` has only `StrictHostKeyChecking` (no HostName/User). If the current-user default is not `me`, adjust the `!= "me"` guard to match the box's `home.username`.

- [ ] **Step 3: Commit**

```bash
git add modules/home/ssh.nix
git commit -m "feat(fleet): slim ssh.nix to hub cyphy.kz alias + non-default users

MagicDNS (Headscale gg.ez) now resolves every fleet name, so per-box tailnet-IP
HostName blocks are dropped; only the hub's public cyphy.kz address (resilience:
managing the hub must not depend on the transport it hosts) and non-default SSH
users remain.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4: Hand-delete the managed hosts block on this box (real-box, non-repo)

**Files:** `C:\Windows\System32\drivers\etc\hosts` (homeserver/METHE-SERVER — verified 2026-07-15 that one `# BEGIN fleet hosts` block is present). The retired `hosts` role has no remove mode, so this is manual, elevated, one box.

- [ ] **Step 1: Back up and remove the block (elevated pwsh, on this box)**

In an **Administrator** PowerShell:
```powershell
$h = "$env:WINDIR\System32\drivers\etc\hosts"
Copy-Item $h "$h.bak-fleet-hosts" -Force
$t = Get-Content $h -Raw
$t = [regex]::Replace($t, '(?s)\r?\n?# BEGIN fleet hosts.*?# END fleet hosts\r?\n?', "`r`n")
Set-Content $h $t -Encoding ascii -NoNewline
Select-String -Path $h -Pattern "fleet hosts"   # expect: no matches
```
Expected: the `# BEGIN fleet hosts … # END fleet hosts` block is gone; a `.bak-fleet-hosts` backup remains; `Select-String` finds nothing. (Any other Windows box that had the block applied needs the same one-off; g614jv/desktop and the VPS never had it, per the Layer 1 real-box notes — confirm per box before assuming.)

- [ ] **Step 2: Verify names still resolve via MagicDNS (not the hosts file)**

```powershell
Resolve-DnsName server ; Resolve-DnsName hub.gg.ez
```
Expected: `server`→`100.64.0.3` and `hub.gg.ez`→`100.64.0.1` still resolve — now purely via MagicDNS, proving the hosts block was redundant.

### Task 5: Open the Layer 3 PR

- [ ] **Step 1: Push + PR**

```bash
git push -u origin feat/fleet-magicdns-cleanup
gh pr create --title "Fleet rename — Layer 3: MagicDNS adoption cleanup" --body "Retires the hosts-file machinery (fleet-hosts.nix + hosts role) now that MagicDNS (Headscale gg.ez, accept-dns pinned) is the resolver; slims ssh.nix to the hub cyphy.kz alias + non-default users. Depends on Layer 1 (#1) merged + Layer 2 (gg.ez + node renames) live. Pre-merge gate: nix flake check + ssh-settings render on latitude; MagicDNS resolution confirmed with the hosts block removed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-review notes (spec coverage)

- Spec Layer 2 (a) gg.ez deploy → L2.2 (+rollback); (b) given-name renames → L2.3. ✓
- Spec Layer 3: retire fleet-hosts.nix + hosts role + block → Task 2 + Task 4; pin accept-dns → Task 1; slim ssh.nix → Task 3. ✓
- Gating (L3 needs L1 merged + L2 live) → Global Constraints + Task-0 precondition. ✓
- Deferred/real-box: all `nix eval` on latitude; L2 prod-auth on VPS; Task 4 elevated on this box. Marked throughout.
