#!/usr/bin/env bash
# Global worktree CREATE dispatcher (personal fleet; wired into Orca's Create-worktree
# hook, or run by hand from inside a worktree). Two brackets, in order:
#   1. gortex track (user-wide, guarded) — only if the daemon is up AND the main checkout
#      is already covered AND this worktree isn't tracked yet. No-op otherwise.
#   2. the repo's own local setup script (first candidate that exists + is executable).
# gortex lives ONLY here, never in the committed repo scripts, so non-gortex teammates and
# machines without the daemon are unaffected. Always exits 0 (never blocks worktree creation).
set -u

log() { printf '[worktree-setup] %s\n' "$*" >&2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "not inside a git work tree; nothing to do"; exit 0;
}

wt_root=$(git rev-parse --show-toplevel)

# Main checkout = parent of the absolutized git common dir.
common=$(git rev-parse --git-common-dir)
case "$common" in
  /* | [A-Za-z]:* ) : ;;
  * ) common=$(cd "$wt_root" && cd "$common" && pwd) ;;
esac
main_root=$(dirname "$common")
gitdir=$(git rev-parse --absolute-git-dir)

# Resolve a dir to its physical path; echo the input unchanged if it isn't one.
# Needed on both sides of the comparison below: git reports physical paths, while
# gortex may report a path through a symlink (/var vs /private/var on macOS, or a
# symlinked home), and a prefix-only difference would silently disable tracking
# with a "not covered" message that looks like a config mistake.
resolve_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

# The tracked-repo paths, one per line, straight from the daemon.
#
# Ask the DAEMON rather than parse a config file, on purpose: the config location
# has already drifted once — this script hard-defaulted to
# $HOME/.config/gortex/config.yaml while gortex's global config is
# $HOME/.gortex/config.yaml — and a config path that doesn't exist makes every
# guard below fail CLOSED. Daemon up, repo covered, and still nothing ever tracked,
# with one "not covered" line to show for it. Both call sites already sit behind
# `gortex daemon status`, so the daemon is up by the time this runs.
#
# sed, not jq: this runs on Git Bash boxes with no jq. `gortex repos --json` is
# pretty-printed one field per line, so a line match is enough. The second sed
# turns the doubled backslashes of a native-Windows path (C:\\Users\\...) into
# forward slashes, which Git Bash's `cd` accepts.
#
# The query is captured, not piped straight into sed, so the FAILURE is
# distinguishable from an empty list: a pipeline's exit status is sed's, so an older
# gortex without `repos --json` would hand back nothing and read as "no repos
# tracked" — i.e. "not covered" — reviving the exact silent fail-closed this
# function was written to delete, only keyed on binary version instead of config
# path. Callers must branch on the non-zero return with their own log line.
gortex_tracked_paths() {
  local raw
  raw=$(gortex repos --json 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" \
    | sed -n 's/^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
    | sed 's/\\\\/\//g'
}

# Exact match of a resolved dir ($1) against a newline-separated path list ($2).
list_has_path() {
  local target line
  target="$(resolve_dir "$1")"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "$(resolve_dir "$line")" = "$target" ] && return 0
  done <<LIST
$2
LIST
  return 1
}

# Graph prefix for a linked worktree. --as-worktree without --name defaults to the
# directory basename, and Orca lays worktrees out as
# ~/orca/workspaces/<repo>/<branch-leaf> — so every repo's `agenda` worktree would
# fight over a single `agenda` prefix. Qualify it with the main checkout's
# basename, unless the worktree dir already carries that prefix.
wt_prefix() {
  local m w
  m=$(basename "$1"); w=$(basename "$2")
  case "$w" in
    "$m" | "$m"-*) printf '%s' "$w" ;;
    *) printf '%s-%s' "$m" "$w" ;;
  esac
}

# 1. gortex track FIRST (guarded).
if [ "$gitdir" = "$common" ]; then
  log "main checkout; skipping gortex track"
elif ! command -v gortex >/dev/null 2>&1; then
  log "gortex not installed; skipping gortex track"
elif ! gortex daemon status >/dev/null 2>&1; then
  log "gortex daemon down; skipping gortex track"
else
  if ! tracked=$(gortex_tracked_paths); then
    log "gortex repos unavailable; skipping track"
  elif ! list_has_path "$main_root" "$tracked"; then
    log "main checkout not covered by gortex ($main_root); skipping track"
  elif list_has_path "$wt_root" "$tracked"; then
    log "worktree already tracked; skipping track"
  else
    prefix=$(wt_prefix "$main_root" "$wt_root")
    if gortex track "$wt_root" --as-worktree --name "$prefix" >/dev/null 2>&1; then
      log "tracked worktree $wt_root as $prefix"
    else
      log "gortex track failed (non-fatal)"
    fi
  fi
fi

# 1b. Link generic gitignored config from the main checkout into a fresh linked
#     worktree (a fresh worktree carries only committed files). Idempotent; never
#     clobber; a dangling symlink counts as already-linked. Skipped in the main
#     checkout, where there is nothing distinct to link into.
if [ "$gitdir" != "$common" ]; then
  for rel in .env .claude/settings.local.json; do
    src="$main_root/$rel"
    dst="$wt_root/$rel"
    if [ -e "$src" ] && [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" \
        && log "linked $rel" \
        || log "WARN: failed to link $rel"
    fi
  done
fi

# 2. Then the repo-local setup script (first executable candidate wins).
for rel in .orca/worktree-setup.sh docker/worktree-setup.sh .worktree/setup.sh scripts/worktree-setup.sh; do
  cand="$wt_root/$rel"
  if [ -x "$cand" ]; then
    log "running repo-local setup: $rel"
    ( cd "$wt_root" && "$cand" ) || log "repo-local setup exited $? (non-fatal)"
    break
  fi
done

exit 0
