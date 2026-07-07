#!/usr/bin/env bash
# provision/provision.sh — fleet front door (WSL / Linux / nixos).
# Phase 1: detect/select the machine and PRINT the plan. Applies nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision/lib/fleet.sh
source "$HERE/lib/fleet.sh"

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
while IFS= read -r role; do
    if [ "$MODE" = "apply" ]; then
        echo "  ✗ $role — apply: not yet implemented (later phase)"
    else
        echo "  • $role — plan: would converge via the $platform executor for '$role'"
    fi
done < <(fleet_roles "$MACHINE")

if [ "$MODE" = "apply" ]; then
    echo "apply is not implemented in Phase 1; run without --apply." >&2
    exit 1
fi
