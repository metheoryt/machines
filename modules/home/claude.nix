# Claude Code config, version-controlled in this repo under agents/ and linked
# into every Claude profile dir (~/.claude and each ~/.claude-<postfix>). This is
# the nix path for Linux/macOS; Windows/non-Nix machines use agents/bootstrap.sh,
# which produces the identical one-hop symlinks.
#
# PROFILE REGISTRY (dynamic — no hardcoded profile list): the set of profiles is
# driven by the committed settings files. The primary settings.json plus each
# agents/settings.<postfix>.json declares one profile:
#   settings.json            -> ~/.claude
#   settings.<postfix>.json  -> ~/.claude-<postfix>   (e.g. settings.pure.json -> ~/.claude-pure)
# Drop a new settings.<postfix>.json in the repo and the next `just switch`
# provisions ~/.claude-<postfix> with the full shared set — no edit here needed.
# A leftover profile dir with no matching settings file (e.g. a retired
# ~/.claude-work on another machine) is simply ignored, never half-provisioned.
#
# EVERYTHING is linked by the activation script below — NOT home.file /
# mkOutOfStoreSymlink — for two reasons:
#   - one-hop-direct dest -> repo working tree, so editing ~/.claude/<file> from
#     ANY repo edits the tracked file here and takes effect IMMEDIATELY (no
#     nixos-rebuild to iterate); commit here + `git pull` elsewhere to propagate.
#     In particular a memory edit is a plain git-repo write — never needs `switch`.
#   - Claude Code's settings writer (/config, /plugin marketplace add) resolves
#     only one symlink level before writing its settings.json.tmp beside the
#     target; routing settings.json through home.file (i.e. the /nix/store) makes
#     that tmp land in the read-only store and fail with EROFS. A direct one-hop
#     link is always writable. This mirrors bootstrap.sh's plain `ln -s`.
#
# Secrets, transcripts, caches and plugins/ are intentionally NOT linked — they
# stay machine-local per profile (see agents/.gitignore). settings.local.json in
# particular is never linked: machine-local (personal: gortex hooks; work/pure:
# PURE_SENTRY_TOKEN), owned by neither this module nor bootstrap.sh.
{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  # Repo agents/ dir on this machine (fish helpers cd to ~/machines, the flake).
  agents = "${config.home.homeDirectory}/machines/agents";
in {
  # Runs after writeBoundary so home-manager has already removed any prior
  # store-routed symlinks it used to manage under the profile dirs, and $HOME
  # exists. One profile is provisioned per committed settings.<postfix>.json.
  home.activation.linkClaudeProfiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Single deployer: bootstrap.sh is THE implementation of the profile links
    # (shared with Windows/macOS). Call it once per committed settings*.json
    # profile; the personal ~/.claude call also provisions ~/.codex. MACHINES_HOST_ID
    # gives bootstrap the authoritative host id so nix and bash name the per-host
    # memory file identically (no drift). Runs after writeBoundary so home-manager
    # has already GC'd any prior store-routed links before bootstrap recreates them.
    for setsrc in "${agents}"/settings.json "${agents}"/settings.*.json; do
      [ -e "$setsrc" ] || continue
      base="$(basename "$setsrc" .json)"
      if [ "$base" = settings ]; then
        prof="$HOME/.claude"
      else
        prof="$HOME/.claude-''${base#settings.}"
      fi
      PATH="${lib.makeBinPath [pkgs.coreutils pkgs.findutils]}:$PATH" \
      CLAUDE_CONFIG_DIR="$prof" MACHINES_HOST_ID="${hostname}" \
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash "${agents}/bootstrap.sh"
    done
  '';
}
