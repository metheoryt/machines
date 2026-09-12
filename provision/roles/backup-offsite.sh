# provision/roles/backup-offsite.sh — the `backup-offsite` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_backup_offsite.
#
# backup-offsite = this box is a SINK. It receives other machines' backups and can
# never delete them. `offsite` is the only member carrying it.
#
# DISTINCT FROM backup-hub, and the difference is the direction of trust, not the
# software. The hub holds the fleet's repositories AND their passwords, because it
# is in the owner's own flat and it prunes them. This box is 900 km away in a house
# he does not occupy, so it holds NO password at all: it serves --append-only, it
# never prunes, and it proves its own bytes with restic-pack-verify.sh, which needs
# no key (a pack file's name IS the SHA-256 of its stored bytes). A stolen box
# yields ciphertext.
#
# IT ALSO DOES NOT CREATE REPOSITORIES, for the reason backup/base.yaml spells out:
# a role that ran `restic init` would reintroduce the silent-empty-repo failure
# that design closes.
#
# WHY THE SERVER IS NATIVE HERE AND A CONTAINER ON LATITUDE. latitude's rest-server
# is part of the cyphy.kz stack and lives in the `vps` repo — machines here,
# services there. This box has no stack; being a sink is its entire purpose, so it
# is a machine fact. It also keeps Docker off the appliance, and with it the
# bind-source race that has cost this fleet two multi-day outages: a container that
# starts before its disk mounts silently gets an empty auto-created directory and
# reports healthy.
# shellcheck shell=bash

# role_backup_offsite <mode> <platform> <machine>
#   mode: dry-run | apply
role_backup_offsite() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local installer="$repo/hosts/$machine/debian/install-rest-server.sh"
    local selfcheck="$repo/hosts/$machine/debian/offsite-selfcheck.sh"

    case "$platform" in
        debian)
            if [ ! -f "$installer" ]; then
                echo "  backup-offsite: no installer for $machine (skipped)"
                echo "                  expected $installer"
                return 0
            fi
            if [ "$mode" != "apply" ]; then
                # A DRY RUN MUST NOT ASSERT — the suite runs on whatever box you
                # happen to be on, and none of them have /mnt/vault. Asserting here
                # would make roles.test.sh red everywhere but the village.
                echo "  backup-offsite: would run (as root) $installer"
                echo "  backup-offsite: installs rest-server $(sed -n 's/^REST_SERVER_VERSION=//p' "$installer" | head -1),"
                echo "                  --append-only --private-repos, htpasswd auth,"
                echo "                  WILDCARD bind (a tailnet-address bind cannot"
                echo "                  survive a reboot — see the unit's header)."
                echo "  backup-offsite: holds NO repository password and never prunes."
                [ -f "$selfcheck" ] && echo "  backup-offsite: would run $selfcheck"
                return 0
            fi
            if [ "$(id -u)" -eq 0 ]; then
                bash "$installer" || return $?
                [ -f "$selfcheck" ] && bash "$selfcheck"
            else
                sudo bash "$installer" || return $?
                [ -f "$selfcheck" ] && sudo bash "$selfcheck"
            fi
            ;;
        *)
            # DELIBERATE, like backup-hub's. This role is a physical disk addressed
            # by UUID, a listening port and a systemd unit on one box. A generic arm
            # here could only pretend. If a second offsite site ever exists, give it
            # its own hosts/<name>/<platform>/ and add the arm then.
            echo "  backup-offsite: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
