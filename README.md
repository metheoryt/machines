# NixOS Configuration

Personal NixOS flake-based system configuration managing two laptops:

- **g16** — ASUS ROG G16, Intel + NVIDIA RTX 40-series (PRIME offload)
- **latitude5520** — Dell Latitude 5520, Intel Tiger Lake (integrated only)

For a Linux dev environment on Windows, `bootstrap/` provisions a disposable
Debian/Ubuntu WSL box with the portable layer (synced agent config + CLI tools).

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

**`hosts/g16/`** — ASUS ROG G16
- NVIDIA RTX 40-series via PRIME offload (Intel primary, NVIDIA on-demand)
- Imports: `base`, `laptop`, `gnome`, `nvidia`, `asus-rog`, `development`, home-manager
- ASUS services: `asusd`, `supergfxd`
- Battery charge limit: 85% via `charge-upto <percent>`

**`hosts/latitude5520/`** — Dell Latitude 5520
- Intel Tiger Lake with `intel-compute-runtime` (replaces `intel-ocl`)
- Imports: `base`, `laptop`, `gnome`, `dell-latitude`, `development`, home-manager
- Thunderbolt authorization via `bolt` service
- Battery charge limit: 85% via `charge-upto <percent>`

**`bootstrap/`** — disposable non-Nix distro (Linux dev environment on Windows)
- `bootstrap/ubuntu.sh` provisions a fresh Debian/Ubuntu box (or throwaway WSL2 distro)
  with the *portable* layer only: the git-synced Claude/Codex config (via
  `agents/bootstrap.sh`) + core CLI tools (gortex, claude, codex, gh, ripgrep/fd/fzf, …).
- Imperative and apt-based — no NixOS. See `bootstrap/README.md` for usage and
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

### g16 NVIDIA PRIME

Intel (primary) + NVIDIA (on-demand via `nvidia-offload`):

```bash
# Run a program on the NVIDIA GPU
nvidia-offload <command>
```

Bus IDs: Intel `PCI:00:02:0`, NVIDIA `PCI:01:00:0` — verify with `lspci | grep -E "VGA|3D"` if offload breaks.

NVIDIA driver changes can cause `nixos-rebuild switch` to fail mid-session. Use `just upgrade` (sets next boot, then reboot) instead of `just upgrade-now`.

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
# Includes: nixfmt-classic, nil, nixd, alejandra, git, just, direnv, wget, curl, jq, yq
```

## Locale & Timezone

- Timezone: `Asia/Almaty`
- Locale: `ru_RU.UTF-8`
- State version: 25.05
