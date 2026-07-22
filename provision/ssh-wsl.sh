#!/usr/bin/env bash
# provision/ssh-wsl.sh — give THIS WSL2 distro a fleet SSH identity: its own
# key-only sshd trusting the fleet's public keys (inbound), a persisted ed25519
# fleet key trusted by the other boxes (outbound), and a merged ~/.ssh/config
# fleet block so `ssh latitude`/`ssh server`/`ssh hub` Just Work from inside the
# distro. Companion to tailscale-wsl.sh.
#
# Model: a LEAF node, not a fleet.json member. The distro reaches out to the
# fleet AND accepts inbound fleet logins (it installs fleet-authorized-keys into
# its own ~/.ssh/authorized_keys), but is not added to fleet.json (its OS
# hostname g614jv collides with the `desktop` Windows host's detect.hostname, and
# the box is disposable). So other boxes get no `ssh <name>` alias back to it —
# reach it by tailnet IP / MagicDNS name. The inbound trust is a SNAPSHOT copy
# (unlike ssh-server.nix's declarative keyFiles): re-run this script after a new
# member joins the fleet to pick up its key.
#
# Durable across a `wsl --unregister` rebuild: the fleet key is persisted on the
# Windows host ($FLEET_KEY_DIR, default /mnt/c/Users/<winuser>/.fleet) and
# restored on the next provision, so its fleet-authorized-keys entry never goes
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

Establishes: a key-only sshd trusting fleet-authorized-keys (inbound); a persisted
ed25519 key ~/.ssh/id_fleet trusted by the fleet (outbound); a merged fleet block
in ~/.ssh/config (ssh latitude/server/hub). Run AFTER tailscale-wsl.sh. Idempotent.

  -h, --help   show this help

Env: FLEET_KEY_DIR (persistence store; default /mnt/c/Users/<winuser>/.fleet),
     FLEET_WIN_USER (Windows user for the store path; default auto-detected),
     MACHINES_REPO (repo clone; default $HOME/machines).
EOF
}

CONFIG_MARKER_BEGIN="# >>> fleet-ssh (managed by ssh-wsl.sh) >>>"
CONFIG_MARKER_END="# <<< fleet-ssh <<<"
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
    ( [ .machines | to_entries[] |
      ( [ "Host " + .key ]
        + ( if (.value.ssh.host // null) != null then [ "  HostName " + .value.ssh.host ] else [] end )
        + ( if (.value.ssh.user // "me") != "me" then [ "  User " + .value.ssh.user ] else [] end )
        + [ "  IdentityFile ~/.ssh/id_fleet", "  StrictHostKeyChecking accept-new" ]
      ) | join("\n")
    ] )
    + [ "Host *.gg.ez\n  User me\n  IdentityFile ~/.ssh/id_fleet\n  StrictHostKeyChecking accept-new" ]
    | join("\n\n")
  ' <<<"$1"
}

# True (exit 0) iff the base64 key body $1 already appears as the 2nd field of a
# line in authorized-keys/fleet-authorized-keys file $2 (comment-insensitive).
# Unreadable/missing file → false.
ssh_wsl_key_present() {
  local body="$1" file="$2"
  [ -r "$file" ] || return 1
  awk -v b="$body" '$2 == b { found = 1 } END { exit(found ? 0 : 1) }' "$file"
}

# Merge fleet public-key lines ($2, e.g. fleet-authorized-keys content) into
# existing authorized_keys content ($1): keep every existing non-blank line
# verbatim, then append each fleet key whose key BODY (2nd field) is not already
# present. Blanks + #-comments are dropped from the fleet side; existing blanks
# are dropped, existing comments kept. Echoes the merged content. Idempotent by
# body-key — merge(merge(x)) == merge(x). Pure: the only IO is reading its two
# string args. The trust is a SNAPSHOT — a member added later is not picked up
# until ssh-wsl.sh re-runs (unlike NixOS keyFiles, which re-reads each rebuild).
ssh_wsl_merge_authorized_keys() {
  awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }
    FNR == NR {                        # $1 — existing authorized_keys
      if (blank($0)) next
      print
      if ($1 !~ /^#/ && $2 != "") have[$2] = 1
      next
    }
    blank($0) || $1 ~ /^#/ { next }    # $2 — fleet keys: skip blanks + comments
    $2 != "" && !($2 in have) { print; have[$2] = 1 }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
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

# Map this box's hostname ($2) to the fleet member whose detect.hostname matches
# it (case-insensitive), so the per-Windows-host leaf key is named after the
# fleet box it lives inside (e.g. g614jv → desktop → me@wsl-desktop). Falls back
# to the sanitized hostname when no fleet member matches. Deterministic; the only
# IO is invoking jq on the fleet.json content ($1).
ssh_wsl_host_label() {
  local label
  label="$(jq -r --arg h "$2" '
    .machines | to_entries[]
    | select((.value.detect.hostname // "" | ascii_downcase) == ($h | ascii_downcase))
    | .key' <<<"$1" 2>/dev/null | head -1)"
  [ -n "$label" ] || label="$(ssh_wsl_sanitize "$2")"
  printf '%s' "$label"
}

# Normalize a public-key line ($1, e.g. `ssh-keygen -y` output) to exactly
# "<type> <body> <comment>": keep only the first two fields (ssh-keygen -y echoes
# any embedded comment, which would otherwise double-stamp) and apply comment $2.
ssh_wsl_stamp_pub() {
  printf '%s %s\n' "$(printf '%s' "$1" | awk '{print $1, $2}')" "$2"
}

# Allow sourcing just the functions (for tests) without running main.
[ "${SSH_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Args ──────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  warn "does not look like WSL — continuing anyway."
fi
have jq || die "jq not found — run provision/linux.sh first (its CORE apt base installs jq)."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

if ! systemctl show-environment >/dev/null 2>&1; then
  die "systemd not running in this distro. Add to /etc/wsl.conf:  [boot]\\nsystemd=true  then 'wsl -t $(uname -n)' and re-open."
fi

MACHINES_REPO="${MACHINES_REPO:-$HOME/machines}"
FLEET_JSON="$MACHINES_REPO/fleet.json"
[ -r "$FLEET_JSON" ] || die "fleet.json not readable at $FLEET_JSON — set \$MACHINES_REPO to your clone."

# ── 1. sshd (key-only) ────────────────────────────────────────────────────────
info "Installing + configuring sshd (key-only)…"
$SUDO apt-get install -y openssh-server >/dev/null || die "openssh-server install failed."
$SUDO ssh-keygen -A >/dev/null 2>&1 || true   # ensure host keys (idempotent)

DROPIN="/etc/ssh/sshd_config.d/10-fleet.conf"
DROPIN_WANT="# Managed by ssh-wsl.sh — key-only auth for the fleet. Do not edit.
PasswordAuthentication no
KbdInteractiveAuthentication no"
if [ "$($SUDO cat "$DROPIN" 2>/dev/null)" != "$DROPIN_WANT" ]; then
  printf '%s\n' "$DROPIN_WANT" | $SUDO tee "$DROPIN" >/dev/null
  ok "wrote $DROPIN"
else
  ok "sshd drop-in already current"
fi
$SUDO systemctl enable --now ssh >/dev/null 2>&1 || die "could not enable/start ssh.service."
$SUDO systemctl reload-or-restart ssh || warn "sshd reload-or-restart failed — check 'systemctl status ssh'."

# ── 2. Fleet identity key, persisted on the Windows host ──────────────────────
KEY="$HOME/.ssh/$FLEET_KEY_NAME"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
# One key per Windows HOST (the store below is host-scoped, so every distro on a
# host shares it) — so name it after the host, not the distro: map uname -n to
# the matching fleet member (g614jv → desktop), else the sanitized hostname.
KEY_COMMENT="me@wsl-$(ssh_wsl_host_label "$(cat "$FLEET_JSON")" "$(uname -n)")"

# Resolve the persistence store. Auto-detect the single non-system dir under
# /mnt/c/Users unless FLEET_WIN_USER / FLEET_KEY_DIR pin it.
FLEET_KEY_DIR="${FLEET_KEY_DIR:-}"
if [ -z "$FLEET_KEY_DIR" ]; then
  win_user="${FLEET_WIN_USER:-}"
  if [ -z "$win_user" ] && [ -d /mnt/c/Users ]; then
    win_user="$(find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d \
      ! -iname 'Public' ! -iname 'Default' ! -iname 'Default User' \
      ! -iname 'All Users' ! -iname 'DefaultAppPool' -printf '%f\n' 2>/dev/null)"
    [ "$(printf '%s\n' "$win_user" | grep -c .)" = 1 ] || win_user=""
  fi
  [ -n "$win_user" ] && FLEET_KEY_DIR="/mnt/c/Users/$win_user/.fleet"
fi

STORE_KEY=""
[ -n "$FLEET_KEY_DIR" ] && STORE_KEY="$FLEET_KEY_DIR/$FLEET_KEY_NAME"

persist_key() {  # copy the live key pair into the store (best-effort; /mnt/c = Windows ACLs)
  [ -n "$FLEET_KEY_DIR" ] || { warn "no persistence store (set \$FLEET_KEY_DIR) — key NOT persisted; a rebuild will mint a NEW key and need re-appending to fleet-authorized-keys."; return; }
  mkdir -p "$FLEET_KEY_DIR" || { warn "could not create $FLEET_KEY_DIR — key not persisted."; return; }
  # shellcheck disable=SC2015  # ok() is a printf wrapper, never fails; || warn is the real else
  cp "$KEY" "$STORE_KEY" && cp "$KEY.pub" "$STORE_KEY.pub" \
    && ok "persisted fleet key → $STORE_KEY (Windows ACLs; unix 0600 not enforced on /mnt/c)" \
    || warn "could not copy key into $FLEET_KEY_DIR."
}

if [ -n "$STORE_KEY" ] && [ -f "$STORE_KEY" ]; then
  install -m600 "$STORE_KEY" "$KEY"
  # Derive the public key from the restored private key rather than trusting a
  # stored .pub — a priv-only store still yields a correct ~/.ssh/id_fleet.pub.
  # Keep only type+body (ssh-keygen -y echoes any embedded comment, which would
  # double-stamp), then apply the host-based comment so every restore (rebuild or
  # second distro on this host) is labelled after the host, not blank/doubled.
  if pub="$(ssh-keygen -y -f "$KEY" 2>/dev/null)"; then
    ssh_wsl_stamp_pub "$pub" "$KEY_COMMENT" > "$KEY.pub"; chmod 644 "$KEY.pub"
  else die "could not derive public key from restored $KEY."; fi
  ok "restored fleet key from store ($STORE_KEY)"
elif [ -f "$KEY" ]; then
  ok "fleet key already present ($KEY)"
  persist_key   # store was wiped but the local key survives — re-persist it
else
  info "Generating fleet key $KEY (ed25519)…"
  ssh-keygen -t ed25519 -N '' -C "$KEY_COMMENT" -f "$KEY" >/dev/null || die "ssh-keygen failed."
  persist_key
fi

# ── 3. Trust outward — append id_fleet.pub to fleet-authorized-keys ────────────
MESH_KEYS="$MACHINES_REPO/provision/fleet-authorized-keys"
PUB_BODY="$(awk '{print $2}' "$KEY.pub")"
if [ ! -f "$MESH_KEYS" ]; then
  warn "fleet-authorized-keys not found at $MESH_KEYS — skipped trust append (set \$MACHINES_REPO)."
elif ssh_wsl_key_present "$PUB_BODY" "$MESH_KEYS"; then
  ok "already trusted (fleet-authorized-keys)"
else
  printf '%s\n' "$(cat "$KEY.pub")" >> "$MESH_KEYS"
  ok "appended id_fleet.pub → provision/fleet-authorized-keys"
  warn "commit + push fleet-authorized-keys, then re-provision the other boxes (nixos-rebuild switch / windows.ps1) so they trust this key."
fi

# ── 4. Trust inward — install fleet-authorized-keys into ~/.ssh/authorized_keys
# Make THIS box accept inbound fleet logins (mirrors ssh-server.nix's keyFiles on
# NixOS). Snapshot copy — re-run this script after a new member joins the fleet.
AUTHK="$HOME/.ssh/authorized_keys"
if [ ! -f "$MESH_KEYS" ]; then
  warn "fleet-authorized-keys not found at $MESH_KEYS — skipped inbound trust (box won't accept fleet SSH)."
else
  EXISTING_AK=""
  [ -f "$AUTHK" ] && EXISTING_AK="$(cat "$AUTHK")"
  tmp_ak="$(mktemp)"
  ssh_wsl_merge_authorized_keys "$EXISTING_AK" "$(cat "$MESH_KEYS")" > "$tmp_ak"
  if [ -f "$AUTHK" ] && cmp -s "$tmp_ak" "$AUTHK"; then
    ok "authorized_keys already trusts the fleet"
  else
    install -m600 "$tmp_ak" "$AUTHK"
    ok "installed fleet keys → $AUTHK (inbound trust)"
  fi
  rm -f "$tmp_ak"
fi

# ── 5. Client config — merged fleet block in ~/.ssh/config ────────────────────
CONFIG="$HOME/.ssh/config"
STANZAS="$(ssh_wsl_render_config "$(cat "$FLEET_JSON")")" || die "rendering fleet config failed."
[ -n "$STANZAS" ] || die "fleet config rendered empty — check $FLEET_JSON."
BLOCK="$CONFIG_MARKER_BEGIN
$STANZAS
$CONFIG_MARKER_END"

EXISTING=""
[ -f "$CONFIG" ] && EXISTING="$(cat "$CONFIG")"
tmp="$(mktemp)"
ssh_wsl_merge_config "$EXISTING" "$BLOCK" > "$tmp"
install -m600 "$tmp" "$CONFIG"
rm -f "$tmp"
ok "merged fleet block into $CONFIG (block replaced; rest untouched)"

# ── 6. Verify ─────────────────────────────────────────────────────────────────
# shellcheck disable=SC2015  # ok() is a printf wrapper, never fails; || warn is the real else
$SUDO systemctl is-active --quiet ssh && ok "sshd active" || warn "sshd not active — check 'systemctl status ssh'."
if have ss; then
  # shellcheck disable=SC2015  # ok() is a printf wrapper, never fails; || warn is the real else
  ss -ltn 2>/dev/null | grep -qE '[:.]22 ' && ok "listening on :22" || warn "no listener on :22 yet."
fi
[ -f "$KEY" ] && ok "fleet key: $KEY (pub: $KEY.pub)"
# shellcheck disable=SC2015  # ok() is a printf wrapper, never fails; || warn is the real else
[ -f "$AUTHK" ] && ok "inbound trust: $AUTHK ($(grep -cvE '^\s*($|#)' "$AUTHK" 2>/dev/null) fleet keys)" || warn "no ~/.ssh/authorized_keys — inbound fleet SSH will be refused."
info "Try:  ssh -o BatchMode=yes latitude true   (works once latitude trusts id_fleet)"
printf '\nNext: commit+push provision/fleet-authorized-keys and re-provision the other boxes if this run appended a key.\n'
