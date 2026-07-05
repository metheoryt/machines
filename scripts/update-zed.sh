#!/usr/bin/env bash
# Update modules/home/zed-bin.nix to the latest stable Zed release.
#
# Queries the GitHub API for the newest stable (non-prerelease) tag, prefetches
# the x86_64 Linux tarball, and rewrites the `version` + `hash` lines in place.
# Zed tags are v-prefixed (v1.5.4) and the version field is stored without it.
# Invoked automatically by `just update` (and therefore `just upgrade`), but can
# also be run on its own.
#
# Requires: curl, jq, nix (all present in the dev shell / system).
set -euo pipefail

repo="zed-industries/zed"
file="$(cd "$(dirname "$0")" && pwd)/modules/home/zed-bin.nix"

tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
latest=${tag#v}
current=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file" | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest Zed release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ zed already at latest ($current)"
  exit 0
fi

echo "⬆️  zed $current → $latest"
url="https://github.com/${repo}/releases/download/v${latest}/zed-linux-x86_64.tar.gz"
hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')

sed -i -E "s|^([[:space:]]*version = )\"[^\"]+\";|\1\"${latest}\";|" "$file"
sed -i -E "s|^([[:space:]]*hash = )\"sha256-[^\"]+\";|\1\"${hash}\";|" "$file"

echo "✅ zed updated to $latest ($hash)"
