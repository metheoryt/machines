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

      # Shared memory & per-host file (same sources Claude uses).
      ".codex/memory/global.md".source = link "${agents}/memory/global.md";
      ".codex/memory/personality".source = link "${agents}/memory/personality";
      ".codex/host-memory.md".source = link "${agents}/hosts/${hostname}.md";
    }
    # Shared from agents/: skills + hook scripts. Codex-specific: subagents.
    // linkEntries "skills" agents "plugin/skills" ../../agents/plugin/skills
    // linkEntries "hooks" agents "plugin/hooks" ../../agents/plugin/hooks
    // linkEntries "agents" codex "subagents" ../../agents/codex/subagents;
}
