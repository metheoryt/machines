#!/usr/bin/env bash
# Bootstrap: symlink this repo's version-controlled agent config (agents/) into
# the live Claude config dir so the same skills/agents/commands/statusline/
# settings are reused on every machine. Portable baseline for Windows (Git Bash),
# macOS and Linux. On NixOS/nix-darwin the same links are also declared in
# modules/home/claude.nix — either mechanism produces identical symlinks.
#
# It also brings up gortex (code-intelligence MCP server): installs the binary on
# Windows if missing (NixOS gets it declaratively via pkgs/gortex.nix) and runs
# the machine-local `gortex install --no-claude-md` wiring. See the "Gortex"
# section below.
#
# The links point straight at the repo working tree, so editing a file in
# ~/.claude (from ANY repo you're working in) edits the tracked file here; commit
# from this repo and pull elsewhere to propagate.
#
# Idempotent. Re-run any time. Usage:
#   bash agents/bootstrap.sh
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

# Repo agents/ dir = the directory this script lives in (absolute).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Backups go OUTSIDE the scanned skills/agents/commands dirs (a *.bak sibling
# inside skills/ would be picked up by Claude as a stray duplicate skill).
BAK_ROOT="$CLAUDE_DIR/.bootstrap-bak"

[ -n "${DRY_RUN:-}" ] || mkdir -p "$CLAUDE_DIR"

# Each profile gets the SHARED set + a committed per-profile settings.json,
# chosen by convention from the profile dir's name:
#   ~/.claude            -> settings.json
#   ~/.claude-<postfix>  -> settings.<postfix>.json   (e.g. ~/.claude-pure -> settings.pure.json)
# Codex rides with the personal run (~/.claude) only. The machine-local
# settings.local.json is never touched by any profile.
_resolve() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
CLAUDE_BASE="$(basename "$CLAUDE_DIR")"
case "$CLAUDE_BASE" in
  .claude-*) POSTFIX="${CLAUDE_BASE#.claude-}" ;;
  *)         POSTFIX=default ;;
esac
if [ "$(_resolve "$CLAUDE_DIR")" = "$(_resolve "$HOME/.claude")" ]; then
  IS_PERSONAL=1
else
  IS_PERSONAL=0
  printf 'Secondary profile "%s" — SHARED set + settings.%s.json (Codex skipped, settings.local.json untouched)\n\n' "$CLAUDE_BASE" "$POSTFIX"
fi

linked=0
skipped=0
backed=0
failed=0
would_link=0
would_backup=0

# In DRY_RUN, create no directories (detection below tolerates missing dirs).
_mkdir() { [ -n "${DRY_RUN:-}" ] || mkdir -p "$@"; }

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
# first and restoring it if the symlink can't be created. In DRY_RUN, detect
# and report what WOULD happen without touching anything.
link() {
  local src="$1" dest="$2"
  if [ ! -e "$src" ]; then
    printf '  ! missing in repo, skipping: %s\n' "$src"
    return
  fi
  # Already pointing at the repo file (possibly via a home-manager chain) — skip.
  if [ "$dest" -ef "$src" ]; then
    printf '  = already linked: %s\n' "$dest"
    skipped=$((skipped + 1))
    return
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      printf '  = already linked: %s\n' "$dest"
      skipped=$((skipped + 1))
      return
    fi
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would relink: %s -> %s\n' "$dest" "$src"
      would_link=$((would_link + 1))
      return
    fi
    rm -f "$dest"  # wrong/old symlink target — replace it
  elif [ -e "$dest" ]; then
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would back up + link: %s -> %s\n' "$dest" "$src"
      would_backup=$((would_backup + 1))
      would_link=$((would_link + 1))
      return
    fi
    backup_target "$dest" && backed=$((backed + 1))
  else
    if [ -n "${DRY_RUN:-}" ]; then
      printf '  ~ would link: %s -> %s\n' "$dest" "$src"
      would_link=$((would_link + 1))
      return
    fi
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

# hash_file <path>: content hash for change-detection. sha256 preferred; cksum
# fallback keeps it working on a stripped Windows Git Bash without coreutils sha.
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else cksum "$1" | cut -d' ' -f1; fi
}

# copy_managed <abs-src> <abs-dest>: maintain dest as a REAL FILE seeded from the
# committed src — deliberately NOT a symlink. A tool that writes through the live
# config (Orca injecting its agent-hooks block into settings.json / codex hooks.json)
# then mutates only this local copy, never the tracked repo file — so the working
# tree never dirties and convergence's clean-tree gate never jams. The tracked
# file stays the deliberate shared baseline; changes to it are explicit commits.
#
# Propagation without churn: a sibling .<name>.srchash stamp records the hash of
# the committed src at the last seed. Re-copy ONLY when (a) dest is missing or is
# still a symlink (first migration off the old link), or (b) the committed src
# changed since the last seed (a pull / provisioning brought new baseline). Between
# committed changes the live copy — including any tool injection — is left
# untouched, so a running tool's hooks survive bootstrap runs (the tool re-injects
# on launch, not on file change; an unconditional overwrite would silently disable
# them mid-session). Re-seed fires from provisioning (post-merge hook, linux.sh /
# windows.ps1, nixos switch) — never from the per-worktree setup script, which
# operates a layer below this machine-global profile file.
copy_managed() {
  local src="$1" dest="$2" stamp srchash
  if [ ! -e "$src" ]; then
    printf '  ! missing in repo, skipping: %s\n' "$src"
    return
  fi
  stamp="$(dirname "$dest")/.$(basename "$dest").srchash"
  srchash="$(hash_file "$src")"
  if [ -f "$dest" ] && [ ! -L "$dest" ] \
     && [ "$(cat "$stamp" 2>/dev/null)" = "$srchash" ]; then
    printf '  = already synced (local edits kept): %s\n' "$dest"
    skipped=$((skipped + 1))
    return
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would sync (real copy): %s -> %s\n' "$dest" "$src"
    would_link=$((would_link + 1))
    return
  fi
  # A symlink carries no content (the baseline lives in the repo) — just drop it.
  # A real file with NO stamp was never managed by us (hand-authored, or a pre-fix
  # copy): back it up first, matching link()'s safety. A real file WITH a stamp is
  # our own copy being re-seeded (baseline changed) — clobber it without cluttering
  # the backup tree. backup_target moves it aside, so the rm below is a no-op then.
  if [ -e "$dest" ] && [ ! -L "$dest" ] && [ ! -f "$stamp" ]; then
    backup_target "$dest" && backed=$((backed + 1))
  fi
  rm -f "$dest"                       # drop the old symlink (or leftover)
  mkdir -p "$(dirname "$dest")"
  if cp "$src" "$dest" 2>/dev/null; then
    printf '%s\n' "$srchash" > "$stamp" 2>/dev/null || true
    printf '  + synced (real copy): %s -> %s\n' "$dest" "$src"
    linked=$((linked + 1))
  else
    printf '  ✗ could not copy: %s\n' "$dest"
    failed=$((failed + 1))
  fi
}

# host_id: this machine's hostname, sanitized to a filename. Prefers Windows
# COMPUTERNAME (ME-G614JV), else `hostname` (g16 / latitude5520 on the nix
# laptops). This is only the off-nix fallback: on NixOS, claude.nix passes the
# authoritative host id via the MACHINES_HOST_ID env var (the `hostname`
# specialArg == networking.hostName), consumed below as
# "${MACHINES_HOST_ID:-$(host_id)}" — single source of host-naming, also used
# by balance-refresh.py's device id.
host_id() {
  local h="${COMPUTERNAME:-$(hostname 2>/dev/null)}"
  h="${h%%.*}"                                   # strip any DNS suffix
  printf '%s' "$h" | tr -c 'A-Za-z0-9_-' '_'
}

# link_entries_into <abs-src-sub> <abs-dest-sub>: symlink each ENTRY inside the
# source subdir into the dest subdir individually, so machine-local additions
# coexist with tracked ones.
link_entries_into() {
  local src_sub="$1" dest_sub="$2"
  [ -d "$src_sub" ] || return
  _mkdir "$dest_sub"
  local entry base
  for entry in "$src_sub"/* "$src_sub"/.[!.]*; do
    [ -e "$entry" ] || continue           # no matches → skip the literal glob
    base="$(basename "$entry")"
    [ "$base" = ".gitkeep" ] && continue   # placeholder, not real config
    [ "$base" = "hooks.json" ] && continue # cyphy plugin manifest, not a Codex hook
    [ "$base" = "tests" ] && continue      # hook test scripts, not runtime hooks
    link "$entry" "$dest_sub/$base"
  done
}

# Lib-only mode: `BOOTSTRAP_LIB_ONLY=1 . bootstrap.sh` loads the helper functions
# (link / copy_managed / hash_file / …) without running the profile bootstrap —
# used by tests/bootstrap.test.sh to exercise copy_managed in isolation.
if [ -n "${BOOTSTRAP_LIB_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

printf 'Bootstrapping Claude config\n  repo:  %s\n  live:  %s\n\n' "$SRC_DIR" "$CLAUDE_DIR"

# Shared whole-file links (every profile).
for f in statusline-command.sh balance-refresh.py; do
  link "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
# settings.json is committed per-profile, chosen by convention (see the POSTFIX
# block above): ~/.claude -> settings.json, ~/.claude-<postfix> ->
# settings.<postfix>.json. Falls back to the primary settings.json if the
# profile's own file isn't committed. The machine-local settings.local.json
# (personal: gortex hooks + gortex permission allow; pure: PURE_SENTRY_TOKEN
# secret) is never linked — it stays local and Claude merges it over settings.json.
#
# copy_managed, NOT link: Orca injects its agent-hooks block into the live
# settings.json, and Claude itself writes it (/plugin, /config). As a symlink both
# land in the tracked repo file and jam convergence. A real copy keeps those writes
# machine-local; the tracked baseline changes only by deliberate commit, re-seeded
# here when it changes. See copy_managed's header for the churn-free stamp logic.
if [ "$POSTFIX" = default ]; then
  settings_src="$SRC_DIR/settings.json"
else
  settings_src="$SRC_DIR/settings.$POSTFIX.json"
  [ -e "$settings_src" ] || settings_src="$SRC_DIR/settings.json"
fi
copy_managed "$settings_src" "$CLAUDE_DIR/settings.json"

# Memory & knowledge base. Global instructions + global memory store are shared
# across all machines; the per-host file is chosen by hostname (imported by
# CLAUDE.md as host-memory.md). All are git-tracked and loaded into every
# session — see README.md "Memory & knowledge base".
# Instruction file: AGENTS.md is canonical; link ~/.claude/CLAUDE.md to it directly.
link "$SRC_DIR/AGENTS.md" "$CLAUDE_DIR/CLAUDE.md"
_mkdir "$CLAUDE_DIR/memory"
link "$SRC_DIR/memory/global.md" "$CLAUDE_DIR/memory/global.md"
link "$SRC_DIR/memory/personality" "$CLAUDE_DIR/memory/personality"

# Per-host memory: link agents/hosts/<host>.md -> ~/.claude/host-memory.md. Seed
# an empty stub in the repo the first time a new host runs this, so the import
# never dangles (commit it to start recording host-scoped memory there).
# Host id: nix passes the authoritative hostname via MACHINES_HOST_ID (so nix and
# bootstrap name the per-host memory file identically). Off-nix, fall back to the
# sanitized OS hostname. Single source of host-naming — see host_id().
HOST_ID="${MACHINES_HOST_ID:-$(host_id)}"
host_src="$SRC_DIR/hosts/$HOST_ID.md"
if [ ! -e "$host_src" ]; then
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would seed host memory stub: %s\n' "$host_src"
  else
    mkdir -p "$SRC_DIR/hosts"
    {
      printf '# Host: %s\n\n' "$HOST_ID"
      printf '<!--\nPer-host memory + instructions for this machine. Symlinked to\n'
      # shellcheck disable=SC2088  # literal tilde: this is documentation text, not a path to expand
      printf '~/.claude/host-memory.md and imported by ~/.claude/CLAUDE.md, so it loads ONLY\n'
      printf 'when the hostname matches. Tracked in git, synced everywhere, inert on other\n'
      printf 'hosts. Do NOT put secrets here.\n-->\n\n## Notes\n'
    } > "$host_src"
    printf '  + seeded host memory stub: %s\n' "$host_src"
  fi
fi
if [ -n "${DRY_RUN:-}" ] && [ ! -e "$host_src" ]; then
  printf '  ~ would link: %s -> (seeded stub)\n' "$CLAUDE_DIR/host-memory.md"
  would_link=$((would_link + 1))
else
  link "$host_src" "$CLAUDE_DIR/host-memory.md"
fi

# cyphy plugin: one whole-directory symlink replaces the four entry-by-entry
# loops above. skills/agents/commands/hooks all live inside agents/plugin/ now,
# discovered by Claude Code as a skills-directory plugin (cyphy@skills-dir) —
# live, in place, no copy-to-cache, no install/update step.
_mkdir "$CLAUDE_DIR/skills"
link "$SRC_DIR/plugin" "$CLAUDE_DIR/skills/cyphy"

# My own subagents: per-file links so machine-local agents AND the
# gortex-rendered gortex-*.md all coexist in ~/.claude/agents/.
link_entries_into "$SRC_DIR/subagents" "$CLAUDE_DIR/agents"

# ── Codex config (~/.codex) — rides with the personal run only ───────────────
if [ "$IS_PERSONAL" -eq 1 ]; then
  CODEX_SRC="$SRC_DIR/codex"
  CODEX_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
  _mkdir "$CODEX_DIR"
  printf '\nBootstrapping Codex config\n  live:  %s\n\n' "$CODEX_DIR"

  link "$SRC_DIR/AGENTS.md" "$CODEX_DIR/AGENTS.md"

  _mkdir "$CODEX_DIR/memory"
  link "$SRC_DIR/memory/global.md"    "$CODEX_DIR/memory/global.md"
  link "$SRC_DIR/memory/personality" "$CODEX_DIR/memory/personality"
  link "$host_src"                    "$CODEX_DIR/host-memory.md"

  # copy_managed, NOT link: Orca injects its agent-hooks block into the live
  # hooks.json; a symlink would dirty the tracked repo file. Codex never
  # self-writes it, so the copy has no propagation cost beyond baseline edits.
  copy_managed "$CODEX_SRC/hooks.json" "$CODEX_DIR/hooks.json"

  link_entries_into "$SRC_DIR/plugin/skills" "$CODEX_DIR/skills"
  link_entries_into "$SRC_DIR/plugin/hooks"  "$CODEX_DIR/hooks"
  link_entries_into "$CODEX_SRC/subagents"   "$CODEX_DIR/agents"
fi

# ── gortex: code-intelligence engine / MCP server ────────────────────────────
# Two concerns, split by platform (see docs/superpowers/specs/2026-07-20-gortex-
# bootstrap-wiring-design.md):
#   binary — NixOS gets it declaratively (pkgs/gortex.nix + development.nix);
#            Windows installs it here if missing. Other off-nix platforms are
#            left to the user (no automated installer wired for them yet).
#   wiring — `gortex install --no-claude-md` regenerates the machine-local
#            skills/agents/hooks + user MCP config for the profile being
#            provisioned. --no-claude-md is LOAD-BEARING: it keeps gortex's rule
#            block OUT of the shared, git-tracked agents/AGENTS.md (reached via
#            the ~/.claude/CLAUDE.md symlink), so bootstrap never mutates the
#            fleet-synced instruction file. Generated artefacts stay machine-local
#            and are never committed (see commit 4a4ec52). The daemon is NOT
#            started here — `gortex mcp` (from .mcp.json) brings it up per session.

# Resolve the gortex binary: PATH first, then the known Windows install dir (the
# PS installer's user-PATH edit isn't visible to the already-running shell).
gortex_bin() {
  if command -v gortex >/dev/null 2>&1; then command -v gortex; return 0; fi
  local win="${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/gortex/gortex.exe"
  [ -x "$win" ] && { printf '%s' "$win"; return 0; }
  return 1
}

# Windows only: install the binary if missing. Install-if-missing (never on every
# run) so a plain `git pull`-triggered bootstrap doesn't re-download. Upgrades:
# re-run the installer by hand — it floats to latest.
ensure_gortex_binary() {
  [ "$IS_WINDOWS" -eq 1 ] || return 0   # NixOS/macOS/other-Linux: not installed here
  gortex_bin >/dev/null 2>&1 && { printf '  = gortex binary present\n'; return 0; }
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would install gortex (PowerShell installer)\n'; return 0
  fi
  printf '  + installing gortex (PowerShell installer)…\n'
  powershell.exe -NoProfile -Command "irm https://get.gortex.dev/install.ps1 | iex" \
    || printf '  ✗ gortex install failed — run manually: irm https://get.gortex.dev/install.ps1 | iex\n'
}

# All platforms except nix activation: regenerate machine-local wiring for the
# profile in $CLAUDE_DIR. Idempotent — skips a profile already wired unless
# GORTEX_REWIRE=1 forces a refresh (e.g. after a binary upgrade).
ensure_gortex_wired() {
  # nix activation also runs bootstrap.sh; keep that fast/offline. On NixOS the
  # wiring runs from a login shell via `just gortex-setup` (GORTEX_ALLOW_NIX_WIRE
  # overrides the skip if ever needed).
  if [ -e /etc/NIXOS ] && [ -z "${GORTEX_ALLOW_NIX_WIRE:-}" ]; then
    printf '  = skipping gortex wiring under NixOS (run: just gortex-setup)\n'; return 0
  fi
  local gx; gx="$(gortex_bin)" || { printf '  ! gortex not installed — skipping wiring\n'; return 0; }
  # Marker: gortex hooks land in this profile's settings.local.json (default
  # posture installs hooks). Cheap, robust across gortex versions.
  if [ -z "${GORTEX_REWIRE:-}" ] && grep -q gortex "$CLAUDE_DIR/settings.local.json" 2>/dev/null; then
    printf '  = gortex already wired: %s (GORTEX_REWIRE=1 to refresh)\n' "$CLAUDE_DIR"; return 0
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would wire gortex: %s install --yes --agents claude-code --no-claude-md (%s)\n' "$gx" "$CLAUDE_DIR"
    return 0
  fi
  printf '  + wiring gortex for %s…\n' "$CLAUDE_DIR"
  "$gx" install --yes --agents claude-code --no-claude-md --claude-config-dir "$CLAUDE_DIR" \
    || printf '  ✗ gortex install failed for %s\n' "$CLAUDE_DIR"
}

printf '\nGortex\n'
ensure_gortex_binary
ensure_gortex_wired

# Auto-refresh: point this clone's git hooks at agents/git-hooks so future pulls
# (merge / rebase / checkout) re-link without a manual bootstrap run. core.hooksPath
# is LOCAL (per-clone) config, so this only affects this checkout. Skipped on NixOS,
# where `nixos-rebuild switch` owns the links — the hooks no-op there anyway.
install_git_hooks() {
  [ -e /etc/NIXOS ] && return 0
  command -v git >/dev/null 2>&1 || return 0
  local repo hp cur
  repo="$(git -C "$SRC_DIR" rev-parse --show-toplevel 2>/dev/null)" || return 0
  hp="$SRC_DIR/git-hooks"
  [ -d "$hp" ] || return 0
  cur="$(git -C "$repo" config --local --get core.hooksPath 2>/dev/null || true)"
  if [ "$cur" = "$hp" ]; then
    printf '  = git hooks already installed (core.hooksPath)\n'
  elif [ -n "$cur" ]; then
    # Respect a hooksPath the user set themselves — don't clobber it.
    printf '  ! core.hooksPath already set to %s — leaving it; auto-refresh not installed\n' "$cur"
  elif [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would install git hooks (core.hooksPath -> %s)\n' "$hp"
  else
    git -C "$repo" config --local core.hooksPath "$hp" \
      && printf '  + git hooks installed (core.hooksPath -> %s)\n' "$hp"
  fi
}
install_git_hooks

# Prune empty backup dirs left behind by restores (keeps real backups).
[ -z "${DRY_RUN:-}" ] && [ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null

if [ -n "${DRY_RUN:-}" ]; then
  printf '\n(dry-run) would-link=%d  would-back-up=%d  already-linked=%d\n' \
    "$would_link" "$would_backup" "$skipped"
else
  printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
    "$linked" "$skipped" "$backed" "$failed"
fi
[ -d "$BAK_ROOT" ] && printf 'Previous real files saved under %s\n' "$BAK_ROOT"

if [ "$failed" -gt 0 ]; then
  printf '\n%s\n' "⚠ Some symlinks could not be created."
  if [ "$IS_WINDOWS" -eq 1 ]; then
    cat <<'EOF'

On Windows, creating symlinks requires elevated rights. Enable ONE of:
  • Developer Mode: Settings → Privacy & security → For developers → Developer Mode = On
  • or run Git Bash "as Administrator"
Then re-run:  bash agents/bootstrap.sh
(Your live config was left intact — originals were restored from backup.)
EOF
  fi
  exit 1
fi
