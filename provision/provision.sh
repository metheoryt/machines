#!/usr/bin/env bash
# provision/provision.sh — fleet front door (WSL / Linux / nixos).
# Phase 1: detect/select the machine and PRINT the plan. Applies nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision/lib/fleet.sh
source "$HERE/lib/fleet.sh"

# Role executors (each defines role_<name>). Optional — absent dir is fine.
for _rf in "$HERE"/roles/*.sh; do
    [ -e "$_rf" ] || continue
    # shellcheck source=/dev/null
    source "$_rf"
done

MODE="dry-run"; MACHINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --apply)   MODE="apply" ;;
        --machine) MACHINE="${2:-}"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# Resolve the machine: explicit --machine, else detect, else prompt to pick.
if [ -z "$MACHINE" ]; then
    if MACHINE="$(fleet_detect)"; then
        echo "▸ Detected this host as: $MACHINE"
    else
        echo "! Could not auto-detect this host ($(hostname)). Choose one:" >&2
        select m in $(fleet_machines); do MACHINE="$m"; break; done
    fi
fi
if [ -z "$MACHINE" ]; then echo "no machine selected" >&2; exit 2; fi

# A name that is not in the manifest must fail HERE and loudly. See
# fleet_has_machine: without this the run emits a raw jq error, prints no roles, and
# still exits 0 -- "provisioned nothing, reported success", which is the same failure
# the role executors' `*)` arms are guarded against in provision/tests/roles.test.sh.
if ! fleet_has_machine "$MACHINE"; then
    echo "unknown machine: $MACHINE" >&2
    echo "known machines: $(fleet_machines | tr '\n' ' ')" >&2
    exit 2
fi

platform="$(fleet_platform "$MACHINE")"
echo "▸ Machine: $MACHINE   platform: $platform   mode: $MODE"
echo "▸ Roles:"
# Read roles into an array first so the confirm `read` below uses the terminal,
# not the role stream (a `while read < <(...)` loop would swallow the answer).
roles=()
while IFS= read -r role; do roles+=("$role"); done < <(fleet_roles "$MACHINE")

# Roles with no executor under provision/roles/, declared unimplemented ON
# PURPOSE. This list is the whole difference between "we know" and "nobody
# noticed": a role NOT named here and with no executor makes `--apply` exit 1,
# the same way fleet_has_machine above makes an unknown MACHINE exit 2, and for
# the same reason — "provisioned nothing, reported success" is the failure mode
# both guards exist to kill. Before this list, `just provision --machine
# latitude --apply` did nothing for four of its seven roles and exited 0.
#
# A future executor lands by DELETING its name from here. That deletion is the
# reviewable event; adding one back is a deliberate declaration, not a shrug.
# Overridable so the guard itself is testable (provision/tests/fleet-profile.test.sh)
# and so a human can demand a strict run: MACHINES_PLANNED_ROLES= just provision …
PLANNED_ROLES="${MACHINES_PLANNED_ROLES-base ssh-server backup-hub backup-client}"

rc=0
for role in "${roles[@]}"; do
    fn="role_${role//-/_}"
    if declare -F "$fn" >/dev/null; then
        if [ "$MODE" = "apply" ]; then
            echo "  ▸ $role — preview:"
            "$fn" dry-run "$platform" "$MACHINE"
            printf "  Apply %s? [y/N] " "$role"
            read -r ans
            case "$ans" in
                [yY]|[yY][eE][sS])
                    echo "  ⟳ applying ${role}…"
                    if "$fn" apply "$platform" "$MACHINE"; then
                        echo "  ✓ $role applied."
                    else
                        echo "  ✗ $role failed." >&2
                        rc=1
                    fi
                    ;;
                *) echo "  – $role skipped." ;;
            esac
        else
            echo "  ▸ $role — plan:"
            "$fn" dry-run "$platform" "$MACHINE"
        fi
    else
        # Declared-planned or not? The padded-substring match is deliberate:
        # `*"$role"*` alone would let a role named `ssh` match the declaration
        # of `ssh-server`.
        case " $PLANNED_ROLES " in
            *" $role "*)
                if [ "$MODE" = "apply" ]; then
                    echo "  – $role — apply: no executor yet (declared); skipped"
                else
                    echo "  • $role — plan: no executor yet (declared)"
                fi
                ;;
            *)
                # rc=1 under --apply ONLY. A dry run is a preview: it writes
                # nothing, so it reports loudly and still exits 0, leaving the
                # nonzero status to mean "an apply did not do what it said".
                # The message is identical in both modes so the preview is the
                # warning you get BEFORE the run that fails.
                echo "  ✗ $role — no executor, and not declared in PLANNED_ROLES" >&2
                # An `if`, not `[ … ] && rc=1`: this script runs under `set -e`,
                # where a trailing test that evaluates false is a failed command
                # and kills the run — so the dry-run path would abort here.
                if [ "$MODE" = "apply" ]; then rc=1; fi
                ;;
        esac
    fi
done

exit $rc
