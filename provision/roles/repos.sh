# provision/roles/repos.sh — the `repos` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_repos.
#
# repos = your working repos cloned into the per-account home-dir layout by
# provision/repos.sh (host-agnostic; DRY_RUN-capable; interactive fzf select on
# apply). Wrapped here UNCHANGED. It runs on every posix platform: cloning
# working repos is plain imperative git with nothing platform-specific in it.
# shellcheck shell=bash

# role_repos <mode> <platform> <machine>
#   mode: dry-run | apply
role_repos() {
    local mode="$1" platform="$2" machine="$3"
    # repo root = two levels up from provision/roles/ .
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local script="$repo/provision/repos.sh"

    case "$platform" in
        wsl|debian|darwin)
            # repos.sh is host-agnostic plain git — darwin joins every other
            # posix platform with no special case.
            if [ ! -f "$script" ]; then
                echo "  repos: repos.sh not found at $script — is this repo cloned here?" >&2
                return 1
            fi
            # Groups come from the manifest when it declares them
            # (`repo_groups`), else repos.sh keeps its own default.
            #
            # This role must stay sourceable WITHOUT lib/fleet.sh — provision.sh
            # sources the lib first, `roles.test.sh` does not — and what makes
            # that safe is the redirect below, not a guard around it: an
            # undefined `fleet_repo_groups` is a plain "command not found",
            # which `set -u` does not trip, so mapfile reads nothing and the
            # array stays empty. A `declare -F` guard was written here first and
            # deleted after mutation-testing showed removing it changed nothing.
            local groups=()
            mapfile -t groups < <(fleet_repo_groups "$machine" 2>/dev/null || true)
            # An empty array must reach repos.sh as NO argument: `repos.sh ""`
            # matches no group row and clones nothing while looking deliberate.
            # The `+` form is defence-in-depth, not a fix for a live bug —
            # measured on bash 5.3.9, a bare "${groups[@]}" already expands to
            # zero words under `set -u`. It matters only on bash < 4.4, where the
            # bare form errors as unbound instead.
            if [ "$mode" = "apply" ]; then
                bash "$script" ${groups[@]+"${groups[@]}"}
            else
                DRY_RUN=1 bash "$script" ${groups[@]+"${groups[@]}"}
            fi
            ;;
        *)
            echo "  repos: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
