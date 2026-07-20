#!/usr/bin/env bash
# Update pkgs/gortex.nix to the latest gortex release.
#
# Queries the GitHub API for the newest release tag, prefetches the x86_64 Linux
# tarball, and rewrites the `version` + `hash` lines in place. gortex tags are
# v-prefixed (v0.60.0) and the version field is stored without it. This is the
# NixOS half of the "float" story: the Windows boxes float via the upstream
# installer, while latitude pins here and bumps with this script.
# Invoked automatically by `just update` (and therefore `just upgrade`), but can
# also be run on its own. Nix-only (needs `nix store prefetch-file`) — run it on
# the NixOS box, never on the Windows fleet members.
#
# Requires: curl, jq, nix (all present in the dev shell / system).
set -euo pipefail

repo="zzet/gortex"
file="$(cd "$(dirname "$0")/.." && pwd)/pkgs/gortex.nix"

tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
latest=${tag#v}
current=$(sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$file" | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest gortex release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ gortex already at latest ($current)"
  exit 0
fi

echo "⬆️  gortex $current → $latest"
url="https://github.com/${repo}/releases/download/v${latest}/gortex_linux_amd64.tar.gz"
hash=$(nix store prefetch-file --json "$url" | jq -r '.hash')

sed -i -E "s|^([[:space:]]*version = )\"[^\"]+\";|\1\"${latest}\";|" "$file"
sed -i -E "s|^([[:space:]]*hash = )\"sha256-[^\"]+\";|\1\"${hash}\";|" "$file"

echo "✅ gortex updated to $latest ($hash)"
