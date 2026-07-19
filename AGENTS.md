# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Repository Overview

Config, provisioning, and data-backup for a small machine fleet — NixOS *and*
Windows:

- **g614jv / ME-G614JV** — ASUS ROG G16 2024, RTX 4060; **Windows-only** (WSL
  hostname `g614jv`, native `ME-G614JV`). Its former NixOS install `g16` was
  retired 2026-07-08; `hosts/desktop/` now holds only `windows/`.
- **homeserver** — ASUS ROG **G15** 2023 (model **G513IE**), RTX 3050 Ti,
  Windows 11 + Docker Desktop; logical name `server`, OS hostname
  `methe-server` (**being renamed to `g513ie`** — the model code; see the
  hostname-normalization spec). Runs the cyphy.kz service platform
- **latitude5520** — Dell Latitude 5520, Intel Tiger Lake, NixOS hostname `latitude5520`
- **hub** — Debian VPS at `cyphy.kz` (tailnet `100.64.0.1`), a first-class
  `fleet.json` member (roles `base, ssh-server, agents, dotfiles,
  backup-client`); runs the Headscale control server + the AmneziaWG VPN hub.
  Services live in the sibling `vps` repo.

The NixOS hosts use Home Manager (system-level integration) and share a common
module set with host-specific overrides. The repo also carries the Windows
install/reinstall + backup scripts (`hosts/desktop/windows/`) and shared Win11
install media (`install-media/`).

**`machines` / `vps` boundary:** `machines` owns the *machines* — NixOS +
Windows provisioning and data backup. The sibling **`vps`** repo owns the
*services* the homeserver runs (Immich, Navidrome, Forgejo, the cyphy.kz
platform). Machine here, services there.

## Common Commands

All commands run from repo root. System-modifying commands require `sudo` (via `nixos-rebuild`).

```bash
# Validate syntax quickly (no build)
just quick
# or: bash scripts/quick-check.sh

# Full flake evaluation check
just check
# or: nix flake check

# Format all Nix files (alejandra)
just fmt

# Build without activating
just build

# Build and activate immediately
just switch

# Safe upgrade path for NVIDIA: update inputs + set for next boot, then reboot
just upgrade

# Update flake inputs only
just update

# Temporarily test a configuration (reverts on next boot)
just test

# Enter development shell with Nix tooling
just shell

# Clean old generations (>7 days)
just clean
```

## Architecture

### Flake structure (`flake.nix`)

- **Inputs:** nixpkgs (unstable), nixpkgs-stable (25.05), home-manager, nixos-hardware, claude-code-nix
- **Stable overlay:** `pkgs.stable.*` available everywhere — use to pin critical packages (drivers, kernel) to stable while rest runs unstable
- **`specialArgs`** passes `inputs`, `system`, `nixpkgs-stable` into all modules
- **Formatter:** alejandra
- **Dev shell:** nixfmt, nil, nixd, alejandra, git, just, direnv, wget, curl, jq, yq

### Module structure (`modules/`)

Each module is self-contained (options + config + services). Modules don't import each other — `configuration.nix` imports them all.

| Module | Responsibility |
|---|---|
| `system/base.nix` | systemd-boot, Nix daemon, flakes, binary caches, networking, ZRAM swap, weekly GC, core packages, Fish shell |
| `system/laptop.nix` | power-profiles-daemon, thermald, touchpad (libinput), backlight (acpilight/actkbd), lid/power-button behavior, S3 deep sleep, Intel microcode |
| `system/fleet.nix` | fleet.json data / ssh.nix source of truth |
| `system/ssh-server.nix` | keys-only sshd over the tailnet — the fleet SSH-server role |
| `system/self-update.nix` | self-update mechanism |
| `system/git-autofetch/` | auto-fetch timer |
| `desktop/gnome.nix` | GDM + GNOME (Wayland), PipeWire audio, XDG portals, fonts (JetBrainsMono Nerd Font, Noto, Fira Code), excluded GNOME apps |
| `hardware/asus-rog.nix` | **orphaned** — `charge-upto` command + systemd service, ROG keyboard evdev fixes (mic mute, Fn+arrows), DPCD backlight kernel params; no host imports it since NixOS g16 was removed |
| `hardware/dell-latitude.nix` | `charge-upto` command + systemd service, Intel compute runtime, Thunderbolt (bolt service), fstrim |
| `nvidia.nix` | **orphaned** — NVIDIA open kernel modules, PRIME offload mode (Intel primary, NVIDIA on-demand), fine-grained power mgmt, Wayland env vars, Vulkan/OpenCL, nvidia-container-toolkit; no host imports it since NixOS g16 was removed |
| `programs/development.nix` | nix-ld, Docker (auto-start + auto-prune), Python 3.13 + uv, dev tools (git, gh, jq, ripgrep, ast-grep, fd, bat, etc.), direnv + nix-direnv, Fish + Zsh |
| `home/me.nix` | Home Manager for user `me`: packages, git config, Fish aliases/functions, Starship prompt, Ghostty config, GNOME dconf settings, fastfetch |
| `home/ssh.nix` | SSH client config generated from fleet.json |
| `home/claude.nix` | Claude Code profile bootstrap wiring |
| `home/orca-bin.nix` | Orca IDE AppImage wrapper |
| `home/pycharm-bin.nix` | PyCharm AppImage wrapper |
| `home/zed-bin.nix` | Zed AppImage wrapper |
| `home/rustdesk-bin.nix` | RustDesk client wrapper |
| `home/rustdesk-config.nix` | RustDesk server key + known-peer IDs |

### Fleet networking / tailnet architecture

The fleet transport is a self-hosted **Headscale tailnet** (`cc.cyphy.kz`,
MagicDNS suffix `gg.ez`, CGNAT `100.64.0.0/10`); `fleet.json` (repo root) is
the machine manifest, and the `ssh-server` role (`modules/system/ssh-server.nix`
+ `windows.ps1` step 7) generates every host's keys-only-sshd-over-tailnet
story. The old AmneziaWG mesh was retired from the repo 2026-07-17 (AmneziaWG
survives only as the VPS's obfuscated VPN for RU relatives).

### Host configurations

Currently a single NixOS host:

**`hosts/latitude/nixos/configuration.nix`** (flake attr `latitude`;
`networking.hostName` stays `latitude5520` — only the repo label/flake attr
changed)
- Imports: base, laptop, self-update, git-autofetch, ssh-server, gnome, dell-latitude, development, home-manager
- Hostname: `latitude5520`, timezone Asia/Almaty, locale ru_RU.UTF-8
- Overrides intel-ocl with intel-compute-runtime; adds intel-media-driver, intel-vaapi-driver
- Thunderbolt: bolt service enabled

**`hosts/*/nixos/hardware-configuration.nix`** — auto-generated by `nixos-generate-config`, do not edit.

The Windows hosts (`g614jv`/`ME-G614JV`, `homeserver`) carry no NixOS
configuration — they carry install/reinstall + backup scripts under
`hosts/<name>/windows/`.

### Home Manager integration

Runs at system level (`nixosModules.default`) with `useGlobalPkgs = true` and `useUserPackages = true`. User packages share the system nixpkgs — do not add a separate `nixpkgs` input in home-manager configs.

### Key patterns

- **Module composition:** Add new functionality by creating a module and adding it to the host's `imports` list.
- **Stable pins:** Use `pkgs.stable.<name>` for packages that must not track unstable (e.g. drivers).
- **Override precedence:** `lib.mkDefault` in modules allows host-level overrides; `lib.mkForce` prevents them.
- **Custom module options:** `asus-rog.nix` and `dell-latitude.nix` define `hardware.*.battery.chargeUpto` options — set them in host config.

## Hardware Context

### Two-layer hostname convention

- **Logical name** — the fleet key / SSH alias / tailnet node / repo
  `hosts/<dir>` — role-based and stable: `latitude` / `desktop` / `server` /
  `hub`.
- **OS hostname** — `detect.hostname` in `fleet.json` — the hardware model,
  lowercased: `latitude5520`, `g614jv`, `g513ie`, `27608`.
- `hub`/`27608` is the VPS special-case: no laptop model, so its OS hostname
  is just the VPS ID, not a model code.
- The server's *live* OS hostname is still `methe-server` — `g513ie` above is
  the target model name; the flip happens in Phase 2 (`Rename-Computer` +
  reboot on the box), not yet applied.

### g16 (ASUS ROG G16)

- CPU: Intel (kvm-intel, microcode updates enabled)
- GPU: Intel integrated (primary, `PCI:00:02:0`) + NVIDIA discrete (PRIME offload, `PCI:01:00:0`)
- Run on NVIDIA GPU: `nvidia-offload <command>`
- Verify bus IDs if offload breaks: `lspci | grep -E "VGA|3D"`
- Fine-grained power management: NVIDIA GPU powers off when idle
- **NVIDIA upgrade safety:** Driver changes can cause `nixos-rebuild switch` to fail mid-session. Use `just upgrade` (set next boot) over `just switch` when the change includes NVIDIA.

### latitude5520 (Dell Latitude 5520)

- CPU: Intel 11th Gen Tiger Lake (kvm-intel)
- GPU: Intel integrated only (intel-compute-runtime for OpenCL)
- Root: LUKS-encrypted ext4
- Thunderbolt: authorized via bolt

### Both hosts

- Battery charge limit: 85% default, `charge-upto <percent>` to change
- Bluetooth: off at boot — enable manually when needed
- Swap: ZRAM (50% memory, zstd)
- Sleep: S3 deep (`mem_sleep_default=deep`)
