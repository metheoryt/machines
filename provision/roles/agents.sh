# provision/roles/agents.sh — the `agents` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_agents.
#
# agents = the synced Claude/Codex config produced by agents/bootstrap.sh.
# On nixos it is owned by home-manager (claude.nix/codex.nix) and applied by
# `just switch`, so the dispatcher must NOT run bootstrap.sh there.
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
        nixos)
            echo "  agents: owned by home-manager (claude.nix/codex.nix) — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian)
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
