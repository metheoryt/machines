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
# hooks/skills/agents/commands are packaged as the "cyphy" Claude Code
# skills-directory plugin (agents/plugin/), linked whole into
# <profileDir>/skills/cyphy — mirroring bootstrap.sh's single `link` call for
# the same directory. Adding a hook/skill/agent/command needs NO edit here or
# in bootstrap.sh: both just link the directory, Claude Code discovers its
# contents at load time.
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
  # Repo agents/ dir on this machine (fish helpers cd to ~/machines, which is the flake).
  agents = "${config.home.homeDirectory}/machines/agents";
  link = config.lib.file.mkOutOfStoreSymlink;

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
      # cyphy plugin: one whole-directory symlink replaces the four per-entry
      # linkEntries calls that used to wire skills/agents/commands/hooks
      # individually — they all live inside agents/plugin/ now, discovered by
      # Claude Code as a skills-directory plugin (cyphy@skills-dir).
      "${profileDir}/skills/cyphy".source = link "${agents}/plugin";
    };
in {
  home.file =
    profileFiles ".claude" "settings.personal.json"
    // profileFiles ".claude-work" "settings.work.json";
}
