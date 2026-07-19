# Fleet hostname normalization: model-based OS names + logical repo dirs

**Date:** 2026-07-19
**Status:** approved (design)

## Problem

Fleet host naming is inconsistent *in meaning* across three layers, and one
host is now mislabelled after g16's NixOS install was retired.

Three naming layers exist:

- **Logical name** — the fleet key in `fleet.json`, also the SSH alias
  (`modules/home/ssh.nix`), the Tailscale/Headscale node name, and (ideally) the
  repo host-dir. Role/function-based: `latitude`, `desktop`, `server`, `hub`.
- **Model / physical name** — the box's OS hostname, matched by
  `detect.hostname` in `fleet.json` (`fleet_detect()` compares it against
  `hostname` on Linux and `$env:COMPUTERNAME` on Windows).
- **Repo host-dir** — `hosts/<dir>/`.

Current state and what's wrong with it:

| logical | OS hostname (`detect.hostname`) | repo dir | model-based? | dir = fleet key? |
|---|---|---|---|---|
| `latitude` | `latitude5520` (Dell Latitude 5520) | `hosts/latitude` | yes ✓ | yes ✓ |
| `desktop` | `g614jv` (ROG Strix G614JV) | `hosts/g16` | yes ✓ | **no** ✗ |
| `server` | `methe-server` (role/owner name) | `hosts/homeserver` | **no** ✗ | **no** ✗ |
| `hub` | `27608` (VPS instance id) | — (lives in `vps` repo) | n/a (not a laptop) | n/a |

- The OS-hostname layer mixes conventions: `latitude5520`/`g614jv` are hardware
  models, but `methe-server` is a role/owner name.
- The repo-dir layer mixes conventions: `hosts/latitude` matches its fleet key,
  but `hosts/g16` (a nickname) and `hosts/homeserver` (a role) do not.
- `g16`'s NixOS install is gone — it is Windows-only now (the `desktop` box,
  model G614JV). Docs still describe it as a NixOS host.

Note: the Tailscale/Headscale node names are **already** normalized to the
logical names (`server.gg.ez`, `desktop.gg.ez`, `latitude.gg.ez`, `hub.gg.ez`),
and Headscale enforces node-name uniqueness — so "only one host can be named
`server`" is already guaranteed at the network layer. No SSH/tailnet change is
needed. There is also **no `detect.hostname` drift**: live checks confirm the
real OS hostnames are exactly what `fleet.json` records (`methe-server`,
`27608`, `g614jv`, `latitude5520`).

## Decision

Commit to a clean **two-layer convention**, applied uniformly:

- **Logical layer** (stable, role-based): fleet key = SSH alias = tailnet node =
  **repo host-dir**. `latitude`, `desktop`, `server`, `hub`. Unchanged as
  values; repo dirs are brought into line.
- **Physical layer** (hardware fact): OS hostname = `detect.hostname` = the
  machine's **hardware model**, lowercased. `latitude5520`, `g614jv`, `g513ie`,
  `27608`.

Rationale: the logical name is stable across hardware swaps (swapping the
server's laptop shouldn't touch `hosts/server` or the SSH alias); the model name
is the honest physical identity and is the only thing that must equal the box's
real OS hostname for `fleet_detect` to work. `latitude` already embodies this
split; we extend it to the rest.

Target end-state:

| logical (fleet key · ssh · tailnet · repo dir) | model (OS hostname = `detect.hostname`) |
|---|---|
| `latitude` | `latitude5520` |
| `desktop` | `g614jv` |
| `server` | **`g513ie`** (was `methe-server`) |
| `hub` | `27608` |

**Hub stays `27608`** — it is a Debian VPS, not a laptop; `27608` is the
provider's real instance identity, and its services/backups live in the sibling
`vps` repo. Out of scope here.

## Components / change set

### Core — hostname + memory + docs (required)

1. **`fleet.json`** — `server.detect.hostname`: `methe-server` → `g513ie`.
   (latitude/desktop/hub unchanged.)
2. **`agents/hosts/methe-server.md` → `agents/hosts/g513ie.md`** — per-host
   memory is symlinked by `bootstrap.sh` as `hosts/<hostname>.md`; the file must
   follow the new hostname. Update its self-referential prose.
3. **Delete stale `agents/hosts/ME-G614JV.md`** — the desktop box's current
   hostname is `g614jv` (live file `g614jv.md`); `ME-G614JV.md` is the retired
   old Windows-install name and is dead.
4. **Live docs** describing hostnames/hardware — reconcile to the convention and
   the real models (`server` = ROG Strix **G513IE**, RTX 3050 Ti; `desktop`/g16
   = ROG Strix **G614JV**), and stop calling g16 a NixOS host (it is
   Windows-only `desktop` now):
   - project `CLAUDE.md` (repo overview table + hardware context)
   - `README.md`, `AGENTS.md`
   - `hosts/*/README.md`
   - `.claude/memory/project.md`
   - `docs/fleet-roadmap.md`
5. **Provision scripts** referencing `methe-server` → `g513ie`
   (`provision/lib/Fleet.psm1` is data-driven off `fleet.json`, but grep
   `provision/` for literal `methe-server` and fix any). Leave `27608`
   references (still correct).

### Structural — repo host-dir renames (approved)

6. **`git mv hosts/g16 hosts/desktop`** and **`git mv hosts/homeserver
   hosts/server`** — repo dir = fleet key for every host.
7. Rewrite path references to the renamed dirs, notably the **public bootstrap
   entrypoint**: the hardcoded `raw.githubusercontent.com/.../hosts/g16/windows/install.ps1`
   URL inside `hosts/g16/windows/install.ps1` itself, plus all
   `hosts/g16/windows/` path references in the reinstall runbook,
   `install-media/README.md`, `AGENTS.md`, `README.md`, `justfile`, and memory.
   `flake.nix` refers only to `hosts/latitude` (unaffected).

### Out of scope / left as history

- `docs/superpowers/plans/**` and `docs/superpowers/specs/**` — dated historical
  records; not rewritten.
- Logical name `latitude` is itself model-derived (a mild inconsistency in the
  logical layer), but renaming it is high-churn (ssh alias, tailnet node, fleet
  key, dir) for no functional gain and was not requested. Left as-is.
- The `hub`/`27608` VPS and its `vps`-repo backups.

## Operational runbook (off-repo, user-executed)

The repo change to `detect.hostname` is inert until the box itself is renamed —
`detect.hostname` must equal the real `$env:COMPUTERNAME`.

On the `server` box (Windows), elevated PowerShell:

```powershell
Rename-Computer -NewName g513ie -Restart
```

- SSH and Tailscale are unaffected — both address the box by its tailnet node
  name `server`, not by COMPUTERNAME.
- Between merging the repo change and rebooting the box, `fleet_detect` on that
  box will not match (`methe-server` ≠ `g513ie`); this is expected and
  self-heals on reboot. Sequence the merge and the reboot close together.
- Watch for local churn a Windows rename can trigger: Docker Desktop re-auth,
  and restic snapshot host identity (snapshots are `--host`-tagged; wherever the
  homeserver's backup client runs, new snapshots land under `g513ie` — verify
  retention/prune still matches). No `backup/` config exists in this repo, so
  this is operational, not a repo change.

## Verification

1. `just quick` / `nix flake check` still pass (flake refs only
   `hosts/latitude`, so dir renames don't touch it — confirm).
2. `grep -rn 'methe-server' .` (excluding `docs/superpowers/`) returns nothing.
3. `grep -rn 'hosts/g16\|hosts/homeserver' .` (excluding `docs/superpowers/`)
   returns nothing.
4. `agents/hosts/` contains `g513ie.md`, `g614jv.md`, `latitude5520.md` and no
   `methe-server.md` / `ME-G614JV.md`.
5. After the box reboot: on `server`, `fleet_detect` (via the provision entry)
   resolves to `server`; `ssh server hostname` prints `g513ie`.

## Data flow (unchanged mechanics)

`fleet.json` (single source of truth) → `modules/system/fleet.nix` →
`modules/home/ssh.nix` (SSH aliases from fleet keys; unaffected — keys don't
change) and `provision/lib/{fleet.sh,Fleet.psm1}` (`fleet_detect` matches
`detect.hostname` against the live OS hostname). Only the `server` record's
`detect.hostname` value and the two repo-dir names change.
