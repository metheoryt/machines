#!/usr/bin/env bash
# Bump provision/gortex.version to the latest gortex release.
#
# Queries the GitHub API for the newest release tag and rewrites the pin. gortex
# tags are v-prefixed (v0.61.4); the pin is stored without it.
#
# THIS SCRIPT WAS BROKEN AND IS NOW FIXED (2026-08-01). It used to rewrite
# `version` + `hash` in pkgs/gortex.nix and needed `nix store prefetch-file` for
# the hash — so once the fleet had no Nix host it could not run anywhere, while
# tier_gortex went on reading a pin that nothing could bump. There is no hash any
# more: tier_gortex installs the release tarball over HTTPS from GitHub and
# verifies nothing, which is the same trust root as the pin itself. Dropping the
# hash loses no check that was actually being made.
#
# Requires: curl, jq. Runs on any platform in the fleet.
set -euo pipefail

repo="zzet/gortex"
file="$(cd "$(dirname "$0")/.." && pwd)/provision/gortex.version"

[ -f "$file" ] || { echo "❌ pin not found: $file" >&2; exit 1; }

tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')
latest=${tag#v}
current=$(grep -vE '^[[:space:]]*#' "$file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [ -z "$latest" ] || [ "$latest" = "null" ]; then
  echo "❌ Could not determine latest gortex release" >&2
  exit 1
fi

if [ "$latest" = "$current" ]; then
  echo "✅ gortex already at latest ($current)"
  exit 0
fi

echo "⬆️  gortex $current → $latest"
# Replace only the bare-semver line, so the file's header survives the bump.
tmp="$(mktemp)"
awk -v v="$latest" '
  /^[[:space:]]*#/ { print; next }
  /[0-9]+\.[0-9]+\.[0-9]+/ && !done { print v; done = 1; next }
  { print }
' "$file" > "$tmp"
mv "$tmp" "$file"

echo "✅ gortex pin updated to $latest"
echo "   Commit + push it: every box picks it up via converge (the pin is a"
echo "   reprovision trigger in scripts/converge.sh's _touches_driver)."
