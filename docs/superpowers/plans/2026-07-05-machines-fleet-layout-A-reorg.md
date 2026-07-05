# Machines Fleet Layout — Plan A: machines-internal reorg

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the `machines` repo so its top-level layout reflects a fleet of physical machines — per-host OS subdirs, shared `install-media/` and `scripts/`, a reserved `homeserver` host — with all Nix wiring and Windows-script self-references updated to match.

**Architecture:** Pure file moves within one repo plus mechanical path rewiring. No behavior changes. Correctness is validated by the Nix flake evaluator (`just quick`, `nix flake check`) and `git grep` sweeps for stale references — this is infra, so there are no unit tests. `git mv` everywhere to preserve history.

**Tech Stack:** Nix flakes, Home Manager, `just`, PowerShell scripts (edited, not run — no Windows host here), Markdown docs.

**Companion:** Plan B (`2026-07-05-machines-fleet-layout-B-backup.md`) does the cross-repo restic relocation. Plans A and B are independent; either can land first. This plan does **not** touch `backup/` or the `vps` repo.

## Global Constraints

- **Use `git mv`** for every relocation — never delete+recreate or `cp`. History must be preserved and the diff must read as a rename.
- **Reference spec:** `docs/superpowers/specs/2026-07-05-machines-fleet-layout-design.md`.
- **The fleet:** `g16` = ASUS ROG G16 2024 / RTX 4060 (NixOS host `g16` + Windows `ME-G614JV`); `homeserver` = ASUS ROG G16 2023 / RTX 3050 Ti (Win11, hostname `methe-server`); `latitude5520` = Dell, NixOS.
- **`~/nix` is NOT a rename leftover** — it is the symlink name Home Manager reads (`~/nix/agents`), independent of the repo folder name. Never rename it.
- **`.ps1`/`.bat` files are not executed** (no Windows host) — edit by inspection; verify via `git grep` that no stale path/repo-name strings remain.
- **After each task, the flake must still evaluate:** `just quick` must pass; the nixos-touching task must also pass `nix flake check`.

---

### Task 1: Split host NixOS config into `nixos/` subdirs

**Files:**
- Move: `hosts/g16/configuration.nix` → `hosts/g16/nixos/configuration.nix`
- Move: `hosts/g16/hardware-configuration.nix` → `hosts/g16/nixos/hardware-configuration.nix`
- Move: `hosts/latitude5520/configuration.nix` → `hosts/latitude5520/nixos/configuration.nix`
- Move: `hosts/latitude5520/hardware-configuration.nix` → `hosts/latitude5520/nixos/hardware-configuration.nix`
- Modify: `flake.nix` (mkHost paths)
- Modify: both moved `configuration.nix` files (module import depth)

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces: hosts now live at `hosts/<host>/nixos/`; `flake.nix` `mkHost` reads `./hosts/${hostname}/nixos/configuration.nix` and `.../nixos/hardware-configuration.nix`. Later tasks (docs) rely on these paths.

- [ ] **Step 1: Move the four Nix files**

```bash
cd /home/me/gh/machines
mkdir -p hosts/g16/nixos hosts/latitude5520/nixos
git mv hosts/g16/configuration.nix          hosts/g16/nixos/configuration.nix
git mv hosts/g16/hardware-configuration.nix hosts/g16/nixos/hardware-configuration.nix
git mv hosts/latitude5520/configuration.nix          hosts/latitude5520/nixos/configuration.nix
git mv hosts/latitude5520/hardware-configuration.nix hosts/latitude5520/nixos/hardware-configuration.nix
```

- [ ] **Step 2: Repoint `flake.nix` mkHost to the `nixos/` subdir**

In `flake.nix`, inside `mkHost`, change the two module paths:

```nix
        modules =
          [
            ./hosts/${hostname}/nixos/configuration.nix
            ./hosts/${hostname}/nixos/hardware-configuration.nix
            home-manager.nixosModules.default
            ({...}: { nixpkgs = nixpkgsConfig; })
          ]
```

(Only the first two lines change — append `nixos/` after `${hostname}/`.)

- [ ] **Step 3: Fix module import depth in both moved `configuration.nix`**

Each `configuration.nix` moved one directory deeper, so every `../../modules/...` import is now `../../../modules/...`. Apply to both files:

```bash
cd /home/me/gh/machines
sed -i 's#\.\./\.\./modules/#../../../modules/#g' \
  hosts/g16/nixos/configuration.nix \
  hosts/latitude5520/nixos/configuration.nix
```

Then confirm no `../../modules/` (two-dot) references remain and the three-dot ones are present:

```bash
git grep -n '\.\./\.\./modules/' hosts/ ; echo "^ must be EMPTY"
git grep -n '\.\./\.\./\.\./modules/' hosts/ | head
```

- [ ] **Step 4: Verify the flake still evaluates**

Run: `just quick`
Expected: PASS (syntax OK).

Run: `nix flake check`
Expected: all four checks (`nixos-g16`, `nixos-latitude5520`, `home-g16`, `home-latitude5520`) evaluate without a "path does not exist" error. (A build may be slow; evaluation success is the gate.)

- [ ] **Step 5: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "hosts: split NixOS config into per-host nixos/ subdirs"
```

---

### Task 2: Rename the g16 Windows-reinstall dir and pull in git-autofetch.ps1

**Files:**
- Move: `hosts/g16/windows-reinstall/` → `hosts/g16/windows/` (all files **except** `autounattend.xml`, which Task 3 promotes)
- Move: `scripts/git-autofetch.ps1` → `hosts/g16/windows/git-autofetch.ps1`
- Modify: `hosts/g16/windows/install.ps1` (hardcoded `windows-reinstall` paths)
- Modify: `hosts/g16/windows/windows-reinstall-runbook.md` (path + repo-name staleness)
- Modify: `hosts/g16/windows/backup.ps1` (doc-comment repo-name staleness)
- Modify: `justfile` (line ~48 error-string path)

**Interfaces:**
- Consumes: nothing.
- Produces: g16's Windows reinstall flow lives at `hosts/g16/windows/`; `git-autofetch.ps1` sits beside it. Task 3 will `git mv` `autounattend.xml` out of the old dir — do that move in Task 3, so this task deliberately leaves `autounattend.xml` where it is until then. (If executing Task 3 first, adjust ordering; tasks are otherwise independent.)

- [ ] **Step 1: Rename the directory (git mv every file except autounattend.xml)**

```bash
cd /home/me/gh/machines
mkdir -p hosts/g16/windows
git mv hosts/g16/windows-reinstall/backup.ps1                    hosts/g16/windows/backup.ps1
git mv hosts/g16/windows-reinstall/restore.ps1                   hosts/g16/windows/restore.ps1
git mv hosts/g16/windows-reinstall/install.ps1                   hosts/g16/windows/install.ps1
git mv hosts/g16/windows-reinstall/windows-reinstall-runbook.md  hosts/g16/windows/windows-reinstall-runbook.md
git mv scripts/git-autofetch.ps1                                 hosts/g16/windows/git-autofetch.ps1
```

(Leave `hosts/g16/windows-reinstall/autounattend.xml` in place — Task 3 moves it. After Task 3 the old dir is empty and Git drops it automatically.)

- [ ] **Step 2: Fix hardcoded paths in `install.ps1`**

Replace every `hosts\g16\windows-reinstall\` with `hosts\g16\windows\` (Windows-style backslash paths — two occurrences: the `Join-Path` to `restore.ps1`, and the raw-githubusercontent URL uses forward slashes `hosts/g16/windows-reinstall/install.ps1`):

```bash
cd /home/me/gh/machines
sed -i 's#hosts\\g16\\windows-reinstall\\#hosts\\g16\\windows\\#g; s#hosts/g16/windows-reinstall/#hosts/g16/windows/#g' \
  hosts/g16/windows/install.ps1
git grep -n 'windows-reinstall' hosts/g16/windows/install.ps1 ; echo "^ must be EMPTY"
```

- [ ] **Step 3: Fix path + repo-name staleness in the runbook and backup.ps1**

The runbook and `backup.ps1` still say `windows-reinstall/` (the old dir) and `nix` (the old repo name: `GitHub\nix`, `github.com/metheoryt/nix`). Fix all:

```bash
cd /home/me/gh/machines
for f in hosts/g16/windows/windows-reinstall-runbook.md hosts/g16/windows/backup.ps1; do
  sed -i \
    -e 's#hosts/g16/windows-reinstall/#hosts/g16/windows/#g' \
    -e 's#hosts\\g16\\windows-reinstall#hosts\\g16\\windows#g' \
    -e 's#GitHub\\nix\\#GitHub\\machines\\#g' \
    -e 's#GitHub\\nix#GitHub\\machines#g' \
    -e 's#github.com/metheoryt/nix#github.com/metheoryt/machines#g' \
    "$f"
done
```

Then **read the runbook by eye** for residual prose references to "the nix repo" / `R:\windows-reinstall\` SSD-copy folder (in `backup.ps1` line ~254 it creates `$Dst\..\windows-reinstall`). Decide per the spec: the SSD standalone-copy folder name (`R:\windows-reinstall\`) is a runtime artifact, not a repo path — leave it as-is unless you also want to rename the SSD folder (out of scope; note it and move on). Confirm no stale *repo* references remain:

```bash
git grep -nE 'windows-reinstall|github.com/metheoryt/nix|GitHub\\nix' hosts/g16/windows/ \
  | grep -vE 'R:\\windows-reinstall|\\\.\.\\windows-reinstall'
echo "^ must be EMPTY (ignoring the R:\\ SSD-copy artifact)"
```

- [ ] **Step 4: Fix the `justfile` error-string path**

Line ~48 has an error message referencing `hosts/g16/windows-reinstall runbook`. Change only that path text (leave `~/nix`):

```bash
cd /home/me/gh/machines
sed -i 's#hosts/g16/windows-reinstall runbook#hosts/g16/windows runbook#g' justfile
git grep -n 'windows-reinstall' justfile ; echo "^ must be EMPTY"
git grep -n '~/nix' justfile | head ; echo "^ ~/nix intentionally preserved"
```

- [ ] **Step 5: Verify the flake still evaluates**

Run: `just quick`
Expected: PASS. (No Nix files changed here, but `justfile` did — confirm `just quick` still parses and runs.)

- [ ] **Step 6: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "g16/windows: rename windows-reinstall -> windows; pull in git-autofetch.ps1; fix nix->machines staleness"
```

---

### Task 3: Promote autounattend.xml to shared `install-media/` and track ventoy.json

**Files:**
- Move: `hosts/g16/windows-reinstall/autounattend.xml` → `install-media/autounattend.xml`
- Create: `install-media/ventoy.json`
- Create: `install-media/README.md`
- Modify: `hosts/g16/windows/windows-reinstall-runbook.md` (repoint autounattend + Ventoy references)

**Interfaces:**
- Consumes: nothing.
- Produces: shared Win11 install media at `install-media/`. The runbook (moved in Task 2) references `../../install-media/autounattend.xml` in prose and `install-media/ventoy.json`.

- [ ] **Step 1: git mv the answer file (do NOT copy the Downloads version)**

The tracked `autounattend.xml` is already the correct, current file — a normalized diff against `~/Downloads/autounattend.xml` is empty (same 803 lines, same embedded schneegans commit hash; the Downloads copy differs only in CRLF line endings). Preserve history and avoid a spurious whole-file diff:

```bash
cd /home/me/gh/machines
mkdir -p install-media
git mv hosts/g16/windows-reinstall/autounattend.xml install-media/autounattend.xml
```

Confirm it moved as a pure rename (no content hunk):

```bash
git diff --cached --stat install-media/autounattend.xml
git status --short | grep autounattend   # expect: R  hosts/g16/windows-reinstall/autounattend.xml -> install-media/autounattend.xml
```

- [ ] **Step 2: Create `install-media/ventoy.json`**

Exact content the runbook documents (Ventoy Auto Install plugin):

```json
{ "auto_install": [ { "image": "/Win11_25H2_Russian_x64_v2.iso", "template": "/unattend/autounattend.xml" } ] }
```

- [ ] **Step 3: Create `install-media/README.md`**

```markdown
# install-media — shared Windows 11 install media

Tracked config for the **Ventoy install USB** (the Kingston XS2000, partition
`P:`). Applies to **every** Win11 machine in the fleet — the `g16` daily driver
and the `homeserver` (`methe-server`). The answer file is generic: it prompts
for the computer name at install time, so one file serves all machines.

## Files

| Repo file          | Deploy to                     | Purpose                                        |
|--------------------|-------------------------------|------------------------------------------------|
| `autounattend.xml` | `P:\unattend\autounattend.xml` | Win11 answer file (locale, debloat, RDP, bypass) |
| `ventoy.json`      | `P:\ventoy\ventoy.json`        | Ventoy Auto Install plugin: maps the Win11 ISO → the answer file |

**This repo is source of truth.** After editing either file, copy it to the USB
path above so the two stay in sync.

## Not tracked (recreatable)

- The Windows ISO (`Win11_25H2_Russian_x64_v2.iso`) and the other ISOs on `P:`.
- `P:\rsti\` — Intel RST/VMD storage drivers (from Intel/ASUS), needed on the
  install disk screen when VMD is on.

## Deploy

Mount the Ventoy USB as `P:`, then from a checkout of this repo:

```powershell
Copy-Item install-media\autounattend.xml P:\unattend\autounattend.xml -Force
Copy-Item install-media\ventoy.json      P:\ventoy\ventoy.json        -Force
```

The g16 reinstall runbook (`hosts/g16/windows/windows-reinstall-runbook.md`)
walks the full boot → install → restore flow that uses this media.
```

- [ ] **Step 4: Repoint the runbook's autounattend + Ventoy references**

In `hosts/g16/windows/windows-reinstall-runbook.md`:
- The link `[`./autounattend.xml`](./autounattend.xml)` → `[`install-media/autounattend.xml`](../../install-media/autounattend.xml)`.
- The Ventoy box that transcribes the JSON inline: keep the explanatory prose but note the config is now the tracked file `install-media/ventoy.json` (deploy by copy, no longer transcribed from prose).
- Any "The repo's `autounattend.xml`" phrasing → point at `install-media/autounattend.xml`.

Then verify no runbook reference still points at a co-located `./autounattend.xml`:

```bash
cd /home/me/gh/machines
git grep -n 'autounattend' hosts/g16/windows/windows-reinstall-runbook.md
# every hit must resolve to install-media/, not ./autounattend.xml
```

- [ ] **Step 5: Verify**

Run: `python3 -c "import json,sys; json.load(open('install-media/ventoy.json')); print('ventoy.json OK')"`
Expected: `ventoy.json OK`.

Run: `just quick`
Expected: PASS (no Nix change; sanity only).

- [ ] **Step 6: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "install-media: promote shared Win11 autounattend.xml + track ventoy.json"
```

---

### Task 4: Tidy loose root scripts into `scripts/`

**Files:**
- Move: `update-pycharm.sh`, `update-rustdesk.sh`, `update-zed.sh`, `quick-check.sh` → `scripts/`
- Modify: `justfile` (update-script invocation paths)
- Modify: `AGENTS.md` (the `bash quick-check.sh` mention)

**Interfaces:**
- Consumes: nothing.
- Produces: shared repo tooling under `scripts/`. `justfile` recipes call `{{flake_dir}}/scripts/update-*.sh`.

- [ ] **Step 1: Move the four scripts**

```bash
cd /home/me/gh/machines
git mv update-pycharm.sh  scripts/update-pycharm.sh
git mv update-rustdesk.sh scripts/update-rustdesk.sh
git mv update-zed.sh      scripts/update-zed.sh
git mv quick-check.sh     scripts/quick-check.sh
```

- [ ] **Step 2: Repoint `justfile`**

Change the three update recipes to call the scripts under `scripts/`:

```bash
cd /home/me/gh/machines
sed -i 's#{{flake_dir}}/update-#{{flake_dir}}/scripts/update-#g' justfile
git grep -n 'flake_dir}}/scripts/update-' justfile   # expect 3 hits
git grep -n 'flake_dir}}/update-' justfile ; echo "^ must be EMPTY"
```

Also check `just quick` / any recipe that shells `quick-check.sh` by bare name and repoint to `scripts/quick-check.sh` if present:

```bash
git grep -n 'quick-check.sh' justfile
```

- [ ] **Step 3: Repoint the `AGENTS.md` mention**

```bash
cd /home/me/gh/machines
sed -i 's#bash quick-check.sh#bash scripts/quick-check.sh#g' AGENTS.md
git grep -n 'quick-check.sh' AGENTS.md
```

(`CLAUDE.md` is a symlink to `AGENTS.md`; editing `AGENTS.md` covers both.)

- [ ] **Step 4: Verify the update recipes resolve**

Run: `just --evaluate` (or `just -n update-zed`)
Expected: the dry-run shows `…/scripts/update-zed.sh`, no "No such file" from a stale path.

Run: `just quick`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "scripts: move update-* and quick-check into scripts/; repoint justfile + AGENTS.md"
```

---

### Task 5: Reserve the homeserver fleet slot

**Files:**
- Create: `hosts/homeserver/README.md`
- Create: `agents/hosts/methe-server.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `hosts/homeserver/` exists as a documented fleet slot; `methe-server` has per-host agent memory.

- [ ] **Step 1: Create `hosts/homeserver/README.md`**

```markdown
# homeserver

A fleet peer of `g16`: **ASUS ROG G16 2023, RTX 3050 Ti**, running **Windows 11
+ Docker Desktop (WSL2)** under the `methe` profile. Windows hostname:
`methe-server`.

- **What it runs** (Immich, Navidrome, Forgejo, the cyphy.kz service platform)
  is defined in the **`vps` repo**, not here. This repo owns the *machine*, not
  its services.
- **Its data backups** (Immich Postgres/media) live at `../../backup/homeserver/`
  (fleet restic system).
- **OS reinstall runbook:** not yet written — deferred; adapt from
  `../g16/windows/windows-reinstall-runbook.md` when needed. Shared Win11 install
  media (answer file + Ventoy config) is already at `../../install-media/`.
```

- [ ] **Step 2: Create `agents/hosts/methe-server.md`**

Match the shape of the existing `agents/hosts/g16.md` — a per-host memory stub. Read one first for the exact heading convention, then create:

```markdown
# methe-server (homeserver)

<!-- Per-host agent memory for the homeserver: ASUS ROG G16 2023 / RTX 3050 Ti,
     Windows 11 + Docker Desktop, methe profile. Loaded on this host only. -->

## Host

- ASUS ROG G16 2023, RTX 3050 Ti. Windows 11 + Docker Desktop (WSL2 backend).
- Runs the cyphy.kz self-hosted service platform — service definitions live in
  the `vps` repo; this machine's config/backup live in `machines`.
```

- [ ] **Step 3: Verify**

```bash
cd /home/me/gh/machines
test -f hosts/homeserver/README.md && test -f agents/hosts/methe-server.md && echo "both present"
just quick   # sanity
```

- [ ] **Step 4: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "homeserver: reserve fleet slot (README + methe-server agent memory)"
```

---

### Task 6: Doc coherence — README.md and CLAUDE.md

**Files:**
- Modify: `README.md` (title, architecture tree)
- Modify: `AGENTS.md` (the project instructions behind the `CLAUDE.md` symlink — repository overview + host paths)

**Interfaces:**
- Consumes: the final layout from Tasks 1–5.
- Produces: docs match the tree. Terminal task.

- [ ] **Step 1: Retitle and re-tree `README.md`**

- Change the H1 from `# NixOS Configuration` to a fleet framing, e.g. `# machines — personal machine fleet`.
- Replace the intro ("Personal NixOS flake-based system configuration managing two laptops") with the three-machine fleet (g16 2024, homeserver/methe-server 2023, latitude5520) and note NixOS + Windows + the shared `install-media/`, `backup/`, `agents/`, `scripts/` subtrees.
- Update the `### Module Structure` fenced tree and the `### Host Configurations` paths to `hosts/<host>/nixos/…`.
- Add a one-line note: the `vps` repo is the sibling *service platform* (what the homeserver runs); `machines` owns machine provisioning + data backup.

- [ ] **Step 2: Update `AGENTS.md` (CLAUDE.md) repository overview + paths**

- Repository Overview: reframe from "two laptops" to the three-machine fleet incl. `homeserver` (`methe-server`); note the repo now also carries Windows install/reinstall, the fleet restic `backup/`, and shared `install-media/`.
- Any `hosts/*/configuration.nix` path → `hosts/*/nixos/configuration.nix`.
- Note the `machines` / `vps` boundary (provisioning + backup here; services there).

- [ ] **Step 3: Verify no doc still describes the old layout**

```bash
cd /home/me/gh/machines
git grep -nE 'hosts/(g16|latitude5520)/configuration.nix' README.md AGENTS.md ; echo "^ must be EMPTY"
git grep -n 'windows-reinstall' README.md AGENTS.md ; echo "^ must be EMPTY"
just quick
```

- [ ] **Step 4: Commit**

```bash
cd /home/me/gh/machines
git add -A
git commit -m "docs: reframe README + CLAUDE.md around the machine fleet + new layout"
```

---

## Final verification (whole plan)

- [ ] `just quick` passes.
- [ ] `nix flake check` evaluates all four outputs without path errors.
- [ ] Stale-reference sweep is empty:

```bash
cd /home/me/gh/machines
git grep -nE 'windows-reinstall|github.com/metheoryt/nix|GitHub\\nix' \
  | grep -vE 'R:\\windows-reinstall|\\\.\.\\windows-reinstall|docs/superpowers/(specs|plans)/'
echo "^ must be EMPTY (ignoring SSD artifact + historical spec/plan docs)"
git grep -nE '\.\./\.\./modules/' hosts/ ; echo "^ must be EMPTY"
git grep -n 'flake_dir}}/update-' justfile ; echo "^ must be EMPTY"
```

- [ ] Tree matches the spec: `hosts/{g16,latitude5520}/nixos/`, `hosts/g16/windows/`, `hosts/homeserver/README.md`, `install-media/{autounattend.xml,ventoy.json,README.md}`, `scripts/{update-*,quick-check}.sh`, `agents/hosts/methe-server.md`.
