#!/usr/bin/env bash
# provision/repos.sh — clone your working repos into a per-account home-dir
# layout, migrating any existing ~/gh/ clones into it first. Host-agnostic
# (Git Bash on Windows, native Linux/macOS). Clone-if-absent; git-autofetch
# keeps them current after. Best-effort: warns + continues if gh is missing.
#
# Usage:
#   bash provision/repos.sh                 # all groups
#   bash provision/repos.sh my cyphy671     # personal box
#   bash provision/repos.sh pure            # work box
#   DRY_RUN=1 bash provision/repos.sh my    # print clone/migrate actions without doing them
#                                           # (note: still queries gh + switches gh's active account, restored to metheoryt at end)
#
# Interactive selection: every group discovers its non-archived repos via gh,
# then you pick which ones to clone in an fzf multi-select (TAB to mark, ENTER
# to clone the marked ones). Only repos not already present are offered. Without
# a usable terminal (piped output, DRY_RUN, or fzf not installed) it prints the
# clonable list and clones NOTHING.
set -u

DRY_RUN="${DRY_RUN:-0}"
GH_ROOT="$HOME/gh"                 # legacy layout to migrate FROM

# key | dir | owner | ssh-alias | gh-account
REPO_GROUPS=(
  "my|my|metheoryt|github.com|metheoryt"
  "pure|pure|thepureapp|github.com|metheoryt"
  "cyphy671|cyphy671|cyphy671|github-cyphy|cyphy671"
)

info() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# owner_of <clone-dir> -> GitHub owner from origin remote (handles git@host:owner/repo & https://host/owner/repo)
owner_of() {
  local url; url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  url="${url#*://}"      # strip scheme:// (https)
  url="${url#*@}"        # strip user@ (git@host:...)
  url="${url#*[:/]}"     # strip host + first ':' or '/'  -> owner/repo
  printf '%s' "${url%%/*}"
}

# migrate_group <dir> <owner>: mv any ~/gh clone owned by <owner> into ~/<dir>/<name>
migrate_group() {
  local dir="$1" owner="$2" gitdir clone name target
  [ -d "$GH_ROOT" ] || return 0
  while IFS= read -r gitdir; do
    clone="$(dirname "$gitdir")"
    name="$(basename "$clone")"
    case "$name" in machines|nix) continue;; esac        # never migrate the config clone
    [ "$(owner_of "$clone")" = "$owner" ] || continue
    target="$HOME/$dir/$name"
    if [ -e "$target" ]; then warn "skip migrate (target exists): $target"; continue; fi
    run "mkdir -p '$HOME/$dir'"
    run "mv '$clone' '$target'"
    info "migrated: $clone -> $target"
  done < <(find "$GH_ROOT" -maxdepth 3 -type d -name .git 2>/dev/null)
}

clone_one() {  # <alias> <owner> <repo> <dir>
  local alias="$1" owner="$2" repo="$3" dir="$4" target="$HOME/$4/$3"
  case "$repo" in machines|nix) return;; esac   # never clone the config repo itself
  [ -e "$target" ] && { info "exists: $target"; return; }
  run "mkdir -p '$HOME/$dir'"
  run "git clone 'git@$alias:$owner/$repo.git' '$target'"
}

discover_all() {  # <owner> <account> -> non-archived repo names, one per line
  local owner="$1" account="$2"
  have gh || { warn "gh missing — cannot discover $owner"; return 1; }
  gh auth switch --user "$account" >/dev/null 2>&1 || true
  gh repo list "$owner" --no-archived --limit 1000 --json name -q '.[].name' 2>/dev/null
}

# select_repos <label> <repo…> -> prints chosen repo names, one per line.
# Interactive fzf multi-select when a terminal is available; otherwise (DRY_RUN,
# no TTY, or no fzf) prints the clonable list to stderr and selects NOTHING.
select_repos() {
  local label="$1"; shift
  [ "$#" -eq 0 ] && return 0
  if [ "$DRY_RUN" = 1 ] || ! have fzf || ! { : >/dev/tty; } 2>/dev/null; then
    local why="no TTY"; have fzf || why="fzf missing"; [ "$DRY_RUN" = 1 ] && why="DRY_RUN"
    { warn "$label: not selecting interactively ($why) — cloning nothing; $# clonable repo(s):"
      printf '       %s\n' "$@"; } >&2
    return 0
  fi
  printf '%s\n' "$@" | fzf --multi --no-sort --height=80% --border \
    --prompt="clone from $label > " \
    --header="TAB mark · ENTER clone marked · ESC clone none  ($# available)"
}

main() {
  local selected=("$@")
  [ ${#selected[@]} -eq 0 ] && selected=(my pure cyphy671)
  local key row g dir owner alias account repo _absent
  for key in "${selected[@]}"; do
    row=""; for g in "${REPO_GROUPS[@]}"; do [ "${g%%|*}" = "$key" ] && row="$g"; done
    [ -n "$row" ] || { warn "unknown group: $key"; continue; }
    IFS='|' read -r _ dir owner alias account <<< "$row"
    printf '\n== group %s  (~/%s <- %s)\n' "$key" "$dir" "$owner"
    migrate_group "$dir" "$owner"
    _absent=()
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      case "$repo" in machines|nix) continue;; esac
      [ -e "$HOME/$dir/$repo" ] || _absent+=("$repo")
    done < <(discover_all "$owner" "$account")
    if [ "${#_absent[@]}" -eq 0 ]; then
      info "nothing to clone for $owner (all present or none discovered)"
      continue
    fi
    while IFS= read -r repo; do
      [ -n "$repo" ] && clone_one "$alias" "$owner" "$repo" "$dir"
    done < <(select_repos "$owner" "${_absent[@]}")
  done
  have gh && gh auth switch --user metheoryt >/dev/null 2>&1 || true   # restore default gh account
  printf '\nDone.%s\n' "$([ "$DRY_RUN" = 1 ] && printf ' (dry-run — nothing changed)')"
}

main "$@"
