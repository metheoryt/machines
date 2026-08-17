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

# ── Refuse to link the live profile at a throwaway copy of this repo ──────────
# Every link below points straight at $SRC_DIR, so bootstrapping from a COPY of
# the repo gives the live config dir a set of symlinks whose targets vanish when
# that copy does. Claude Code then fails the statusline command silently and the
# dotfiles-owned memory files read as deleted — the symptom looks nothing like
# the cause. Observed on air 2026-07-28: an agent session snapshotted agents/
# into its own scratchpad, ran this script from there, and five ~/.claude paths
# (statusline-command.sh, balance-refresh.py, CLAUDE.md, host-memory.md,
# memory/global.md) plus the memory/personality DIRECTORY were left dangling at
# /private/tmp/…/scratchpad/pre/agents/. Only the dotfiles-sync commit debounce
# kept four personality-facet deletions from being committed and pushed.
#
# Two shapes are refused: a temp-dir copy, and a linked git worktree (where a
# worktree agent would otherwise repoint the live profile at a tree that gets
# removed on merge-back). Set MACHINES_BOOTSTRAP_ALLOW_COPY=1 to override.
#
# BOOTSTRAP_LIB_ONLY is exempt: it defines the helpers and links nothing, so the
# damage this guards against cannot happen. Without the exemption, sourcing the
# library from a worktree hits `exit 1` and takes the SOURCING shell down with
# it — which is how agents/tests/bootstrap.test.sh died after two checks, in
# silence, whenever the suite ran from a worktree.
if [ -z "${MACHINES_BOOTSTRAP_ALLOW_COPY:-}" ] && [ -z "${BOOTSTRAP_LIB_ONLY:-}" ]; then
  _src_real="$(readlink -f "$SRC_DIR" 2>/dev/null || printf '%s' "$SRC_DIR")"
  _why=""
  # Worktree check FIRST: a worktree agent's tree usually also sits under a temp
  # root, and "linked git worktree" is the more actionable of the two reasons.
  # A linked worktree has --git-dir (…/.git/worktrees/<name>) != --git-common-dir.
  if command -v git >/dev/null 2>&1; then
    _gd="$(git -C "$_src_real" rev-parse --absolute-git-dir 2>/dev/null || true)"
    _gc="$(git -C "$_src_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$_gd" ] && [ -n "$_gc" ] && [ "$_gd" != "$_gc" ]; then
      _why="it is a linked git worktree"
    fi
  fi
  if [ -z "$_why" ]; then
    case "$_src_real" in
      /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*)
        _why="it is under a temp directory" ;;
      "${TMPDIR:-/nonexistent-tmpdir}"/*)
        _why="it is under \$TMPDIR" ;;
    esac
  fi
  if [ -n "$_why" ]; then
    printf '  ✗ refusing to bootstrap from %s\n' "$_src_real" >&2
    printf '    %s, so every symlink this would create in the live profile\n' "$_why" >&2
    printf '    dies with that copy. Run it from the canonical checkout instead:\n' >&2
    printf '        bash ~/machines/agents/bootstrap.sh\n' >&2
    printf '    Override (you almost never want this): MACHINES_BOOTSTRAP_ALLOW_COPY=1\n' >&2
    exit 1
  fi
fi
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# The PRIMARY profile's live dir — always ~/.claude, independent of which profile
# this run is bootstrapping. Dotfiles owns the content inside it; secondary
# profiles are linked AT it, not at the repo.
#
# It must NOT be derived from CLAUDE_CONFIG_DIR: that variable is how a secondary
# profile run is driven (CLAUDE_CONFIG_DIR=~/.claude-pure), so deriving from it
# would make PRIMARY_DIR equal CLAUDE_DIR on every run and the fan-out guard
# would never fire. MACHINES_PRIMARY_DIR exists only so the tests can point it at
# a throwaway dir.
PRIMARY_DIR="${MACHINES_PRIMARY_DIR:-$HOME/.claude}"
# Backups go OUTSIDE the scanned skills/agents/commands dirs (a *.bak sibling
# inside skills/ would be picked up by Claude as a stray duplicate skill).
BAK_ROOT="$CLAUDE_DIR/.bootstrap-bak"

[ -n "${DRY_RUN:-}" ] || mkdir -p "$CLAUDE_DIR"

# Each profile gets the SHARED set + a committed per-profile settings.json,
# chosen by convention from the profile dir's name:
#   ~/.claude            -> settings.json
#   ~/.claude-<postfix>  -> settings.<postfix>.json   (e.g. ~/.claude-pure -> settings.pure.json)
# The machine-local settings.local.json is never touched by any profile.
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
  # ── An Orca-managed per-account dir is NOT a `.claude-<postfix>` profile ───
  # Orca points CLAUDE_CONFIG_DIR at ~/.local/share/orca/claude-accounts/<uuid>/auth.
  # Its basename is `auth`, so POSTFIX lands on `auth`, settings.auth.json does
  # not exist, and the fallback below deploys the TRACKED BASELINE over the
  # mirror orca-profile-sync.sh maintains there.
  #
  # Not hypothetical: git-hooks/_refresh-claude-config runs this script after
  # every pull/checkout/rebase and (before the fix landing alongside this) passed
  # the shell's own CLAUDE_CONFIG_DIR straight through — inside an Orca terminal,
  # the account dir. Observed 2026-08-01: one `git stash` round-trip re-seeded
  # that account's settings.json from the baseline and moved the merged file into
  # .bootstrap-bak. A direct `bash agents/bootstrap.sh` typed in an Orca terminal
  # does the same, which is why the guard lives here and not only in the hook.
  #
  # Redirect rather than refuse: for an Orca profile, "bootstrap" IS the mirror.
  # Skipped under BOOTSTRAP_LIB_ONLY — a caller sourcing the helpers wants the
  # functions, never an exec.
  if [ -z "${BOOTSTRAP_LIB_ONLY:-}" ] && [ -f "$SRC_DIR/orca-profile-sync.sh" ] \
     && { [ -f "$CLAUDE_DIR/.orca-managed-claude-auth" ] \
          || case "$CLAUDE_DIR" in */orca/claude-accounts/*/auth) true ;; *) false ;; esac; }; then
    printf 'Orca-managed profile "%s" — running the mirror instead of the\n' "$CLAUDE_DIR"
    printf 'secondary-profile bootstrap (see agents/orca-profile-sync.sh).\n'
    printf 'To bootstrap the PRIMARY profile from here:\n'
    printf '    env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh   (or: just agent-bootstrap)\n\n'
    exec bash "$SRC_DIR/orca-profile-sync.sh" "$CLAUDE_DIR"
  fi
  printf 'Secondary profile "%s" — SHARED set + settings.%s.json (settings.local.json untouched)\n\n' "$CLAUDE_BASE" "$POSTFIX"
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
# config (Orca injecting its agent-hooks block into settings.json)
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

# retire_link <abs-dest>: remove dest IF AND ONLY IF it is a symlink pointing
# into $SRC_DIR — i.e. a link this script used to own and no longer does. Used
# during the handover of a path from bootstrap to the dotfiles repo: the content
# is already a real file on converged boxes (copy_managed did that), and this
# clears the stale symlink on a box that lagged, so the incoming dotfiles merge
# is not blocked by an untracked path.
#
# NEVER deletes a real file. After the handover the real file at dest IS the
# dotfiles-tracked content; removing it would destroy memory and the 10-minute
# sync timer would then commit the deletion.
retire_link() {
  local dest="$1" tgt
  [ -L "$dest" ] || return 0                     # real file, or nothing there
  # ONE HOP, not _resolve(): _resolve falls back to echoing its argument when
  # readlink -f is unavailable, and a path never matches $SRC_DIR/*, so the guard
  # below would silently pass and nothing would ever be retired.
  tgt="$(readlink "$dest")"
  case "$tgt" in
    "$SRC_DIR"/*) ;;                             # ours — fall through and drop it
    *) return 0 ;;                               # someone else's link
  esac
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would retire stale link: %s\n' "$dest"
    return 0
  fi
  rm -f "$dest"
  printf '  - retired stale link: %s\n' "$dest"
}

# link_if_present <abs-src> <abs-dest>: link() only if src exists. The fan-out
# links into ~/.claude-<postfix> point at the PRIMARY profile's real
# file, which the handover ordering does not guarantee is in place yet — beat 1
# lands this script fleet-wide, and a box whose content has not been converted
# has nothing at the primary path. Plain link() would leave a dangling symlink
# there; this leaves the path empty, and the next bootstrap run wires it.
link_if_present() {
  if [ -e "$1" ]; then
    link "$1" "$2"
  else
    printf '  . skipped (source not present yet): %s\n' "$2"
  fi
}

# host_id: this machine's hostname, sanitized to a filename. Prefers Windows
# COMPUTERNAME (ME-G614JV), else `hostname` (g16 / latitude5520 on the nix
# laptops). This is only the off-nix fallback: on NixOS, claude.nix passes the
# authoritative host id via the MACHINES_HOST_ID env var (the `hostname`
# specialArg == networking.hostName), consumed below as
# "${MACHINES_HOST_ID:-$(host_id)}" — single source of host-naming, also used
# by balance-refresh.py's device id.
#
# NO LONGER CALLED BY THIS SCRIPT (2026-07-28): per-host memory moved to dotfiles,
# which is branch-per-machine and needs no host id. Kept deliberately — it is the
# canonical hostname-sanitization spec that provision/lib/fleet.sh,
# provision/macos-prep.sh and provision/tests/fleet-profile.test.sh cite by name
# ("mirrors agents/bootstrap.sh's host_id()"). Deleting it as dead code would
# orphan those references. modules/home/claude.nix still passes MACHINES_HOST_ID;
# that is now inert rather than wrong.
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
    link "$entry" "$dest_sub/$base"
  done
}

# gortex_merge_hooks <profile-dir>: copy the hooks gortex installed into that
# profile's settings.local.json over into its settings.json.
#
# `gortex install` writes its Claude Code hooks to <profile>/settings.local.json,
# where Claude Code never reads them. Probed 2026-07-31: a marker hook and an
# `env` entry placed in ~/.claude/settings.local.json neither fired nor applied,
# while the identical hook in ~/.claude/settings.json did. User scope is
# settings.json only — the `.local.json` variant exists at PROJECT scope. So the
# hooks gortex installs are inert exactly where it puts them, and had never once
# run on this fleet.
#
# COPY, never move. `gortex install` rewrites settings.local.json on each rewire,
# and ensure_gortex_wired's "already wired" marker greps that same file.
#
# Runs on EVERY bootstrap, not only when wiring happens: copy_managed re-seeds
# settings.json from the committed baseline whenever that baseline changes, which
# drops the merged hooks. Re-merging here restores them within the same run.
#
# Append-only and order-preserving — hook order is observable, and Orca injects
# its own blocks into settings.json that must survive untouched.
gortex_merge_hooks() {
  local dir="${1:-$CLAUDE_DIR}" src dst tmp
  src="$dir/settings.local.json"
  dst="$dir/settings.json"
  [ -f "$src" ] || return 0
  grep -q gortex "$src" 2>/dev/null || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf '  ! jq not found — gortex hooks stay inert in %s\n' "$src"
    return 0
  fi
  if [ ! -f "$dst" ]; then
    printf '  ! no %s to merge into — skipping gortex hooks\n' "$dst"
    return 0
  fi
  tmp="$(mktemp "$dst.XXXXXX")" || return 0
  if ! jq -s '
        # A gortex hook entry, identified by its command rather than its position.
        def isgx: [(.hooks // [])[] | .command // ""] | any(test("gortex hook"));
        .[0] as $dst | .[1] as $src
        | ($dst.hooks // {}) as $d | ($src.hooks // {}) as $s
        | $dst
        | .hooks = (reduce ($s | keys_unsorted[]) as $k ($d;
              ($s[$k] // [])                       as $new
            | ($new | map(select(isgx)))           as $newgx
            | ($d[$k] // [])                       as $cur
            # CONVERGE, do not merely append: a gortex hook whose command differs
            # only in its flags (`gortex hook` vs `gortex hook --mode=nudge`) is
            # the SAME hook with a different posture, so it must replace the stale
            # entry in place rather than join it. Appending leaves both, Claude
            # Code applies the most restrictive verdict, and the default deny of
            # the bare entry silently wins — see bootstrap.test.sh case 9f.
            # (No apostrophes in this comment: the jq program is single-quoted in
            # bash, so one would close the string. It did, on the first run.)
            # Replacing in place (not remove-then-append) keeps hook order stable.
            | ($cur | map(if isgx and (($newgx | length) > 0) then $newgx[0] else . end)) as $conv
            # Collapse the exact duplicates that replacement can create when the
            # profile somehow accumulated more than one gortex entry for an event.
            | ($conv | reduce .[] as $e ([]; if any(. == $e) then . else . + [$e] end)) as $uniq
            # Entries the source has and this event lacks entirely — how a hook
            # event only gortex declares (PreCompact) gets created at all.
            | .[$k] = ($uniq + [ $new[] | select(. as $e | ($uniq | any(. == $e)) | not) ])))
      ' "$dst" "$src" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf '  ✗ could not merge gortex hooks into %s\n' "$dst"
    return 0
  fi
  # Compare canonically: jq reformats, so a byte compare would report a diff on
  # every run even when the hook set is already identical.
  if [ "$(jq -S -c . "$tmp" 2>/dev/null)" = "$(jq -S -c . "$dst" 2>/dev/null)" ]; then
    rm -f "$tmp"
    printf '  = gortex hooks already merged into %s\n' "$dst"
    return 0
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    rm -f "$tmp"
    printf '  ~ would merge gortex hooks into %s\n' "$dst"
    return 0
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv "$tmp" "$dst" && printf '  + merged gortex hooks into %s\n' "$dst"
}

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

# Hook posture, fleet-wide. `nudge` since 2026-08-17, chosen over the installer
# default `deny` after measuring all four on air:
#
#   deny           PreToolUse refuses Grep/Glob anywhere under a tracked repo, and
#                  Read of any file with indexed symbols. The installer default.
#   nudge          soft-denies once per burst of consecutive non-symbolic calls,
#                  then lets the next through (measured: calls 1,2 pass, 3 denied,
#                  4,5 pass). A speed bump that cannot become a wall.
#   enrich         never denies; the same guidance arrives as context afterwards.
#   consult-unlock advertised as deny-until-first-graph-query. NOT USED: the
#                  unlock could not be reproduced on air 2026-08-17 (a source read
#                  stayed denied after a real mcp__gortex__search in the same
#                  session, via both PreToolUse and PostToolUse). Its whole value
#                  is a transition that does not demonstrably happen.
#
# Why loosen at all: `deny` blocks by TARGET, not by whether the graph would
# actually answer better — `grep -n foo AGENTS.md` is refused while `Read` of the
# same file is allowed, and a literal that collides with indexed doc symbols
# needs a regex metachar to get through. The graph is still the better tool for
# symbol work and nudge keeps saying so; it just stops arguing after once.
#
# Override per run: GORTEX_HOOK_MODE=deny just gortex-setup. Note the "Native
# Gortex MCP is mandatory" sentence is compiled into the binary and rides every
# posture — the wording does not soften with the mechanism.
: "${GORTEX_HOOK_MODE:=nudge}"

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
  #
  # The marker deliberately does NOT check the posture. A mode change is a change
  # to already-wired profiles, so gating on it would make every bootstrap re-run
  # the installer; `just gortex-setup` (GORTEX_REWIRE=1) is the way to push a new
  # posture out, and gortex_merge_hooks converges settings.json on whatever the
  # last install wrote.
  if [ -z "${GORTEX_REWIRE:-}" ] && grep -q gortex "$CLAUDE_DIR/settings.local.json" 2>/dev/null; then
    printf '  = gortex already wired: %s (GORTEX_REWIRE=1 to refresh)\n' "$CLAUDE_DIR"; return 0
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would wire gortex: %s install --yes --agents claude-code --no-claude-md --hook-mode %s (%s)\n' \
      "$gx" "$GORTEX_HOOK_MODE" "$CLAUDE_DIR"
    return 0
  fi
  printf '  + wiring gortex for %s (hook posture: %s)…\n' "$CLAUDE_DIR" "$GORTEX_HOOK_MODE"
  "$gx" install --yes --agents claude-code --no-claude-md --hook-mode "$GORTEX_HOOK_MODE" \
    --claude-config-dir "$CLAUDE_DIR" \
    || printf '  ✗ gortex install failed for %s\n' "$CLAUDE_DIR"
}

# Lib-only mode: `BOOTSTRAP_LIB_ONLY=1 . bootstrap.sh` loads the helper functions
# (link / copy_managed / hash_file / gortex_merge_hooks / …) without running the
# profile bootstrap — used by tests/bootstrap.test.sh to exercise them in isolation.
if [ -n "${BOOTSTRAP_LIB_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi

printf 'Bootstrapping Claude config\n  repo:  %s\n  live:  %s\n\n' "$SRC_DIR" "$CLAUDE_DIR"

# Shared whole-file links (every profile).
# statusline + balance refresh are dotfiles-owned real files at ~/.claude/.
# settings.json references them as "$HOME/.claude/statusline-command.sh", so the
# reference is unchanged. Secondary profiles link at the primary.
for f in statusline-command.sh balance-refresh.py; do
  retire_link "$CLAUDE_DIR/$f"
  if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
    link_if_present "$PRIMARY_DIR/$f" "$CLAUDE_DIR/$f"
  fi
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
# across all machines and still deployed from this repo. The PER-HOST file is no
# longer one of them — it is dotfiles-owned; see the block below.
# Agent instructions are dotfiles-owned (~/.claude/CLAUDE.md, tracked on main).
# Distinct from $HOME/CLAUDE.md, which is ambient in every session under $HOME.
retire_link "$CLAUDE_DIR/CLAUDE.md"
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link_if_present "$PRIMARY_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
fi
# The shared memory store is dotfiles-owned: real files at
# ~/.claude/memory/{global.md,personality/*.md}, tracked on the dotfiles repo's
# main branch. bootstrap only clears links from the era when agents/memory/ was
# the source. Secondary profiles are linked AT the primary below.
_mkdir "$CLAUDE_DIR/memory"
retire_link "$CLAUDE_DIR/memory/global.md"
retire_link "$CLAUDE_DIR/memory/personality"
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link_if_present "$PRIMARY_DIR/memory/global.md"   "$CLAUDE_DIR/memory/global.md"
  link_if_present "$PRIMARY_DIR/memory/personality" "$CLAUDE_DIR/memory/personality"
fi

# Per-host memory is dotfiles-owned: a real file at ~/.claude/host-memory.md,
# tracked on this machine's dotfiles branch (host-local — it must never reach
# main). bootstrap only clears a stale link from the era when agents/hosts/<id>.md
# was the source, so an unconverged box does not block the dotfiles merge.
retire_link "$CLAUDE_DIR/host-memory.md"
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link_if_present "$PRIMARY_DIR/host-memory.md" "$CLAUDE_DIR/host-memory.md"
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

# Codex (~/.codex) was deployed from here until 2026-08-01, when it was dropped
# fleet-wide — unused, and 627MB of vendored release binaries per box. The
# plugin's hooks.json still takes the config dir as an argument rather than
# deriving it, which is what made a second agent deployable at all; keep that
# shape if another one ever arrives.

printf '\nGortex\n'
ensure_gortex_binary
ensure_gortex_wired
# Unconditional, and deliberately outside ensure_gortex_wired's early returns:
# the hooks need re-merging after any settings.json re-seed, not only when
# wiring ran. See gortex_merge_hooks for why the merge is needed at all.
gortex_merge_hooks "$CLAUDE_DIR"

# ── Orca-managed profiles — the fan-out no naming convention can reach ───────
# Orca runs Claude Code against a per-account config dir
# (~/.local/share/orca/claude-accounts/<account-uuid>/auth), so the
# ~/.claude-<postfix> convention above never sees it. orca-profile-sync.sh
# mirrors the primary profile into each such dir; see its header.
#
# Personal run only, and deliberately LAST: the mirror's source is the primary
# profile in its final state — after copy_managed re-seeded settings.json and
# gortex_merge_hooks put the hooks back. A secondary-profile run has nothing to
# contribute (it is not the source), and running it there would fan a
# secondary's content out to every account.
if [ "$IS_PERSONAL" -eq 1 ] && [ -f "$SRC_DIR/orca-profile-sync.sh" ]; then
  # --relink first: a profile migrated into ~/.claude-profiles is reached through
  # a symlink Orca can replace with a fresh dir on re-auth. Re-heal before
  # populating, so the sync writes to the real profile rather than into a
  # throwaway dir Orca will own. No-op when every link is healthy, and it skips
  # (never aborts on) a profile with a live session — this runs unattended after
  # every pull.
  if [ -f "$SRC_DIR/orca-profile-link.sh" ]; then
    printf '\n'
    bash "$SRC_DIR/orca-profile-link.sh" --relink || true
  fi
  printf '\n'
  bash "$SRC_DIR/orca-profile-sync.sh" || true
  # Harvest LAST: the copy should include the curated set the sync just wrote.
  # One-way rsync out to ~/.claude-profiles/<name>, so transcripts and sessions
  # survive Orca dropping its account dir. Delta-only, so it costs ~nothing per
  # pull; never fails the bootstrap.
  if [ -f "$SRC_DIR/orca-profile-harvest.sh" ]; then
    printf '\n'
    bash "$SRC_DIR/orca-profile-harvest.sh" || true
  fi
fi

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
