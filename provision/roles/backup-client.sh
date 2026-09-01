# provision/roles/backup-client.sh — the `backup-client` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_backup_client.
#
# A THIN WRAPPER, ON PURPOSE. The implementation is provision/backup-client.sh,
# which is also step 6 of the WSL chain — so a fleet.json member and a
# self-declared WSL distro install their backups through the SAME code, and
# neither has to reach across a machine boundary to do it.
#
# The difference is only where the identity comes from. Here it is the manifest
# machine name, passed explicitly; standalone it is resolved from
# fleet.local.json (see that file's header for why detection cannot be trusted
# on a WSL box). Passing it explicitly is also what keeps this executor testable
# off-host.
# shellcheck shell=bash

# role_backup_client <mode> <platform> <machine>
#   mode: dry-run | apply
role_backup_client() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    case "$platform" in
        debian|wsl|nixos|darwin)
            BACKUP_CLIENT_LIB_ONLY=1
            # shellcheck source=provision/backup-client.sh
            source "$repo/provision/backup-client.sh"
            backup_client_install "$mode" "$machine"
            ;;
        *)
            # windows has its OWN executor now — provision/roles/backup-client.ps1,
            # reached through provision.ps1. This arm is for a platform with
            # neither, and it must stay: a platform silently missing from both
            # sides is the "provisioned nothing, reported success" failure.
            echo "  backup-client: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
