# Machines: fleet-oriented layout — design

**Date:** 2026-07-05
**Status:** approved (design), pending implementation plan
**Scope:** two repos — `machines` (primary) and `vps` (backup subtree removal only)

## Problem

The repo was renamed `nix` → `machines` because it outgrew "a NixOS flake." It
now carries: two Linux laptops' NixOS config, g16's Windows reinstall/backup/
restore flow, a loose Windows `scripts/git-autofetch.ps1`, the OS-agnostic
`agents/` config tier, and `docs/`. But the top-level layout still *reads* as "a
NixOS flake with a Windows corner." The layout should reflect the real idea: a
**fleet of physical machines**, each provisioned and kept alive (provision →
back up → restore) by this repo, drawing on shared material.

## The fleet (ground truth)

| Host | Hardware | OSes / environments | Role |
|------|----------|---------------------|------|
| `g16` | ASUS ROG G16 **2024**, RTX 4060 | NixOS (`g16`) + Windows (`ME-G614JV`) + WSL | Daily driver |
| `homeserver` | ASUS ROG G16 **2023**, RTX 3050 Ti | Windows 11 + Docker Desktop (WSL2) | Service box (cyphy.kz) |
| `latitude5520` | Dell Latitude 5520, Tiger Lake | NixOS | Secondary laptop |

Two near-identical ASUS G16s a year apart; roles disambiguate them (`g16` =
2024 daily driver, `homeserver` = 2023 service box). No rename to the existing
`g16` host.

## Organizing idea

- **Top level** = the fleet of machines + the shared material they draw on.
- **Inside each machine** = config split by OS/environment.
- `flake.nix`, `modules/`, `pkgs/` stay at root — the Nix entrypoint and shared
  building blocks.
- `agents/` (cross-machine agent config), `backup/` (fleet-spanning restic
  system), `docs/` — cross-cutting subtrees, peers of one another.
- **`vps` stays a separate repo** — the *service platform* the fleet serves
  (edge VPS + Docker services). `machines` owns *how each box becomes itself and
  keeps its data*; `vps` owns *what the boxes run*.

## Target tree

```
machines/
  flake.nix                    modules/    pkgs/          # shared nix (root)
  agents/    docs/                                        # cross-cutting (unchanged)
  scripts/                                                # shared repo tooling
    update-pycharm.sh  update-rustdesk.sh  update-zed.sh  quick-check.sh
  backup/                                                 # fleet restic system (moved from vps)
    base.yaml   restic-install.bat   restic-install.sh
    homeserver/   # immich-* profiles (g16-2023)
    g16/          # music profile      (was laptop/)
    g16-wsl/      # /home/me profile   (was wsl/)
  install-media/                                          # shared Win11 install media (all win11 machines)
    autounattend.xml   # generic answer file (git mv'd from hosts/g16/windows-reinstall/)
    ventoy.json        # Ventoy Auto Install plugin config (newly tracked; was runbook prose)
    README.md          # deploy -> P:\unattend\ + P:\ventoy\; ISOs / RST drivers not tracked
  hosts/
    g16/
      nixos/      configuration.nix   hardware-configuration.nix
      windows/    backup.ps1  restore.ps1  install.ps1
                  windows-reinstall-runbook.md   git-autofetch.ps1
    latitude5520/
      nixos/      configuration.nix   hardware-configuration.nix
    homeserver/
      README.md                                          # fleet peer; runs -> vps repo
  agents/hosts/methe-server.md                           # per-host agent memory (new)
```

## Change set

### 1. Moves (within `machines`)

- `hosts/g16/{configuration,hardware-configuration}.nix` → `hosts/g16/nixos/`
- `hosts/latitude5520/{configuration,hardware-configuration}.nix` → `hosts/latitude5520/nixos/`
- `hosts/g16/windows-reinstall/` → `hosts/g16/windows/`
  (backup.ps1, restore.ps1, install.ps1, windows-reinstall-runbook.md — **not**
  autounattend.xml, which promotes to shared `install-media/`; see §2b)
- `scripts/git-autofetch.ps1` → `hosts/g16/windows/` (g16-Windows-only; belongs with its machine)
- `update-{pycharm,rustdesk,zed}.sh` + `quick-check.sh` → `scripts/`
  (`scripts/` is vacated by `git-autofetch.ps1` moving out; becomes "shared repo tooling")

### 2. Backup system move (cross-repo: `vps` → `machines`)

- Move the entire `vps/backup/` subtree to `machines/backup/`, preserving its
  internal structure and `base.yaml` inheritance. Rationale: a backup profile is
  a *data-protection definition* (a restic client/schedule), not a service
  definition. The Immich **service** (`compose.yml`) and the restic **REST
  server** (`homeserver/restic-server/`) stay in `vps`; the backup **clients**
  come to `machines`. `machines` and `vps` communicate over the network
  (`rest:http://server.lan:8001/…`), not the filesystem.
- **Rename config subdirs to fleet names**, config-location only:
  - `laptop/` → `g16/`
  - `wsl/` → `g16-wsl/`
  - `homeserver/` stays.
- **Invariant — do NOT change** the restic **repository URLs/paths**
  (`G:\backup-homeserver\…`, `rest:http://server.lan:8001/laptop-music`,
  `rest:http://server.lan:8001/wsl`) **or the profile names** inside
  `profiles.yaml`. Those name stateful backends and scheduled tasks; changing
  them orphans existing snapshots/schedules. Only the containing directory name
  changes. (A dir named `g16/` whose profile still targets `…/laptop-music` is
  expected and fine — the URL is a backend id, not a label.)
- Carry the gitignore rules protecting backup secrets into `machines/.gitignore`:
  `**/pass.txt`, `**/.env` (verify not already covered).
- `install-tasks.{bat,sh}` and `base.yaml` use only self-relative paths
  (`%~dp0`, `dirname "$0"`, `pass.txt`, `{{ .Profile.Name }}`) — they relocate
  without edits beyond the dir rename.
- **In `vps`:** delete `vps/backup/`; move its README/CLAUDE.md "Backups"
  section out (replace with a one-line pointer: "backup clients live in the
  `machines` repo; this repo runs the restic REST server as a service").

### 2b. Shared Win11 install media (`install-media/`)

The `autounattend.xml` currently at `hosts/g16/windows-reinstall/` is a
**generic** Win11 answer file (schneegans-generated: interactive computer-name
via `Read-Host`, `TEMPNAME` placeholder, no `<DiskConfiguration>`, TPM/SecureBoot
bypass + debloat). Nothing g16-specific — it applies to **every** Win11 machine
in the fleet (g16 daily driver **and** homeserver). It's mis-filed under a host.
Promote it to a shared top-level `install-media/`, alongside the Ventoy config
that currently exists only as prose in the runbook.

- **`git mv`** `hosts/g16/windows-reinstall/autounattend.xml` →
  `install-media/autounattend.xml`. **Do NOT `cp` the `~/Downloads/autounattend.xml`
  copy over it** — a normalized diff proves they are the same 803-line file (same
  embedded schneegans commit hash); the Downloads copy differs only in line
  endings (CRLF↔LF). Copying it in would flip every line, produce a spurious
  whole-file diff, and discard git history for a zero-content change. The content
  is already tracked; the only genuine gap this request exposes is the untracked
  `ventoy.json`.
- **New `install-media/ventoy.json`** — extract the Auto Install plugin config
  the runbook documents verbatim:
  ```json
  { "auto_install": [ { "image": "/Win11_25H2_Russian_x64_v2.iso", "template": "/unattend/autounattend.xml" } ] }
  ```
- **New `install-media/README.md`** — the Ventoy USB deploy story: repo is source
  of truth; copy `autounattend.xml` → `P:\unattend\autounattend.xml` and
  `ventoy.json` → `P:\ventoy\ventoy.json`; ISOs and `P:\rsti\` Intel RST/VMD
  drivers are recreatable and **not** tracked. Applies to all Win11 machines.
- **Runbook (now `hosts/g16/windows/windows-reinstall-runbook.md`)**: repoint its
  `./autounattend.xml` link and the Ventoy prose to the shared
  `install-media/` location; note `ventoy.json` is now a tracked file (deploy by
  copy, no longer transcribed from prose).

Flat by intent (YAGNI): homeserver Win11 reinstall is deferred, so there is one
real consumer (g16's runbook) today — enough to justify a shared location, not a
nested tree mirroring the USB's `P:\ventoy\` / `P:\unattend\` paths.

### 3. Wiring the moves force (mechanical; grep-verified before applying)

- `flake.nix`: `./hosts/${hostname}/configuration.nix` → `.../nixos/configuration.nix`
  (and `hardware-configuration.nix`).
- Both `configuration.nix`: module imports `../../modules/…` → `../../../modules/…`
  (one level deeper).
- `justfile`: `{{flake_dir}}/update-*.sh` → `{{flake_dir}}/scripts/update-*.sh`;
  the `hosts/g16/windows-reinstall` reference in the line-48 error string →
  `hosts/g16/windows`.
- `install.ps1`: two hardcoded `hosts\g16\windows-reinstall\…` paths (incl. the
  raw-githubusercontent URL) → `hosts\g16\windows\…`.
- `AGENTS.md`: `bash quick-check.sh` mention → `bash scripts/quick-check.sh`.

### 4. Staleness fixes (rename leftovers)

While editing the moved Windows files, fix old-repo-name references left by the
`nix` → `machines` rename:

- Runbook + `backup.ps1` doc-comments: `GitHub\nix` → `GitHub\machines`,
  `github.com/metheoryt/nix` → `github.com/metheoryt/machines`, and
  `windows-reinstall/` path refs → `windows/`.
- `justfile:48`: fix only the stale path text in the error string
  (`hosts/g16/windows-reinstall runbook` → `hosts/g16/windows runbook`).
  **Leave `~/nix` untouched** — that symlink name is what home-manager reads
  (`~/nix/agents`) and is independent of the repo's folder name; it is not a
  rename leftover.

### 5. New — reserve the homeserver's fleet slot

- `hosts/homeserver/README.md`: documents it as a fleet peer — ASUS ROG G16
  2023 / RTX 3050 Ti, Win11 + Docker Desktop, `methe` profile; its backup lives
  at `backup/homeserver/`; **what it runs is defined in the `vps` repo**; its OS
  reinstall runbook is not yet written (deferred — adapt from g16's).
- `agents/hosts/methe-server.md`: per-host agent memory (Windows hostname
  `methe-server`), matching the existing `ME-G614JV.md` / `g16.md` /
  `latitude5520.md` pattern.

### 6. Doc coherence

- `README.md`: retitle from "NixOS Configuration" to the fleet framing; replace
  the module-structure tree with the new layout; note `vps` as the sibling
  platform repo.
- `CLAUDE.md`: update the architecture section's host paths
  (`hosts/*/configuration.nix` → `hosts/*/nixos/configuration.nix`) and the
  repository-overview framing (fleet, three machines incl. homeserver, backup
  system, `vps` boundary).

## Explicitly out of scope

- **WSL bootstrap** — reproducible provisioning of the g16 WSL instance on a
  fresh distro (beyond the `g16-wsl` restic data backup). A distinct new
  capability; its own brainstorm → spec. Future home: `hosts/g16/wsl/`. When
  built, the `g16-wsl` backup profile may migrate beside it. Not touched here.
- Renaming `vps` (e.g. to `homelab`/`cyphy`) — separate move.
- Writing the homeserver's OS reinstall runbook — future; `hosts/homeserver/`
  reserves its place.
- Any `vps` change beyond removing `backup/` and its docs.

## Verification

- `just quick` (syntax) and `nix flake check` pass after the moves.
- Grep sweep confirms zero stale references remain: `windows-reinstall`,
  `GitHub\nix`, `github.com/metheoryt/nix`, root-relative `update-*.sh` /
  `quick-check.sh` paths.
- `git grep` in `machines/backup/` confirms restic repository URLs and profile
  names are byte-for-byte unchanged from the `vps` originals (only dir names
  differ).
- `install-media/autounattend.xml` arrives via `git mv` (history preserved,
  content byte-identical) — the diff for that file is a pure rename with no
  content hunk. `ventoy.json` is valid JSON matching the runbook's block.
- The `.ps1` / `.bat` files are not executed here (no Windows host); correctness
  is by inspection + path consistency.

## Implementation (two plans / PRs)

The change spans two risk profiles; split them so the risky one is isolated:

- **Plan A — `machines`-internal reorg** (low-risk, mechanical): host `nixos/`
  split, `windows/` rename, `scripts/` tidy, `install-media/` promotion +
  `ventoy.json`, staleness fixes, homeserver slot, doc coherence. All moves +
  path rewiring within one repo; verified by `just quick` / `nix flake check`.
- **Plan B — cross-repo backup relocation** (stateful, higher-risk): move
  `vps/backup/` → `machines/backup/` with the frozen-repo-URL invariant; edit
  `vps` docs. Isolated so a mistake here can't entangle the clean reorg, and the
  restic-URL check gates it alone.

## Decisions log

1. Organizing axis: **by machine (fleet)**; `flake.nix`/`modules`/`pkgs` at root.
2. Per-host OS split: `hosts/<host>/nixos/`; `hosts/g16/windows/`.
3. `git-autofetch.ps1` → `hosts/g16/windows/`.
4. Tidy `scripts/`: update-scripts + quick-check moved in.
5. Fix `nix` → `machines` staleness in moved Windows files + `justfile`.
6. `vps` stays separate (platform); backup subtree relocates out of it.
7. Backup → `machines`, **top-level `machines/backup/`**, machine-named subdirs;
   shared `base.yaml` + `restic-install` kept; repo URLs + profile names
   unchanged; restic-server *service* stays in `vps`.
8. Homeserver host: reserve slot (`README.md` + `agents/hosts/<hostname>.md`).
9. WSL bootstrap: out of scope; follow-on spec; `hosts/g16/wsl/`.
10. Doc coherence: `README.md` + `CLAUDE.md` (+ `vps` docs) updated.
11. Win11 install media: shared top-level `install-media/`; `autounattend.xml`
    `git mv`'d there (content already tracked — the Downloads copy is the same
    file); `ventoy.json` newly tracked (was runbook prose). Flat, not nested.
12. Execution split into two plans/PRs: (A) `machines`-internal reorg,
    (B) cross-repo stateful backup relocation.
