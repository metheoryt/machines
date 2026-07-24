# machines — personal machine fleet

Config, provisioning, and data-backup for a small fleet of physical machines —
NixOS *and* Windows. The NixOS hosts are a flake (Home Manager integrated); the
Windows hosts carry their reinstall/backup scripts and shared install media.

- **desktop** (`g614jv` WSL / `ME-G614JV` native) — ASUS ROG G16 2024, RTX 4060;
  **Windows-only**. Its former NixOS install `g16` was retired 2026-07-08.
- **homeserver** — ASUS ROG **G15** 2023 (model **G513IE**), RTX 3050 Ti.
  Windows 11 + Docker Desktop, logical name `server`, OS hostname `g513ie`
  (renamed from `methe-server` 2026-07-20 — the model code; see the
  hostname-normalization spec). Runs the cyphy.kz service platform (defined in the
  sibling **`vps`** repo — that repo owns the *services*; `machines` owns the
  *machine* + its data backups).
- **latitude5520** — Dell Latitude 5520, Intel Tiger Lake (integrated only).
  NixOS.

Top-level layout: `hosts/<host>/{nixos,windows}/` (per-machine OS config),
`modules/` (shared NixOS modules), `install-media/` (shared Win11 answer file +
Ventoy config), `backup/` (fleet restic clients), `scripts/` (shared repo
tooling), `agents/` (agent config, memory, bootstrap).

## Onboarding — start here

| Box kind | One command |
|---|---|
| **NixOS** — latitude5520 | `just switch` |
| **Windows** — ME-G614JV, g513ie | `provision\windows.ps1` (`-Work` adds the work profile) |
| **WSL / any glibc Linux** — persisted or throwaway | `bash provision/linux.sh` |

All three link your synced agent config for you (via `agents/bootstrap.sh`); to
re-link only that, run `bash agents/bootstrap.sh` (or `just agent-bootstrap`; on
NixOS `just switch`). To clone your repos into the `~/my` · `~/pure` ·
`~/cyphy671` layout, run `bash provision/repos.sh <groups>` (e.g. `my cyphy671`
on a personal box, `pure` on a work box).

For a Linux dev environment on Windows, `provision/linux.sh` provisions a
persisted or disposable Debian/Ubuntu WSL box with the portable layer (synced
agent config + CLI tools) — a peer of `install-media/`.

## Quick Start

```bash
# Validate syntax without building
just quick

# Build and switch to new configuration
just switch

# Safe path when updating NVIDIA drivers (reboots into new config)
just upgrade
```

## Common Commands

| Command | Description |
|---|---|
| `just quick` | Fast syntax validation (no build) |
| `just check` | Full `nix flake check` evaluation |
| `just fmt` | Format all `.nix` files with alejandra |
| `just build` | Build without activating |
| `just switch` | Build and activate immediately |
| `just test` | Temporary test (reverts on next boot) |
| `just boot` | Set for next boot without switching |
| `just upgrade` | Update inputs + set for next boot (safe for NVIDIA) |
| `just upgrade-now` | Update inputs + switch immediately |
| `just update` | Update flake inputs only |
| `just clean` | Remove generations older than 7 days |
| `just cleanup` | Remove all old generations (interactive) |
| `just status` | Show system info (hostname, kernel, uptime, memory, disk, battery) |
| `just hardware` | Show hardware details (CPU, GPU, storage) |
| `just generations` | List system and Home Manager generations |
| `just rollback` | Interactive rollback to previous generation |
| `just diff` | Show recent system changes |
| `just shell` | Enter dev shell with Nix tooling |
| `just search <pkg>` | Search nixpkgs |
| `just run <pkg>` | Run a package temporarily |
| `just health` | Check store, services, disk |

## Architecture

### Flake Inputs

| Input | Channel | Purpose |
|---|---|---|
| `nixpkgs` | unstable | Primary package set |
| `nixpkgs-stable` | 25.05 | Pinned packages via `pkgs.stable.*` |
| `home-manager` | unstable | User-level config |
| `nixos-hardware` | latest | Hardware-specific modules |
| `claude-code-nix` | latest | Claude Code package |

### Module Structure

```
modules/
├── system/
│   ├── base.nix          # Boot, Nix daemon, networking, ZRAM, core packages
│   └── laptop.nix        # Power profiles, thermald, touchpad, backlight, S3 sleep
├── desktop/
│   └── gnome.nix         # GDM + GNOME (Wayland), PipeWire, fonts, XDG portals
├── hardware/
│   ├── asus-rog.nix      # Battery charge threshold, ROG keyboard fixes, DPCD backlight
│   └── dell-latitude.nix # Battery charge threshold, Thunderbolt, Intel GPU
├── home/
│   └── me.nix            # Home Manager: packages, git, Fish, Starship, Ghostty, GNOME dconf
├── nvidia.nix            # NVIDIA open modules, PRIME offload, fine-grained power, Wayland vars
└── programs/
    └── development.nix   # Dev tools, Docker, Python 3.13, nix-ld, direnv
```

### Host Configurations

**`hosts/desktop/windows/`** — ROG G16 2024 (Windows-only); NixOS `g16` retired.

**`hosts/latitude5520/nixos/`** — Dell Latitude 5520
- Intel Tiger Lake with `intel-compute-runtime` (replaces `intel-ocl`)
- Imports: `base`, `laptop`, `gnome`, `dell-latitude`, `development`, home-manager
- Thunderbolt authorization via `bolt` service
- Battery charge limit: 85% via `charge-upto <percent>`

**`provision/`** — persisted or disposable non-Nix distro (Linux dev environment on Windows), a peer of `install-media/`
- `provision/linux.sh` provisions a fresh Debian/Ubuntu box (or persisted/throwaway WSL2 distro)
  with the *portable* layer only: the git-synced Claude/Codex config (via
  `agents/bootstrap.sh`) + core CLI tools (gortex, claude, codex, gh, ripgrep/fd/fzf, …).
- Imperative and apt-based — no NixOS. See `provision/README.md` for usage and
  base-distro guidance.

### Home Manager (`modules/home/me.nix`)

User `me` (Maxim Romanyuk) configuration:
- **Shell:** Fish with aliases, NixOS rebuild shortcuts (`nrs`, `nrt`, `nrb`), fastfetch on login
- **Terminal:** Ghostty (Dracula dark / GitHub Light), JetBrainsMono Nerd Font 10pt
- **Prompt:** Starship with git status, nix-shell indicator
- **Git:** rebase pulls, diff3 merges, common aliases
- **GNOME:** dconf settings — battery %, Alt+F4 close, Ctrl+Alt+T → Ghostty, power policy
- **Key packages:** google-chrome, telegram-desktop, ghostty, vlc, gimp, libreoffice, zed-editor, pycharm, claude-code, rustdesk

## Hardware Notes

### Battery Charge Limiting

Both hosts cap battery charging at 85% by default:

```bash
# Change the charge limit (takes effect immediately + persists across reboots)
charge-upto 80
charge-upto 100   # disable limit
```

## Development Shell

```bash
just shell
# Includes: nixfmt, nil, nixd, alejandra, git, just, direnv, wget, curl, jq, yq
```

## Locale & Timezone

- Timezone: `Asia/Almaty`
- Locale: `ru_RU.UTF-8`
- State version: 25.05

## Worktree dispatchers

`worktree-setup.sh` / `worktree-teardown.sh` (fleet root) are tool-agnostic hooks
for the git-worktree lifecycle. Run with CWD = the worktree, no arguments.

- **Orca IDE:** point the *Create worktree* hook at
  `~/machines/agents/worktree-setup.sh` and the *Delete worktree* hook at
  `~/machines/agents/worktree-teardown.sh` (absolute paths; the fleet repo path is
  stable across machines).
- **Manual:** run either from inside a worktree.

**What they do.** Setup: gortex-`track`s the worktree (`--as-worktree`) *first*, then
runs the repo's own setup script. Teardown: runs the repo's own teardown script
*first*, then `gortex untrack`s the worktree and reconciles (prunes any tracked
`~/.config/gortex/config.yaml` path missing on disk — catches worktrees removed
outside the IDE).

**gortex coupling is guarded and personal.** Every gortex action is gated on
`gortex daemon status`; with the daemon down or gortex absent the gortex step is a
silent no-op, so committed work repos and non-gortex teammates are unaffected.
gortex is `track`ed only when the *main* checkout is already covered by the daemon.

**Repo-local script candidates** (first executable match wins, then stop):
`.orca/` → `docker/` → `.worktree/` → `scripts/`, basename
`worktree-setup.sh`/`setup.sh` (or `-teardown.sh`/`teardown.sh`). backend-api ships
`docker/worktree-setup.sh` + `docker/worktree-teardown.sh`; they carry no gortex
references.

**Caveat:** reconcile prunes *any* tracked path gone from disk, including a
temporarily-unmounted drive — re-track it on return.
