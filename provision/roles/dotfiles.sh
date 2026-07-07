# provision/roles/dotfiles.sh — the `dotfiles` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_dotfiles.
#
# dotfiles = cross-platform home config managed by chezmoi, sourced from
# machines/dotfiles/ (stateless --source mode; updates come via `git pull`, not
# `chezmoi update`). On nixos it is owned by home-manager, so the dispatcher
# must NOT run chezmoi there.

# _dotfiles_ensure_chezmoi <mode>: returns 0 if chezmoi is usable afterward.
# apply: install via get.chezmoi.io -> ~/.local/bin if missing. dry-run: if
# missing, print "would install" and return 1 (nothing to diff yet).
_dotfiles_ensure_chezmoi() {
    local mode="$1"
    command -v chezmoi >/dev/null 2>&1 && return 0
    if [ "$mode" = apply ]; then
        if ! command -v curl >/dev/null 2>&1; then
            echo "  dotfiles: chezmoi + curl both missing — cannot install chezmoi." >&2
            return 1
        fi
        echo "  dotfiles: installing chezmoi -> ~/.local/bin ..."
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" || return 1
        export PATH="$HOME/.local/bin:$PATH"
        command -v chezmoi >/dev/null 2>&1
        return
    fi
    echo "  ~ would install chezmoi (get.chezmoi.io -> ~/.local/bin)"
    return 1
}

# role_dotfiles <mode> <platform> <machine>
#   mode: dry-run | apply
role_dotfiles() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local src="$repo/dotfiles"

    case "$platform" in
        nixos)
            echo "  dotfiles: owned by home-manager on nixos — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian)
            if [ ! -d "$src" ]; then
                echo "  dotfiles: chezmoi source not found at $src — is this repo cloned here?" >&2
                return 1
            fi
            if ! _dotfiles_ensure_chezmoi "$mode"; then
                # dry-run + chezmoi absent already reported "would install"; nothing to diff.
                [ "$mode" = apply ] && return 1 || return 0
            fi
            if [ "$mode" = apply ]; then
                chezmoi apply --source "$src"
            else
                chezmoi diff --source "$src"
            fi
            ;;
        *)
            echo "  dotfiles: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
