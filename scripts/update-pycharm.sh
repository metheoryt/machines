#!/usr/bin/env bash
# Update modules/home/pycharm-bin.nix to the latest upstream PyCharm release.
#
# Queries the JetBrains release API for the newest PyCharm (PCP) release,
# prefetches the x86_64 Linux tarball, and rewrites the `version` + `hash` lines
# in place. Invoked automatically by `just update` (and therefore `just
# upgrade`), but can also be run on its own.
#
# Requires: curl, jq, nix (all present in the dev shell / system).
set -euo pipefail

file="$(cd "$(dirname "$0")" && pwd)/modules/home/pycharm-bin.nix"
api="https://data.services.jetbrains.com/products/releases?code=PCP&latest=true&type=release"

latest=$(curl -fsSL "$api" | jq -r '.PCP[0].version')
current=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file" | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest PyCharm release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ pycharm already at latest ($current)"
  exit 0
fi

echo "⬆️  pycharm $current → $latest"
url="https://download.jetbrains.com/python/pycharm-${latest}.tar.gz"
hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')

sed -i -E "s|^([[:space:]]*version = )\"[^\"]+\";|\1\"${latest}\";|" "$file"
sed -i -E "s|^([[:space:]]*hash = )\"sha256-[^\"]+\";|\1\"${hash}\";|" "$file"

echo "✅ pycharm updated to $latest ($hash)"
