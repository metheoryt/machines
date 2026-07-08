# provision/lib/fleet.sh — shared manifest helpers (source me; do not execute).
# Requires: jq. Consumers: provision.sh, the `just provision` recipe.
# shellcheck shell=bash

# Repo root = two levels up from this file (provision/lib/ -> repo).
_fleet_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

fleet_manifest_path() { echo "$(_fleet_lib_dir)/../../fleet.json"; }

fleet_machines() {
    jq -r '.machines | keys[]' "$(fleet_manifest_path)"
}

# Echo the machine whose detect.hostname matches this box; return 1 if none.
fleet_detect() {
    local h; h="$(hostname)"
    local m
    m="$(jq -r --arg h "$h" \
        '.machines | to_entries[] | select(.value.detect.hostname == $h) | .key' \
        "$(fleet_manifest_path)")"
    if [ -z "$m" ]; then return 1; fi
    echo "$m"
}

fleet_platform() {
    jq -r --arg m "$1" '.machines[$m].platform' "$(fleet_manifest_path)"
}

fleet_roles() {
    jq -r --arg m "$1" '.machines[$m].roles[]' "$(fleet_manifest_path)"
}
