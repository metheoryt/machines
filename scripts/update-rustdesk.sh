#!/usr/bin/env bash
# Update modules/home/rustdesk-bin.nix to the latest upstream RustDesk release.
#
# Queries the GitHub API for the newest stable (non-prerelease) tag, prefetches
# the x86_64 Flutter .deb, and rewrites the `version` + `hash` lines in place.
# Invoked automatically by `just update` (and therefore `just upgrade`), but can
# also be run on its own.
#
# Requires: curl, jq, nix (all present in the dev shell / system).
set -euo pipefail

repo="rustdesk/rustdesk"
file="$(cd "$(dirname "$0")" && pwd)/modules/home/rustdesk-bin.nix"

latest=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
current=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file" | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest RustDesk release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ rustdesk already at latest ($current)"
  exit 0
fi

echo "⬆️  rustdesk $current → $latest"
url="https://github.com/${repo}/releases/download/${latest}/rustdesk-${latest}-x86_64.deb"
hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')

sed -i -E "s|^([[:space:]]*version = )\"[^\"]+\";|\1\"${latest}\";|" "$file"
sed -i -E "s|^([[:space:]]*hash = )\"sha256-[^\"]+\";|\1\"${hash}\";|" "$file"

echo "✅ rustdesk updated to $latest ($hash)"
