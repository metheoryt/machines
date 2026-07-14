# Fleet rename — Layer 1 (repo labels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename each fleet machine to its consistent target name at the machines-repo layer (`fleet.json` key + latitude's flake attr / dir / host-memory), keeping all OS-identity identifiers untouched, and ship it as one mergeable PR.

**Architecture:** Layer 1 of the three-layer design (`docs/superpowers/specs/2026-07-15-fleet-rename-and-magicdns-adoption-design.md`). It is auth-free and local: no VPS, no live-tailnet, no Headscale changes. Renaming `fleet.json` keys re-points the generated `ssh <name>` aliases and the derived `params.hosts`/`machines` map; a full-label rename of the sole NixOS box (latitude) covers its flake attr, `hosts/` dir, host-memory file, and decouples `just switch` from the OS hostname.

**Tech Stack:** Nix flakes + home-manager, `fleet.json` (jq), a `justfile`, git.

## Global Constraints

- **Target names → machines:** `hub`=vps, `latitude`=latitude5520, `desktop`=g614jv, `server`=homeserver. The iOS phone (`ipheoryt12`) is untouched.
- **OS hostnames are NOT renamed.** Keep `networking.hostName = "latitude5520"` and every `detect.hostname` verbatim: `27608` (hub), `latitude5520` (latitude), `g614jv` (desktop), `methe-server` (server).
- **No AWG changes.** Keep every `mesh.*` field verbatim, including `peerName` (`nix-lat5520`, `me-g614jv`, `wg0-homeserver`) and `mesh.ip`.
- **Key rename is AWG-safe** — verified: `mesh-vpn.nix` reads only value-level constants (`obfuscation`/`vpsPublicKey`/`endpoint`/`port`), and no `.nix`/`.sh`/`.ps1` indexes `fleet.json` by a literal machine key; `fleet_detect()` matches by `detect.hostname` and echoes the (new) key.
- **Layer 1 does NOT touch:** the `hosts` role, `fleet-hosts.nix`, `ssh.nix`'s structure, or any `roles` array — those are Layers 2–3. The `hosts` role stays listed in `fleet.json` for now.
- **Nix acceptance (`nix flake check`, `nix eval`) runs only on latitude** (the sole NixOS box). Edits and jq checks can be made from any box; the real gate is on latitude before merge.

---

### Task 1: Create the branch and rename the `fleet.json` keys

**Files:**
- Modify: `fleet.json` (rename the four top-level `machines` keys)

**Interfaces:**
- Produces: `fleet.json` `machines` keyed `hub`/`latitude`/`desktop`/`server`; each machine's `detect.hostname`, `mesh.*`, `tailnet.ip`, `ssh.*`, `roles` unchanged. Consumed by `ssh.nix` (alias names), `mesh-vpn-params.nix` (`hosts`/`machines` maps), and the provisioner libs (`fleet_detect`).

- [ ] **Step 1: Create the feature branch**

Run (from the repo root, on `main`, working tree clean):
```bash
git switch -c feat/fleet-rename-labels
```

- [ ] **Step 2: Rename the four keys in `fleet.json`**

Edit `fleet.json` — change ONLY the four top-level keys under `machines`. The final file is exactly (values byte-identical to today, keys renamed):

```json
{
  "machines": {
    "latitude": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.8", "role": "member", "peerName": "nix-lat5520" },
      "tailnet": { "ip": "100.64.0.2" },
      "roles": ["base", "mesh-member", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client", "hosts"],
      "detect": { "hostname": "latitude5520" }
    },
    "desktop": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.6", "role": "member", "peerName": "me-g614jv" },
      "tailnet": { "ip": "100.64.0.4" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "repos", "hosts"],
      "detect": { "hostname": "g614jv" }
    },
    "server": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.2", "role": "member", "peerName": "wg0-homeserver" },
      "tailnet": { "ip": "100.64.0.3" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client", "hosts"],
      "detect": { "hostname": "methe-server" }
    },
    "hub": {
      "platform": "debian",
      "mesh": { "ip": "10.0.0.1", "role": "hub", "managePeers": "/home/debian/vps/vps/manage-peers.sh" },
      "tailnet": { "ip": "100.64.0.1" },
      "ssh": { "user": "debian", "host": "cyphy.kz" },
      "roles": ["base", "mesh-hub", "ssh-server", "agents", "dotfiles", "backup-client", "hosts"],
      "detect": { "hostname": "27608" }
    }
  }
}
```

- [ ] **Step 3: Verify JSON validity + keys + preserved fields**

Run (any box with `jq`; on latitude, or Git Bash if jq present):
```bash
jq -e '.machines | keys == ["desktop","hub","latitude","server"]' fleet.json
jq -r '.machines | to_entries[] | "\(.key)\t\(.value.detect.hostname)\t\(.value.mesh.peerName // "-")\t\(.value.tailnet.ip)"' fleet.json
```
Expected: first line prints `true` (exit 0); table shows `desktop g614jv me-g614jv 100.64.0.4`, `hub 27608 - 100.64.0.1`, `latitude latitude5520 nix-lat5520 100.64.0.2`, `server methe-server wg0-homeserver 100.64.0.3` — i.e. keys renamed, OS hostnames + peerNames + tailnet IPs intact.

- [ ] **Step 4: Confirm no lingering literal old-key lookup broke**

Run:
```bash
grep -rn '"latitude5520"\|"homeserver"\|"g614jv"\|"vps"' --include=*.nix modules/ 2>/dev/null | grep -v 'peerName\|detect\|hostName\|# '
```
Expected: no output (no NixOS module indexes `fleet.json` by a literal machine key; `mesh-vpn-params.nix` maps generically). If any line appears, it is a real consumer — stop and reconcile before continuing.

- [ ] **Step 5: Commit**

```bash
git add fleet.json
git commit -m "feat(fleet): rename fleet.json keys to consistent names (hub/latitude/desktop/server)

Re-points generated ssh aliases (ssh hub/latitude/desktop/server) and the
derived params.hosts/machines maps. OS hostnames (detect.hostname,
networking.hostName), mesh.* (incl. peerName/ip), tailnet.ip, ssh.* all
unchanged. AWG-safe: mesh-vpn.nix indexes no fleet keys; fleet_detect matches
by detect.hostname.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Full-label rename of the NixOS box (latitude)

**Files:**
- Rename: `hosts/latitude5520/` → `hosts/latitude/` (git mv)
- Rename: `agents/hosts/latitude5520.md` → `agents/hosts/latitude.md` (git mv)
- Modify: `flake.nix` (lines ~149, 155, 181, 182)
- Modify: `justfile` (add `nixos_attr` var; lines 48, 78, 84, 90, 148, 271)
- Modify: `hosts/latitude/nixos/configuration.nix` (line ~123 `hostname` specialArg)

**Interfaces:**
- Consumes: renamed `fleet.json` from Task 1 (independent — flake eval does not read `fleet.json` by the old key).
- Produces: `nixosConfigurations.latitude`, `homeConfigurations."me@latitude"`, checks `nixos-latitude`/`home-latitude`; `just switch` targets `.#latitude`; `hostname` specialArg = `"latitude"` so `claude.nix`/`codex.nix` link `agents/hosts/latitude.md`. `networking.hostName` stays `"latitude5520"`.

- [ ] **Step 1: Rename the host dir and the host-memory file**

```bash
git mv hosts/latitude5520 hosts/latitude
git mv agents/hosts/latitude5520.md agents/hosts/latitude.md
```

- [ ] **Step 2: Rename the flake attrs in `flake.nix`**

In `flake.nix`, make these four edits:

Line ~149 (`nixosConfigurations`):
```nix
      latitude = mkHost "latitude" [
        nixos-hardware.nixosModules.dell-latitude-5520
      ];
```
Line ~155 (`homeConfigurations`):
```nix
      "me@latitude" = mkHome "latitude";
```
Lines ~181–182 (`checks`):
```nix
      nixos-latitude = self.nixosConfigurations.latitude.config.system.build.toplevel;
      home-latitude = self.homeConfigurations."me@latitude".activationPackage;
```

(`mkHost "latitude"` now resolves `./hosts/latitude/nixos/…` — the dir renamed in Step 1 — and threads `hostname = "latitude"` as a specialArg.)

- [ ] **Step 3: Decouple `just switch` from the OS hostname**

In `justfile`, add a dedicated attr variable next to the existing `hostname` var (after line 44):
```
flake_dir := justfile_directory()
# The sole NixOS box's flake attribute. Decoupled from `hostname` because the
# OS hostname stays `latitude5520` while the flake attr is `latitude`. A second
# NixOS box turns this into a hostname->attr map.
nixos_attr := "latitude"
```
Then replace `{{hostname}}` with `{{nixos_attr}}` in the six `nixos-rebuild` recipe lines — 48, 78, 84, 90, 148, 271. Each becomes e.g.:
```
    sudo nixos-rebuild switch --flake {{flake_dir}}#{{nixos_attr}}
```
(Leave the `hostname := ` line and all non-`nixos-rebuild` uses untouched.)

- [ ] **Step 4: Point the embedded home-manager specialArg at the new label**

In `hosts/latitude/nixos/configuration.nix`, the `home-manager.extraSpecialArgs` block (line ~121–124):
```nix
    extraSpecialArgs = {
      inherit inputs;
      hostname = "latitude";
    };
```
Leave `networking.hostName = "latitude5520";` (line ~33) UNCHANGED.

- [ ] **Step 5: Sanity-check for leftover references**

Run:
```bash
grep -rn "latitude5520" --include=*.nix --include=justfile flake.nix justfile modules/ hosts/ 2>/dev/null
```
Expected remaining hits (all benign/intended):
- `hosts/latitude/nixos/configuration.nix`: `networking.hostName = "latitude5520"` (intended — OS identity stays);
- the `fleet.meshVpn` comment block above `address = "10.0.0.8/32"`, which mentions "matches mesh-vpn-params.nix `hosts.latitude5520`" — now stale (the derived map key is `latitude`); optionally update the comment to `hosts.latitude`, not required for correctness.

No `mkHost`, `nixosConfigurations`, `homeConfigurations`, `checks`, or `hosts/latitude5520/` path references may remain. Investigate anything outside the two expected hits above.

- [ ] **Step 6: Nix acceptance gate (RUN ON latitude)**

This step requires a NixOS evaluator; run it on latitude (locally, or `ssh latitude` once Task 1's alias is live — or over the current `ssh latitude5520`/tailnet path). From the repo clone on latitude:
```bash
nix flake check
nix eval --raw .#nixosConfigurations.latitude.config.system.build.toplevel.outPath
nix eval --json .#homeConfigurations.\"me@latitude\".config.programs.ssh.settings --apply 'builtins.attrNames'
```
Expected: `nix flake check` prints "all checks passed" (or builds the two renamed checks without an "attribute 'latitude5520' missing" error); the toplevel resolves to a store path; the ssh settings attr names include `hub`, `latitude`, `desktop`, `server`, `*`. If latitude is not reachable this session, mark this step BLOCKED and record it as the PR's pre-merge gate (see Task 3).

- [ ] **Step 7: Commit**

```bash
git add flake.nix justfile hosts/ agents/hosts/
git commit -m "feat(fleet): full-label rename of the NixOS box latitude5520 -> latitude

Renames the flake attr, hosts/ dir, and host-memory file to 'latitude', and
decouples 'just switch' from the OS hostname via a nixos_attr justfile var.
networking.hostName + detect.hostname stay latitude5520 (OS identity, out of
scope). host-memory specialArg moves with the file so claude.nix/codex.nix link
agents/hosts/latitude.md.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Open the Layer 1 PR with the acceptance gate recorded

**Files:** none (git/PR only)

**Interfaces:**
- Consumes: the two commits from Tasks 1–2 on `feat/fleet-rename-labels`.
- Produces: a pushed branch + PR whose body states the Layer 1 scope and the pre-merge Nix gate.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/fleet-rename-labels
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "Fleet rename — Layer 1: repo labels (hub/latitude/desktop/server)" --body "$(cat <<'EOF'
Layer 1 of docs/superpowers/specs/2026-07-15-fleet-rename-and-magicdns-adoption-design.md — auth-free, local only.

## What
- Rename `fleet.json` keys → generated `ssh hub/latitude/desktop/server` aliases + derived params maps.
- Full-label rename of the sole NixOS box: flake attr, `hosts/latitude/` dir, host-memory file, `just switch` decoupled from OS hostname via a `nixos_attr` var.

## Out of scope (later layers)
- OS hostnames unchanged (`networking.hostName`, every `detect.hostname`).
- No AWG changes (`mesh.*` verbatim). No `hosts`-role / `fleet-hosts.nix` / `ssh.nix`-slim changes (Layer 3). No Headscale/`gg.ez` (Layer 2).

## Pre-merge gate (real box)
- [ ] `nix flake check` green on **latitude** with the renamed attrs (Task 2 Step 6).
- [ ] `ssh` settings render aliases `hub/latitude/desktop/server` (hub → cyphy.kz).

AWG-safe: `mesh-vpn.nix` indexes no fleet keys; `fleet_detect` matches by `detect.hostname`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Report the PR URL and the outstanding gate**

State the PR URL and whether the Task 2 Step 6 Nix gate passed this session or is deferred to latitude before merge.

---

## Post-merge follow-up (NOT this plan)

After Layer 1 merges, plan Layers 2–3 (VPS `gg.ez` deploy + `headscale nodes rename`; then MagicDNS-adoption cleanup: retire `fleet-hosts.nix` + `hosts` role + the hosts-file block on this box, pin `--accept-dns` on latitude, slim `ssh.nix`). Those need prod SSH auth and are gated on Layer 1 + a live-MagicDNS confirmation.
