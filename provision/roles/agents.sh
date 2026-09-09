# provision/roles/agents.sh — the `agents` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_agents.
#
# agents = the synced Claude Code config produced by agents/bootstrap.sh.
#
# Until 2026-09-09 this carried a `nixos` arm that skipped bootstrap.sh, because
# home-manager (claude.nix, applied by `just switch`) owned the config there.
# Both the module and the recipe were deleted 2026-08-01 with the flake, and no
# fleet.json machine has had `platform: nixos` since — so the arm was a branch
# no run could take. Every posix platform now runs bootstrap.sh, which is what
# every posix platform in the fleet already did.
# shellcheck shell=bash

# role_agents <mode> <platform> <machine>
#   mode: dry-run | apply
role_agents() {
    # shellcheck disable=SC2034  # machine: kept for role-signature parity
    local mode="$1" platform="$2" machine="$3"
    # repo root = two levels up from provision/roles/ .
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local boot="$repo/agents/bootstrap.sh"

    case "$platform" in
        wsl|debian|darwin)
            # darwin is not special here: bootstrap.sh already branches on
            # `uname -s` and handles Darwin, so the dispatcher just runs it.
            if [ ! -f "$boot" ]; then
                echo "  agents: bootstrap.sh not found at $boot — is this repo cloned here?" >&2
                return 1
            fi
            if [ "$mode" = "apply" ]; then
                bash "$boot"
            else
                DRY_RUN=1 bash "$boot"
            fi
            ;;
        *)
            echo "  agents: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
