# provision/roles/backup-hub.sh — the `backup-hub` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_backup_hub.
#
# backup-hub = this box HOLDS other machines' restic repositories and serves them
# over REST. latitude is the only member carrying it.
#
# IT INSTALLS NOTHING, AND THAT IS THE BOUNDARY, NOT AN OMISSION. The REST server
# is a container defined in the sibling `vps` repo -- machines here, services
# there (AGENTS.md). This role also does NOT create repositories: `initialize` is
# opt-in per profile for the reason backup/base.yaml spells out, and a role that
# ran `restic init` would reintroduce exactly the silent-empty-repo failure that
# design closes. Scheduling latitude's own jobs is `backup-client`'s work -- one
# profiles.yaml holds both the `latitude` and `g614jv-maintenance` profiles and
# `schedule --all` installs both from one place, so a second scheduler here would
# be two roles racing to write the same four unit files.
#
# What is left is verification, which is the thing this service has actually
# needed: it failed silently four times, every one found by a manual audit. The
# deep check lives in hosts/latitude/debian/restic-hub-selfcheck.sh (ten checks,
# on a timer since 2026-08-29); this role runs it, so there is one implementation
# of "is the hub healthy" rather than two that drift.
# shellcheck shell=bash

# role_backup_hub <mode> <platform> <machine>
#   mode: dry-run | apply
role_backup_hub() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local selfcheck="$repo/hosts/$machine/debian/restic-hub-selfcheck.sh"

    case "$platform" in
        debian)
            if [ ! -f "$selfcheck" ]; then
                echo "  backup-hub: no selfcheck for $machine (skipped)"
                echo "              expected $selfcheck"
                return 0
            fi
            if [ "$mode" != "apply" ]; then
                # A DRY RUN MUST NOT ASSERT. The suite that exercises this runs
                # on whatever box you happen to be on -- desktop-wsl has no
                # /mnt/spare320 and no container, so asserting here would make
                # roles.test.sh red everywhere but latitude.
                echo "  backup-hub: would run (as root) $selfcheck"
                echo "  backup-hub: asserts the drive by UUID, the repo config, that the"
                echo "              container and host see ONE .htpasswd (the bind-race guard),"
                echo "              the listening port, and snapshot freshness."
                echo "  backup-hub: installs nothing — the REST server is a \`vps\` service,"
                echo "              and repositories are never created by a role."
                return 0
            fi
            # Apply = verify. A nonzero here is the point: it turns a hub that
            # has quietly stopped serving into a failed role rather than a green
            # line, which is the whole reason the selfcheck exists.
            #
            # SUDO IS NOT OPTIONAL. The repo dir is drwx------ root:root, so a
            # non-root run of the selfcheck reports two of its ten checks as
            # MISSING / none-found on a healthy hub -- measured 2026-09-01, and
            # the reason the script now refuses to run as anyone else (exit 2).
            if [ "$(id -u)" -eq 0 ]; then
                bash "$selfcheck"
            else
                sudo bash "$selfcheck"
            fi
            ;;
        *)
            # DELIBERATE, unlike backup-client's fallthrough. This role is not
            # portable in principle: it is a physical USB drive addressed by
            # UUID, a docker container, and a listening port on one box. A
            # generic arm here could only pretend. If a second host ever holds
            # repositories, give it its own hosts/<name>/<platform>/ selfcheck
            # and add the arm then.
            echo "  backup-hub: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
