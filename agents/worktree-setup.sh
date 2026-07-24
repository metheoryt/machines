#!/usr/bin/env bash
# Global worktree CREATE dispatcher (personal fleet; wired into Orca's Create-worktree
# hook, or run by hand from inside a worktree). Two brackets, in order:
#   1. gortex track (user-wide, guarded) — only if the daemon is up AND the main checkout
#      is already covered AND this worktree isn't tracked yet. No-op otherwise.
#   2. the repo's own local setup script (first candidate that exists + is executable).
# gortex lives ONLY here, never in the committed repo scripts, so non-gortex teammates and
# machines without the daemon are unaffected. Always exits 0 (never blocks worktree creation).
set -u

CONFIG="${GORTEX_CONFIG:-$HOME/.config/gortex/config.yaml}"

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

# config path membership: exact match of a resolved dir against a repos[].path entry.
# Parse the flat `- path: <p>` lines; tolerate optional quotes and trailing whitespace.
config_has_path() {
  local target="$1" line p
  [ -f "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"- path:"*) : ;;
      *) continue ;;
    esac
    p=${line#*path:}
    p=$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    [ -n "$p" ] || continue
    [ "$p" = "$target" ] && return 0
  done < "$CONFIG"
  return 1
}

# 1. gortex track FIRST (guarded).
if [ "$gitdir" = "$common" ]; then
  log "main checkout; skipping gortex track"
elif ! command -v gortex >/dev/null 2>&1; then
  log "gortex not installed; skipping gortex track"
elif ! gortex daemon status >/dev/null 2>&1; then
  log "gortex daemon down; skipping gortex track"
elif ! config_has_path "$main_root"; then
  log "main checkout not covered by gortex ($main_root); skipping track"
elif config_has_path "$wt_root"; then
  log "worktree already tracked; skipping track"
else
  if gortex track "$wt_root" --as-worktree >/dev/null 2>&1; then
    log "tracked worktree $wt_root"
  else
    log "gortex track failed (non-fatal)"
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
