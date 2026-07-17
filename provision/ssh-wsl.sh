#!/usr/bin/env bash
# provision/ssh-wsl.sh — give THIS WSL2 distro a fleet SSH identity: its own
# key-only sshd, a persisted ed25519 fleet key trusted by the other boxes, and a
# merged ~/.ssh/config fleet block so `ssh latitude`/`ssh server`/`ssh hub` Just
# Work from inside the distro. Companion to tailscale-wsl.sh + orca-serve.sh.
#
# Model: a LEAF node, not a fleet.json member. The distro reaches out to the
# fleet and is trusted by it, but is not added to fleet.json (its OS hostname
# g614jv collides with the `desktop` Windows host's detect.hostname, and the box
# is disposable). So other boxes are not auto-configured to `ssh` back to it.
#
# Durable across a `wsl --unregister` rebuild: the fleet key is persisted on the
# Windows host ($FLEET_KEY_DIR, default /mnt/c/Users/<winuser>/.fleet) and
# restored on the next provision, so its mesh-authorized-keys entry never goes
# stale. sshd is key-only (PasswordAuthentication no); the WSL console is always
# available independent of sshd, so there is no lockout risk.
#
# Idempotent; safe to re-run. Run AFTER tailscale-wsl.sh (needs the tailnet up
# and MagicDNS resolving). Requires jq (installed by linux.sh's CORE apt base).
#
# Env knobs (all defaulted):
#   FLEET_KEY_DIR   persistence store       (default /mnt/c/Users/<winuser>/.fleet)
#   FLEET_WIN_USER  Windows user for the store path (default: auto-detected)
#   MACHINES_REPO   this repo clone          (default $HOME/machines)
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
ssh-wsl.sh — give THIS WSL distro a fleet SSH identity (leaf node).

Establishes: a key-only sshd; a persisted ed25519 key ~/.ssh/id_fleet trusted by
the fleet; a merged fleet block in ~/.ssh/config (ssh latitude/server/hub). Run
AFTER tailscale-wsl.sh. Idempotent.

  -h, --help   show this help

Env: FLEET_KEY_DIR (persistence store; default /mnt/c/Users/<winuser>/.fleet),
     FLEET_WIN_USER (Windows user for the store path; default auto-detected),
     MACHINES_REPO (repo clone; default $HOME/machines).
EOF
}

CONFIG_MARKER_BEGIN="# >>> fleet-ssh (managed by ssh-wsl.sh) >>>"
CONFIG_MARKER_END="# <<< fleet-ssh <<<"
# shellcheck disable=SC2034  # FLEET_KEY_NAME is exported for Task 2's main
FLEET_KEY_NAME="id_fleet"

# DNS-label safe: lowercase, non [a-z0-9-] → '-', collapse repeats, trim edges.
# Local copy of tailscale-wsl.sh's ts_sanitize_hostname — the scripts stay
# independent, so we duplicate this tiny helper rather than cross-source.
ssh_wsl_sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Render the fleet client-config stanzas from fleet.json content (passed as $1),
# mirroring modules/home/ssh.nix: HostName only for the hub (its ssh.host), a
# User line only when ssh.user != me, and IdentityFile + StrictHostKeyChecking on
# every block. Blocks are separated by a blank line, no trailing blank. Markers
# are added by the caller. Deterministic; the only IO is invoking jq on $1.
ssh_wsl_render_config() {
  jq -r '
    [ .machines | to_entries[] |
      ( [ "Host " + .key ]
        + ( if .value.mesh.role == "hub" then [ "  HostName " + .value.ssh.host ] else [] end )
        + ( if (.value.ssh.user // "me") != "me" then [ "  User " + .value.ssh.user ] else [] end )
        + [ "  IdentityFile ~/.ssh/id_fleet", "  StrictHostKeyChecking accept-new" ]
      ) | join("\n")
    ] | join("\n\n")
  ' <<<"$1"
}

# True (exit 0) iff the base64 key body $1 already appears as the 2nd field of a
# line in authorized-keys/mesh-authorized-keys file $2 (comment-insensitive).
# Unreadable/missing file → false.
ssh_wsl_key_present() {
  local body="$1" file="$2"
  [ -r "$file" ] || return 1
  awk -v b="$body" '$2 == b { found = 1 } END { exit(found ? 0 : 1) }' "$file"
}

# Merge fleet BLOCK ($2) into existing ~/.ssh/config content ($1): drop any prior
# marked span (BEGIN..END inclusive), keep everything else, and append the block
# exactly once, separated by a single blank line. Echoes the new content.
# Deterministic and idempotent by construction — command substitution strips the
# trailing newlines, so merge(merge(x)) == merge(x) with no blank-line accretion.
ssh_wsl_merge_config() {
  local kept
  kept="$(printf '%s\n' "$1" | awk -v b="$CONFIG_MARKER_BEGIN" -v e="$CONFIG_MARKER_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip')"
  if [ -n "$kept" ]; then
    printf '%s\n\n%s\n' "$kept" "$2"
  else
    printf '%s\n' "$2"
  fi
}

# Allow sourcing just the functions (for tests) without running main.
[ "${SSH_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null
