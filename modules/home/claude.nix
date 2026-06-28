# Claude Code config, version-controlled in this repo under claude/ and symlinked
# into ~/.claude. This is the idiomatic nix path for Linux/macOS; Windows uses
# claude/bootstrap.sh (which produces the identical symlinks). Keep the two in
# sync — same set of links, same entry-by-entry granularity.
#
# mkOutOfStoreSymlink points the live config straight at the repo working tree
# (not a read-only /nix/store copy), so:
#   - editing ~/.claude/<file> from ANY repo edits the tracked file here, and
#   - changes take effect immediately, with no `nixos-rebuild` to iterate.
# Commit from this repo and pull on the other machines to propagate.
#
# Secrets, transcripts, caches and plugins/ are intentionally NOT linked — they
# stay machine-local in ~/.claude (see claude/.gitignore for the full list).
{ config, ... }:
let
  # Repo checkout location on this machine. The fish helpers cd to ~/nix, so the
  # flake lives there. Change this if you clone the repo elsewhere.
  claude = "${config.home.homeDirectory}/nix/claude";
  link = config.lib.file.mkOutOfStoreSymlink;
in
{
  # Whole-file links.
  home.file.".claude/settings.json".source = link "${claude}/settings.json";
  home.file.".claude/statusline-command.sh".source = link "${claude}/statusline-command.sh";
  home.file.".claude/balance-refresh.py".source = link "${claude}/balance-refresh.py";

  # Entry-by-entry (not the whole dir) so machine-local skills/agents added
  # directly in ~/.claude keep working alongside the tracked ones.
  home.file.".claude/skills/update-balance".source = link "${claude}/skills/update-balance";
  home.file.".claude/agents/quick-tasks.md".source = link "${claude}/agents/quick-tasks.md";

  # commands/ is currently empty (only a .gitkeep in the repo); add per-command
  # links here as you create them, e.g.:
  #   home.file.".claude/commands/foo.md".source = link "${claude}/commands/foo.md";
}
