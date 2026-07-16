#!/usr/bin/env bash
# provision/tailscale-wsl.sh — enroll THIS WSL2 distro as a distinct node on the
# fleet's Headscale tailnet (control https://cc.cyphy.kz), so a server running
# inside the distro (Orca, ssh, rustdesk) is reachable from other tailnet nodes
# at its OWN 100.64.x.y — independent of the Windows host's own Tailscale.
# Pairs with provision/orca-serve.sh.
#
# Model: one tailscaled PER distro (NOT host mirrored-networking), so N distros
# on one Windows host each get a distinct identity and Orca can use the default
# port 6768 everywhere. Inbound arrives via the VPS DERP relay (region 999)
# through WSL's default NAT — no port forwarding, no .wslconfig change.
#
# Zero-touch re-enroll: the resolved pre-auth key is persisted to
# /etc/headscale/authkey (root:root 0600) and a systemd *system* oneshot
# (tailscale-autoconnect.service) re-runs `tailscale up` at boot whenever the
# node isn't already connected — so a rebuilt/logged-out distro rejoins the
# tailnet with no hand-pasted key.
#
# Idempotent; safe to re-run. Requires systemd in the distro (Ubuntu 24.04+/
# 26.04 default; else set [boot] systemd=true in /etc/wsl.conf and `wsl -t <d>`).
#
# Usage (inside the distro) — supply the reusable pre-auth key (headscale user
# 'fleet') by ANY ONE of, precedence high→low:
#   bash ~/machines/provision/tailscale-wsl.sh --authkey-file provision/secrets/authkey
#   HEADSCALE_AUTHKEY='<key>' bash ~/machines/provision/tailscale-wsl.sh
#   bash ~/machines/provision/tailscale-wsl.sh   # reuse persisted /etc/headscale/authkey
#   # optional custom node name:
#   ORCA_TS_HOSTNAME=devbox bash ~/machines/provision/tailscale-wsl.sh
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
tailscale-wsl.sh — enroll THIS WSL distro as its own Headscale tailnet node.

Pre-auth key precedence (high→low): --authkey-file <path>, $HEADSCALE_AUTHKEY,
persisted /etc/headscale/authkey. The resolved key is persisted (root:root 0600)
and a boot-time systemd oneshot (tailscale-autoconnect.service) re-enrolls
hands-free after a rebuild/logout.

  --enroll                mint a fresh reusable key over SSH to the control
                          server, then enroll (needs SSH access to the VPS)
  --authkey-file <path>   read the reusable pre-auth key from <path>
  --hostname <name>       node name (else $ORCA_TS_HOSTNAME, else prompt on a
                          TTY, else wsl-<distro>)
  -h, --help              show this help

Env: HEADSCALE_AUTHKEY (key), ORCA_TS_HOSTNAME (node name; default wsl-<distro>),
     HEADSCALE_SSH (default debian@cyphy.kz), HEADSCALE_USER_ID (default 1),
     HEADSCALE_KEY_EXPIRY (default 2160h) — the last three drive --enroll.
EOF
}

LOGIN_SERVER="https://cc.cyphy.kz"
AUTHKEY_STORE="/etc/headscale/authkey"

# DNS-label safe: lowercase, non [a-z0-9-] → '-', collapse repeats, trim edges.
ts_sanitize_hostname() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Pick a pre-auth key by precedence: --authkey-file > $HEADSCALE_AUTHKEY >
# persisted store. Args are the three already-materialized candidate values
# (pure, so tailscale-wsl.test.sh can exercise the precedence without touching
# /etc or sudo). Echoes "<source>\t<key>"; both empty when every candidate is.
ts_pick_key() {
  if   [ -n "$1" ]; then printf 'authkey-file\t%s' "$1"
  elif [ -n "$2" ]; then printf 'env\t%s' "$2"
  elif [ -n "$3" ]; then printf 'persisted\t%s' "$3"
  else printf '\t'; fi
}

# Extract the single "key" field from headscale's JSON preauthkey output — no
# jq dependency (the WSL box needs nothing extra installed). Tolerates
# pretty-printed / multiline JSON. Echoes the key, or nothing if absent.
ts_extract_key_json() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -n -E 's/.*"key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}

# Mint a fresh reusable + expiring pre-auth key from the control server over
# SSH (headscale is native there and the ssh user runs it without sudo). Echoes
# the key on success; returns non-zero on ssh/headscale failure. Overridable via
# $HEADSCALE_SSH, $HEADSCALE_USER_ID, $HEADSCALE_KEY_EXPIRY.
ts_mint_key() {
  local target="${HEADSCALE_SSH:-debian@cyphy.kz}"
  local uid="${HEADSCALE_USER_ID:-1}"
  local ttl="${HEADSCALE_KEY_EXPIRY:-2160h}"
  local json
  json="$(ssh -o ConnectTimeout=15 "$target" \
    "headscale preauthkeys create --user $uid --reusable --expiration $ttl -o json")" || return 1
  ts_extract_key_json "$json"
}

# Allow sourcing just the functions (for tests) without running main.
[ "${TS_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── Args ──────────────────────────────────────────────────────────────────────
AUTHKEY_FILE=""
HOSTNAME_ARG=""
ENROLL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --enroll) ENROLL=1; shift ;;
    --authkey-file) AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    --hostname) HOSTNAME_ARG="${2:-}"; [ -n "$HOSTNAME_ARG" ] || die "--hostname needs a name."; shift 2 ;;
    --hostname=*) HOSTNAME_ARG="${1#*=}"; shift ;;
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

SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

# systemd is required for tailscaled + the autoconnect unit.
if ! systemctl show-environment >/dev/null 2>&1; then
  die "systemd not running in this distro. Add to /etc/wsl.conf:  [boot]\\nsystemd=true  then 'wsl -t $(uname -n)' and re-open."
fi

# ── Node hostname ─────────────────────────────────────────────────────────────
# Precedence: --hostname > $ORCA_TS_HOSTNAME > interactive prompt (TTY only) >
# computed default. Every source is sanitized to a DNS-safe label. A prompt
# fires ONLY on a TTY, so piped/automated runs never block on stdin.
DEFAULT_NAME="wsl-$(ts_sanitize_hostname "${WSL_DISTRO_NAME:-$(uname -n)}")"
if [ -n "$HOSTNAME_ARG" ]; then
  HOSTNAME_TS="$(ts_sanitize_hostname "$HOSTNAME_ARG")"
elif [ -n "${ORCA_TS_HOSTNAME:-}" ]; then
  HOSTNAME_TS="$(ts_sanitize_hostname "$ORCA_TS_HOSTNAME")"
elif [ -t 0 ]; then
  printf '\033[0;36m▸ Node hostname [%s]: \033[0m' "$DEFAULT_NAME" >&2
  read -r reply || reply=""
  HOSTNAME_TS="$([ -n "$reply" ] && ts_sanitize_hostname "$reply" || printf '%s' "$DEFAULT_NAME")"
else
  HOSTNAME_TS="$DEFAULT_NAME"
fi
[ -n "$HOSTNAME_TS" ] || HOSTNAME_TS="$DEFAULT_NAME"   # sanitizing junk (e.g. "!!!") → empty
info "Node hostname: $HOSTNAME_TS"

# ── Resolve the pre-auth key (precedence: --authkey-file → env → persisted) ───
FILE_KEY=""
if [ -n "$AUTHKEY_FILE" ]; then
  [ -r "$AUTHKEY_FILE" ] || die "--authkey-file not readable: $AUTHKEY_FILE"
  FILE_KEY="$(tr -d '[:space:]' < "$AUTHKEY_FILE")"
  [ -n "$FILE_KEY" ] || die "--authkey-file is empty: $AUTHKEY_FILE"
fi
STORE_KEY=""
[ -e "$AUTHKEY_STORE" ] && STORE_KEY="$($SUDO cat "$AUTHKEY_STORE" 2>/dev/null | tr -d '[:space:]')"

if [ "$ENROLL" = 1 ]; then
  info "Minting a reusable key via ${HEADSCALE_SSH:-debian@cyphy.kz} (user ${HEADSCALE_USER_ID:-1}, expiry ${HEADSCALE_KEY_EXPIRY:-2160h})…"
  AUTHKEY="$(ts_mint_key)" || die "mint failed — check \$HEADSCALE_SSH and your SSH access to the control server."
  [ -n "$AUTHKEY" ] || die "mint returned no key — check 'headscale preauthkeys create' on the control server."
  KEY_SRC="enroll"
else
  picked="$(ts_pick_key "$FILE_KEY" "${HEADSCALE_AUTHKEY:-}" "$STORE_KEY")"
  tab=$'\t'
  KEY_SRC="${picked%%"$tab"*}"
  AUTHKEY="${picked#*"$tab"}"
fi
[ -n "$KEY_SRC" ] && info "Pre-auth key source: $KEY_SRC"

# Persist a freshly-supplied key (from file/env) so the autoconnect unit and
# future runs can re-enroll hands-free. A key that came from the store is
# already persisted — don't rewrite it.
if [ -n "$AUTHKEY" ] && [ "$KEY_SRC" != persisted ]; then
  $SUDO mkdir -p "$(dirname "$AUTHKEY_STORE")"
  printf '%s\n' "$AUTHKEY" | $SUDO tee "$AUTHKEY_STORE" >/dev/null
  $SUDO chown root:root "$AUTHKEY_STORE"
  $SUDO chmod 0600 "$AUTHKEY_STORE"
  ok "pre-auth key persisted → $AUTHKEY_STORE (root:root 0600)"
fi

# ── Already enrolled? ─────────────────────────────────────────────────────────
ALREADY_UP=0
if have tailscale && tailscale ip -4 2>/dev/null | grep -qE '^100\.'; then
  ALREADY_UP=1
  ok "already enrolled: $(tailscale ip -4 | head -1) ($HOSTNAME_TS.fleet.mesh)"
fi

# ── Install tailscale ─────────────────────────────────────────────────────────
if have tailscale; then
  ok "tailscale already installed"
else
  info "Installing tailscale…"
  curl -fsSL https://tailscale.com/install.sh | sh || die "tailscale install failed."
fi

# ── Start the daemon ──────────────────────────────────────────────────────────
$SUDO systemctl enable --now tailscaled || die "could not start tailscaled."

# ── /dev/net/tun sanity ───────────────────────────────────────────────────────
[ -e /dev/net/tun ] || warn "/dev/net/tun missing — inbound serving may need 'tailscaled --tun=userspace-networking'. Modern WSL2 kernels provide tun."

# ── Enroll (skip if already up) ───────────────────────────────────────────────
if [ "$ALREADY_UP" = 0 ]; then
  [ -n "$AUTHKEY" ] || die "no pre-auth key available. Provide one via --authkey-file <path>, \$HEADSCALE_AUTHKEY, or a prior $AUTHKEY_STORE (reusable key, headscale user 'fleet')."
  info "Enrolling on $LOGIN_SERVER as $HOSTNAME_TS…"
  $SUDO tailscale up \
    --login-server "$LOGIN_SERVER" \
    --authkey "$AUTHKEY" \
    --hostname "$HOSTNAME_TS" \
    || die "tailscale up failed."
fi

# ── Boot-time autoconnect oneshot (zero-touch re-enroll) ──────────────────────
# Runs as root at every boot; re-enrolls ONLY when not already connected
# ('tailscale status' short-circuits the '|| tailscale up'), so a normal reboot
# whose state persisted in /var/lib/tailscale is a no-op, while a rebuilt or
# logged-out distro rejoins hands-free. ConditionPathExists gates on the
# persisted key; without it the unit is inert. Hostname is baked at install time
# (system units don't see $WSL_DISTRO_NAME).
AUTOCONNECT_UNIT="/etc/systemd/system/tailscale-autoconnect.service"
if [ -n "$AUTHKEY" ] || [ -e "$AUTHKEY_STORE" ]; then
  $SUDO tee "$AUTOCONNECT_UNIT" >/dev/null <<UNIT
[Unit]
Description=Auto-enroll this WSL distro on the Headscale tailnet ($HOSTNAME_TS)
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
ConditionPathExists=$AUTHKEY_STORE

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/sh -c 'tailscale status --peers=false >/dev/null 2>&1 || tailscale up --login-server $LOGIN_SERVER --authkey "\$(cat $AUTHKEY_STORE)" --hostname $HOSTNAME_TS'

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  if $SUDO systemctl enable tailscale-autoconnect.service >/dev/null 2>&1; then
    ok "boot autoconnect enabled → $AUTOCONNECT_UNIT"
  else
    warn "could not enable tailscale-autoconnect.service"
  fi
else
  warn "no key persisted at $AUTHKEY_STORE — skipped the boot autoconnect unit (zero-touch re-enroll unavailable). Re-run with --authkey-file/\$HEADSCALE_AUTHKEY to enable it."
fi

# ── Verify ────────────────────────────────────────────────────────────────────
IP="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$IP" ] || die "enrolled but no tailnet IPv4 yet — check 'tailscale status'."
ok "node '$HOSTNAME_TS' up at $IP  (MagicDNS: ${HOSTNAME_TS}.fleet.mesh)"
printf '\nNext: bash %s\n' "$(dirname "$0")/orca-serve.sh"
