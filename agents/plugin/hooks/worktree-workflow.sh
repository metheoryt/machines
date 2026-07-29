#!/usr/bin/env bash
# Claude Code SessionStart hook — surface the personal git worktree-mode workflow.
#
# Fires ONLY when cwd is a LINKED git worktree whose `origin` remote is not on the
# blocklist. Prints live main<->branch divergence + the worktree-mode section of
# the canonical doc (agents/docs/git-workflow.md). Runs no git-mutating command.
# Always exits 0 so it can never block a session from starting.
set -u

# Remotes to stay silent for (work repos with their own PR flow).
# Org-anchored: the trailing slash matches the github.com:thepureapp/* org
# segment (both SSH and HTTPS forms), so a personal repo whose name merely
# contains "thepureapp" is not wrongly silenced.
BLOCKLIST=(thepureapp/)

# Session JSON arrives on stdin; pull cwd, fall back to $PWD.
cwd="$(jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Must be inside a git repo.
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Must be a LINKED worktree: absolute git-dir differs from the common git-dir.
gd="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common="$(cd "$cwd" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || exit 0
[ -n "$common" ] || exit 0
[ "$gd" != "$common" ] || exit 0

# origin must not be blocklisted.
origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
for pat in "${BLOCKLIST[@]}"; do
  case "$origin" in *"$pat"*) exit 0 ;; esac
done

# --- live state ---
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# The base is per-branch — a worktree can be branched off another feature
# branch, not just the repo default. Same resolution order as the status line
# (agents/statusline-command.sh, section 1), so both agree on what "base" is:
#   1. branch.<head>.base — fork parent recorded at worktree-creation time
#   2. origin/HEAD  3. main
base="$(git -C "$cwd" config --get "branch.$branch.base" 2>/dev/null || true)"
case "$base" in
  refs/remotes/*) base="${base#refs/remotes/}"; base="${base#*/}" ;;   # drop remote name
  refs/heads/*)   base="${base#refs/heads/}" ;;
  origin/*)       base="${base#origin/}" ;;
esac
if [ -z "$base" ]; then
  base="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  base="${base#origin/}"
  [ -n "$base" ] || base="main"
fi

# Where the base branch is actually checked out — for a non-default base that is
# some other linked worktree, not the base checkout. Say so plainly when it is
# checked out nowhere; the merge-back has to run wherever the branch lives.
base_checkout="$(git -C "$cwd" worktree list --porcelain 2>/dev/null |
  awk -v want="refs/heads/$base" '
    /^worktree /  { wt = substr($0, 10) }
    $0 == "branch " want { print wt; exit }
  ')"
if [ -n "$base_checkout" ]; then
  base_where="checked out at $base_checkout"
else
  base_where="not checked out in any worktree"
fi

counts="$(git -C "$cwd" rev-list --left-right --count "refs/heads/$base...HEAD" 2>/dev/null)"
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
printf '  base branch     : %s (%s)\n' "$base" "$base_where"
printf '  divergence      : %s behind, %s ahead of local %s\n' "$behind" "$ahead" "$base"
printf '  working tree    : %s\n\n' "$clean"

if [ -f "$doc" ]; then
  sed -n '/<!-- WORKTREE-MODE:START -->/,/<!-- WORKTREE-MODE:END -->/p' "$doc"
else
  printf '(canonical rules doc not found at %s)\n' "$doc"
fi

exit 0
