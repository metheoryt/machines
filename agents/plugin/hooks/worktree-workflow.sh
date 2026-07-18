#!/usr/bin/env bash
# Claude Code SessionStart hook — surface the personal git worktree-mode workflow.
#
# Fires ONLY when cwd is a LINKED git worktree whose `origin` remote is not on the
# blocklist. Prints live main<->branch divergence + the worktree-mode section of
# the canonical doc (agents/docs/git-workflow.md). Runs no git-mutating command.
# Always exits 0 so it can never block a session from starting.
set -u

# Remotes to stay silent for (work repos with their own PR flow).
BLOCKLIST=(thepureapp)

# Session JSON arrives on stdin; pull cwd, fall back to $PWD.
cwd="$(jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Must be inside a git repo.
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Must be a LINKED worktree: absolute git-dir differs from the common git-dir.
gd="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common="$(cd "$cwd" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)" || exit 0
[ -n "$common" ] || exit 0
[ "$gd" != "$common" ] || exit 0

# origin must not be blocklisted.
origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
for pat in "${BLOCKLIST[@]}"; do
  case "$origin" in *"$pat"*) exit 0 ;; esac
done

# --- live state ---
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
base="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
base="${base#origin/}"
[ -n "$base" ] || base="main"
base_checkout="$(dirname "$common")"

counts="$(git -C "$cwd" rev-list --left-right --count "$base...HEAD" 2>/dev/null)"
behind="$(printf '%s' "$counts" | awk '{print $1}')"
ahead="$(printf '%s' "$counts" | awk '{print $2}')"
[ -n "$behind" ] || behind="?"
[ -n "$ahead" ] || ahead="?"

if [ -z "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
  clean="clean"
else
  clean="DIRTY (uncommitted changes — do not auto-sync)"
fi

# --- canonical rules (single source of truth) ---
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
doc="$script_dir/../../docs/git-workflow.md"

printf 'You are in a git WORKTREE of a personal fleet-sync repo — worktree-mode git rules apply.\n\n'
printf 'Live state:\n'
printf '  worktree branch : %s\n' "$branch"
printf '  base branch     : %s (checked out at %s)\n' "$base" "$base_checkout"
printf '  divergence      : %s behind, %s ahead of local %s\n' "$behind" "$ahead" "$base"
printf '  working tree    : %s\n\n' "$clean"

if [ -f "$doc" ]; then
  sed -n '/<!-- WORKTREE-MODE:START -->/,/<!-- WORKTREE-MODE:END -->/p' "$doc"
else
  printf '(canonical rules doc not found at %s)\n' "$doc"
fi

exit 0
