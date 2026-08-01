# AGENTS.md

This file provides guidance to Claude Code and other agents working in this
repository. The repo-root `CLAUDE.md` is a **symlink to this file** — edit
`AGENTS.md`, never create a second real file at the `CLAUDE.md` path.

## Repository Overview

> **Fleet migration in flight (as of 2026-08-01).** Plans:
> `docs/superpowers/plans/2026-07-27-fleet-migration-mac-primary-latitude-server.md`
> and `2026-07-28-latitude-wipe-harvest.md` (status: open). `air` becomes the
> primary dev box; latitude converts to the always-on services host with NixOS
> slated for retirement (`fleet.json` already declares it `platform: debian`,
> `profile: server` — commits `380cb55`, `0aa4eb9`); the G15 (`server`) is being
> drained and retired. The machine descriptions below are the pre-migration
> state — verify the live OS/role before acting on them.

Config, provisioning, and data-backup for a small machine fleet — NixOS *and*
Windows:

- **g614jv / ME-G614JV** — ASUS ROG G16 2024, RTX 4060; **Windows-only** (WSL
  hostname `g614jv`, native `ME-G614JV`). Its former NixOS install `g16` was
  retired 2026-07-08; `hosts/desktop/` now holds only `windows/`.
- **homeserver** — ASUS ROG **G15** 2023 (model **G513IE**), RTX 3050 Ti,
  Windows 11 + Docker Desktop; logical name `server`, OS hostname `g513ie`
  (renamed from `methe-server` 2026-07-20 — the model code; see the
  hostname-normalization spec). Runs the cyphy.kz service platform
- **latitude5520** — Dell Latitude 5520, Intel Tiger Lake, NixOS hostname `latitude5520`
- **air** — MacBook, `platform: darwin`, tailnet `100.64.0.7`, roles `base,
  ssh-server, agents, dotfiles, repos`. Provisioned with `just provision-mac air`
  plus the dotfiles role; the Nix build/switch recipes below do **not** apply to it.
- **hub** — Debian VPS at `cyphy.kz` (tailnet `100.64.0.1`), a first-class
  `fleet.json` member (roles `base, ssh-server, agents, dotfiles,
  backup-client`); runs the Headscale control server + the AmneziaWG VPN hub.
  Services live in the sibling `vps` repo.

The NixOS hosts use Home Manager (system-level integration) and share a common
module set with host-specific overrides. The repo also carries Windows
install/reinstall + backup scripts (`hosts/desktop/windows/`) and shared Win11
install media (`install-media/`).

**`machines` / `vps` boundary:** `machines` owns the *machines* — NixOS +
Windows provisioning and data backup. The sibling **`vps`** repo owns the
*services* the homeserver runs (Immich, Navidrome, Forgejo, the cyphy.kz
platform). Machine here, services there.

## Common Commands

All commands run from repo root. `just --list` is the full menu (~45 recipes).
System-modifying commands require `sudo` (via `nixos-rebuild`).

**The build/dev recipes below are NixOS-only** — `build`, `switch`, `boot`,
`test`, `check`, `quick`, `iso`, `vm`, `upgrade` all fail on `air` (darwin) and
on the Windows boxes, which have no Nix. See the fleet/provisioning block for
what those hosts run instead.

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

### Fleet / provisioning (every platform)

```bash
# Role front door — flag syntax; a bare positional exits 2
just provision --machine <machine> --dry-run
just provision --machine <machine> --apply

just provision-mac <machine>            # provision THIS Mac end to end
just provision-wsl <nickname>           # self-declare THIS WSL distro
                                        #   (--no-tailscale for a second distro)

just agent-bootstrap                    # link ~/.claude + ~/.codex
just agent-bootstrap-profile <postfix>  # provision ~/.claude-<postfix>
just agent-sync-orca                    # mirror ~/.claude into Orca's per-account
                                        #   profiles (once per Orca auth; also runs
                                        #   at the end of agent-bootstrap)
just hermes-bootstrap                   # link ~/.hermes
just gortex-setup                       # wire per-profile gortex (NixOS only)

just update-gortex | update-orca | update-rustdesk   # bump pinned out-of-tree pkgs
```

### Tests

Plain bash scripts — **no recipe runs them**, and `just test` is
`nixos-rebuild test`, not the suite.

```bash
bash provision/tests/roles.test.sh      # one file; prints ALL PASS, nonzero on failure

# whole suite
for t in provision/tests/*.test.sh provision/*.test.sh \
         agents/tests/*.test.sh scripts/converge.test.sh; do bash "$t"; done
```

## Architecture

### Flake structure (`flake.nix`)

- **Inputs:** nixpkgs (unstable), nixpkgs-stable (25.05), home-manager, nixos-hardware, claude-code-nix
- **Stable overlay:** `pkgs.stable.*` available everywhere — use to pin critical packages (drivers, kernel) to stable while rest runs unstable
- **`specialArgs`** passes `inputs`, `system`, `nixpkgs-stable` into all modules
- **Formatter:** alejandra
- **Dev shell:** nixfmt, nil, nixd, alejandra, git, just, direnv, wget, curl, jq, yq
- **Outputs:** `nixosConfigurations.latitude` **and** `.latitude5520` — the same
  system bound twice, so `nixos-rebuild --flake .#$(hostname)` and `converge.sh`
  can resolve by OS hostname; plus `homeConfigurations."me@latitude"` and
  `checks` for both.
- **`pylspFixOverlay`** pins python-lsp-server to fork `metheoryt@e4ee218`
  (upstream PR #715 — the `pylsp_definitions` crash gortex hits constantly).
  Delete the overlay once nixpkgs ships the fix.

### Module structure (`modules/`)

Each module is self-contained (options + config + services). Modules don't import each other — `configuration.nix` imports them all.

| Module | Responsibility |
|---|---|
| `system/base.nix` | systemd-boot, Nix daemon, flakes, binary caches, networking, ZRAM swap, weekly GC, core packages, Fish shell |
| `system/laptop.nix` | power-profiles-daemon, thermald, touchpad (libinput), backlight (acpilight/actkbd), lid/power-button behavior, S3 deep sleep, Intel microcode |
| `system/fleet.nix` | fleet.json data / ssh.nix source of truth |
| `system/ssh-server.nix` | keys-only sshd over the tailnet — the fleet SSH-server role |
| `system/fleet-selfpull.nix` | auto-pull backend — runs `provision/fleet-selfpull.sh` on a timer, the same script the non-Nix members use (replaced the NixOS-only `self-update.nix`) |
| `system/git-autofetch/` | auto-fetch timer |
| `system/machines-converge.nix` | NixOS convergence trigger — root `.path` unit watches `.git/logs/HEAD`, fires a rebuild after an ff-pull |
| `desktop/gnome.nix` | GDM + GNOME (Wayland), PipeWire audio, XDG portals, fonts (JetBrainsMono Nerd Font, Noto, Fira Code), excluded GNOME apps |
| `hardware/asus-rog.nix` | **orphaned** — `charge-upto` command + systemd service, ROG keyboard evdev fixes (mic mute, Fn+arrows), DPCD backlight kernel params; no host imports it since NixOS g16 was removed |
| `hardware/dell-latitude.nix` | `charge-upto` command + systemd service, Intel compute runtime, Thunderbolt (bolt service), fstrim |
| `nvidia.nix` | **orphaned** — NVIDIA open kernel modules, PRIME offload mode (Intel primary, NVIDIA on-demand), fine-grained power mgmt, Wayland env vars, Vulkan/OpenCL, nvidia-container-toolkit; no host imports it since NixOS g16 was removed |
| `programs/development.nix` | nix-ld, Docker (auto-start + auto-prune), Python 3.13 + uv, dev tools (git, gh, jq, ripgrep, ast-grep, fd, bat, etc.), direnv + nix-direnv, Fish + Zsh |
| `home/me.nix` | Home Manager for user `me`: packages, git config, Fish aliases/functions, Starship prompt, Ghostty config, GNOME dconf settings, fastfetch |
| `home/ssh.nix` | SSH client config generated from fleet.json |
| `home/claude.nix` | Claude Code profile bootstrap wiring |
| `home/orca-bin.nix` | Orca IDE AppImage wrapper |
| `home/rustdesk-bin.nix` | RustDesk client wrapper |
| `home/rustdesk-config.nix` | RustDesk server key + known-peer IDs |

### Other top-level directories

None of these are Nix modules — they are the non-NixOS half of the repo.

| Dir | What it is |
|---|---|
| `provision/` | Cross-platform provisioner — `provision.{sh,ps1}` role front door, `roles/*.{sh,ps1}` executors, `lib/` manifest readers (`fleet.sh`, `Fleet.psm1`, `tiers.sh`), `linux.sh`/`macos.sh` tier drivers, `statusboard/`, `tests/`. See `provision/README.md`. |
| `agents/` | Version-controlled agent config — `plugin/` (skills, subagents, hooks, commands), `subagents/`, `git-hooks/`, `bootstrap.sh`, `orca-profile-sync.sh` (mirrors `~/.claude` into Orca's per-account config dirs), `worktree-{setup,teardown}.sh`, `tests/`. See `agents/README.md` and `agents/docs/git-workflow.md`. |
| `hermes/` | Hermes Agent config — `config.yaml`, `skills/`; `bootstrap.sh` links it into `~/.hermes/`. Its `memories/` is an **empty, unfilled slot** — the agent-config handover did not fill it. |
| `scripts/` | `converge.sh` (convergence engine) + `converge.test.sh`, `quick-check.sh` (the `just quick` gate), the `update-*.sh` version bumpers. |
| `pkgs/` | Pinned out-of-tree packages (e.g. `gortex.nix`). |
| `install-media/` | Shared Win11 install media. |

### Fleet networking / tailnet architecture

The fleet transport is a self-hosted **Headscale tailnet** (`cc.cyphy.kz`,
MagicDNS suffix `gg.ez`, CGNAT `100.64.0.0/10`); `fleet.json` (repo root) is
the machine manifest, and the `ssh-server` role (`modules/system/ssh-server.nix`
+ `windows.ps1` step 7) generates every host's keys-only-sshd-over-tailnet
story. The old AmneziaWG mesh was retired from the repo 2026-07-17 (AmneziaWG
survives only as the VPS's obfuscated VPN for RU relatives).

Self-declared WSL hosts are first-class fleet hosts that never appear in
`fleet.json`: each carries a gitignored `fleet.local.json`
(`{nickname, fleet:true, platform, dispatch}`), written by
`provision/fleet-local.sh` as step 4 of `just provision-wsl <nickname>` (chain:
`tailscale-wsl.sh → ssh-wsl.sh → linux.sh → fleet-local.sh → wsl-fixes.sh`).
Its Windows parent discovers it live via `wsl -l -q` + reading each distro's
`fleet.local.json`. Only a `dispatch:direct` distro (the one that owns the
tailnet node, at most one per Windows host — WSL2 distros share one network
namespace) is reached directly at `<nickname>.gg.ez`; every other distro is
`dispatch:parent`, reached as `wsl.exe -d <distro>` through its Windows
parent — not through a `fleet.json` entry either way. The shared dispatch primitive
`agents/plugin/skills/lib/fleet-dispatch.sh` (`fd_probe`/`fd_run`/
`fd_wsl_hosts`) is sourced by both `/ship`'s `fleet-pull.sh` and kb-refresh's
`fleet-gather.sh`; it also handles the Windows-native members (`desktop`,
`server`) by dispatching through Git Bash via PowerShell's call operator,
keyed on `platform: windows` in `fleet.json`.

### Host configurations

Currently a single NixOS host:

**`hosts/latitude/nixos/configuration.nix`** (flake attr `latitude`;
`networking.hostName` stays `latitude5520` — only the repo label/flake attr
changed)
- Imports: base, laptop, fleet-selfpull, machines-converge, git-autofetch, ssh-server, gnome, dell-latitude, development, home-manager
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
- The server's *live* OS hostname is now `g513ie` — renamed from
  `methe-server` via `Rename-Computer` + reboot on the box, verified live
  2026-07-20.
- **Self-declared WSL hosts add a third identity, outside this two-layer
  scheme entirely**: they are not a `fleet.json` member, so there's no
  logical-name/OS-hostname pair — just a `fleet.local.json` nickname. Only a
  `dispatch:direct` distro (at most one per Windows host — WSL2 distros share
  one network namespace) owns the tailnet node and is reached directly at
  `<nickname>.gg.ez`; other distros are `dispatch:parent` and are reached
  through their Windows parent instead.

### latitude5520 (Dell Latitude 5520)

- CPU: Intel 11th Gen Tiger Lake (kvm-intel)
- GPU: Intel integrated only (intel-compute-runtime for OpenCL)
- Root: LUKS-encrypted ext4
- Thunderbolt: authorized via bolt
- Battery charge limit: 85% default, `charge-upto <percent>` to change
- Bluetooth: off at boot — enable manually when needed
- Swap: ZRAM (50% memory, zstd)
- Sleep: S3 deep (`mem_sleep_default=deep`)
