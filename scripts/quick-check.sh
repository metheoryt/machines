#!/usr/bin/env bash

# Quick NixOS Configuration Check
# Simple validation script for basic configuration health

set -e

echo "🔍 Quick Configuration Check"
echo "============================="

# Check if we're in a NixOS flake directory
if [ ! -f "flake.nix" ]; then
    echo "❌ No flake.nix found in current directory"
    exit 1
fi

echo "✅ Found flake.nix"

# Check if required configuration files exist
REQUIRED_FILES=(
    "hosts/latitude/nixos/configuration.nix"
    "hosts/latitude/nixos/hardware-configuration.nix"
    "modules/home/me.nix"
)

echo "📁 Checking required files..."
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $file exists"
    else
        echo "❌ Missing: $file"
        exit 1
    fi
done

# ── Nix-dependent gates ───────────────────────────────────────────────────────
# Gate on the binary FIRST. Every check below sent stderr to /dev/null, so on a
# box without nix a MISSING BINARY was indistinguishable from a real parse error
# and this script reported "❌ Syntax error in: <file>" for every .nix file it
# was handed. Most of the fleet is now non-Nix (air/macOS, desktop + server on
# Windows, hub on Debian), so that false failure was the normal outcome, not an
# edge case.
if ! command -v nix-instantiate > /dev/null 2>&1 || ! command -v nix > /dev/null 2>&1; then
    echo ""
    echo "⏭  SKIPPED: the Nix gates (parse, flake check, dry-run build)."
    echo "   No nix on this box, so they cannot run here — this is NOT a failure."
    echo "   Run them on a NixOS fleet member after pushing:"
    echo "     ssh latitude 'cd ~/machines && git pull --ff-only && just quick'"
    echo ""
    echo "🎉 Non-Nix checks passed (required files present)."
    exit 0
fi

# Quick syntax check on main files
echo "🔍 Checking basic syntax..."
for file in "${REQUIRED_FILES[@]}"; do
    # Keep stderr: a parse error should say WHAT is wrong, not just that it is.
    if err="$(nix-instantiate --parse "$file" 2>&1 >/dev/null)"; then
        echo "✅ Syntax OK: $(basename "$file")"
    else
        echo "❌ Syntax error in: $file"
        printf '%s\n' "$err" | head -5
        exit 1
    fi
done

# Try to evaluate the flake
echo "🧪 Testing flake evaluation..."
if nix flake check --no-build > /dev/null 2>&1; then
    echo "✅ Flake checks passed"
else
    echo "⚠️  Flake has warnings (may still work)"
fi

# Check if we can build the configuration (dry-run)
echo "🔨 Testing configuration build..."
if nix build --dry-run ".#nixosConfigurations.latitude.config.system.build.toplevel" > /dev/null 2>&1; then
    echo "✅ Configuration can be built"
else
    echo "❌ Configuration build would fail"
    echo "Run 'nix flake check' for detailed errors"
    exit 1
fi

echo ""
echo "🎉 Basic configuration check passed!"
echo "Configuration appears ready for building."
echo ""
echo "Next steps:"
echo "  just build    - Build the configuration"
echo "  just test     - Test configuration temporarily"
echo "  just switch   - Apply configuration permanently"
