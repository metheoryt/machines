# provision/roles/dotfiles.sh — the `dotfiles` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_dotfiles.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.4
#
# dotfiles = the private metheoryt/dotfiles repo, BARE-REPO technique: ~/.dotfiles
# is a bare git repo whose work-tree is $HOME, so tracked files already live at
# their real paths. No symlinks, no render step, no chezmoi.
#
# Runs on EVERY platform including nixos. The old nixos no-op existed because
# chezmoi collided with home-manager; the bare repo does not. Under the spec's
# shared-XOR-host invariant a home-manager-owned path is simply host-local —
# allow-listed on non-Nix branches, absent from main and from latitude's branch —
# so there is nothing for the two mechanisms to fight over.
# shellcheck shell=bash

DOTFILES_REMOTE="${DOTFILES_REMOTE:-git@github.com:metheoryt/dotfiles.git}"

# _dotfiles_branch <machine>: the logical fleet name to check out. Prefers the
# shared resolver (which honours a self-declared WSL host's fleet.local.json
# nickname); falls back to the machine the dispatcher already resolved, so this
# role stays sourceable and testable standalone.
_dotfiles_branch() {
    local b=""
    if declare -F fleet_logical_name >/dev/null 2>&1; then
        b="$(fleet_logical_name 2>/dev/null || true)"
    fi
    [ -n "$b" ] || b="$1"
    printf '%s' "$b"
}

# role_dotfiles <mode> <platform> <machine>
#   mode: dry-run | apply
role_dotfiles() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local gitdir="$HOME/.dotfiles"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync"
    local branch; branch="$(_dotfiles_branch "$machine")"

    case "$platform" in
        nixos|wsl|debian|darwin) : ;;
        *)
            echo "  dotfiles: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac

    if [ -z "$branch" ]; then
        echo "  dotfiles: could not resolve a logical fleet name — refusing to check out an empty branch." >&2
        return 1
    fi

    if [ "$mode" = dry-run ]; then
        echo "  ~ would clone $DOTFILES_REMOTE (bare) -> $gitdir"
        echo "  ~ would check out branch '$branch' (creating it from main if absent)"
        echo "  ~ would record the branch at $state/branch"
        echo "  ~ would install the 10-min dotfiles-sync timer"
        return 0
    fi

    # 1. Clone the bare repo if absent. `--bare` gives no work-tree of its own;
    #    every later call must pass --work-tree explicitly.
    if [ ! -d "$gitdir" ]; then
        echo "  dotfiles: cloning $DOTFILES_REMOTE -> $gitdir ..."
        git clone --quiet --bare "$DOTFILES_REMOTE" "$gitdir" || {
            echo "  dotfiles: clone failed — is this box's key registered for the private repo?" >&2
            return 1
        }
    fi
    local df=(git --git-dir="$gitdir" --work-tree="$HOME")
    # Never enumerate the rest of $HOME. Without this, `dotfiles status` lists
    # every untracked file in the home directory.
    "${df[@]}" config status.showUntrackedFiles no
    # `git clone --bare` sets NO remote.origin.fetch, so a bare clone has no
    # refs/remotes/origin/* at all and every `origin/main` / `origin/<branch>`
    # reference below — and in the sync timer — fails to resolve. Idempotent.
    "${df[@]}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

    # 2. Check out this host's branch, creating it from main if it does not exist.
    #
    # THE CHECKOUT MUST BE GUARDED. git refuses it when an untracked file already
    # sits at a tracked path, and on a real box that is the NORMAL case, not an
    # edge case: air already has ~/.config/gh/config.yml, latitude has a
    # home-manager-generated ~/.ssh/config. Unguarded, the checkout is refused,
    # HEAD stays on the clone's default (main), the role writes the wrong branch
    # into the state file, and every sync tick from then on hits the wrong-branch
    # arm and exits 1 — a timer that looks installed and never works.
    "${df[@]}" fetch --quiet origin || true
    _dotfiles_checkout() {
        if "${df[@]}" "$@"; then return 0; fi
        echo "  dotfiles: checkout refused — untracked files in \$HOME already occupy tracked paths." >&2
        echo "  dotfiles: git named them above. Back each one up, delete it, and re-run:" >&2
        echo "    mv ~/<path> ~/<path>.pre-dotfiles" >&2
        echo "  dotfiles: NOT recording the branch or installing the timer — a timer" >&2
        echo "  dotfiles: on the wrong branch would refuse every tick silently." >&2
        return 1
    }
    if "${df[@]}" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        _dotfiles_checkout checkout --quiet "$branch" || return 1
    elif "${df[@]}" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        _dotfiles_checkout checkout --quiet -b "$branch" --track "origin/$branch" || return 1
    else
        echo "  dotfiles: branch '$branch' does not exist — creating it from origin/main."
        _dotfiles_checkout checkout --quiet -b "$branch" origin/main || return 1
        "${df[@]}" push --quiet -u origin "$branch" || \
            echo "  dotfiles: could not push the new branch — it stays local until the next sync tick." >&2
    fi

    # Belt-and-suspenders: never record a branch HEAD is not actually on.
    if [ "$("${df[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]; then
        echo "  dotfiles: HEAD is not on '$branch' after checkout — refusing to continue." >&2
        return 1
    fi

    # 3. Record the branch for the timer. The timer must NOT resolve fleet
    #    identity itself: that would couple it to jq and to this repo being
    #    present. It reads this file and refuses to run if HEAD disagrees.
    mkdir -p "$state"
    printf '%s\n' "$branch" > "$state/branch"

    echo "  dotfiles: $gitdir on branch '$branch'."

    # 4. Install the timer. tier_dotfiles_sync lives in provision/lib/tiers.sh,
    #    which linux.sh / macos.sh source but provision.sh does not — so source
    #    it here when it is not already in scope.
    if ! declare -F tier_dotfiles_sync >/dev/null 2>&1; then
        # tiers.sh expects these; define no-op-safe versions if absent. They are
        # invoked by tiers.sh, not from here — hence the SC2329 waiver. Tested
        # with `declare -F`, NOT `command -v`: `info` is a real binary (texinfo)
        # on most Linux boxes, so `command -v info` would find it and leave
        # tier_dotfiles_sync calling the texinfo reader instead of a printf.
        # shellcheck disable=SC2329
        declare -F info >/dev/null 2>&1 || info() { printf '  %s\n' "$*"; }
        # shellcheck disable=SC2329
        declare -F ok   >/dev/null 2>&1 || ok()   { printf '  ✓ %s\n' "$*"; }
        # shellcheck disable=SC2329
        declare -F warn >/dev/null 2>&1 || warn() { printf '  ! %s\n' "$*" >&2; }
        # shellcheck disable=SC2329
        declare -F have >/dev/null 2>&1 || have() { command -v "$1" >/dev/null 2>&1; }
        REPO="${REPO:-$repo}"
        # shellcheck source=provision/lib/tiers.sh
        TIERS_LIB_ONLY=1 source "$repo/provision/lib/tiers.sh"
    fi
    tier_dotfiles_sync
}
