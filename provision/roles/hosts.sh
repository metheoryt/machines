# provision/roles/hosts.sh — the `hosts` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_hosts.
#
# hosts = fleet-wide name resolution via a marker-delimited managed block in the
# system hosts file (/etc/hosts), generated from fleet.json tailnet IPs. On nixos
# it is owned by modules/system/fleet-hosts.nix (networking.hosts), so the
# dispatcher must NOT touch /etc/hosts there. Target path is overridable via
# FLEET_HOSTS_FILE (for testing without root).
# shellcheck shell=bash

_HOSTS_BEGIN="# BEGIN fleet hosts (managed by provision - do not edit)"
_HOSTS_END="# END fleet hosts"

# Emit the managed block (markers + one "ip   name" line per machine, sorted).
_hosts_block() {
    printf '%s\n' "$_HOSTS_BEGIN"
    jq -r '.machines | to_entries | sort_by(.key)[] | "\(.value.tailnet.ip)   \(.key)"' \
        "$(fleet_manifest_path)"
    printf '%s' "$_HOSTS_END"
}

# Echo <file> with any existing managed block removed AND trailing blank lines
# trimmed (so repeated applies converge byte-for-byte).
_hosts_without_block() {
    awk -v b="$_HOSTS_BEGIN" -v e="$_HOSTS_END" '
        $0==b {inblk=1; next}
        $0==e {inblk=0; next}
        !inblk {lines[++n]=$0}
        END {
            while (n>0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i=1;i<=n;i++) print lines[i]
        }
    ' "$1"
}

# role_hosts <mode> <platform> <machine>
#   mode: dry-run | apply
role_hosts() {
    # shellcheck disable=SC2034  # machine: kept for role-signature parity
    local mode="$1" platform="$2" machine="$3"
    case "$platform" in
        nixos)
            echo "  hosts: owned by networking.hosts on nixos — applied by 'just switch'; dispatcher skips."
            return 0
            ;;
        wsl|debian) ;; # proceed
        *)
            echo "  hosts: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac

    local target="${FLEET_HOSTS_FILE:-/etc/hosts}"
    local block; block="$(_hosts_block)"

    if [ "$mode" = apply ]; then
        local tmp; tmp="$(mktemp)"
        { _hosts_without_block "$target"; printf '\n%s\n' "$block"; } > "$tmp"
        if [ -w "$target" ]; then
            cat "$tmp" > "$target"
        else
            sudo cp "$tmp" "$target"
        fi
        rm -f "$tmp"
        echo "  hosts: wrote fleet block to $target"
    else
        echo "  hosts: would write this block to $target:"
        printf '%s\n' "$block" | sed 's/^/    /'
    fi
}
