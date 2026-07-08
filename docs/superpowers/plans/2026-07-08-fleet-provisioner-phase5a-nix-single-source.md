# Phase 5a — Nix single-source-of-truth refactor + g16 removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `fleet.json` the single name-keyed source of truth for mesh IPs (Nix derives from it), generate the SSH `matchBlocks` instead of hand-maintaining them, and remove the retired NixOS `g16` fleet-wide — all session/dry-build-verifiable, no real-box or VPS access required.

**Architecture:** `modules/system/mesh-vpn-params.nix` becomes the single `builtins.fromJSON` site for the repo-root `fleet.json`; it exposes the raw `machines` records plus a derived name→mesh-IP `hosts` map, and keeps only the genuinely non-per-host constants (`vpsPublicKey`/`port`/`endpoint`/`obfuscation`). `modules/home/ssh.nix` stops enumerating hosts by hand and generates one `matchBlock` per member via `builtins.mapAttrs`, keying the `HostName` on `mesh.role` (hub → public domain, else → mesh IP). The dead NixOS `g16` machine (entry + flake wiring + host dir + the quick-check helper's hardcoded paths) is deleted; `g614jv` (Windows) is the live ROG and keeps mesh `.6`.

**Tech Stack:** Nix (flakes, home-manager, `builtins.fromJSON`/`readFile`/`mapAttrs`), JSON (`fleet.json`), `jq` (cheap cross-platform gate), bash (`quick-check.sh`).

## Global Constraints

- **AmneziaWG obfuscation constants are load-bearing** — `vpsPublicKey`, `port`, and every `obfuscation.*` value in `mesh-vpn-params.nix` MUST stay byte-for-byte unchanged (one wrong digit = silent no-handshake). This refactor only changes how the `hosts` map is *sourced*, never these constants.
- **`fleet.json` is the single source of truth for mesh IPs.** After this phase no mesh IP is hand-written in any `.nix` file; every consumer derives from `fleet.json`.
- **The hub-hostname rule keys on `mesh.role`.** `mesh.role == "hub"` → `params.endpoint` (`cyphy.kz`); every other member → its `mesh.ip`. A naive "hostname = mesh.ip for all" generator silently regresses the deliberate choice that the `vps` SSH block points at the public domain, not `10.0.0.1`, so managing the VPS never depends on the tunnel it hosts.
- **No Nix on the Windows checkout.** `jq` gates run anywhere (Windows Git Bash / WSL); every `nix eval` / `nix flake check` / dry-build step runs on a nix-capable box — **latitude5520** (matching how Phase 0/1 were validated). Each such step is labelled `[nix box]` and assumes `cd ~/machines && git pull` first.
- **Additive `fleet.json` fields only.** The new `ssh.user` and `mesh.peerName` keys are optional and additive; the Phase 1 parsers (`provision/lib/fleet.sh` jq, `provision/lib/Fleet.psm1` `ConvertFrom-Json`) read by explicit key and ignore unknown keys, so they are unaffected.

## Out of scope (do not do in 5a)

- **`mesh.peerName` has no Nix consumer yet.** It lands here as data-only; the `mesh-member` executor in **Phase 5b** is its first reader. This is intended — do not add a Nix consumer or treat the unused field as dead clutter.
- **Only `hosts/g16/nixos/` is deleted.** `hosts/g16/windows/` stays — it is the live ROG's Windows config, still valid. So `hosts/g16/` survives containing only `windows/`, under a directory name (`g16`) that no longer matches its machine key (`g614jv`). Renaming that dir is **not** part of 5a — do not rename it, and do not be alarmed to find a `g16` windows dir after "removing g16."
- **`homeserver`'s `mesh.peerName` stays defaulted** (omitted → defaults to the machine key `homeserver`). Confirming the real VPS peer name via `manage-peers.sh list` is a Phase 5b / runbook step (needs VPS access this session can't reach).
- The VPS `manage-peers.sh` non-interactive prerequisite and the `mesh-member`/`mesh-hub` executors are **Phase 5b**.
- Do **not** touch the ~40 non-breaking `g16` mentions in docs/plans/comments (including the `justfile:56` error-message pointer at `hosts/g16/windows` runbook, which stays valid). Only the build-breaking references (`flake.nix`, `scripts/quick-check.sh`) and the stated data files change.

---

### Task 1: `fleet.json` — remove g16, add `ssh.user` + `mesh.peerName`

**Files:**
- Modify: `fleet.json`

**Interfaces:**
- Consumes: nothing (this is the source of truth).
- Produces: `machines.<name>.mesh.ip :: string`, `machines.<name>.mesh.role :: "member"|"hub"`, optional `machines.<name>.mesh.peerName :: string` (defaults to `<name>`), optional `machines.<name>.ssh.user :: string` (defaults to `"me"`). Machine keys after this task: `latitude5520`, `g614jv`, `homeserver`, `vps` (no `g16`).

- [ ] **Step 1: Write the new `fleet.json`**

Replace the entire file with (g16 entry gone; `mesh.peerName` set on the two members whose VPS peer name differs from the machine key; `ssh.user` set on the two Windows members and the Debian hub; `latitude5520` omits `ssh` → defaults to `me`):

```json
{
  "machines": {
    "latitude5520": {
      "platform": "nixos",
      "mesh": { "ip": "10.0.0.8", "role": "member", "peerName": "nix-lat5520" },
      "roles": ["base", "mesh-member", "ssh-server", "dev", "desktop", "laptop", "agents", "dotfiles", "repos", "backup-client"],
      "detect": { "hostname": "latitude5520" }
    },
    "g614jv": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.6", "role": "member", "peerName": "me-g614jv" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "repos"],
      "detect": { "hostname": "g614jv" }
    },
    "homeserver": {
      "platform": "windows",
      "mesh": { "ip": "10.0.0.2", "role": "member" },
      "ssh": { "user": "methe" },
      "roles": ["base", "mesh-member", "ssh-server", "agents", "dotfiles", "backup-hub", "backup-client"],
      "detect": { "hostname": "methe-server" }
    },
    "vps": {
      "platform": "debian",
      "mesh": { "ip": "10.0.0.1", "role": "hub" },
      "ssh": { "user": "debian" },
      "roles": ["base", "mesh-hub", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
  }
}
```

- [ ] **Step 2: Gate — valid JSON, g16 gone, fields present** (runs anywhere with `jq`: Windows Git Bash or WSL)

Run:
```bash
cd ~/machines   # or the repo root on Windows: cd /c/Users/methe/machines
jq -e '
  (.machines | has("g16") | not)                             # g16 removed
  and (.machines | keys | sort == ["g614jv","homeserver","latitude5520","vps"])
  and (.machines.g614jv.ssh.user == "methe")
  and (.machines.homeserver.ssh.user == "methe")
  and (.machines.vps.ssh.user == "debian")
  and (.machines.latitude5520 | has("ssh") | not)            # latitude defaults to "me"
  and (.machines.g614jv.mesh.peerName == "me-g614jv")
  and (.machines.latitude5520.mesh.peerName == "nix-lat5520")
  and (.machines.g614jv.mesh.ip == "10.0.0.6")               # the old .6 collision is now g614jv-only
' fleet.json && echo "GATE OK"
```
Expected: prints `true` then `GATE OK`. (If `jq` isn't on the Windows box, run this step in WSL or on the nix box — it's a cheap early check, not the acceptance gate.)

- [ ] **Step 3: Commit**

```bash
git add fleet.json
git commit -m "phase5a: fleet.json single source — drop g16, add ssh.user + mesh.peerName

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Derive Nix from `fleet.json` — `mesh-vpn-params.nix` + `ssh.nix`

These two files are one reviewable unit: switching the params map to a derivation and switching `ssh.nix` to a generator are coupled (the hand-written `params.hosts.g16` reference in `ssh.nix` breaks the moment the derived map drops g16, so both change together).

**Files:**
- Modify: `modules/system/mesh-vpn-params.nix`
- Modify: `modules/home/ssh.nix`

**Interfaces:**
- Consumes (from Task 1): `fleet.json` `machines` records, incl. `mesh.ip`, `mesh.role`, optional `ssh.user`.
- Produces:
  - `mesh-vpn-params.nix` attrs (unchanged surface + two derived): `vpsPublicKey`, `port`, `endpoint`, `obfuscation` (unchanged); `machines :: attrset` (raw `fleet.json` machine records); `hosts :: attrset name→bareMeshIP` (derived, replaces the hand map). `mesh-vpn.nix` keeps consuming `params.{obfuscation,vpsPublicKey,endpoint,port}` — those are untouched.
  - `ssh.nix`: `programs.ssh.matchBlocks` generated as one block per member, keyed by machine name, `hostname = role=="hub" ? endpoint : hosts.<name>`, `user = ssh.user or "me"`.

- [ ] **Step 1: Rewrite `modules/system/mesh-vpn-params.nix`** (add the `fromJSON` derivation; drop the hand-written `hosts`; keep constants byte-for-byte)

```nix
# modules/system/mesh-vpn-params.nix
#
# Non-secret AmneziaWG mesh constants + the fleet's machine records / mesh-IP
# map, the latter DERIVED from the repo-root fleet.json (the single source of
# truth for mesh IPs — Phase 5a). Plain data (imported by
# modules/system/mesh-vpn.nix and modules/home/ssh.nix), NOT a NixOS module.
#
# The constants below are the REAL non-secret AmneziaWG values, read from the
# live VPS (`awg show`) + ~/my/vps/vps/awg.env on 2026-07-08. They are
# interface-level and safe to commit (public key, port, obfuscation params).
# Only the per-host PRIVATE keys are secret and never live here. The obfuscation
# params MUST match the VPS exactly — one wrong digit = silent no-handshake, no
# error.
let
  # Single fromJSON site for the whole repo: every mesh-IP consumer derives from
  # here, so a box's IP is changed in exactly one place (fleet.json).
  fleet = builtins.fromJSON (builtins.readFile ../../fleet.json);
  machines = fleet.machines;
in {
  # VPS_PUBLIC_KEY (public — safe to commit).
  vpsPublicKey = "Hm4m5Cce1RdzpbcOezzliDBxV4ZY2tp9mIMWXNivY1s=";

  # AWG_PORT (the VPS wg0 listening port).
  port = 64531;

  # Endpoint by domain (Decision 7): a VPS IP change is one DNS update.
  endpoint = "cyphy.kz";

  # AWG_JC/JMIN/JMAX/S1/S2/H1..H4 — MUST match the VPS interface exactly.
  obfuscation = {
    Jc = 4;
    Jmin = 40;
    Jmax = 70;
    S1 = 71;
    S2 = 64;
    H1 = 4170542315;
    H2 = 917531710;
    H3 = 2420372300;
    H4 = 330186316;
  };

  # Raw fleet machine records (platform/roles/mesh/ssh/detect), for consumers
  # that need role or ssh.user — e.g. the ssh.nix matchBlocks generator.
  inherit machines;

  # Derived name -> bare mesh IP (no /32), from fleet.json. Replaces the old
  # hand-maintained map that had drifted (missing g614jv/vps, listed dead g16).
  hosts = builtins.mapAttrs (_name: m: m.mesh.ip) machines;
}
```

- [ ] **Step 2: Rewrite `modules/home/ssh.nix`** (generate `matchBlocks`; keep the `{...}:` signature by using `builtins.mapAttrs`)

```nix
# modules/home/ssh.nix
#
# Non-interactive SSH client config for the fleet, so `ssh latitude5520` (etc.)
# Just Works for agents and humans: fixed HostName, User, and accept-new
# host-key policy (TOFU-then-pin, safe on a private self-controlled mesh).
# Imported by me.nix.
#
# matchBlocks are GENERATED from fleet.json (via mesh-vpn-params.nix) — one
# block per fleet member, so adding/removing a machine or changing its IP is a
# one-line fleet.json edit. HostName keys on mesh.role: the hub (vps) points at
# its public domain so managing it never depends on the tunnel it hosts; every
# other member points at its mesh IP.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
{...}: let
  params = import ../system/mesh-vpn-params.nix;
  mkBlock = name: m: {
    hostname =
      if m.mesh.role == "hub"
      then params.endpoint # e.g. cyphy.kz — never the 10.0.0.1 mesh IP
      else params.hosts.${name};
    user = m.ssh.user or "me";
    extraOptions.StrictHostKeyChecking = "accept-new";
  };
in {
  programs.ssh = {
    enable = true;
    matchBlocks = builtins.mapAttrs mkBlock params.machines;
  };
}
```

- [ ] **Step 3: `[nix box]` Gate — derived `hosts` map is correct and g16-free**

Run (on latitude5520 after `git pull`):
```bash
cd ~/machines
nix eval --json -f modules/system/mesh-vpn-params.nix hosts
```
Expected (order may vary): `{"g614jv":"10.0.0.6","homeserver":"10.0.0.2","latitude5520":"10.0.0.8","vps":"10.0.0.1"}` — contains `g614jv` and `vps`, does **not** contain `g16`.

- [ ] **Step 4: `[nix box]` Gate — the generated SSH matchBlocks evaluate green with the right hostnames/users**

Run:
```bash
cd ~/machines
nix eval --json \
  ".#homeConfigurations.\"me@latitude5520\".config.programs.ssh.matchBlocks" \
  --apply 'bs: builtins.mapAttrs (_: b: { inherit (b) hostname user; }) bs'
```
Expected: an object whose keys are exactly `latitude5520`, `g614jv`, `homeserver`, `vps` (no `g16`), with:
- `latitude5520` → `{ "hostname": "10.0.0.8", "user": "me" }`
- `g614jv` → `{ "hostname": "10.0.0.6", "user": "methe" }`
- `homeserver` → `{ "hostname": "10.0.0.2", "user": "methe" }`
- `vps` → `{ "hostname": "cyphy.kz", "user": "debian" }` ← hub keeps the public domain, NOT `10.0.0.1`.

(If your home-manager exposes matchBlocks under a slightly different attr path, fall back to `nix build --dry-run .#homeConfigurations.\"me@latitude5520\".activationPackage` — a clean dry-build proves the generator evaluates; the eval above is the sharper check.)

- [ ] **Step 5: Commit**

```bash
git add modules/system/mesh-vpn-params.nix modules/home/ssh.nix
git commit -m "phase5a: derive mesh hosts + SSH matchBlocks from fleet.json

Single fromJSON site in mesh-vpn-params.nix; ssh.nix generates one
matchBlock per member (hub keeps public domain, others use mesh IP).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Remove the NixOS `g16` fleet-wide — `flake.nix`, host dir, `quick-check.sh`

**Files:**
- Modify: `flake.nix` (remove 5 `g16` references)
- Delete: `hosts/g16/nixos/` (both `configuration.nix` and `hardware-configuration.nix`; the directory becomes empty of nixos and is removed — **leave `hosts/g16/windows/` untouched**)
- Modify: `scripts/quick-check.sh` (repoint hardcoded g16 paths → latitude5520)

**Interfaces:**
- Consumes: nothing new.
- Produces: `self.nixosConfigurations` = `{ latitude5520 }` only; `self.homeConfigurations` = `{ "me@latitude5520" }` only; `self.checks.<system>` = `{ nixos-latitude5520, home-latitude5520 }` only.

- [ ] **Step 1: Remove the `g16` host from `flake.nix`**

Delete the `g16 = mkHost "g16" [ … ];` block from `nixosConfigurations` (the block with the three `nixos-hardware` common-cpu-intel / common-pc-laptop / common-pc-laptop-ssd modules), leaving:

```nix
    nixosConfigurations = {
      latitude5520 = mkHost "latitude5520" [
        nixos-hardware.nixosModules.dell-latitude-5520
      ];
    };
```

Delete the `"me@g16"` line from `homeConfigurations`, leaving:

```nix
    homeConfigurations = {
      "me@latitude5520" = mkHome "latitude5520";
    };
```

Delete the two `g16` check lines from `checks.${system}`, leaving:

```nix
    checks.${system} = {
      nixos-latitude5520 = self.nixosConfigurations.latitude5520.config.system.build.toplevel;
      home-latitude5520 = self.homeConfigurations."me@latitude5520".activationPackage;
    };
```

- [ ] **Step 2: Delete the NixOS g16 host directory** (leave the windows sibling)

Run:
```bash
cd ~/machines
git rm -r hosts/g16/nixos
git status --short hosts/g16   # confirm ONLY hosts/g16/nixos/* staged for deletion; hosts/g16/windows/* untouched
```
Expected: `hosts/g16/nixos/configuration.nix` and `hosts/g16/nixos/hardware-configuration.nix` shown deleted; nothing under `hosts/g16/windows/` listed.

- [ ] **Step 3: Repoint `scripts/quick-check.sh` off the deleted g16 paths → latitude5520**

In `scripts/quick-check.sh`, change the `REQUIRED_FILES` array from the g16 paths to latitude5520:

```bash
REQUIRED_FILES=(
    "hosts/latitude5520/nixos/configuration.nix"
    "hosts/latitude5520/nixos/hardware-configuration.nix"
    "modules/home/me.nix"
)
```

And change the dry-run build target near the end of the file from `g16` to `latitude5520`:

```bash
if nix build --dry-run ".#nixosConfigurations.latitude5520.config.system.build.toplevel" > /dev/null 2>&1; then
```

- [ ] **Step 4: `[nix box]` Gate — flake evaluates, g16 is gone, latitude5520 still builds**

Run (on latitude5520 after `git pull`):
```bash
cd ~/machines
nix eval --json '.#nixosConfigurations' --apply 'builtins.attrNames'
# Expected: ["latitude5520"]   (no "g16")

nix flake check --no-build
# Expected: no error about a missing hosts/g16/nixos path; checks evaluate.

nix build --dry-run '.#nixosConfigurations.latitude5520.config.system.build.toplevel'
# Expected: dry-build plan prints, no eval error.

./scripts/quick-check.sh
# Expected: all ✅ (finds latitude5520 files, dry-build target resolves).
```

- [ ] **Step 5: Commit**

```bash
git add flake.nix scripts/quick-check.sh
git rm -r --cached hosts/g16/nixos 2>/dev/null; git add -A hosts/g16/nixos
git commit -m "phase5a: remove retired NixOS g16 (flake wiring, host dir, quick-check)

g614jv (Windows) is the live ROG and owns mesh .6; the NixOS g16 install
is gone. Leaves hosts/g16/windows/ (still-valid ROG Windows config).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Fix stale project memory + final acceptance sweep

**Files:**
- Modify: `.claude/memory/project.md` (correct the stale "g16 = live NixOS member / shares `.6`" facts and mark 5a done)

**Interfaces:**
- Consumes: the green state from Tasks 1–3.
- Produces: none (documentation + verification only).

- [ ] **Step 1: Update `.claude/memory/project.md`**

In the "Fleet network" section, correct the stale bullets so they reflect the post-5a reality. Specifically:
- In the peer-map bullet, change the parenthetical that still frames `.6` as an ambiguous g16/g614jv slot to state plainly: `.6`=`g614jv` (`me-g614jv`), the Windows-only ROG; the NixOS `g16` install is retired and removed from the repo.
- In the Phase 5 bullet, change "Phase 5a removes them" (future) to record that Phase 5a is **EXECUTED**: `fleet.json` is the single mesh-IP source of truth (`mesh-vpn-params.nix` derives `hosts` + exposes `machines` via `fromJSON`; `ssh.nix` generates `matchBlocks` keyed on `mesh.role`), the new `ssh.user`/`mesh.peerName` fields are in place (`g614jv`/`homeserver`=`methe`, `vps`=`debian`; peerNames `me-g614jv`/`nix-lat5520`), and the NixOS `g16` (fleet.json entry, `flake.nix` wiring, `hosts/g16/nixos/`, `quick-check.sh` paths) is gone — `hosts/g16/windows/` deliberately kept. Note the remaining follow-ups: **Phase 5b** (VPS `manage-peers.sh` non-interactive prereq + the mesh-member/mesh-hub executors, real-box), and that `homeserver`'s `mesh.peerName` is still defaulted pending `manage-peers.sh list` confirmation.

(Keep it to edits of the existing bullets — one fact per bullet, curated; do not duplicate.)

- [ ] **Step 2: `[nix box]` Final acceptance sweep** (single pass confirming the whole phase is green)

Run (on latitude5520 after `git pull`):
```bash
cd ~/machines
set -e
echo "1) g16 absent from flake outputs:"
nix eval --json '.#nixosConfigurations' --apply 'builtins.attrNames'   # ["latitude5520"]
echo "2) derived hosts (fleet.json is the source), no g16:"
nix eval --json -f modules/system/mesh-vpn-params.nix hosts
echo "3) hub keeps public domain, Windows members use methe:"
nix eval --json \
  ".#homeConfigurations.\"me@latitude5520\".config.programs.ssh.matchBlocks" \
  --apply 'bs: builtins.mapAttrs (_: b: { inherit (b) hostname user; }) bs'
echo "4) full dry-build of the live NixOS member:"
nix build --dry-run '.#nixosConfigurations.latitude5520.config.system.build.toplevel'
echo "5) flake check:"
nix flake check --no-build
echo "ALL GREEN"
```
Expected: `["latitude5520"]`; the g16-free hosts map; the four matchBlocks with `vps`→`cyphy.kz`/`debian` and the two Windows members→`methe`; a clean dry-build; `ALL GREEN`.

- [ ] **Step 3: Commit**

```bash
git add .claude/memory/project.md
git commit -m "phase5a: record executed — memory fix (g16 retired, fleet.json is SoT)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (against `2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md`, the 5a-labelled scope):
- `fleet.json` as mesh-IP source of truth → Task 2 (`fromJSON` derivation) + Task 1 (the data).
- `mesh-vpn-params.nix` derives `hosts`, drops hand map, keeps constants → Task 2 Step 1.
- `modules/home/ssh.nix` generator with the hub-hostname (`mesh.role`) rule → Task 2 Step 2.
- New `ssh.user` / `mesh.peerName` fields → Task 1 (with the g614jv=`methe` correction verified on-box).
- `g16` removal (fleet.json entry, `hosts/g16/nixos/`, `mesh-vpn-params.nix` line) → Task 1 + Task 3; the params `g16` line disappears structurally via the derivation (Task 2). Flake wiring + `quick-check.sh` (build-breaking refs implied by "remove g16") → Task 3.
- `.claude/memory/project.md` stale-bullet fix → Task 4.
- Verification (nix eval derived hosts + generated ssh blocks + g16-gone + dry-build) → Task 2 Steps 3–4, Task 3 Step 4, Task 4 Step 2.

**Placeholder scan:** every code step shows the full target content (whole `fleet.json`, whole `mesh-vpn-params.nix`, whole `ssh.nix`, exact flake blocks, exact `quick-check.sh` array/target). No TBD/TODO/"handle edge cases".

**Type consistency:** `mesh-vpn-params.nix` exposes `vpsPublicKey`/`port`/`endpoint`/`obfuscation`/`machines`/`hosts`; `mesh-vpn.nix` consumes the first four (untouched); `ssh.nix` consumes `params.machines` (iteration), `params.hosts.${name}` (IP), `params.endpoint` (hub), and `m.mesh.role` / `m.ssh.user or "me"`. `mkBlock : name -> machineRecord -> matchBlock` matches `builtins.mapAttrs`'s `(name: value: …)` signature. `hosts` keys == `machines` keys == fleet machine keys, so `params.hosts.${name}` always resolves. `m.ssh.user or "me"` falls through even when the whole `ssh` attr is absent (latitude5520), so no eval error.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-08-fleet-provisioner-phase5a-nix-single-source.md`.**

Note on verification: the `jq` gate (Task 1) runs on this Windows box or WSL, but every `nix eval` / `nix flake check` / dry-build step runs on **latitude5520** (this checkout has no Nix) — so full acceptance requires a pull + run on that box.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks. Best fit here since the Nix gates land on latitude5520 and each task is a tight, independently-reviewable diff.
2. **Inline Execution** — execute tasks in this session with checkpoints. Caveat: this session can complete the edits + `jq` gate but **cannot run the Nix verification** (no Nix on Windows); the `[nix box]` gates would be deferred to a latitude5520 run.

**Which approach?**
