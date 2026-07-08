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
#
# settings.json is NOT linked via home.file/mkOutOfStoreSymlink like the rest —
# home.file routes every source through the Nix store, so a mkOutOfStoreSymlink
# there ends up as dest -> store-symlink -> store-symlink -> repo file (a
# 3-hop chain, first two hops inside the read-only store). Claude Code's
# settings writer (`/plugin marketplace add`, `/config`, etc.) resolves only
# one level of symlink before writing its `settings.json.tmp.*` beside that
# target — landing inside the immutable store and failing with EROFS. Instead
# settings.json is linked directly by an activation script below: dest -> repo
# file in one hop, always writable. See `agents/bootstrap.sh`'s `link()` for
# the non-Nix machines, which already does a plain one-hop `ln -s`.
{
  config,
  hostname,
  lib,
  ...
}: let
  # Repo agents/ dir on this machine (fish helpers cd to ~/machines, which is the flake).
  agents = "${config.home.homeDirectory}/machines/agents";
  link = config.lib.file.mkOutOfStoreSymlink;

  # Shared (non-settings.json) links for one profile dir (".claude" or ".claude-work").
  profileFiles = profileDir: {
    "${profileDir}/statusline-command.sh".source = link "${agents}/statusline-command.sh";
    "${profileDir}/balance-refresh.py".source = link "${agents}/balance-refresh.py";
    # AGENTS.md is canonical; <profile>/CLAUDE.md links straight to the real file.
    "${profileDir}/CLAUDE.md".source = link "${agents}/AGENTS.md";
    "${profileDir}/memory/global.md".source = link "${agents}/memory/global.md";
    "${profileDir}/memory/personality".source = link "${agents}/memory/personality";
    "${profileDir}/host-memory.md".source = link "${agents}/hosts/${hostname}.md";
    # cyphy plugin: one whole-directory symlink replaces the four per-entry
    # linkEntries calls that used to wire skills/agents/commands/hooks
    # individually — they all live inside agents/plugin/ now, discovered by
    # Claude Code as a skills-directory plugin (cyphy@skills-dir).
    "${profileDir}/skills/cyphy".source = link "${agents}/plugin";
  };
in {
  home.file = profileFiles ".claude" // profileFiles ".claude-work";

  # settings.json committed per-profile: personal -> settings.personal.json,
  # work -> settings.work.json. Direct one-hop symlink (see comment above) —
  # runs after writeBoundary so the profile dirs already exist.
  home.activation.linkClaudeSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "$HOME/.claude" "$HOME/.claude-work"
    $DRY_RUN_CMD ln -sfn "${agents}/settings.personal.json" "$HOME/.claude/settings.json"
    $DRY_RUN_CMD ln -sfn "${agents}/settings.work.json" "$HOME/.claude-work/settings.json"
  '';
}
