# provision/roles/mesh-member.sh — the `mesh-member` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_mesh_member.
#
# NixOS: `switch` already declares awg0 + sshd (modules/system/mesh-vpn.nix).
# The only imperative gap is the out-of-store private key. This executor: if
# /etc/amnezia-wg/awg0.key is absent, fetch THIS box's conf from the VPS hub
# (lib/mesh.sh), extract the PrivateKey, and write it root-owned; then verify
# the tunnel (handshake + that the AmneziaWG kernel module is loaded). It never
# mutates the declared config and never generates keys locally.
#
# wsl shares the Windows host tunnel; debian is the hub, not a member.
# Design: docs/superpowers/specs/2026-07-08-fleet-provisioner-phase5-mesh-executor-design.md
# shellcheck shell=bash

role_mesh_member() {
    local mode="$1" platform="$2" machine="$3"
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=provision/lib/mesh.sh
    source "$here/../lib/mesh.sh"

    case "$platform" in
        nixos)
            local key=/etc/amnezia-wg/awg0.key
            if [ -f "$key" ]; then
                echo "  mesh-member: $key present — key already installed (no fetch)."
            elif [ "$mode" = apply ]; then
                echo "  mesh-member: $key absent — fetching this box's conf from the hub…"
                local conf priv
                if conf="$(mesh_ssh_fetch "$machine")"; then
                    priv="$(printf '%s\n' "$conf" | sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' | head -1)"
                    if [ -z "$priv" ]; then
                        echo "  mesh-member: fetched conf had no PrivateKey — aborting (nothing written)." >&2
                        return 1
                    fi
                    if ! sudo install -m 600 -o root -g root -D /dev/null "$key"; then
                        echo "  mesh-member: could not create $key (install failed) — nothing written." >&2
                        return 1
                    fi
                    if ! printf '%s\n' "$priv" | sudo tee "$key" >/dev/null; then
                        echo "  mesh-member: could not write $key (tee failed)." >&2
                        return 1
                    fi
                    echo "  mesh-member: wrote $key (root:600). PrivateKey not shown."
                else
                    mesh_manual_hint "$machine"
                    return 0   # graceful: a hub hiccup must not fail the run
                fi
            else
                mesh_dryrun_line "$machine" "$key"
            fi
            if [ "$mode" = apply ]; then
                _mesh_member_nixos_verify
            else
                echo "  ~ would verify awg0 handshake + kernel module after install."
            fi
            return 0
            ;;
        wsl)
            echo "  mesh-member: wsl shares the Windows host's AmneziaVPN tunnel — no separate setup (skipped)."
            return 0
            ;;
        debian)
            echo "  mesh-member: 'debian' is the hub platform, not a mesh member (skipped)."
            return 0
            ;;
        *)
            echo "  mesh-member: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac
}

# Best-effort tunnel verify (apply only; may prompt for sudo). Non-fatal.
_mesh_member_nixos_verify() {
    if command -v awg >/dev/null 2>&1 && sudo awg show awg0 >/dev/null 2>&1; then
        local hs
        hs="$(sudo awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)"
        if [ -n "$hs" ] && [ "$hs" != 0 ]; then
            echo "  mesh-member: awg0 up with a recent handshake. ✓"
        else
            echo "  mesh-member: awg0 configured but no handshake yet (enable/keepalive, or check the hub peer)."
        fi
    else
        echo "  mesh-member: awg0 not up. If 'modprobe: amneziawg not found', reboot into the LTS kernel 6.18.38 so the out-of-tree module loads."
    fi
}
