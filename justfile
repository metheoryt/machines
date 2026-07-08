# Justfile for NixOS system management
# Run `just --list` to see all available commands

# On Windows there is no POSIX `sh` on PATH, so just can't run backticks/recipes
# (it dies on `hostname := ...` below). Point it at Git Bash. Ignored on
# Linux/macOS, which use the default `sh`. If Git is installed elsewhere, either
# fix this path or skip just entirely and run the PS bootstrap:
#   provision\windows.ps1
set windows-shell := ['C:/Program Files/Git/bin/bash.exe', '-cu']

# Default recipe - show help
default:
    @echo "🚀 NixOS System Management Commands"
    @echo ""
    @echo "Build and Deploy:"
    @echo "  just build     - Build system configuration"
    @echo "  just switch    - Build and switch to new configuration"
    @echo "  just test      - Build and test configuration (temporary)"
    @echo "  just boot      - Build and set for next boot"
    @echo ""
    @echo "Updates:"
    @echo "  just update      - Update all flake inputs"
    @echo "  just upgrade     - Update and set for next boot (safe for Nvidia)"
    @echo "  just upgrade-now - Update and switch immediately"
    @echo ""
    @echo "Maintenance:"
    @echo "  just clean     - Clean old generations and garbage collect"
    @echo "  just cleanup   - Deep cleanup (remove all old generations)"
    @echo "  just optimize  - Optimize Nix store"
    @echo ""
    @echo "Development:"
    @echo "  just fmt       - Format all Nix files"
    @echo "  just check     - Check configuration syntax"
    @echo "  just quick     - Quick configuration validation"
    @echo "  just shell     - Enter development shell"
    @echo ""
    @echo "System Info:"
    @echo "  just status    - Show system status"
    @echo "  just hardware  - Show hardware information"
    @echo "  just generations - Show system generations"

# Variables
hostname := `hostname`
flake_dir := justfile_directory()
# Build system configuration without switching
build:
    @echo "🔨 Building NixOS configuration..."
    sudo nixos-rebuild build --flake {{flake_dir}}#{{hostname}}
    @echo "✅ Build complete!"

# Guard: home-manager (claude.nix/codex.nix) reads ~/machines/agents via
# mkOutOfStoreSymlink, so ~/machines must resolve to this clone. If the repo
# isn't cloned there directly, a dangling/missing ~/machines silently breaks
# the agent config — fail loud instead.
_check-machines-link:
    @test -e ~/machines/agents/AGENTS.md || { echo "❌ ~/machines is missing or dangling — home-manager reads ~/machines/agents. If this clone lives elsewhere, symlink it: ln -sfn {{flake_dir}} ~/machines (see hosts/g16/windows runbook, Phase 4.0)"; exit 1; }

# NOT run by switch/update on NixOS — claude.nix/codex.nix own the links there,
# applied by `just switch`. Escape hatch for non-Nix machines or a forced re-link.
# Relative path (not {{flake_dir}}): just runs recipes with cwd = justfile dir,
# and on Windows {{flake_dir}} is a backslash path bash mangles (C:Users… → not
# found). No-just fallbacks: `bash agents/bootstrap.sh`, or on Windows the PS
# script provision\windows.ps1.
# Bootstrap personal agent config (~/.claude + ~/.codex)
agent-bootstrap:
    @echo "🔗 Bootstrapping agent config (personal ~/.claude + ~/.codex)..."
    @env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh

# Bootstrap the work profile (~/.claude-work) — shared set only, settings untouched.
agent-bootstrap-work:
    @echo "🔗 Bootstrapping agent config (work ~/.claude-work)..."
    @CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh

# Build and switch to new configuration
switch: _check-machines-link
    @echo "🔧 Switching to new NixOS configuration..."
    sudo nixos-rebuild switch --flake {{flake_dir}}#{{hostname}}
    @echo "✅ System switched successfully!"

# Build and test configuration temporarily
test: _check-machines-link
    @echo "🧪 Testing NixOS configuration..."
    sudo nixos-rebuild test --flake {{flake_dir}}#{{hostname}}
    @echo "✅ Test complete! Changes are temporary."

# Build and set for next boot
boot: _check-machines-link
    @echo "🥾 Setting configuration for next boot..."
    sudo nixos-rebuild boot --flake {{flake_dir}}#{{hostname}}
    @echo "✅ Configuration set for next boot!"

# Update flake inputs (and out-of-tree pinned packages like rustdesk, zed, pycharm)
update:
    @echo "📦 Updating flake inputs..."
    nix flake update --flake {{flake_dir}}
    @just update-rustdesk
    @just update-zed
    @just update-pycharm
    @echo "✅ Flake inputs updated!"

# Bump rustdesk-bin.nix to the latest upstream release (also run by `update`)
update-rustdesk:
    @echo "📦 Checking for new RustDesk release..."
    {{flake_dir}}/scripts/update-rustdesk.sh

# Bump zed-bin.nix to the latest stable upstream release (also run by `update`)
update-zed:
    @echo "📦 Checking for new Zed release..."
    {{flake_dir}}/scripts/update-zed.sh

# Bump pycharm-bin.nix to the latest upstream release (also run by `update`)
update-pycharm:
    @echo "📦 Checking for new PyCharm release..."
    {{flake_dir}}/scripts/update-pycharm.sh

# Update and set for next boot (safe for Nvidia drivers)
upgrade:
    @echo "⬆️ Upgrading system..."
    just update
    just boot
    @echo "🎉 System upgrade complete!"
    @echo "⚠️  Please reboot your system to activate the new configuration."

# Update and switch immediately (may fail with Nvidia driver mismatch)
upgrade-now:
    @echo "⬆️ Upgrading system (immediate switch)..."
    just update
    just switch
    @echo "🎉 System upgrade complete!"

# Clean old generations and garbage collect
clean:
    @echo "🧹 Cleaning system..."
    @echo "Removing system generations older than 7 days..."
    sudo nix-collect-garbage --delete-older-than 7d
    @echo "Removing user generations older than 7 days..."
    nix-collect-garbage --delete-older-than 7d
    @echo "✅ Cleanup complete!"

# Deep cleanup - remove all old generations
cleanup:
    @echo "🗑️ Deep cleaning system..."
    @echo "⚠️ This will remove ALL old generations. Continue? (Ctrl+C to cancel)"
    @read
    sudo nix-collect-garbage -d
    nix-collect-garbage -d
    sudo nixos-rebuild switch --flake {{flake_dir}}#{{hostname}}
    @echo "✅ Deep cleanup complete!"

# Optimize Nix store
optimize:
    @echo "⚡ Optimizing Nix store..."
    sudo nix-store --optimise
    @echo "✅ Store optimization complete!"

# Format all Nix files (alejandra — matches the flake formatter + pre-commit hook)
fmt:
    @echo "🎨 Formatting Nix files..."
    alejandra {{flake_dir}}
    @echo "✅ Formatting complete!"

# Check configuration syntax
check:
    @echo "🔍 Checking configuration..."
    nix flake check {{flake_dir}}
    @echo "✅ Configuration check passed!"

# Quick configuration check
quick:
    @echo "🔍 Running quick configuration check..."
    ./scripts/quick-check.sh

# Enter development shell
shell:
    @echo "🐚 Entering development shell..."
    nix develop {{flake_dir}}

# Show system status
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
generations:
    @echo "📋 System Generations"
    @echo "====================="
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
    @echo ""
    @echo "🏠 Home Manager Status"
    @echo "======================"
    systemctl --user status home-manager-me.service --no-pager || echo "Home Manager service not active"

# Show flake info
info:
    @echo "📄 Flake Information"
    @echo "===================="
    nix flake show {{flake_dir}}
    @echo ""
    @echo "📦 Flake Metadata"
    @echo "================="
    nix flake metadata {{flake_dir}}

# Rollback to previous generation
rollback:
    @echo "⏪ Rolling back to previous generation..."
    @echo "⚠️ This will rollback to the previous system generation. Continue? (Ctrl+C to cancel)"
    @read
    sudo nixos-rebuild switch --rollback
    @echo "✅ Rollback complete!"

# Show recent system changes
diff:
    @echo "📈 Recent System Changes"
    @echo "========================"
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -2

# Repair Nix store
repair:
    @echo "🔧 Repairing Nix store..."
    sudo nix-store --verify --check-contents --repair
    @echo "✅ Store repair complete!"

# Show system logs
logs:
    @echo "📜 Recent System Logs"
    @echo "===================="
    journalctl --system --since "1 hour ago" --no-pager

# Monitor system resources
monitor:
    @echo "📊 System Resource Monitor"
    @echo "Press Ctrl+C to exit"
    htop

# Test configuration in VM
vm:
    @echo "🖥️ Building and running configuration in VM..."
    nixos-rebuild build-vm --flake {{flake_dir}}#{{hostname}}
    @echo "VM built successfully! Run ./result/bin/run-nixos-vm to start."

# Build ISO installer
iso:
    @echo "💿 Building NixOS installer ISO..."
    nix build {{flake_dir}}#nixosConfigurations.{{hostname}}.config.system.build.isoImage
    @echo "✅ ISO built successfully!"

# Quick system health check
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
backup:
    @echo "💾 Backing up current configuration..."
    cp -r {{flake_dir}} {{flake_dir}}.backup.$(date +%Y%m%d_%H%M%S)
    @echo "✅ Backup created in {{flake_dir}}.backup.$(date +%Y%m%d_%H%M%S)"

# Show package search
search PACKAGE:
    @echo "🔍 Searching for package: {{PACKAGE}}"
    nix search nixpkgs {{PACKAGE}}

# Show package info
show PACKAGE:
    @echo "📦 Package information for: {{PACKAGE}}"
    nix search nixpkgs#{{PACKAGE}} --json | jq

# Run a package temporarily
run PACKAGE:
    @echo "🏃 Running {{PACKAGE}} temporarily..."
    nix run nixpkgs#{{PACKAGE}}

# Enter shell with package
shell-with PACKAGE:
    @echo "🐚 Entering shell with {{PACKAGE}}..."
    nix shell nixpkgs#{{PACKAGE}}

# Fleet front door: detect this machine and show its provisioning plan.
# Pass extra args through, e.g. `just provision --machine vps` or `--apply`.
# Relative path (not {{justfile_directory()}}): just runs recipes with cwd =
# justfile dir, and on Windows the absolute {{...}} is a backslash path bash
# mangles (C:Users… → not found) — same reason agent-bootstrap stays relative.
provision *ARGS:
    bash provision/provision.sh {{ARGS}}
