# provision/roles/mesh-hub.sh — the `mesh-hub` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_mesh_hub.
#
# The AmneziaWG hub (the VPS) is owned by the sibling ~/my/vps repo
# (setup-awg.sh brings up wg0; manage-peers.sh manages peers). This repo does
# not provision the hub — the executor is a no-op pointer, in both modes.
# shellcheck shell=bash

role_mesh_hub() {
    # shellcheck disable=SC2034  # mode/platform/machine: role-signature parity
    local mode="$1" platform="$2" machine="$3"
    echo "  mesh-hub: the AmneziaWG hub is owned by the ~/my/vps repo (setup-awg.sh / manage-peers.sh) — not provisioned from here."
    return 0
}
