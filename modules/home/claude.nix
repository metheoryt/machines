# Claude Code config, version-controlled in this repo under agents/ and symlinked
# into both ~/.claude (personal) and ~/.claude-work (work). This is the idiomatic
# nix path for Linux/macOS; Windows uses agents/bootstrap.sh (which produces the
# identical symlinks for both profiles).
#
# mkOutOfStoreSymlink points the live config straight at the repo working tree
# (not a read-only /nix/store copy), so:
#   - editing ~/.claude/<file> (or ~/.claude-work/<file>) from ANY repo edits the
#     tracked file here, and
#   - changes take effect immediately, with no `nixos-rebuild` to iterate.
# Commit from this repo and pull on the other machines to propagate.
#
# The entry-dir links (hooks/skills/agents/commands) are AUTO-DISCOVERED from the
# filesystem via `linkEntries`, mirroring bootstrap.sh's `link_entries_into`. That's
# what keeps this file in sync with bootstrap.sh: adding a hook/skill/agent/
# command needs NO edit here — both mechanisms derive the same set from the repo.
# (readDir reads the flake source, i.e. git-tracked files, so commit a new entry
# for `switch` to pick it up; bootstrap reads the working tree directly.)
#
# Secrets, transcripts, caches and plugins/ are intentionally NOT linked — they
# stay machine-local in ~/.claude / ~/.claude-work (see agents/.gitignore for the
# full list). settings.local.json in particular is deliberately absent from both
# profiles below: it stays machine-local (personal: gortex hooks; work:
# PURE_SENTRY_TOKEN secret), owned by neither this module nor bootstrap.sh.
{
  config,
  osConfig,
  lib,
  ...
}: let
  # Repo agents/ dir on this machine (fish helpers cd to ~/nix, which is the flake).
  agents = "${config.home.homeDirectory}/nix/agents";
  link = config.lib.file.mkOutOfStoreSymlink;

  # Link each entry inside a source subdir into <profileDir>/<targetSub>/ individually.
  # targetSub and srcSub differ only for subagents (source `subagents/`, target the
  # tool-dictated `agents/`). srcDir is the in-tree literal (enumeration only).
  linkEntries = profileDir: targetSub: srcSub: srcDir:
    lib.mapAttrs'
    (name: _:
      lib.nameValuePair "${profileDir}/${targetSub}/${name}" {
        source = link "${agents}/${srcSub}/${name}";
      })
    (lib.filterAttrs (name: _: name != ".gitkeep") (builtins.readDir srcDir));

  # All shared links for one profile dir (".claude" or ".claude-work"),
  # parameterized by which committed settings file becomes settings.json.
  # settings.local.json is intentionally NOT managed here — it stays machine-local
  # (personal: gortex hooks; work: PURE_SENTRY_TOKEN secret), owned by neither
  # this module nor bootstrap.sh.
  profileFiles = profileDir: settingsFile:
    {
      "${profileDir}/settings.json".source = link "${agents}/${settingsFile}";
      "${profileDir}/statusline-command.sh".source = link "${agents}/statusline-command.sh";
      "${profileDir}/balance-refresh.py".source = link "${agents}/balance-refresh.py";
      # AGENTS.md is canonical; <profile>/CLAUDE.md links straight to the real file.
      "${profileDir}/CLAUDE.md".source = link "${agents}/AGENTS.md";
      "${profileDir}/memory/global.md".source = link "${agents}/memory/global.md";
      "${profileDir}/memory/practices.md".source = link "${agents}/memory/practices.md";
      "${profileDir}/host-memory.md".source = link "${agents}/hosts/${osConfig.networking.hostName}.md";
    }
    // linkEntries profileDir "hooks" "hooks" ../../agents/hooks
    // linkEntries profileDir "skills" "skills" ../../agents/skills
    // linkEntries profileDir "agents" "subagents" ../../agents/subagents
    // linkEntries profileDir "commands" "commands" ../../agents/commands;
in {
  home.file =
    profileFiles ".claude" "settings.personal.json"
    // profileFiles ".claude-work" "settings.work.json";
}
