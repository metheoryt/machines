#!/usr/bin/env bash
# provision/tailscale-mac.sh — enroll THIS Mac on the Headscale tailnet.
# Stage 2 of provision/provision-mac.sh; runnable alone. The macOS sibling of
# tailscale-wsl.sh, with the same pre-auth-key precedence and CLI shape.
#
#   bash provision/tailscale-mac.sh --hostname air --authkey-file provision/secrets/authkey
#   HEADSCALE_AUTHKEY='<key>' bash provision/tailscale-mac.sh --hostname air
#   bash provision/tailscale-mac.sh --hostname air     # already logged in → no-op
#
# Pre-auth key precedence (high→low): --authkey-file <path>, $HEADSCALE_AUTHKEY,
# already-joined (skip).
#
# There is deliberately NO --authkey flag. argv is world-readable through `ps`,
# so an inline key is scrapeable by any local process for the lifetime of the
# run; tailscale-wsl.sh omits it for the same reason. Keys belong in
# provision/secrets/, which is gitignored.
#
# Unlike tailscale-wsl.sh this cannot mint its own key by SSHing to hub: a fresh
# Mac has no fleet key that hub trusts yet. The key must be supplied.
#
# Idempotent; safe to re-run.
set -u

TAILSCALE_MAC_LIB_ONLY="${TAILSCALE_MAC_LIB_ONLY:-0}"

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

LOGIN_SERVER="https://cc.cyphy.kz"
# The standalone cask ships its CLI inside the bundle and never on PATH.
TS_APP_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# ── Pure helpers (tested directly under TAILSCALE_MAC_LIB_ONLY=1) ─────────────

# tsm_resolve_key <authkey-file> <env-key>: echo "<source>\t<key>" for the
# winning source, or return 1 when neither is usable. Precedence mirrors
# tailscale-wsl.sh: file beats env. A file that is set but unreadable is an
# error, not a silent fallthrough — otherwise a typo'd path quietly joins the
# tailnet with the wrong key or not at all.
tsm_resolve_key() {
  local file="$1" env_key="$2"
  if [ -n "$file" ]; then
    [ -r "$file" ] || return 2
    local k; k="$(tr -d '[:space:]' < "$file")"
    [ -n "$k" ] || return 2
    printf 'authkey-file\t%s' "$k"; return 0
  fi
  if [ -n "$env_key" ]; then
    printf 'HEADSCALE_AUTHKEY\t%s' "$env_key"; return 0
  fi
  return 1
}

# tsm_expected_ip <fleet.json-content> <machine>: the manifest's tailnet.ip.
tsm_expected_ip() {
  jq -r --arg m "$2" '.machines[$m].tailnet.ip // empty' <<<"$1"
}

# tsm_ip_verdict <actual> <expected>: match | mismatch | unknown.
# `unknown` when either side is empty — we report it rather than guessing.
tsm_ip_verdict() {
  local actual="$1" expected="$2"
  if [ -z "$actual" ] || [ -z "$expected" ]; then printf 'unknown'
  elif [ "$actual" = "$expected" ];             then printf 'match'
  else                                                printf 'mismatch'
  fi
}

# Allow sourcing just the functions (for tests) without running main.
[ "$TAILSCALE_MAC_LIB_ONLY" = 1 ] && return 0 2>/dev/null

# ── Args ──────────────────────────────────────────────────────────────────────
HOSTNAME_ARG=""
AUTHKEY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)      HOSTNAME_ARG="${2:-}"; [ -n "$HOSTNAME_ARG" ] || die "--hostname needs a name."; shift 2 ;;
    --hostname=*)    HOSTNAME_ARG="${1#*=}"; shift ;;
    --authkey-file)  AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || die "--authkey-file needs a path."; shift 2 ;;
    --authkey-file=*) AUTHKEY_FILE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$HOSTNAME_ARG" ] || die "usage: tailscale-mac.sh --hostname <name> [--authkey-file <path>]"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_JSON="$REPO/fleet.json"

# ── Preconditions ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS; this box is $(uname -s). Use tailscale-wsl.sh."

# ── 1. Install the standalone app ─────────────────────────────────────────────
# NOT the Mac App Store build: it is sandboxed and cannot point at a custom
# control server, which makes it useless for Headscale.
info "Tailscale (standalone cask)"
if [ -x "$TS_APP_CLI" ]; then
  ok "Tailscale.app present"
elif have brew; then
  brew install --cask tailscale-app >/dev/null 2>&1 \
    && ok "Tailscale.app installed" \
    || die "brew install --cask tailscale-app failed"
  [ -x "$TS_APP_CLI" ] || die "cask installed but $TS_APP_CLI is missing"
else
  die "Homebrew not found — run provision/macos-prep.sh first"
fi

# Prefer a `tailscale` already on PATH (someone may have linked it); else the
# in-bundle binary.
TS="$TS_APP_CLI"
have tailscale && TS="$(command -v tailscale)"

# ── 2. Join, unless already joined ────────────────────────────────────────────
if "$TS" status >/dev/null 2>&1 && [ -n "$("$TS" ip -4 2>/dev/null)" ]; then
  ok "already joined as $("$TS" ip -4 2>/dev/null)"
else
  set +u  # HEADSCALE_AUTHKEY is intentionally optional
  KEY_INFO="$(tsm_resolve_key "$AUTHKEY_FILE" "${HEADSCALE_AUTHKEY:-}")"; rc=$?
  set -u
  case "$rc" in
    2) die "--authkey-file '$AUTHKEY_FILE' is unreadable or empty" ;;
    1) die "no pre-auth key. Mint one on hub:
    ssh hub 'sudo headscale preauthkeys create --user 1 --expiration 2h'
  then either:
    printf '%s' '<key>' > provision/secrets/authkey   # gitignored
    bash provision/tailscale-mac.sh --hostname $HOSTNAME_ARG --authkey-file provision/secrets/authkey
  or:
    HEADSCALE_AUTHKEY='<key>' bash provision/tailscale-mac.sh --hostname $HOSTNAME_ARG" ;;
  esac
  KEY_SRC="${KEY_INFO%%$'\t'*}"; KEY="${KEY_INFO#*$'\t'}"
  info "joining $LOGIN_SERVER as '$HOSTNAME_ARG' (key from $KEY_SRC)…"
  "$TS" up --login-server "$LOGIN_SERVER" --hostname "$HOSTNAME_ARG" --authkey "$KEY" \
    || die "tailscale up failed"
  ok "joined the tailnet"
fi

"$TS" set --accept-dns=true 2>/dev/null && ok "MagicDNS accepted" || warn "could not set --accept-dns=true"

# ── 3. Verify the address against the manifest ────────────────────────────────
# A warning, not a failure: reconciling a mismatch means editing Headscale or
# fleet.json, neither of which re-running this script fixes. But it must be
# LOUD — this exact drift already bit this migration once, when fleet.json
# claimed .5 and Headscale had long since given that address to a phone.
ACTUAL_IP="$("$TS" ip -4 2>/dev/null | head -1)"
EXPECTED_IP=""
if [ -f "$FLEET_JSON" ] && have jq; then
  EXPECTED_IP="$(tsm_expected_ip "$(cat "$FLEET_JSON")" "$HOSTNAME_ARG")"
fi
case "$(tsm_ip_verdict "$ACTUAL_IP" "$EXPECTED_IP")" in
  match)    ok "tailnet IP $ACTUAL_IP matches fleet.json" ;;
  mismatch) warn "tailnet IP MISMATCH — Headscale assigned $ACTUAL_IP, fleet.json says $EXPECTED_IP"
            printf '    Fix one of them before other members rely on the address:\n' >&2
            printf '      • reassign in Headscale, or\n' >&2
            printf "      • update .machines.%s.tailnet.ip in fleet.json\n" "$HOSTNAME_ARG" >&2 ;;
  unknown)  warn "could not compare the tailnet IP (actual='$ACTUAL_IP', fleet.json='$EXPECTED_IP')" ;;
esac

printf '\n\033[1mTailnet enrollment done.\033[0m Reachable at %s.gg.ez\n' "$HOSTNAME_ARG"
exit 0
