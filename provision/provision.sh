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

platform="$(fleet_platform "$MACHINE")"
echo "▸ Machine: $MACHINE   platform: $platform   mode: $MODE"
echo "▸ Roles:"
# Read roles into an array first so the confirm `read` below uses the terminal,
# not the role stream (a `while read < <(...)` loop would swallow the answer).
roles=()
while IFS= read -r role; do roles+=("$role"); done < <(fleet_roles "$MACHINE")

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
                    echo "  ⟳ applying $role…"
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
        if [ "$MODE" = "apply" ]; then
            echo "  ✗ $role — apply: not yet implemented (skipped)"
        else
            echo "  • $role — plan: would converge via the $platform executor for '$role'"
        fi
    fi
done

exit $rc
