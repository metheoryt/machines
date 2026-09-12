#!/usr/bin/env bash
# provision/linux.sh — provision a Debian/Ubuntu box into the fleet's PORTABLE
# layer. DRIVER ONLY: it resolves this box's PROFILE, then runs that profile's
# ordered tier list from provision/lib/tiers.sh (which holds what this script
# used to do inline):
#   • the git-synced Claude Code agent config (via agents/bootstrap.sh)
#   • the core CLI dev tools (gortex, claude, ripgrep/fd/fzf, …)
#
# Profiles exist so a lean box can converge without the workstation dev layer:
#   workstation — the default (WSL dev distros, and a native Linux desktop):
#                 every tier. The one tier that is not uniform across it is
#                 docker, which skips a WSL distro where Docker Desktop owns
#                 the engine.
#   hub         — the 960MB Debian VPS: no dev apt layer, no gortex,
#                 and deliberately no ssh_accounts (it would overwrite that
#                 box's ~/.ssh/config and kill its only GitHub auth)
#   server      — the always-on services box (latitude, post-NixOS): the full
#                 interactive layer a human SSHes into, minus the code-graph and
#                 secondary-agent tiers a box that runs services never uses, plus
#                 the one fleet-wide publisher tier (gortex_autoupdate) that wants
#                 a box which is always on
# Resolution order: $MACHINES_PROFILE > fleet.json "profile" by OS hostname >
# workstation. See docs/superpowers/specs/2026-07-25-hub-fleet-enrollment-tiers-design.md.
#
# This is the imperative, apt-based driver (it was written as the counterpart to
# the NixOS hosts, deleted 2026-08-01 — see docs/2026-08-01-nixos-harvest.md):
# deliberately NOT a full reproduction of the Nix fleet. It installs a CORE tier
# (must succeed — the script aborts if these fail) and a BEST-EFFORT tier
# (nice-to-have; it warns and continues). Drift-free parity was a NixOS property
# and left with the flake on 2026-08-01 — this driver is best-effort by
# construction, which is the trade the whole repo now runs on. What WSL still
# buys you is a distro you can `wsl --unregister` and re-provision in minutes.
#
# This is also the ONLY complete path for a WSL box: the provision.sh dispatcher
# has no `base` role executor, so it cannot stand one up. Run this script.
#
# Targets glibc apt distros: Debian 11+ / Ubuntu 22.04+. NOT Alpine/musl — the
# prebuilt gortex binary and the native claude CLI are glibc builds.
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
    # docker rides next to the apt layer it extends. It is a NO-OP on a WSL
    # distro — Docker Desktop owns the engine there and provision/wsl-fixes.sh
    # owns the CLI — so it reaches only a native Linux desktop, which is what
    # this profile now also covers. See the tier for why it never upgrades.
    # battery_limit rides here as of 2026-09-08, and the axis is NOT the profile:
    # it is whether the box lives on mains. This list used to omit it with the
    # comment "a laptop someone carries", which described `air` and was simply
    # untrue of the two workstation-profile laptops the fleet actually has —
    # g15 sits on AC as the personal-projects host, g16 as the Windows box
    # (whose cap is G-Helper's, not this repo's). A cell held at 100% on AC
    # swells, which is the whole reason latitude has the cap.
    #
    # `air` is excluded by being darwin, not by being workstation: macos.sh has
    # its own tier list and no battery tier, so nothing here reaches it. The one
    # box this newly touches is g16-wsl, where it is a no-op — but NOT for the
    # reason it is tempting to write down. Measured there 2026-09-08: the distro
    # DOES expose /sys/class/power_supply/BAT1 (and AC1); what it has not got is
    # `charge_control_end_threshold` inside it. The tier's loop tests for that
    # file rather than for a battery, which is what makes it return 0 here — a
    # check for the directory would have run on and failed.
    #
    # A future CARRIED Linux laptop would inherit a cap it may not want. That is
    # the accepted cost of keying on the profile rather than on a per-machine
    # knob, and the fix then is a fleet.json field, not a re-split of this list.
    # lid_ignore rides beside battery_limit on the same mains axis: a box wired to
    # the wall must not suspend when its lid shuts. It is a no-op with no lid
    # (/proc/acpi/button/lid is absent in a WSL distro), and it writes lid policy
    # only — it does NOT mask the sleep targets, so `systemctl suspend` still
    # works on a box someone sits at. See the tier for why that split matters.
    # oom_guard and sysrq are the two halves of the 2026-09-09 lockout, split
    # because they gate on different things. oom_guard caps user-.slice, so it
    # wants a MEASURED user-slice ceiling — g15 has one (4.2 GB steady against
    # 30 GB), latitude does not, which is the only reason `server` omits it. It
    # cannot reach system.slice, so it is structurally incapable of touching
    # docker/immich/postgres. sysrq wants a human at THAT keyboard: latitude's
    # display is one nobody sits at and hub has no keyboard, so there the sysctl
    # would be inert decoration. Both are no-ops without root and self-skip.
    # orca_skills sits AFTER agents_config and agent_clis and not one place
    # later: the skills CLI picks its install targets by looking for agent config
    # directories, so ~/.claude must exist before it runs. It is also not
    # APPENDED — that would land it after dotfiles, which stays last for the
    # reason its own comment gives. It reaches exactly two boxes (g15 and
    # g16-wsl, the runtimes where an Orca-driven `claude` actually runs) and
    # is an info-level skip everywhere else, including darwin.
    TIERS=(apt_min apt_dev docker battery_limit lid_ignore oom_guard sysrq agents_config git_base gortex
           "agent_clis claude" orca_skills shell_init autofetch
           ssh_accounts selfpull ssh_trust dotfiles) ;;
  hub)
    # Lean server tier. Deliberately absent: apt_dev, gortex, and
    # ssh_accounts — the last would overwrite hub's ~/.ssh/config with
    # IdentitiesOnly on a fresh unregistered key and kill its GitHub auth.
    # dotfiles_sync closes the same gap macos.sh has: convergence runs this
    # driver, never provision.sh, so hub's sync timer was installed once by a
    # hand-run role and never re-asserted. The SYNC tier, not `dotfiles` —
    # hub is a fleet.json member and reaches role_dotfiles through the
    # dispatcher's `Apply dotfiles? [y/N]` gate, which listing the enrollment
    # tier here would pre-empt. This one only writes a timer unit.
    TIERS=(apt_min agents_config git_base "agent_clis claude"
           "shell_init --no-fish" autofetch
           "selfpull %h/machines" ssh_trust dotfiles_sync) ;;
  server)
    # The always-on services box. NOT the hub tier: hub is lean because it is a
    # 960MB VPS, whereas this box has 24GB and 470GB and is SSHed into by a
    # human, so it keeps apt_dev (gh, ripgrep/fd/fzf, fish, starship, uv) and
    # fish. It is workstation MINUS the one tier a services box never exercises:
    #   gortex          — a code-graph daemon that wants indexed source checkouts
    # ssh_accounts IS included, unlike hub: this box starts with no key at all
    # after the reinstall, so there is no working GitHub auth for the tier to
    # break, and pinning the account aliases fixes the gap the NixOS config left
    # (modules/home/ssh.nix rendered fleet hosts only — no GitHub block).
    # selfpull stays unpinned: its default roots are "$HOME $HOME/my", which is
    # exactly ~/machines plus ~/my/vps here, and the data disks mount outside
    # $HOME so there is nothing to over-scan.
    # dotfiles stays LAST, as in workstation: the bare-repo checkout is refused
    # when an untracked file already occupies a tracked path, and after the
    # 2026-07-28 handover no earlier tier writes one — agents/bootstrap.sh now
    # retire_link()s ~/.claude/{CLAUDE.md,memory,host-memory.md,statusline-…}
    # instead of symlinking them, and only claims ~/.claude/skills/cyphy, which
    # the dotfiles branch does not track.
    # sudo_nopasswd is server-only and runs FIRST: every later privileged tier —
    # and every converge rebuild afterwards — then takes linux.sh's `sudo -n` path
    # instead of needing a human at a TTY. Deliberately absent from workstation
    # (a laptop someone carries) and from hub (its provider already set it up).
    # statusboard is server-only and packages-only: this is the box with a physical
    # display nobody sits at, so it is the only one that wants a kiosk compositor.
    # Taking a VT from the login prompt stays a deliberate `--install`.
    # battery_limit is next to statusboard for the same reason: this is the box
    # whose hardware is a fact of the deployment rather than of the profile. A
    # laptop wired to the wall forever needs its charge ceiling enforced, and the
    # tier is a no-op wherever the EC exposes no threshold — so it costs a mains-
    # only box nothing to have it in the plan. NOT server-only since 2026-09-08:
    # workstation carries it too, because g15 is also mains-bound. See that
    # list's comment for why the old "workstation = a carried laptop" split was
    # wrong.
    # rapl_read follows statusboard for the same reason and with the same shape: the
    # board's power row reads the CPU's energy counter, which ships root-only, and
    # this widens it to the board's group. It is a no-op on hardware with no RAPL
    # domain. It is a REAL, if small, security decision — see the tier's comment.
    # gortex_autoupdate is the one tier this profile has and workstation does NOT,
    # and it is here BECAUSE gortex is not: the tier publishes a pin bump for the
    # rest of the fleet (provision/gortex.version, which converge treats as a
    # reprovision trigger) and installs nothing locally. It must run on exactly
    # one box — two writers race on the push and strand a commit — so the
    # always-on box that never runs gortex itself is the natural writer. It sits
    # after ssh_accounts because the push needs that tier's GitHub key.
    # lid_ignore is the other half of battery_limit's hardware story, and it closes
    # a gap the 2026-08-03 review named: latitude's no-lid-sleep config was a hand
    # written /etc/systemd/logind.conf.d/99-server.conf that NOTHING in this repo
    # produced, so a reinstall following the repo yielded a services host that
    # suspends when the lid closes. The tier writes lid policy only; the sleep
    # target masking this box also carries stays host-local, being a services-host
    # decision rather than a portable one.
    TIERS=(sudo_nopasswd apt_min apt_dev statusboard battery_limit lid_ignore rapl_read agents_config git_base "agent_clis claude"
           shell_init autofetch ssh_accounts selfpull gortex_autoupdate ssh_trust dotfiles) ;;
  *)
    die "unknown profile '$PROFILE' ($PROFILE_SRC) — expected workstation|hub|server" ;;
esac

printf 'profile: %s (%s)\n' "$PROFILE" "$PROFILE_SRC"

# Dry run prints the plan and exits. Deliberately BEFORE the apt/arch
# preconditions so the tier list is inspectable (and unit-testable) from any box,
# including one that is not the target.
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
  • Authenticate the agent:   claude   (browser login)
  • Optional — live in fish: append to ~/.bashrc:
        case \$- in *i*) exec fish ;; esac
  • This box's clone auto-relinks agent config on git pull (core.hooksPath set
    by agents/bootstrap.sh). Commit from any fleet machine, pull here.

Not installed by design: language servers and a desktop toolchain (the full
fish/ghostty/GNOME setup). This text used to say "only a NixOS host gets
these" and to list docker among them — the last Nix host went 2026-08-01, and
docker is tier_docker on the workstation profile since 2026-09-07.
EOF

exit 0
