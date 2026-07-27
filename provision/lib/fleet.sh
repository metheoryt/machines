# provision/lib/fleet.sh — shared manifest helpers (source me; do not execute).
# Requires: jq. Consumers: provision.sh, the `just provision` recipe.
# shellcheck shell=bash

# Repo root = two levels up from this file (provision/lib/ -> repo).
_fleet_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

fleet_manifest_path() { echo "$(_fleet_lib_dir)/../../fleet.json"; }

fleet_machines() {
    jq -r '.machines | keys[]' "$(fleet_manifest_path)"
}

# fleet_hostname [hostname]: this box's OS hostname with any DNS/mDNS suffix
# stripped, so it can be matched against fleet.json's bare `detect.hostname`.
#
# macOS is why this exists: `hostname` / `uname -n` there return the Bonjour name
# (`air.local`) whenever configd has no better name to offer — which is the
# normal state on DHCP, even after `scutil --set HostName air`. An exact match
# would then miss, dropping provision.sh to its interactive picker and making
# macos.sh resolve its profile from the default instead of the manifest.
#
# Mirrors agents/bootstrap.sh's host_id(), which has always done `${h%%.*}` for
# the same reason — this brings the fleet resolvers in line with it rather than
# inventing a second convention. Harmless everywhere else: no fleet member's
# detect.hostname contains a dot (latitude5520, g614jv, g513ie, 27608, air).
fleet_hostname() {
    local h="${1:-$(hostname)}"
    printf '%s' "${h%%.*}"
}

# Echo the machine whose detect.hostname matches this box; return 1 if none.
fleet_detect() {
    local h; h="$(fleet_hostname)"
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

# fleet_profile <machine>: which provisioning tier list this machine gets
# (provision/linux.sh). Absent field => "workstation" (the full dev layer).
# Requires jq, like the helpers above.
fleet_profile() {
    jq -r --arg m "$1" '.machines[$m].profile // "workstation"' "$(fleet_manifest_path)"
}

# fleet_profile_for_host [hostname]: resolve THIS box's profile straight from
# detect.hostname; empty when no machine matches (e.g. a self-declared WSL host,
# which carries fleet.local.json and no fleet.json entry — the caller defaults it).
# Unlike every other helper here this must work WITHOUT jq: hub ships python3 but
# no jq, and profile resolution happens before the apt tier can install it.
fleet_profile_for_host() {
    local h mf
    h="$(fleet_hostname "${1:-}")"   # strip .local etc — see fleet_hostname
    mf="$(fleet_manifest_path)"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg h "$h" \
            '.machines | to_entries[] | select(.value.detect.hostname == $h) | .value.profile // "workstation"' \
            "$mf"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$mf" "$h" <<'PY'
import json, sys
manifest, host = sys.argv[1], sys.argv[2]
with open(manifest) as fh:
    machines = json.load(fh)["machines"]
for name, m in machines.items():
    if m.get("detect", {}).get("hostname") == host:
        print(m.get("profile", "workstation"))
        break
PY
    fi
}
