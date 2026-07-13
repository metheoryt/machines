# Codex config, version-controlled in this repo and symlinked into ~/.codex.
# Codex is Claude-Code-compatible, so it SHARES the tool-agnostic content
# (memory, hook scripts, skills) from agents/ — single source of truth. Only the
# format-divergent files live in agents/codex/ (hooks.json, subagents/*.toml). The
# global instruction file is agents/AGENTS.md (the canonical real file;
# ~/.claude/CLAUDE.md is a symlink to it). config.toml / auth / sessions stay
# machine-local and are NOT linked (see agents/codex/.gitignore). Windows uses
# agents/bootstrap.sh, which produces the identical links.
{
  config,
  hostname,
  lib,
  ...
}: let
  agents = "${config.home.homeDirectory}/machines/agents";
  codex = "${agents}/codex";
  link = config.lib.file.mkOutOfStoreSymlink;

  # targetSub = ~/.codex/<targetSub>/; srcBase/srcSub = source location under the repo.
  linkEntries = targetSub: srcBase: srcSub: srcDir:
    lib.mapAttrs'
    (name: _:
      lib.nameValuePair ".codex/${targetSub}/${name}" {
        source = link "${srcBase}/${srcSub}/${name}";
      })
    (lib.filterAttrs (name: _: name != ".gitkeep" && name != "hooks.json") (builtins.readDir srcDir));
in {
  home.file =
    {
      # Instruction file: Codex reads AGENTS.md; point at the canonical real file.
      ".codex/AGENTS.md".source = link "${agents}/AGENTS.md";

      # Codex-specific standalone hooks file.
      ".codex/hooks.json".source = link "${codex}/hooks.json";

      # Memory & per-host file (same sources Claude uses) are NOT linked here —
      # they're the frequently-edited files, linked one-hop-direct by the
      # activation script below so they stay OUT of the home-manager generation
      # and an edit is visibly just a git-repo write. Mirrors claude.nix.
    }
    # Shared from agents/: skills + hook scripts. Codex-specific: subagents.
    // linkEntries "skills" agents "plugin/skills" ../../agents/plugin/skills
    // linkEntries "hooks" agents "plugin/hooks" ../../agents/plugin/hooks
    // linkEntries "agents" codex "subagents" ../../agents/codex/subagents;

  # Direct one-hop symlinks for the mutable memory stores (see claude.nix for
  # the rationale). Runs after writeBoundary so home-manager has already removed
  # any prior store-routed memory symlinks.
  home.activation.linkCodexMemory = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "$HOME/.codex/memory"
    $DRY_RUN_CMD ln -sfn "${agents}/memory/global.md" "$HOME/.codex/memory/global.md"
    $DRY_RUN_CMD ln -sfn "${agents}/memory/personality" "$HOME/.codex/memory/personality"
    $DRY_RUN_CMD ln -sfn "${agents}/hosts/${hostname}.md" "$HOME/.codex/host-memory.md"
  '';
}
