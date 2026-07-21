#!/usr/bin/env bash
# Update modules/home/orca-bin.nix to the latest Orca release.
#
# Queries the GitHub API for the newest stable (non-prerelease) tag, prefetches
# the x86_64 Linux AppImage, and rewrites the `version` + `hash` lines in place.
# Orca tags are v-prefixed (v1.4.148) and the version field is stored without it.
# Invoked automatically by `just update` (and therefore `just upgrade`), but can
# also be run on its own.
#
# Requires: curl, jq, nix (all present in the dev shell / system).
set -euo pipefail

repo="stablyai/orca"
file="$(cd "$(dirname "$0")/.." && pwd)/modules/home/orca-bin.nix"

tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
latest=${tag#v}
current=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file" | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest Orca release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ orca already at latest ($current)"
  exit 0
fi

echo "⬆️  orca $current → $latest"
url="https://github.com/${repo}/releases/download/v${latest}/orca-linux.AppImage"
hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')

sed -i -E "s|^([[:space:]]*version = )\"[^\"]+\";|\1\"${latest}\";|" "$file"
sed -i -E "s|^([[:space:]]*hash = )\"sha256-[^\"]+\";|\1\"${hash}\";|" "$file"

echo "✅ orca updated to $latest ($hash)"
