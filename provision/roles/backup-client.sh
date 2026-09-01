# provision/roles/backup-client.sh — the `backup-client` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_backup_client.
#
# backup-client = this box runs restic through resticprofile on a schedule. The
# config is backup/<machine>/, the install command is that directory's own
# install-tasks.sh, and this executor is the thin part: find the directory,
# make sure the two binaries exist, run the script.
#
# WHY THE SCRIPT AND NOT `resticprofile schedule --all` INLINE. The scope is not
# derivable from here. latitude's profiles are `schedule-permission: system` and
# need sudo; desktop-wsl's client is user-scope and must NOT be root, or the
# units land in the system manager and the timer that actually backs the box up
# is never installed. That decision belongs beside the config declaring it, so
# each profile dir ships its own install-tasks.sh and this file calls it.
#
# WHAT IT DOES NOT DO: create a repository. `initialize` is opt-in per profile
# (backup/base.yaml explains why at length -- a global one cannot be overridden,
# and an unmounted `nofail` drive turns init into silent data loss). A first-time
# client is initialised by hand, once.
# shellcheck shell=bash

# role_backup_client <mode> <platform> <machine>
#   mode: dry-run | apply
role_backup_client() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local dir="$repo/backup/$machine"
    local script="$dir/install-tasks.sh"

    case "$platform" in
        debian|wsl|nixos|darwin)
            # A DECLARED-BUT-UNCONFIGURED CLIENT IS A SKIP, NOT A FAILURE.
            # `hub` carries this role with no profile dir: the offsite copy is
            # phase 3 of the design spec and is not built. Saying so on every
            # run is the point -- it keeps an unfinished thing visible without
            # turning the fleet's --apply red.
            if [ ! -d "$dir" ]; then
                echo "  backup-client: no profile dir for $machine (skipped)"
                echo "                 expected $dir"
                return 0
            fi
            # The directory existing but the script not is a different thing
            # entirely: somebody added config and no way to install it. That is
            # a misconfiguration and must be loud.
            if [ ! -f "$script" ]; then
                echo "  backup-client: $dir exists but has no install-tasks.sh" >&2
                return 1
            fi

            local missing=""
            command -v restic        >/dev/null 2>&1 || missing="restic"
            command -v resticprofile >/dev/null 2>&1 || missing="$missing resticprofile"

            if [ "$mode" = "apply" ]; then
                if [ -n "$missing" ]; then
                    case "$platform" in
                        debian|wsl)
                            echo "  backup-client: installing$missing…"
                            bash "$repo/backup/restic-install.sh" || return 1
                            ;;
                        *)
                            # restic-install.sh is apt + a curl'd installer into
                            # /usr/local/bin. Neither is right on darwin or
                            # nixos, and guessing is worse than stopping.
                            echo "  backup-client: missing$missing — install them for $platform first" >&2
                            return 1
                            ;;
                    esac
                fi
                # Nudge, not a gate: a non-lingering user manager kills a
                # user-scope timer at logout.
                #
                # IT FIRES FOR NOBODY TODAY, and that is not an argument for
                # deleting it -- it is the Task 5 hole restated. The only
                # machines reaching this arm are latitude (system-scope, needs no
                # linger) and hub (no profile dir, returns above). The one box
                # where linger decides whether the backup runs at all is
                # desktop-wsl, which provision.sh dispatches no roles to. Do not
                # read this line as evidence that the WSL client is provisioned
                # through here; it is what has to already be right when it is.
                if command -v loginctl >/dev/null 2>&1 \
                   && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "no" ]; then
                    echo "  backup-client: note — linger is off; a user-scope timer"
                    echo "                 dies at logout. sudo loginctl enable-linger $USER"
                fi
                bash "$script"
            else
                # DRY RUN WRITES NOTHING. `resticprofile schedule` creates unit
                # files and has no dry-run of its own, so the only safe preview
                # is to print the command.
                echo "  backup-client: profile dir $dir"
                [ -n "$missing" ] \
                    && echo "  backup-client: would install$missing" \
                    || echo "  backup-client: restic + resticprofile present"
                echo "  backup-client: would run: bash $script"
            fi
            ;;
        *)
            # windows lands here TODAY AND THAT IS A KNOWN HOLE, not a decision.
            # `desktop` is a windows member whose backup client actually runs
            # inside the WSL distro desktop-wsl -- a self-declared host that
            # provision.sh never dispatches roles to at all. See the plan's
            # Task 5.
            echo "  backup-client: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}
