# Justfile for NixOS system management
# Run `just --list` to see all available commands

# On Windows there is no POSIX `sh` on PATH, so just can't run backticks/recipes
# (it dies on `hostname := ...` below). Point it at Git Bash. Ignored on
# Linux/macOS, which use the default `sh`. If Git is installed elsewhere, either
# fix this path or skip just entirely and run the PS bootstrap:
#   provision\windows.ps1
set windows-shell := ['C:/Program Files/Git/bin/bash.exe', '-cu']

# Default recipe — show help.
#
# GENERATED from the recipes themselves, never hand-maintained. This used to be a
# hardcoded block of @echo lines that had to be updated by hand whenever a recipe
# landed; it drifted until 24 of 41 recipes were undocumented (provision-mac,
# provision-wsl, backup, health, rollback, the update-* family, …). Every recipe
# now carries [group('…')] + [doc('…')] attributes, so `just --list` IS the help
# and cannot fall behind.
#
# Adding a recipe: give it both attributes. provision/tests/justfile.test.sh
# fails the build if either is missing.
[private]
default:
    @just --list --list-heading $'🚀 NixOS System Management — `just <recipe>`\n' --list-prefix '  '

# Variables
hostname := `hostname`
flake_dir := justfile_directory()
# The sole NixOS box's flake attribute. Decoupled from `hostname` because the
# OS hostname stays `latitude5520` while the flake attr is `latitude`. A second
# NixOS box turns this into a hostname->attr map.
nixos_attr := "latitude"
# Build system configuration without switching
[group('build')]
[doc('Build the system configuration without activating it')]
build:
    @echo "🔨 Building NixOS configuration..."
    sudo nixos-rebuild build --flake {{flake_dir}}#{{nixos_attr}}
    @echo "✅ Build complete!"

# Guard: home-manager (claude.nix, which invokes bootstrap.sh) reads ~/machines/agents via
# mkOutOfStoreSymlink, so ~/machines must resolve to this clone. If the repo
# isn't cloned there directly, a dangling/missing ~/machines silently breaks
# the agent config — fail loud instead.
_check-machines-link:
    @test -e ~/machines/agents/AGENTS.md || { echo "❌ ~/machines is missing or dangling — home-manager reads ~/machines/agents. If this clone lives elsewhere, symlink it: ln -sfn {{flake_dir}} ~/machines (see hosts/desktop/windows runbook, Phase 4.0)"; exit 1; }

# NOT run by switch/update on NixOS — claude.nix invokes bootstrap.sh to own the links there,
# applied by `just switch`. Escape hatch for non-Nix machines or a forced re-link.
# Relative path (not {{flake_dir}}): just runs recipes with cwd = justfile dir,
# and on Windows {{flake_dir}} is a backslash path bash mangles (C:Users… → not
# found). No-just fallbacks: `bash agents/bootstrap.sh`, or on Windows the PS
# script provision\windows.ps1.
# Bootstrap personal agent config (~/.claude + Orca-managed account profiles)
[group('fleet')]
[doc('Link personal agent config (~/.claude + Orca profiles)')]
agent-bootstrap:
    @echo "🔗 Bootstrapping agent config (personal ~/.claude)..."
    @env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh

# Bootstrap a secondary profile ~/.claude-<postfix> (e.g. `just agent-bootstrap-profile pure`).
# Links the shared set + settings.<postfix>.json; machine-local settings.local.json untouched.
[group('fleet')]
[doc('Link a secondary agent profile ~/.claude-<postfix>')]
agent-bootstrap-profile postfix:
    @echo "🔗 Bootstrapping agent config (~/.claude-{{postfix}})..."
    @CLAUDE_CONFIG_DIR="$HOME/.claude-{{postfix}}" bash agents/bootstrap.sh

# Mirror ~/.claude into every Orca-managed account profile
# (~/.local/share/orca/claude-accounts/<uuid>/auth). Once per Orca auth;
# idempotent, and `just agent-bootstrap` already runs it at the end of a personal
# run. Pass a dir to target one account, `--dry-run` to preview.
[group('fleet')]
[doc('Mirror the base Claude profile into Orca-managed account profiles')]
agent-sync-orca *args:
    @echo "🔗 Syncing base Claude profile into Orca-managed profiles..."
    @bash agents/orca-profile-sync.sh {{args}}

# Move an Orca account profile into ~/.claude-profiles/<name> and leave a symlink
# in Orca's tree, so transcripts and sessions outlive the account dir. Once per
# account, with Orca CLOSED — it refuses to relocate a profile with a live session.
# `--status` shows every pairing; `--relink` re-heals a link Orca replaced.
[group('fleet')]
[doc('Move an Orca account profile into $HOME and link it back')]
agent-link-orca *args:
    @bash agents/orca-profile-link.sh {{args}}

# NixOS-only: run the machine-local `gortex install --no-claude-md` wiring, which
# bootstrap.sh skips under home-manager activation (kept fast/offline there). The
# binary + daemon come from pkgs/gortex.nix + me.nix; this fills in the per-profile
# skills/agents/hooks + user MCP config. Run once per box (re-run after a bump).
[group('fleet')]
[doc('Wire per-profile gortex skills/agents/hooks (NixOS only)')]
gortex-setup:
    @echo "🧠 Wiring gortex (machine-local skills/agents/hooks + MCP)..."
    @GORTEX_ALLOW_NIX_WIRE=1 GORTEX_REWIRE=1 env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh

# Build and switch to new configuration
[group('build')]
[doc('Build and activate the configuration now')]
switch: _check-machines-link
    @echo "🔧 Switching to new NixOS configuration..."
    sudo nixos-rebuild switch --flake {{flake_dir}}#{{nixos_attr}}
    @echo "✅ System switched successfully!"

# Build and test configuration temporarily
[group('build')]
[doc('Activate temporarily — reverts on next boot')]
test: _check-machines-link
    @echo "🧪 Testing NixOS configuration..."
    sudo nixos-rebuild test --flake {{flake_dir}}#{{nixos_attr}}
    @echo "✅ Test complete! Changes are temporary."

# Build and set for next boot
[group('build')]
[doc('Build and set for the next boot')]
boot: _check-machines-link
    @echo "🥾 Setting configuration for next boot..."
    sudo nixos-rebuild boot --flake {{flake_dir}}#{{nixos_attr}}
    @echo "✅ Configuration set for next boot!"

# Update flake inputs (and out-of-tree pinned packages like rustdesk, orca)
[group('update')]
[doc('Update flake inputs + pinned out-of-tree packages')]
update:
    @echo "📦 Updating flake inputs..."
    nix flake update --flake {{flake_dir}}
    @just update-rustdesk
    @just update-orca
    @just update-gortex
    @echo "✅ Flake inputs updated!"

# Bump rustdesk-bin.nix to the latest upstream release (also run by `update`)
[group('update')]
[doc('Bump rustdesk-bin.nix to the latest upstream release')]
update-rustdesk:
    @echo "📦 Checking for new RustDesk release..."
    {{flake_dir}}/scripts/update-rustdesk.sh

# Bump orca-bin.nix to the latest upstream release (also run by `update`)
[group('update')]
[doc('Bump orca-bin.nix to the latest upstream release')]
update-orca:
    @echo "📦 Checking for new Orca release..."
    {{flake_dir}}/scripts/update-orca.sh

# Bump pkgs/gortex.nix to the latest upstream release (also run by `update`).
# NixOS-only (needs `nix store prefetch-file`); the Windows boxes float via the
# upstream installer in agents/bootstrap.sh.
[group('update')]
[doc('Bump pkgs/gortex.nix to the latest release (NixOS only)')]
update-gortex:
    @echo "📦 Checking for new gortex release..."
    {{flake_dir}}/scripts/update-gortex.sh

# Update and set for next boot (safe for Nvidia drivers)
[group('update')]
[doc('Update and set for next boot (safe for NVIDIA)')]
upgrade:
    @echo "⬆️ Upgrading system..."
    just update
    just boot
    @echo "🎉 System upgrade complete!"
    @echo "⚠️  Please reboot your system to activate the new configuration."

# Update and switch immediately (may fail with Nvidia driver mismatch)
[group('update')]
[doc('Update and switch immediately (may hit an NVIDIA mismatch)')]
upgrade-now:
    @echo "⬆️ Upgrading system (immediate switch)..."
    just update
    just switch
    @echo "🎉 System upgrade complete!"

# Clean old generations and garbage collect
[group('maintenance')]
[doc('Remove generations older than 7 days, then garbage-collect')]
clean:
    @echo "🧹 Cleaning system..."
    @echo "Removing system generations older than 7 days..."
    sudo nix-collect-garbage --delete-older-than 7d
    @echo "Removing user generations older than 7 days..."
    nix-collect-garbage --delete-older-than 7d
    @echo "✅ Cleanup complete!"

# Deep cleanup - remove all old generations
[group('maintenance')]
[doc('Deep clean — remove ALL old generations')]
cleanup:
    @echo "🗑️ Deep cleaning system..."
    @echo "⚠️ This will remove ALL old generations. Continue? (Ctrl+C to cancel)"
    @read
    sudo nix-collect-garbage -d
    nix-collect-garbage -d
    sudo nixos-rebuild switch --flake {{flake_dir}}#{{nixos_attr}}
    @echo "✅ Deep cleanup complete!"

# Optimize Nix store
[group('maintenance')]
[doc('Deduplicate the Nix store')]
optimize:
    @echo "⚡ Optimizing Nix store..."
    sudo nix-store --optimise
    @echo "✅ Store optimization complete!"

# Format all Nix files (alejandra — matches the flake formatter + pre-commit hook)
[group('dev')]
[doc('Format all Nix files (alejandra)')]
fmt:
    @echo "🎨 Formatting Nix files..."
    alejandra {{flake_dir}}
    @echo "✅ Formatting complete!"

# Check configuration syntax
[group('dev')]
[doc('Full flake evaluation check')]
check:
    @echo "🔍 Checking configuration..."
    nix flake check {{flake_dir}}
    @echo "✅ Configuration check passed!"

# Quick configuration check
[group('dev')]
[doc('Fast validation — syntax + a one-host dry build')]
quick:
    @echo "🔍 Running quick configuration check..."
    ./scripts/quick-check.sh

# Enter development shell
[group('dev')]
[doc('Enter the development shell')]
shell:
    @echo "🐚 Entering development shell..."
    nix develop {{flake_dir}}

# Show system status
[group('info')]
[doc('Show system status')]
status:
    @echo "📊 System Status"
    @echo "=================="
    @echo "Hostname: $(hostname)"
    @echo "Kernel: $(uname -r)"
    @echo "NixOS Version: $(nixos-version)"
    @echo "Uptime: $(uptime)"
    @echo ""
    @echo "💾 Memory Usage:"
    free -h
    @echo ""
    @echo "💿 Disk Usage:"
    df -h / /boot
    @echo ""
    @echo "🔋 Battery Status:"
    if command -v acpi >/dev/null 2>&1; then acpi; else echo "Battery info not available"; fi

# Show hardware information
[group('info')]
[doc('Show hardware information')]
hardware:
    @echo "🖥️ Hardware Information"
    @echo "======================="
    @echo "CPU Info:"
    lscpu | grep -E "Model name|Architecture|CPU\(s\):|Thread|Core"
    @echo ""
    @echo "Memory Info:"
    cat /proc/meminfo | grep -E "MemTotal|MemAvailable"
    @echo ""
    @echo "GPU Info:"
    lspci | grep -E "VGA|3D"
    @echo ""
    @echo "Storage Info:"
    lsblk -f
    @echo ""
    @echo "USB Devices:"
    lsusb

# Show system generations
[group('info')]
[doc('List all system generations')]
generations:
    @echo "📋 System Generations"
    @echo "====================="
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
    @echo ""
    @echo "🏠 Home Manager Status"
    @echo "======================"
    systemctl --user status home-manager-me.service --no-pager || echo "Home Manager service not active"

# Show flake info
[group('info')]
[doc('Show flake metadata')]
info:
    @echo "📄 Flake Information"
    @echo "===================="
    nix flake show {{flake_dir}}
    @echo ""
    @echo "📦 Flake Metadata"
    @echo "================="
    nix flake metadata {{flake_dir}}

# Rollback to previous generation
[group('maintenance')]
[doc('Roll back to the previous generation (prompts)')]
rollback:
    @echo "⏪ Rolling back to previous generation..."
    @echo "⚠️ This will rollback to the previous system generation. Continue? (Ctrl+C to cancel)"
    @read
    sudo nixos-rebuild switch --rollback
    @echo "✅ Rollback complete!"

# Show recent system changes
[group('info')]
[doc('Show the two most recent system generations')]
diff:
    @echo "📈 Recent System Changes"
    @echo "========================"
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -2

# Repair Nix store
[group('maintenance')]
[doc('Verify and repair the Nix store')]
repair:
    @echo "🔧 Repairing Nix store..."
    sudo nix-store --verify --check-contents --repair
    @echo "✅ Store repair complete!"

# Show system logs
[group('info')]
[doc('System logs from the last hour')]
logs:
    @echo "📜 Recent System Logs"
    @echo "===================="
    journalctl --system --since "1 hour ago" --no-pager

# Monitor system resources
[group('info')]
[doc('Live resource monitor (htop)')]
monitor:
    @echo "📊 System Resource Monitor"
    @echo "Press Ctrl+C to exit"
    htop

# Test configuration in VM
[group('build')]
[doc('Build a throwaway VM of the configuration')]
vm:
    @echo "🖥️ Building and running configuration in VM..."
    nixos-rebuild build-vm --flake {{flake_dir}}#{{nixos_attr}}
    @echo "VM built successfully! Run ./result/bin/run-nixos-vm to start."

# Build ISO installer
[group('build')]
[doc('Build a NixOS installer ISO')]
iso:
    @echo "💿 Building NixOS installer ISO..."
    nix build {{flake_dir}}#nixosConfigurations.{{nixos_attr}}.config.system.build.isoImage
    @echo "✅ ISO built successfully!"

# Quick system health check
[group('info')]
[doc('Quick system health check')]
health:
    @echo "🏥 System Health Check"
    @echo "======================"
    @echo "Checking Nix store..."
    @if nix-store --verify --check-contents >/dev/null 2>&1; then \
        echo "✅ Nix store is healthy"; \
    else \
        echo "❌ Nix store has issues"; \
    fi
    @echo "Checking systemd services..."
    @if systemctl --failed --quiet; then \
        echo "❌ Some systemd services have failed:"; \
        systemctl --failed --no-pager; \
    else \
        echo "✅ All systemd services are running"; \
    fi
    @echo "Checking disk space..."
    @if [ $$(df / | awk 'NR==2 {print $$5}' | sed 's/%//') -gt 90 ]; then \
        echo "⚠️ Root filesystem is over 90% full"; \
    else \
        echo "✅ Disk space is adequate"; \
    fi

# Backup current configuration
[group('maintenance')]
[doc('Copy this repo to a timestamped .backup directory')]
backup:
    @echo "💾 Backing up current configuration..."
    cp -r {{flake_dir}} {{flake_dir}}.backup.$(date +%Y%m%d_%H%M%S)
    @echo "✅ Backup created in {{flake_dir}}.backup.$(date +%Y%m%d_%H%M%S)"

# Show package search
[group('dev')]
[doc('Search nixpkgs for PACKAGE')]
search PACKAGE:
    @echo "🔍 Searching for package: {{PACKAGE}}"
    nix search nixpkgs {{PACKAGE}}

# Show package info
[group('dev')]
[doc('Show nixpkgs metadata for PACKAGE')]
show PACKAGE:
    @echo "📦 Package information for: {{PACKAGE}}"
    nix search nixpkgs#{{PACKAGE}} --json | jq

# Run a package temporarily
[group('dev')]
[doc('Run PACKAGE once without installing it')]
run PACKAGE:
    @echo "🏃 Running {{PACKAGE}} temporarily..."
    nix run nixpkgs#{{PACKAGE}}

# Enter shell with package
[group('dev')]
[doc('Enter a shell with PACKAGE available')]
shell-with PACKAGE:
    @echo "🐚 Entering shell with {{PACKAGE}}..."
    nix shell nixpkgs#{{PACKAGE}}

# Fleet front door: detect this machine and show its provisioning plan.
# Pass extra args through, e.g. `just provision --machine hub` or `--apply`.
# Relative path (not {{justfile_directory()}}): just runs recipes with cwd =
# justfile dir, and on Windows the absolute {{...}} is a backslash path bash
# mangles (C:Users… → not found) — same reason agent-bootstrap stays relative.
[group('fleet')]
[doc('Fleet front door — plan or apply roles for a machine')]
provision *ARGS:
    bash provision/provision.sh {{ARGS}}

# Half-provision THIS WSL distro as a self-declaring, ephemeral fleet host.
# <nickname> = tailnet node name (also its fleet.local.json nickname). Run from
# inside the distro. Relative path (not {{flake_dir}}) — same Windows-path reason
# as agent-bootstrap/provision.
[group('provision')]
[doc('Provision THIS WSL distro as a self-declared fleet host (add --no-tailscale for a second distro)')]
provision-wsl nickname *args:
    bash provision/provision-wsl.sh {{nickname}} {{args}}

# <machine> is a darwin member of fleet.json (e.g. `air`) — an argument rather
# than detected, because stage 1 is what SETS the hostname. One sudo prompt up
# front, then: hostname, Homebrew, tailnet, toolchain, roles.
# Pre-auth key: `--authkey-file provision/secrets/authkey` (gitignored) or
# $HEADSCALE_AUTHKEY. Preview with `--dry-run`.
# Fully provision THIS Mac as a fleet member, end to end.
[group('fleet')]
[doc('Provision THIS Mac as a fleet member, end to end')]
provision-mac machine *ARGS:
    bash provision/provision-mac.sh {{machine}} {{ARGS}}
