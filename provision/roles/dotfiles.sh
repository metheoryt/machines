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
#
# One consequence of the 2026-07-29 auto-backup: on nixos, a home-manager-owned
# path present in $HOME would be moved aside rather than reported. Under the same
# invariant such a path is host-local and absent from a Nix box's branch, so it is
# not in the tree being checked out and never becomes a collision — but if that
# invariant is ever broken, the role now RENAMES the generated file instead of
# stopping. Keep home-manager-owned paths off that box's branch.
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

# _dotfiles_key_material <path>: does this path look like a private key?
#
# The repo's .gitignore re-ignores key material LAST, so such a path should never
# be in the tree to begin with. This is the backstop for the day one is: moving
# ~/.ssh/id_ed25519 aside mid-provision would break fleet SSH for the rest of the
# run, and the fix (put it back) is not obvious from the failure. Refuse instead.
_dotfiles_key_material() {
    case "${1##*/}" in
        id_rsa* | id_ed25519* | id_ecdsa* | id_dsa* | *.pem | *.key | *.gpg) return 0 ;;
    esac
    case "$1" in
        .ssh/id_* | .gnupg/* | .secrets/*) return 0 ;;
    esac
    return 1
}

# _dotfiles_collisions <gitdir> <ref>: paths tracked in <ref> that already exist
# in $HOME but are absent from the index — exactly the set git refuses to
# overwrite. On a fresh bare clone the index is empty, so that is every tracked
# path present in $HOME; on a re-run the index matches and the set is empty.
#
# -C "$HOME" is not cosmetic: `ls-files` is cwd-scoped, and this role runs with
# the cwd inside ~/machines, so without it the index listing would cover only
# paths under machines/ and every other collision would be missed.
#
# `-e || -L` is the other half of that, and it is not belt-and-suspenders: `-e`
# FOLLOWS symlinks, so a DANGLING symlink at a tracked path tests false and was
# skipped — while git, which only lstat()s, refused the checkout over it anyway.
# The backup pass then moved nothing and the role failed with "checkout refused"
# and no explanation. Hit live on g15-wsl 2026-08-27: ~/.claude was full of links
# into /mnt/c/.../GitHub/nix/claude, a layout deleted with the NixOS tree, so
# EVERY collision there was invisible to this function.
_dotfiles_collisions() {
    local gitdir="$1" ref="$2" p idx
    idx="$(git --git-dir="$gitdir" --work-tree="$HOME" -C "$HOME" ls-files 2>/dev/null)"
    git --git-dir="$gitdir" --work-tree="$HOME" ls-tree -r --name-only "$ref" 2>/dev/null |
        while IFS= read -r p; do
            [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ] || continue
            printf '%s\n' "$idx" | grep -qxF -- "$p" && continue
            printf '%s\n' "$p"
        done
}

# _dotfiles_backup_collisions <gitdir> <ref>: move every colliding path aside to
# <path>.pre-dotfiles so the checkout can proceed. Never deletes and never
# overwrites an existing backup — a second run that clobbered the first run's
# backup is the one real data-loss path here, so a taken backup name refuses the
# whole checkout rather than silently winning.
_dotfiles_backup_collisions() {
    local gitdir="$1" ref="$2" p n=0 refused=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if _dotfiles_key_material "$p"; then
            echo "  dotfiles: $p is key material and already exists in \$HOME — refusing to touch it." >&2
            echo "  dotfiles: keys are never tracked; resolve this by hand before re-running." >&2
            refused=1; continue
        fi
        if [ -e "$HOME/$p.pre-dotfiles" ] || [ -L "$HOME/$p.pre-dotfiles" ]; then
            echo "  dotfiles: ~/$p collides and ~/$p.pre-dotfiles already exists — refusing to overwrite it." >&2
            echo "  dotfiles: move or delete the old backup, then re-run." >&2
            refused=1; continue
        fi
        mkdir -p "$(dirname "$HOME/$p")" 2>/dev/null
        if mv "$HOME/$p" "$HOME/$p.pre-dotfiles"; then
            echo "  dotfiles: ~/$p -> ~/$p.pre-dotfiles (untracked file at a tracked path)."
            n=$((n + 1))
        else
            echo "  dotfiles: could not back up ~/$p." >&2
            refused=1
        fi
    done <<< "$(_dotfiles_collisions "$gitdir" "$ref")"
    [ "$refused" = 0 ] || return 1
    [ "$n" = 0 ] || echo "  dotfiles: backed up $n pre-existing file(s); their content is intact at *.pre-dotfiles."
    return 0
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
        echo "  ~ would move any untracked \$HOME file at a tracked path to <path>.pre-dotfiles"
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
    #
    # As of 2026-07-29 the guard does more than report: _dotfiles_backup_collisions
    # below moves the colliding paths aside itself. Doing that by hand was the last
    # manual step of a fresh install, and it is not an edge case — `gh` runs in
    # tier_apt_dev, BEFORE this role, and writes ~/.config/gh/config.yml every
    # time. The collision is structural: every new box hits it.
    "${df[@]}" fetch --quiet origin || true

    # Resolve the ref about to be checked out ONCE, before the arms — the backup
    # pass must enumerate the tree it will actually be compared against, and
    # deriving that separately inside each arm is where a "moved files for nothing,
    # checkout still refused" bug would live.
    local target arm
    if "${df[@]}" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        target="refs/heads/$branch"; arm=local
    elif "${df[@]}" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        target="refs/remotes/origin/$branch"; arm=track
    else
        target="refs/remotes/origin/main"; arm=from-main
    fi

    _dotfiles_checkout() {
        if "${df[@]}" "$@"; then return 0; fi
        echo "  dotfiles: checkout refused — untracked files in \$HOME already occupy tracked paths." >&2
        echo "  dotfiles: git named them above. Back each one up, delete it, and re-run:" >&2
        echo "    mv ~/<path> ~/<path>.pre-dotfiles" >&2
        echo "  dotfiles: NOT recording the branch or installing the timer — a timer" >&2
        echo "  dotfiles: on the wrong branch would refuse every tick silently." >&2
        return 1
    }
    _dotfiles_backup_collisions "$gitdir" "$target" || return 1

    case "$arm" in
        local) _dotfiles_checkout checkout --quiet "$branch" || return 1 ;;
        track) _dotfiles_checkout checkout --quiet -b "$branch" --track "origin/$branch" || return 1 ;;
        from-main)
            echo "  dotfiles: branch '$branch' does not exist — creating it from origin/main."
            _dotfiles_checkout checkout --quiet -b "$branch" origin/main || return 1
            "${df[@]}" push --quiet -u origin "$branch" || \
                echo "  dotfiles: could not push the new branch — it stays local until the next sync tick." >&2
            ;;
    esac

    # Belt-and-suspenders: never record a branch HEAD is not actually on.
    if [ "$("${df[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]; then
        echo "  dotfiles: HEAD is not on '$branch' after checkout — refusing to continue." >&2
        return 1
    fi

    # `git clone --bare` copies every remote head into refs/heads/*, so this box's
    # branch already exists locally the moment the clone finishes, the `local` arm
    # runs, and `checkout <branch>` sets NO upstream. The branch then tracks
    # nothing: a plain `git pull` fails with "no upstream configured" (hit live on
    # latitude, 2026-07-29) while the sync timer keeps working, because it names
    # refs explicitly. So the breakage stays invisible until a human pulls by hand.
    if "${df[@]}" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        "${df[@]}" branch --quiet --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true
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
