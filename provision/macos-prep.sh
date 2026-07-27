#!/usr/bin/env bash
# provision/macos-prep.sh — the PRIVILEGED prerequisites for a macOS fleet member.
# Stage 1 of provision/provision-mac.sh; runnable alone.
#
#   bash provision/macos-prep.sh <machine>       # e.g. air
#
# EVERY sudo in the whole macOS provisioning flow lives in this file, on purpose:
# "what does this ask root for, and why" should be answerable by reading one
# short script rather than auditing a four-stage chain. It prompts once, up
# front, naming what it needs, then keeps the timestamp warm so nothing
# downstream re-prompts. Stages 2-4 need no root at all — Homebrew refuses to run
# under sudo and owns its own prefix, and the role executors write only in $HOME.
#
# Three things need root:
#   1. scutil --set  — the system hostname
#   2. Homebrew's installer — it creates /opt/homebrew (or /usr/local on Intel)
#   3. systemsetup -setremotelogin — inbound SSH (best-effort; see below)
#
# Idempotent; safe to re-run.
set -u

MACOS_PREP_LIB_ONLY="${MACOS_PREP_LIB_ONLY:-0}"

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Pure helpers (tested directly under MACOS_PREP_LIB_ONLY=1) ────────────────

# mp_brew_prefix: Homebrew's prefix for this architecture. Apple Silicon put it
# at /opt/homebrew; Intel Macs keep the historical /usr/local. Callers need this
# BEFORE brew is on PATH, so it cannot be derived from `brew --prefix`.
mp_brew_prefix() {
  case "${1:-$(uname -m)}" in
    arm64|aarch64) printf '/opt/homebrew' ;;
    *)             printf '/usr/local' ;;
  esac
}

# mp_fleet_hostname <fleet.json-content> <machine>: the machine's detect.hostname.
# Empty when the machine is absent — the caller treats that as fatal.
mp_fleet_hostname() {
  jq -r --arg m "$2" '.machines[$m].detect.hostname // empty' <<<"$1"
}

# mp_fleet_platform <fleet.json-content> <machine>
mp_fleet_platform() {
  jq -r --arg m "$2" '.machines[$m].platform // empty' <<<"$1"
}

# Allow sourcing just the functions (for tests) without running main.
[ "$MACOS_PREP_LIB_ONLY" = 1 ] && return 0 2>/dev/null

# ── Args ──────────────────────────────────────────────────────────────────────
MACHINE="${1:-}"
[ -n "$MACHINE" ] || die "usage: macos-prep.sh <machine>   (a darwin member of fleet.json, e.g. air)"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_JSON="$REPO/fleet.json"
[ -f "$FLEET_JSON" ] || die "fleet.json not found at $FLEET_JSON"

# ── Preconditions ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS; this box is $(uname -s)."
have jq || die "jq not found. Bootstrap it first:  brew install jq  (or run this after Homebrew exists)"

FLEET_CONTENT="$(cat "$FLEET_JSON")"
WANT_HOSTNAME="$(mp_fleet_hostname "$FLEET_CONTENT" "$MACHINE")"
PLATFORM="$(mp_fleet_platform "$FLEET_CONTENT" "$MACHINE")"
[ -n "$WANT_HOSTNAME" ] || die "machine '$MACHINE' is not in fleet.json"
[ "$PLATFORM" = darwin ] || die "machine '$MACHINE' has platform '$PLATFORM', not darwin — refusing to rename this Mac"

# ── One sudo prompt, up front ─────────────────────────────────────────────────
printf '\n\033[1mmacos-prep: privileged setup for %s\033[0m\n' "$MACHINE"
printf 'Root is needed for three things:\n'
printf '  1. scutil --set        → system hostname "%s"\n' "$WANT_HOSTNAME"
printf '  2. Homebrew installer  → creates %s\n' "$(mp_brew_prefix)"
printf '  3. systemsetup         → enable Remote Login (inbound SSH)\n\n'

sudo -v || die "could not obtain sudo — cannot set the hostname or install Homebrew"

# Hold the timestamp open for the rest of the chain so no later stage re-prompts.
# Killed on exit; `sudo -n true` never prompts, so a revoked timestamp just ends
# the refresh quietly instead of blocking on a hidden password prompt.
( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
SUDO_KEEPALIVE=$!
# shellcheck disable=SC2064  # expand $SUDO_KEEPALIVE now, not at trap time
trap "kill $SUDO_KEEPALIVE 2>/dev/null || true" EXIT

# ── 1. Hostname ───────────────────────────────────────────────────────────────
# All three must be set. ComputerName is the Finder/AirDrop name, LocalHostName
# the Bonjour name (<name>.local), HostName the one `hostname` reports — and
# only the last is what fleet_detect matches. Setting one is the classic way to
# end up with `hostname` still reporting the old name or a DHCP-supplied one.
info "1/3 hostname → $WANT_HOSTNAME"
if [ "$(scutil --get HostName 2>/dev/null || true)" = "$WANT_HOSTNAME" ] \
   && [ "$(hostname -s 2>/dev/null || true)" = "$WANT_HOSTNAME" ]; then
  ok "hostname already $WANT_HOSTNAME"
else
  sudo scutil --set HostName      "$WANT_HOSTNAME" || die "scutil --set HostName failed"
  sudo scutil --set LocalHostName "$WANT_HOSTNAME" || warn "scutil --set LocalHostName failed"
  sudo scutil --set ComputerName  "$WANT_HOSTNAME" || warn "scutil --set ComputerName failed"
  dscacheutil -flushcache 2>/dev/null || true
  ok "hostname set to $WANT_HOSTNAME"
fi
# `hostname` may still report <name>.local while Bonjour holds the name — that is
# cosmetic, not a fault: provision/lib/fleet.sh's fleet_hostname() strips the
# suffix, exactly as agents/bootstrap.sh's host_id() always has.
if [ "$(hostname 2>/dev/null)" != "$WANT_HOSTNAME" ]; then
  ok "note: \`hostname\` reports '$(hostname)' (mDNS suffix) — resolvers strip it"
fi

# ── 2. Homebrew ───────────────────────────────────────────────────────────────
info "2/3 Homebrew"
BREW_PREFIX="$(mp_brew_prefix)"
if have brew; then
  ok "brew already installed ($(command -v brew))"
elif [ -x "$BREW_PREFIX/bin/brew" ]; then
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  ok "brew found at $BREW_PREFIX/bin/brew (added to PATH for this run)"
else
  info "installing Homebrew (this takes a few minutes)…"
  # NONINTERACTIVE=1 stops the installer waiting on a RETURN keypress. It still
  # uses sudo — which is why the timestamp above is warm before we get here.
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew install failed"
  [ -x "$BREW_PREFIX/bin/brew" ] || die "Homebrew installed but $BREW_PREFIX/bin/brew is missing"
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  ok "Homebrew installed → $BREW_PREFIX"
fi

# ── 3. Remote Login (inbound SSH) ─────────────────────────────────────────────
# Best-effort BY DESIGN. Recent macOS refuses systemsetup unless the invoking
# terminal holds Full Disk Access, and that cannot be granted from a script.
# Nothing downstream needs inbound SSH, so a failure here must not abort a
# provisioning run — it just means other fleet members cannot reach this box yet.
info "3/3 Remote Login (inbound SSH)"
if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'on$'; then
  ok "Remote Login already on"
elif sudo systemsetup -setremotelogin on >/dev/null 2>&1; then
  ok "Remote Login enabled"
else
  warn "could not enable Remote Login (macOS blocks systemsetup without Full Disk Access)"
  printf '    Enable it by hand: System Settings → General → Sharing → Remote Login\n' >&2
  printf '    Not required for the rest of provisioning; inbound fleet SSH stays off until you do.\n' >&2
fi

printf '\n\033[1mmacos-prep done.\033[0m\n'
exit 0
