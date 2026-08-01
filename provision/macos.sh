#!/usr/bin/env bash
# provision/macos.sh — provision a macOS box into the fleet's PORTABLE layer.
# The Darwin sibling of provision/linux.sh: same DRIVER shape, same tier library
# (provision/lib/tiers.sh), different package manager.
#
# Like linux.sh this is a TIER DRIVER, not the role dispatcher. The two are
# unrelated entry points and neither calls the other:
#
#   bash provision/macos.sh                          ← this file: the toolchain
#   bash provision/provision.sh --machine air --apply ← roles from fleet.json
#
# Run the driver first (it installs git/python3/the agent CLIs), then the front
# door (it runs agents/dotfiles/repos through provision/roles/*.sh).
#
# What differs from linux.sh, and why:
#   • Homebrew, not apt — so tier_brew_min / tier_brew_dev replace the apt pair
#     in the tier list, plus tier_brew_cask, which has no Linux counterpart at
#     all. Homebrew refuses to run under sudo and owns its own prefix, so the
#     whole PRIV/SUDO probe linux.sh needs has no analogue: SUDO stays empty and
#     PRIV stays 1. The cask layer is the one exception: a cask links binaries
#     into /usr/local/bin THROUGH sudo, so tier_brew_cask is the single tier here
#     that wants an interactive terminal (see its comment in tiers.sh).
#   • No fdfind/batcat aliasing — brew installs `fd` and `bat` under their real
#     names (see tier_brew_dev).
#   • launchd, not systemd — tier_autofetch / tier_selfpull branch on Darwin
#     internally and install LaunchAgents.
#   • arm64 AND x86_64 are both fine here; the gortex asset is resolved per
#     platform (tier_gortex), unlike linux.sh which is x86_64-only because
#     upstream ships no linux_arm64 build.
#
# Same trade as the Linux path: this is the imperative counterpart to the NixOS
# hosts, deliberately NOT a full reproduction of the Nix fleet. CORE tiers must
# succeed (the script aborts); BEST-EFFORT tiers warn and continue.
#
# Prerequisite — Homebrew, which cannot bootstrap itself unattended (its
# installer wants an interactive sudo for /opt/homebrew):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#
# Idempotent; safe to re-run. Usage on a fresh Mac:
#   git clone <this-repo> ~/machines
#   bash ~/machines/provision/macos.sh
#
# See provision/README.md for post-install steps.
set -u

# ── Pretty output ─────────────────────────────────────────────────────────────
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
WARNINGS=0
APT_UPDATED=""   # unused on darwin; declared because tiers.sh's contract expects it

# ── Locate the repo (this script lives in <repo>/provision/) ──────────────────
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/agents/bootstrap.sh" ] || die "can't find agents/bootstrap.sh under $REPO — run this from inside the machines repo"

# ── Profile resolution: env override > fleet.json by hostname > workstation ────
# Identical to linux.sh. `air` carries no `profile` field, so it resolves to
# workstation via the default.
# shellcheck source=provision/lib/fleet.sh
source "$REPO/provision/lib/fleet.sh"
if [ -n "${MACHINES_PROFILE:-}" ]; then
  PROFILE="$MACHINES_PROFILE"; PROFILE_SRC="from MACHINES_PROFILE"
elif PROFILE="$(fleet_profile_for_host 2>/dev/null)" && [ -n "$PROFILE" ]; then
  PROFILE_SRC="from fleet.json"
else
  PROFILE="workstation"; PROFILE_SRC="default"
fi

# ── Profile → ordered tier list ───────────────────────────────────────────────
# Mirrors linux.sh's table with the apt tiers swapped for brew. There is no
# `hub` arm: the hub is a Debian VPS and always will be — a macOS server profile
# would be inventing a machine that does not exist.
case "$PROFILE" in
  workstation)
    TIERS=(brew_min brew_dev brew_cask agents_config git_base gortex
           "agent_clis claude" shell_init autofetch
           ssh_accounts fleet_ssh selfpull ssh_trust) ;;
  *)
    die "unknown profile '$PROFILE' ($PROFILE_SRC) — macos.sh supports workstation only" ;;
esac

printf 'profile: %s (%s)\n' "$PROFILE" "$PROFILE_SRC"

# Dry run prints the plan and exits. Deliberately BEFORE the platform
# preconditions so the tier list is inspectable (and unit-testable) from any
# box — including the NixOS one this repo is usually edited on.
if [ -n "${MACHINES_TIERS_DRY_RUN:-}" ]; then
  for t in "${TIERS[@]}"; do printf 'tier_%s\n' "$t"; done
  exit 0
fi

# ── Preconditions ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS; this box is $(uname -s). Use provision/linux.sh."

# Put Homebrew on PATH ourselves rather than inheriting it. macOS ships no
# /etc/profile.d equivalent for brew, so its prefix reaches PATH only via the
# shellenv line tier_shell_init seeds into ~/.zshrc — and that file is read by
# INTERACTIVE zsh only. Anything non-interactive (a converge fired detached from
# the post-merge hook, `ssh air bash provision/macos.sh`, a LaunchAgent) gets the
# bare /usr/bin:/bin:/usr/sbin:/sbin and died here claiming Homebrew was missing
# on a box that has had it all along. Same two-prefix probe as the ~/.zshrc seed:
# /opt/homebrew on Apple Silicon, /usr/local on Intel. A no-op when the caller's
# environment already had it.
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$_brew" ] && eval "$("$_brew" shellenv)" && break
done
unset _brew

have brew || die "Homebrew not found. Install it first:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
then re-run this script."

# Homebrew never runs under sudo and installs into a prefix the user owns, so no
# root is needed or wanted. tiers.sh's shared bodies still reference $SUDO and
# $PRIV (tier_autofetch's linger call, the apt tiers' guards) — define them so
# those expansions are empty/benign rather than unbound under `set -u`.
SUDO=""
PRIV=1

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

printf '\n\033[1mProvisioning %s from %s\033[0m\n\n' "$(uname -n)" "$REPO"

# shellcheck source=provision/lib/tiers.sh
source "$REPO/provision/lib/tiers.sh"
for t in "${TIERS[@]}"; do
  # A list entry is "<tier> [args…]". Split it explicitly instead of relying on
  # unquoted expansion, which would also glob any arg containing * ? or [.
  read -r -a _call <<< "$t"
  "tier_${_call[0]}" "${_call[@]:1}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n\033[1mDone.\033[0m %s warning(s).\n\n' "$WARNINGS"
cat <<EOF
Next steps:
  • Open a new shell (or: source ~/.zshrc) so ~/.local/bin is on PATH.
  • Authenticate the agent:   claude   (browser login)
  • Run the role dispatcher:  bash provision/provision.sh --machine air --apply
  • Verify the LaunchAgents loaded:
        launchctl list | grep kz.cyphy
    Expect kz.cyphy.git-autofetch and kz.cyphy.fleet-selfpull.

Docker Desktop comes from tier_brew_cask, but its daemon does not: the app has to
run once, interactively, to install its privileged helper.
  • If the cask step warned, re-run it in a terminal window:
        brew install --cask docker-desktop
  • Then launch it once:  open -a Docker   (verify: docker run --rm hello-world)

Not installed by design (only a NixOS host gets these): the declarative dev
toolchain (language servers, the full fish/ghostty/GNOME setup).
EOF

exit 0
