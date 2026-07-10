# provision/lib/mesh.sh — shared VPS conf-fetch helper (source me; do not execute).
# Sourced by provision/roles/mesh-member.sh. Requires: jq, ssh.
#
# The VPS hub is the AmneziaWG key authority (its ~/my/vps manage-peers.sh runs
# `awg genkey`, assigns the IP, stores the key, and emits the client conf). A
# member does NOT generate keys locally — it SSHes the hub's PUBLIC endpoint
# (never the mesh IP: the mesh is what's being brought up) and fetches its OWN
# peer conf: `show <peer> --conf-only` first (idempotent, no rotation), else
# `add <peer> <ip> --conf-only` (brand-new peer). Add-only, self-only: never
# remove/rewrite other peers — the live wg0 carries friends' peers.
#
# SECRET HANDLING: the fetched conf contains a PrivateKey. It is returned on
# stdout for the caller to install to an out-of-git path; it is NEVER logged,
# echoed, or shown in dry-run. Callers must not print it.
#
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
# shellcheck shell=bash

# Manifest path: env override (tests) else repo-root fleet.json (lib/ -> repo).
MESH_MANIFEST="${MESH_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/fleet.json}"
# ssh binary: env override (tests inject a stub) else the real client.
MESH_SSH="${MESH_SSH:-ssh}"

# "<user>@<host>" for the hub (the single machine with mesh.role=="hub").
# host = ssh.host if set, else the mesh IP; user = ssh.user or "me".
mesh_hub_target() {
    jq -r '
        .machines | to_entries[] | select(.value.mesh.role == "hub") | .value
        | ((.ssh.user // "me") + "@" + (.ssh.host // .mesh.ip))
    ' "$MESH_MANIFEST"
}

# Absolute path to manage-peers.sh on the hub.
mesh_hub_script() {
    jq -r '
        .machines | to_entries[] | select(.value.mesh.role == "hub")
        | .value.mesh.managePeers // "/home/debian/vps/vps/manage-peers.sh"
    ' "$MESH_MANIFEST"
}

# VPS-side peer name for a machine (defaults to the machine key).
mesh_peer_name() {
    jq -r --arg m "$1" '.machines[$m].mesh.peerName // $m' "$MESH_MANIFEST"
}

# Mesh IP for a machine.
mesh_peer_ip() {
    jq -r --arg m "$1" '.machines[$m].mesh.ip' "$MESH_MANIFEST"
}

# Fetch this machine's client conf from the hub. Prints the raw conf to stdout
# on success (rc 0); rc 1 on any failure. Key is captured in a local var and
# never logged. `show` first (no rotation), then `add`.
mesh_ssh_fetch() {
    local machine="$1"
    local target peer ip script conf
    target="$(mesh_hub_target)"
    peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"
    script="$(mesh_hub_script)"

    # 1) existing peer — reuse the stored key (no rotation)
    if conf="$("$MESH_SSH" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
            "sudo bash '$script' show '$peer' --conf-only" 2>/dev/null)" \
        && printf '%s' "$conf" | grep -q '^\[Interface\]'; then
        printf '%s\n' "$conf"
        return 0
    fi

    # 2) not found — create a brand-new peer at its fleet IP
    if conf="$("$MESH_SSH" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
            "sudo bash '$script' add '$peer' '$ip' --conf-only" 2>/dev/null)" \
        && printf '%s' "$conf" | grep -q '^\[Interface\]'; then
        printf '%s\n' "$conf"
        return 0
    fi

    return 1
}

# Graceful-degradation hint (STDERR) — the exact by-hand lines to run on the VPS.
mesh_manual_hint() {
    local machine="$1" target peer ip script
    target="$(mesh_hub_target)"; peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"; script="$(mesh_hub_script)"
    {
        echo "  mesh: could not reach the hub over SSH — skipping (run did NOT fail)."
        echo "  mesh: to provision '$machine' by hand, on the VPS ($target) run:"
        echo "      sudo bash $script show $peer --conf-only     # existing peer"
        echo "      sudo bash $script add  $peer $ip --conf-only # new peer"
    } >&2
}

# Dry-run plan (STDOUT) — key-redacted; describes the SSH + install without doing it.
mesh_dryrun_line() {
    local machine="$1" install_path="$2" target peer ip script
    target="$(mesh_hub_target)"; peer="$(mesh_peer_name "$machine")"
    ip="$(mesh_peer_ip "$machine")"; script="$(mesh_hub_script)"
    echo "  ~ would ssh $target → sudo bash $script show $peer --conf-only (else add $peer $ip --conf-only)"
    echo "  ~ would install the fetched conf to $install_path (PrivateKey redacted; never shown)"
}
