#!/usr/bin/env bash
# Bootstrap: symlink this repo's version-controlled Claude config (claude/) into
# the live Claude config dir so the same skills/agents/commands/statusline/
# settings are reused on every machine. Portable baseline for Windows (Git Bash),
# macOS and Linux. On NixOS/nix-darwin the same links are also declared in
# modules/home/claude.nix — either mechanism produces identical symlinks.
#
# The links point straight at the repo working tree, so editing a file in
# ~/.claude (from ANY repo you're working in) edits the tracked file here; commit
# from this repo and pull elsewhere to propagate.
#
# Idempotent. Re-run any time. Usage:
#   bash claude/bootstrap.sh
set -u

# ── Windows Git Bash: make `ln -s` create real native symlinks. Requires either
# Windows Developer Mode ON (Settings → Privacy & security → For developers) or
# running the shell as Administrator; otherwise ln -s fails under nativestrict. ─
IS_WINDOWS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS=winsymlinks:nativestrict
    IS_WINDOWS=1
    ;;
esac

# Repo claude/ dir = the directory this script lives in (absolute).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Backups go OUTSIDE the scanned skills/agents/commands dirs (a *.bak sibling
# inside skills/ would be picked up by Claude as a stray duplicate skill).
BAK_ROOT="$CLAUDE_DIR/.bootstrap-bak"

mkdir -p "$CLAUDE_DIR"

linked=0
skipped=0
backed=0
failed=0

# Move an existing real target into BAK_ROOT, mirroring its path under
# CLAUDE_DIR. If a backup already exists, the repo copy is canonical so we just
# drop the current file. Returns 0 if a fresh backup was made.
backup_target() {
  local dest="$1"
  local rel="${dest#"$CLAUDE_DIR"/}"
  local bak="$BAK_ROOT/$rel"
  if [ -e "$bak" ]; then
    rm -rf "$dest"
    return 1
  fi
  mkdir -p "$(dirname "$bak")"
  mv "$dest" "$bak"
  printf '  ~ backed up: %s -> %s\n' "$dest" "$bak"
  return 0
}

# Restore the most recent backup of dest (used when a symlink attempt fails so we
# never leave the live config missing a file).
restore_target() {
  local dest="$1"
  local rel="${dest#"$CLAUDE_DIR"/}"
  local bak="$BAK_ROOT/$rel"
  [ -e "$bak" ] || return 1
  rm -rf "$dest"
  mv "$bak" "$dest"
  printf '  ↩ restored from backup: %s\n' "$dest"
}

# link <abs-src> <abs-dest>: symlink dest -> src, backing up any real target
# first and restoring it if the symlink can't be created.
link() {
  local src="$1" dest="$2"
  if [ ! -e "$src" ]; then
    printf '  ! missing in repo, skipping: %s\n' "$src"
    return
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      printf '  = already linked: %s\n' "$dest"
      skipped=$((skipped + 1))
      return
    fi
    rm -f "$dest"  # wrong/old symlink target — replace it
  elif [ -e "$dest" ]; then
    backup_target "$dest" && backed=$((backed + 1))
  fi
  if ln -s "$src" "$dest" 2>/dev/null && [ -L "$dest" ]; then
    printf '  + linked: %s -> %s\n' "$dest" "$src"
    linked=$((linked + 1))
  else
    rm -f "$dest" 2>/dev/null  # clean up any partial entry
    restore_target "$dest"
    printf '  ✗ could not create symlink: %s\n' "$dest"
    failed=$((failed + 1))
  fi
}

# link_entries <subdir>: symlink each ENTRY inside claude/<subdir> into
# ~/.claude/<subdir> individually, so machine-local additions coexist.
link_entries() {
  local sub="$1"
  local src_sub="$SRC_DIR/$sub"
  [ -d "$src_sub" ] || return
  mkdir -p "$CLAUDE_DIR/$sub"
  local entry base
  for entry in "$src_sub"/* "$src_sub"/.[!.]*; do
    [ -e "$entry" ] || continue           # no matches → skip the literal glob
    base="$(basename "$entry")"
    [ "$base" = ".gitkeep" ] && continue  # placeholder, not real config
    link "$entry" "$CLAUDE_DIR/$sub/$base"
  done
}

printf 'Bootstrapping Claude config\n  repo:  %s\n  live:  %s\n\n' "$SRC_DIR" "$CLAUDE_DIR"

# Whole-file links.
for f in settings.json statusline-command.sh balance-refresh.py; do
  link "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done

# Entry-by-entry links (each skill subdir / agent file / command).
link_entries skills
link_entries agents
link_entries commands

# Prune empty backup dirs left behind by restores (keeps real backups).
[ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null

printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
  "$linked" "$skipped" "$backed" "$failed"
[ -d "$BAK_ROOT" ] && printf 'Previous real files saved under %s\n' "$BAK_ROOT"

if [ "$failed" -gt 0 ]; then
  printf '\n%s\n' "⚠ Some symlinks could not be created."
  if [ "$IS_WINDOWS" -eq 1 ]; then
    cat <<'EOF'

On Windows, creating symlinks requires elevated rights. Enable ONE of:
  • Developer Mode: Settings → Privacy & security → For developers → Developer Mode = On
  • or run Git Bash "as Administrator"
Then re-run:  bash claude/bootstrap.sh
(Your live config was left intact — originals were restored from backup.)
EOF
  fi
  exit 1
fi
