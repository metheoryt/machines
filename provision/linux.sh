#!/usr/bin/env bash
# provision/linux.sh — provision a Debian/Ubuntu box into the fleet's PORTABLE
# layer. DRIVER ONLY: it resolves this box's PROFILE, then runs that profile's
# ordered tier list from provision/lib/tiers.sh (which holds what this script
# used to do inline):
#   • the git-synced Claude Code / Codex agent config (via agents/bootstrap.sh)
#   • the core CLI dev tools (gortex, claude, codex, ripgrep/fd/fzf, …)
#
# Profiles exist so a lean box can converge without the workstation dev layer:
#   workstation — the default (WSL dev distros): every tier
#   hub         — the 960MB Debian VPS: no dev apt layer, no gortex, no codex,
#                 and deliberately no ssh_accounts (it would overwrite that
#                 box's ~/.ssh/config and kill its only GitHub auth)
# Resolution order: $MACHINES_PROFILE > fleet.json "profile" by OS hostname >
# workstation. See docs/superpowers/specs/2026-07-25-hub-fleet-enrollment-tiers-design.md.
#
# This is the imperative, apt-based counterpart to the NixOS hosts (hosts/*/nixos/):
# deliberately NOT a full reproduction of the Nix fleet. It installs a CORE tier
# (must succeed — the script aborts if these fail) and a BEST-EFFORT tier
# (nice-to-have; it warns and continues). Full, drift-free fleet parity only
# exists on a NixOS box; on WSL you trade that for zero Nix and a distro you can
# `wsl --unregister` and re-provision in minutes.
#
# This is also the ONLY complete path for a WSL box: the provision.sh dispatcher
# has no `base` role executor, so it cannot stand one up. Run this script.
#
# Targets glibc apt distros: Debian 11+ / Ubuntu 22.04+. NOT Alpine/musl — the
# prebuilt gortex binary and the native claude/codex CLIs are glibc builds.
#
# Idempotent; safe to re-run. Usage inside a fresh Ubuntu/Debian WSL:
#   sudo apt-get update && sudo apt-get install -y git
#   git clone <this-repo> ~/machines
#   bash ~/machines/provision/linux.sh
#
# See provision/README.md for base-distro guidance and post-install steps.
set -u

# ── Pretty output ─────────────────────────────────────────────────────────────
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
WARNINGS=0
APT_UPDATED=""   # set by the first apt tier that refreshes the index

# ── Locate the repo (this script lives in <repo>/provision/) ──────────────────
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/agents/bootstrap.sh" ] || die "can't find agents/bootstrap.sh under $REPO — run this from inside the machines repo"

# ── Profile resolution: env override > fleet.json by hostname > workstation ────
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
# One list per profile; a new profile is a new list, not a new code path.
case "$PROFILE" in
  workstation)
    TIERS=(apt_min apt_dev agents_config git_base gortex
           "agent_clis claude codex" shell_init autofetch
           ssh_accounts selfpull ssh_trust) ;;
  hub)
    # Lean server tier. Deliberately absent: apt_dev, gortex, codex, and
    # ssh_accounts — the last would overwrite hub's ~/.ssh/config with
    # IdentitiesOnly on a fresh unregistered key and kill its GitHub auth.
    TIERS=(apt_min agents_config git_base "agent_clis claude"
           "shell_init --no-fish" autofetch
           "selfpull %h/machines" ssh_trust) ;;
  *)
    die "unknown profile '$PROFILE' ($PROFILE_SRC) — expected workstation|hub" ;;
esac

printf 'profile: %s (%s)\n' "$PROFILE" "$PROFILE_SRC"

# Dry run prints the plan and exits. Deliberately BEFORE the apt/arch
# preconditions so the tier list is inspectable (and unit-testable) from any box,
# including a NixOS one.
if [ -n "${MACHINES_TIERS_DRY_RUN:-}" ]; then
  for t in "${TIERS[@]}"; do printf 'tier_%s\n' "$t"; done
  exit 0
fi

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "this script targets Debian/Ubuntu (apt-get not found). See provision/README.md for other bases."
case "$(uname -m)" in
  x86_64 | amd64) : ;;
  *) die "gortex ships x86_64-linux only; this box is $(uname -m). See provision/README.md." ;;
esac

# Privilege detection. converge (scripts/converge.sh) fires this DETACHED with no
# controlling terminal, as the unprivileged pulling user — so a `sudo` that needs
# a password can't authenticate ("sudo: a terminal is required to authenticate")
# and the old unconditional SUDO="sudo" made the CORE apt tier die on every pull.
# Probe what root we can actually get and never block: passwordless sudo → use
# `sudo -n`; an interactive TTY → allow a normal password prompt; otherwise no
# root is reachable (PRIV=0) and the CORE apt tier degrades to a warn.
SUDO=""
PRIV=1
if [ "$(id -u)" -ne 0 ]; then
  if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"          # passwordless sudo — never prompts, never blocks
  elif have sudo && [ -t 0 ]; then
    SUDO="sudo"             # interactive terminal — allow a password prompt
  elif [ -t 0 ]; then
    die "not root and sudo not found — install sudo or run as root"   # human, no path to root
  else
    PRIV=0                  # non-interactive with no reachable root (e.g. converge) — skip privileged steps
  fi
fi

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"   # so `have claude|gortex|starship|uv` sees
                                       # prior installs under a detached converge
                                       # (a non-login shell lacks ~/.local/bin)

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
  • Open a new shell (or: source ~/.bashrc) so ~/.local/bin is on PATH.
  • Authenticate the agents:  claude   (browser login)   ·   codex
  • Optional — live in fish: append to ~/.bashrc:
        case \$- in *i*) exec fish ;; esac
  • This box's clone auto-relinks agent config on git pull (core.hooksPath set
    by agents/bootstrap.sh). Commit from any fleet machine, pull here.

Not installed by design (only a NixOS host gets these): the declarative dev
toolchain (docker, language servers, the full fish/ghostty/GNOME setup).
EOF

exit 0
