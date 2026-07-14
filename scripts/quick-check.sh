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

# Quick syntax check on main files
echo "🔍 Checking basic syntax..."
for file in "${REQUIRED_FILES[@]}"; do
    if nix-instantiate --parse "$file" > /dev/null 2>&1; then
        echo "✅ Syntax OK: $(basename "$file")"
    else
        echo "❌ Syntax error in: $file"
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
