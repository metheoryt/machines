# provision/roles/repos.sh — the `repos` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_repos.
#
# repos = your working repos cloned into the per-account home-dir layout by
# provision/repos.sh (host-agnostic; DRY_RUN-capable; interactive fzf select on
# apply). Wrapped here UNCHANGED. Unlike agents/dotfiles this is NOT a nixos
# no-op — cloning working repos is imperative and not home-manager-managed, so
# repos.sh runs on nixos too.

# role_repos <mode> <platform> <machine>
#   mode: dry-run | apply
role_repos() {
    local mode="$1" platform="$2" machine="$3"
    # repo root = two levels up from provision/roles/ .
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local script="$repo/provision/repos.sh"

    case "$platform" in
        nixos|wsl|debian)
            if [ ! -f "$script" ]; then
                echo "  repos: repos.sh not found at $script — is this repo cloned here?" >&2
                return 1
            fi
            # No group args => repos.sh defaults to all groups (my pure cyphy671);
            # interactive fzf select (apply) / dry-run listing is the per-box filter.
            if [ "$mode" = "apply" ]; then
                bash "$script"
            else
                DRY_RUN=1 bash "$script"
            fi
            ;;
        *)
            echo "  repos: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
