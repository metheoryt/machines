# provision/lib/tiers.sh — the provisioning tiers (source me; do not execute).
# Bodies moved verbatim out of provision/linux.sh; that script is now the driver
# that resolves a profile (fleet.json "profile") and picks a tier list.
# The profile → tier-list table that selects among these lives in the driver.
# Consumers: provision/linux.sh (apt) and provision/macos.sh (Homebrew).
# Requires the driver's helpers (info/ok/warn/die/have) and globals
# (REPO, SUDO, PRIV, WARNINGS, APT_UPDATED) to be set BEFORE sourcing.
#
# ── Portability contract ──────────────────────────────────────────────────────
# Three kinds of tier live here. Know which you are editing:
#
#   PORTABLE  — identical on every posix platform, shared byte-for-byte:
#               agents_config, git_base, agent_clis, ssh_accounts, ssh_trust.
#               A fix here reaches every box. Do NOT fork these per platform;
#               that is the whole point of the split.
#   PACKAGED  — one tier per package manager, selected by the driver's tier
#               list: apt_min/apt_dev (Debian/Ubuntu) vs brew_min/brew_dev
#               (macOS). Same CORE/best-effort semantics, different installer.
#   SCHEDULED — one body, an explicit Darwin branch at the top: autofetch and
#               selfpull. macOS has no systemd and no usable per-user cron (it
#               needs Full Disk Access), so these install a launchd LaunchAgent
#               instead. The Linux path below each branch is untouched — it runs
#               live on hub and the WSL boxes, and a generic scheduler
#               abstraction would put that at risk for no gain.
#
# Testable: this file only DEFINES functions, so `TIERS_LIB_ONLY=1 source` (or a
# plain source) loads them without running any tier.
# shellcheck shell=bash

# ── Platform predicate + launchd helpers (Darwin) ─────────────────────────────
_is_darwin() { [ "$(uname -s)" = "Darwin" ]; }

# _launchd_write <label> <plist-body-fragment>: emit a LaunchAgent plist and
# (re)load it. `bootout` before `bootstrap` because bootstrap refuses a label
# that is already loaded, which would make every re-run a no-op after the first.
# Returns non-zero if the load fails, so callers can warn.
_launchd_write() {
  local label="$1" body="$2"
  local dir="$HOME/Library/LaunchAgents" plist
  plist="$dir/${label}.plist"
  mkdir -p "$dir"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$label"
    printf '%s' "$body"
    printf '</dict>\n</plist>\n'
  } > "$plist"
  launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1
}

# _launchd_args <cmd…>: the <ProgramArguments> array fragment.
_launchd_args() {
  local a
  printf '  <key>ProgramArguments</key>\n  <array>\n'
  for a in "$@"; do printf '    <string>%s</string>\n' "$a"; done
  printf '  </array>\n'
}

# _launchd_periodic <label> <interval-seconds> <cmd…> — a timer equivalent.
# RunAtLoad is deliberately false: these fire on an interval, and running every
# one of them the instant provisioning finishes would stack a full fetch sweep
# on top of the install. StartInterval alone schedules the first run one
# interval out, which matches the systemd OnBootSec=2min shape closely enough.
_launchd_periodic() {
  local label="$1" interval="$2"; shift 2
  _launchd_write "$label" "$(
    _launchd_args "$@"
    printf '  <key>StartInterval</key><integer>%s</integer>\n' "$interval"
    printf '  <key>ProcessType</key><string>Background</string>\n'
  )"
}

# _launchd_service <label> <cmd…> — a long-running service equivalent
# (systemd Type=simple + Restart=on-failure). KeepAlive/SuccessfulExit=false
# restarts on a crash but not after a clean exit, which is what on-failure means.
_launchd_service() {
  local label="$1"; shift
  _launchd_write "$label" "$(
    _launchd_args "$@"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '  <key>KeepAlive</key>\n  <dict>\n    <key>SuccessfulExit</key><false/>\n  </dict>\n'
  )"
}

# ── CORE 1: base apt packages ─────────────────────────────────────────────────
# Requires root. When none is reachable non-interactively (PRIV=0, e.g. a
# converge run on a box whose user needs an interactive sudo password), SKIP
# rather than die — this is the "skips what it can't do" contract the post-merge
# hook documents. A first, privileged run (interactive or root) still installs.
tier_apt_min() {
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping apt base install (assuming a prior privileged run set up the base tier). Re-run with a TTY or as root to (re)install."
  else
    info "Installing base packages (apt)…"
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq || die "apt-get update failed"
    APT_UPDATED=1
    # All of these are in Debian main / Ubuntu universe. Kept intentionally lean —
    # the dev layer (build tools, ripgrep/fd/fzf) is tier_apt_dev; extras (bat,
    # fish, direnv, delta) are best-effort in there too.
    $SUDO apt-get install -y --no-install-recommends \
      git curl wget ca-certificates xz-utils unzip \
      python3 jq \
      || die "apt base install failed"
    ok "base packages installed"
  fi
}

# ── BEST-EFFORT: the dev apt layer + shell niceties ───────────────────────────
# The workstation-only half of the old CORE apt block plus everything that
# decorates an interactive dev box: fd/fzf/ripgrep, fish/direnv/delta/bat,
# starship, uv, gh. A lean server profile (hub) skips this entirely.
tier_apt_dev() {
  # Same contract as tier_apt_min: with no reachable root non-interactively
  # (a detached converge on a box needing an interactive sudo password) this is
  # a warn-and-skip, not a pile of failing unprivileged apt calls.
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping the dev apt layer"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  # tier_apt_min already refreshed the index in this process — don't pay twice.
  if [ -z "${APT_UPDATED:-}" ]; then
    $SUDO apt-get update -qq || warn "apt-get update failed"
    APT_UPDATED=1
  fi
  info "Installing dev packages (apt)…"
  # ncurses-term rides along with tmux: it carries the tmux-256color terminfo
  # entry, without which `default-terminal "tmux-256color"` makes tmux refuse to
  # start ("missing or unsuitable terminal"). ~/.tmux.conf probes for it and
  # falls back, so this is about getting the better entry, not about booting.
  $SUDO apt-get install -y --no-install-recommends \
    build-essential pkg-config \
    python3-venv python3-pip \
    ripgrep fd-find fzf \
    tmux ncurses-term \
    || warn "apt dev install failed"

  # fd-find installs the binary as `fdfind` on Debian/Ubuntu — add the friendly name.
  have fdfind && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"

  # apt extras — present in most repos, but tolerate absence.
  for p in fish direnv git-delta bat; do
    if $SUDO apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
      ok "$p"
    else
      warn "apt package '$p' unavailable — skipping"
    fi
  done
  # bat installs as `batcat` on Debian/Ubuntu — friendly name.
  have batcat && ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"

  # starship prompt (matches the fleet's prompt tool).
  if have starship; then
    ok "starship already installed"
  else
    info "Installing starship…"
    curl -fsSL https://starship.rs/install.sh | $SUDO sh -s -- -y >/dev/null 2>&1 \
      && ok "starship installed" \
      || warn "starship install failed"
  fi

  # uv — fast Python package manager (installs to ~/.local/bin).
  if have uv; then
    ok "uv already installed"
  else
    curl -fsSL https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
      && ok "uv installed" \
      || warn "uv install failed"
  fi

  # delta: wire it into git only if it actually installed.
  if have delta; then
    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true
    git config --global delta.line-numbers true
  fi

  # gh (GitHub CLI) — NOT in Debian/Ubuntu's default repos, so add GitHub's
  # official apt source. Powers `gh auth login` (the recommended per-box auth) and
  # the statusline PR segment.
  if have gh; then
    ok "gh already installed"
  else
    info "Installing GitHub CLI (gh)…"
    if $SUDO mkdir -p -m 755 /etc/apt/keyrings \
       && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
       && $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
       && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
       && $SUDO apt-get update -qq \
       && $SUDO apt-get install -y gh >/dev/null 2>&1; then
      ok "gh installed"
    else
      warn "gh install failed — see github.com/cli/cli/blob/trunk/docs/install_linux.md"
    fi
  fi

  # gh credential helper for HTTPS remotes (SSH remotes don't need it).
  have gh && git config --global --replace-all credential."https://github.com".helper '!gh auth git-credential'
  return 0
}

# ── BEST-EFFORT: the physical-display status board ────────────────────────────
# Packages only. The board itself is installed by a deliberate act
# (provision/statusboard/statusboard.sh --install for the text board on tty2-6,
# statusboard-gui.sh --install for the kiosk on tty1), because it takes a VT away
# from the login prompt and that is not something a converge run should decide.
#
# What each one is for:
#   cage foot foot-terminfo  the kiosk itself — a Wayland kiosk compositor running
#                            one terminal emulator, which is what lets the charts
#                            use the real block ramp. A psf console font tops out
#                            at 512 glyphs and carries none of U+2581..U+2587, so
#                            the VT path degrades to a repeating ASCII ramp.
#   fontconfig               statusboard-gui.sh --check asks fc-list whether the
#                            chosen font actually covers the ramp, rather than
#                            trusting its name.
#   fonts-jetbrains-mono     that font. NOT the Nerd Font variant — icons are a
#                            separate decision and a separate download.
#   btop                     for the planned second pane; unused until then.
#   polkitd                  THE ESCAPE HATCH. cage -s enables VT switching, but
#                            the switch itself goes through logind's Seat.SwitchTo,
#                            which is polkit-gated. With no polkit installed at all
#                            (a minimal Debian install has none) logind denies every
#                            gated action to non-root, so Ctrl-Alt-F2..F7 silently
#                            does nothing and the only console on the box is
#                            reachable only over the network. Measured on latitude
#                            2026-07-29: cage logged "[libseat] Could not switch
#                            session: Permission denied" on every keypress.
#
# Best-effort throughout: a box that fails to install a terminal emulator should
# still finish provisioning, and the check/install steps refuse to proceed on their
# own if anything here is missing.
tier_statusboard() {
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping the status-board packages"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if [ -z "${APT_UPDATED:-}" ]; then
    $SUDO apt-get update -qq || warn "apt-get update failed"
    APT_UPDATED=1
  fi
  info "Installing status-board packages (apt)…"
  # tmux and ncurses-term are here as well as in tier_apt_min's dev layer, on
  # purpose: the kiosk splits the display with tmux, and its config asks for
  # `default-terminal tmux-256color` — an entry that lives in ncurses-term and
  # without which tmux REFUSES to start. tmux sits upstream of the board in that
  # chain, so its absence is a black screen, not a missing pane. A tier that can
  # produce a black screen must not depend on another tier having run first.
  # smartmontools is the only way to a temperature on a USB-attached drive: the
  # kernel's drivetemp hwmon covers native SATA, and nothing behind a USB-SATA bridge
  # gets a hwmon node at all. Without it the disk block's temperature column is a row
  # of dashes on every spinner. It happened to be installed on latitude by hand, which
  # is exactly the state this tier exists to remove — a reinstall would have lost the
  # temperatures with no error to explain why.
  $SUDO apt-get install -y --no-install-recommends \
    cage foot foot-terminfo fontconfig fonts-jetbrains-mono btop polkitd \
    tmux ncurses-term smartmontools \
    || warn "status-board package install failed — the board's --check will name what is missing"
  return 0
}

# ── SERVER: cap the battery charge level ──────────────────────────────────────
# latitude is a laptop that never moves and never leaves AC, which is the one duty
# cycle that ruins a lithium cell: held at 100% and warm, indefinitely.
#
# Dell's EC can stop short of full, but ONLY in its Custom charge mode, and that is
# the part the retired NixOS module missed: modules/hardware/dell-latitude.nix
# wrote charge_control_end_threshold and nothing else, so the EC stayed in [Fast]
# and charged straight past the limit that sysfs was displaying. Measured on
# latitude 2026-07-29 — end=85, charge_types=[Fast], battery at 94% and still
# Charging; writing Custom flipped it to `Not charging` within three seconds with
# nothing else changed. So the limit was cosmetic for as long as it has existed,
# on NixOS as much as here.
#
# A no-op on hardware with no threshold file, which is what makes it safe to run
# anywhere: a mains-only box or a non-Dell laptop reports and returns rather than
# failing the provision run.
tier_battery_limit() {
  local pct="${1:-85}" start="${2:-80}" bat="" d
  case "$pct" in '' | *[!0-9]*) warn "battery limit '$pct' is not a number — skipping"; return 0 ;; esac
  case "$start" in '' | *[!0-9]*) warn "battery floor '$start' is not a number — skipping"; return 0 ;; esac
  for d in /sys/class/power_supply/BAT*; do
    [ -f "$d/charge_control_end_threshold" ] && { bat="$d"; break; }
  done
  if [ -z "$bat" ]; then
    info "no battery exposes charge_control_end_threshold — skipping the charge limit"
    return 0
  fi
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping the battery charge limit"
    return 0
  fi
  info "Installing charge-upto (charge window ${start}-${pct}%)…"

  $SUDO tee /usr/local/bin/charge-upto >/dev/null <<'CU'
#!/bin/sh
# charge-upto [ceiling] [floor] — cap this laptop's battery charge level.
#
# Installed by tier_battery_limit in machines/provision/lib/tiers.sh. Edit the
# tier and re-provision rather than editing this copy; to change the levels, edit
# /etc/default/charge-upto (persistent) or pass them (until the next boot).
#
# The FLOOR matters as much as the ceiling on a box that never unplugs. With a
# floor of 50 the cell drifts down to 50%, charges back to the ceiling and repeats
# — a 35-point cycle every time, which is harder on it than simply sitting near
# the ceiling. A floor just under the ceiling holds it steady instead.
#
# Writing the thresholds is not enough on a Dell: the EC honours charge_control_*
# only in its Custom charge mode and it comes up in [Fast]. Hence the mode write,
# and hence it comes LAST — after the thresholds it is meant to act on.
set -eu

DEFAULT=85
DEFAULT_START=80
[ -r /etc/default/charge-upto ] && . /etc/default/charge-upto
PCT="${1:-${CHARGE_UPTO:-$DEFAULT}}"
START="${2:-${CHARGE_START:-$DEFAULT_START}}"
case "$PCT" in '' | *[!0-9]*) echo "charge-upto: '$PCT' is not a percentage" >&2; exit 2 ;; esac
if [ "$PCT" -lt 1 ] || [ "$PCT" -gt 100 ]; then
  echo "charge-upto: $PCT is outside 1-100" >&2; exit 2
fi
case "$START" in '' | *[!0-9]*) echo "charge-upto: floor '$START' is not a percentage" >&2; exit 2 ;; esac
if [ "$START" -ge "$PCT" ]; then
  if [ "$PCT" -gt 5 ]; then START=$((PCT - 5)); else START=1; fi
  printf 'charge-upto: floor lowered to %s%% to stay under the %s%% ceiling\n' "$START" "$PCT" >&2
fi

found=0
for b in /sys/class/power_supply/BAT*; do
  [ -f "$b/charge_control_end_threshold" ] || continue
  found=1

  # Floor to its minimum FIRST, so it can never block the ceiling write. The EC
  # wants start below end, which makes the correct write order depend on whether
  # the ceiling is moving up or down; dropping the floor out of the way first
  # removes the dependency, and the EC clamps the 1 up to its own minimum anyway.
  # The real floor goes in after the ceiling, when there is room for it.
  if [ -f "$b/charge_control_start_threshold" ]; then
    printf '1\n' > "$b/charge_control_start_threshold" 2>/dev/null || true
  fi

  printf '%s\n' "$PCT" > "$b/charge_control_end_threshold"

  if [ -f "$b/charge_control_start_threshold" ]; then
    printf '%s\n' "$START" > "$b/charge_control_start_threshold" 2>/dev/null || true
    gots="$(cat "$b/charge_control_start_threshold" 2>/dev/null || echo '')"
    if [ "$gots" != "$START" ]; then
      printf 'charge-upto: %s asked floor %s%%, the EC applied %s%%\n' \
        "$(basename "$b")" "$START" "$gots" >&2
    fi
  fi

  # The EC has its own range and clamps INSIDE a successful write. Measured on
  # latitude 2026-07-29: the start threshold refuses to go below 50 and the end
  # refuses to go below 55 — `echo 35 > start` and `echo 40 > end` both returned
  # success, the first changing nothing and the second landing at 55. So the
  # readback is the truth and the requested value never is, and a difference gets
  # said out loud rather than swallowed: `charge-upto 40` reporting `limit 55%` is
  # easy to read as success at a glance.
  got="$(cat "$b/charge_control_end_threshold" 2>/dev/null || echo '')"
  if [ "$got" != "$PCT" ]; then
    printf 'charge-upto: %s asked for %s%%, the EC applied %s%% — its range wins\n' \
      "$(basename "$b")" "$PCT" "$got" >&2
  fi

  # Only where the EC offers Custom. A battery whose charge_types lists no such
  # mode honours the threshold directly, and writing an unsupported mode would
  # abort the loop under set -e.
  if [ -w "$b/charge_types" ] && grep -q Custom "$b/charge_types"; then
    printf 'Custom\n' > "$b/charge_types"
  fi

  printf 'charge-upto: %s %s-%s%% mode %s — now %s%%, %s\n' \
    "$(basename "$b")" \
    "$(cat "$b/charge_control_start_threshold" 2>/dev/null || echo '?')" \
    "$(cat "$b/charge_control_end_threshold")" \
    "$(tr ' ' '\n' < "$b/charge_types" 2>/dev/null | grep '^\[' | tr -d '[]' || echo n/a)" \
    "$(cat "$b/capacity")" "$(cat "$b/status")"
done

if [ "$found" = 0 ]; then
  echo "charge-upto: no battery exposes charge_control_end_threshold" >&2
  exit 1
fi
CU
  $SUDO chmod 0755 /usr/local/bin/charge-upto

  # Written only when absent: this is the knob a human tunes, and a re-provision
  # must not silently undo `CHARGE_UPTO=60`.
  if [ ! -f /etc/default/charge-upto ]; then
    $SUDO tee /etc/default/charge-upto >/dev/null <<CUD
# Battery charge window, in percent. Read by /usr/local/bin/charge-upto and by
# charge-upto.service at every boot and resume. Change it here and run
# \`sudo systemctl start charge-upto\` to apply without rebooting.
#
# CHARGE_START is the level charging RESUMES at. Keeping it just under the ceiling
# holds the cell steady; a low floor makes it cycle down and back every time,
# which is the harder life. Dell's EC will not take a floor below 50 or a ceiling
# below 55, and clamps silently — charge-upto reports it when that happens.
CHARGE_UPTO=$pct
CHARGE_START=$start
CUD
  fi

  # Boot AND every resume: the EC drops back to its default mode across a power
  # cycle, and a laptop that suspends nightly would otherwise spend most of its
  # life uncapped.
  $SUDO tee /etc/systemd/system/charge-upto.service >/dev/null <<'CUS'
[Unit]
Description=Cap the battery charge level
After=local-fs.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/bin/charge-upto

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
CUS

  if $SUDO systemctl daemon-reload >/dev/null 2>&1 \
    && $SUDO systemctl enable --now charge-upto.service >/dev/null 2>&1; then
    ok "charge-upto installed and applied ($($SUDO systemctl show -p ExecMainStatus --value charge-upto.service 2>/dev/null || echo '?') exit)"
  else
    warn "charge-upto installed but the unit would not enable — run \`sudo charge-upto\` by hand"
  fi
  return 0
}

# ── SERVER: let the status board read the CPU's energy counter ─────────────────
# The board's `power` row is the machine's actual consumption, and RAPL's psys domain
# is the only place on this hardware that number exists. The battery reports zero
# (charging is capped and inhibited), and the USB-C source psy reports zero through
# the PD hub — measured 2026-07-29.
#
# SECURITY, stated plainly rather than buried: /sys/class/powercap/*/energy_uj ships
# mode 0400 root:root because fine-grained energy readings are a side channel. The
# PLATYPUS work (CVE-2020-8694) recovered AES and RSA key material from exactly this
# interface, which is why the kernel restricted it to root in 5.10. This tier widens
# it to one group.
#
# On THIS box that grants no capability that did not already exist: the same user is
# already NOPASSWD ALL through tier_sudo_nopasswd, so anything running as them can
# `sudo cat` the file today. The change is a convenience — no fork and no auth.log
# entry every ten seconds — not a new privilege.
#
# It is scoped to a GROUP rather than 0444 so that statement stays exactly true.
# World-readable would hand the side channel to every other uid on the box, including
# ones that cannot reach root, and nothing here needs that.
#
# Deliberately its own tier, not folded into tier_statusboard: that tier is
# packages-only by design (see the note in linux.sh) and installing a unit from it
# would quietly end that property.
tier_rapl_read() {
  local grp="${1:-}" d found=""
  for d in /sys/class/powercap/intel-rapl:*; do
    [ -f "$d/energy_uj" ] && { found=1; break; }
  done
  if [ -z "$found" ]; then
    info "no RAPL energy counter on this hardware — skipping the power-draw reader"
    return 0
  fi
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping the RAPL read permission"
    return 0
  fi
  # The group the BOARD runs as, which is the invoking user's primary group. Passed
  # explicitly only by a test; deriving it means the tier works on a box where the
  # service user is not called `me`.
  [ -n "$grp" ] || grp="$(id -gn 2>/dev/null || printf '')"
  if [ -z "$grp" ]; then
    warn "cannot determine this user's group — skipping the RAPL read permission"
    return 0
  fi
  info "Installing statusboard-rapl-read (energy counter readable by group $grp)…"

  $SUDO tee /usr/local/bin/statusboard-rapl-read >/dev/null <<CU
#!/bin/sh
# statusboard-rapl-read — make the RAPL energy counters group-readable.
#
# Installed by tier_rapl_read in machines/provision/lib/tiers.sh; edit the tier and
# re-provision rather than editing this copy. See that tier for why this is safe on
# this box and what it would cost on one without passwordless sudo.
#
# Re-run at every boot and resume because these are sysfs attributes: their mode is a
# property of the live kernel object, so it is reset by a reboot and by anything that
# reloads intel_rapl_msr. A one-time chmod would silently stop working.
set -eu

GROUP="\${RAPL_GROUP:-$grp}"
[ -r /etc/default/statusboard-rapl-read ] && . /etc/default/statusboard-rapl-read

found=0
for d in /sys/class/powercap/intel-rapl:*; do
  [ -f "\$d/energy_uj" ] || continue
  found=1
  # Only the PARENT domains. The subdomains (intel-rapl:0:0 core, intel-rapl:0:1
  # uncore) are matched by the same glob and the board never reads them, so leaving
  # them at 0400 keeps the widened surface as small as the feature allows.
  case "\$(basename "\$d")" in *:*:*) continue ;; esac
  chgrp "\$GROUP" "\$d/energy_uj" 2>/dev/null || continue
  chmod 0440 "\$d/energy_uj" 2>/dev/null || true
  printf 'statusboard-rapl-read: %s (%s) now %s\n' \\
    "\$(basename "\$d")" "\$(cat "\$d/name" 2>/dev/null || echo '?')" \\
    "\$(stat -c '%a %U:%G' "\$d/energy_uj" 2>/dev/null || echo '?')"
done

[ "\$found" = 1 ] || { echo "statusboard-rapl-read: no RAPL energy counter present" >&2; exit 1; }
CU
  $SUDO chmod 0755 /usr/local/bin/statusboard-rapl-read

  $SUDO tee /etc/systemd/system/statusboard-rapl-read.service >/dev/null <<'RS'
[Unit]
Description=Make the RAPL energy counters readable by the status board
After=sysinit.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/bin/statusboard-rapl-read

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
RS

  if $SUDO systemctl daemon-reload >/dev/null 2>&1 \
    && $SUDO systemctl enable --now statusboard-rapl-read.service >/dev/null 2>&1; then
    ok "statusboard-rapl-read installed and applied"
  else
    warn "statusboard-rapl-read installed but the unit would not enable — the board's power row will read n/a"
  fi
  return 0
}

# ── CORE 1 (darwin): base Homebrew packages ───────────────────────────────────
# The macOS counterpart of tier_apt_min. No sudo anywhere: Homebrew owns its own
# prefix (/opt/homebrew on Apple Silicon) and refuses to run under sudo, so the
# PRIV/SUDO dance that tier_apt_min needs has no analogue here.
#
# `brew install` on an already-installed formula exits non-zero with "already
# installed" on some versions, so each package is probed with `brew list` first
# — otherwise a re-run of an idempotent script would abort the CORE tier.
tier_brew_min() {
  have brew || die "Homebrew not found — install it first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  info "Installing base packages (brew)…"
  # git/curl ship with macOS but are old (git 2.39-era, curl without HTTP/3);
  # brew's are the ones the rest of the fleet's tooling expects. python3 is NOT
  # preinstalled on macOS 12.3+ (Apple removed it), and agents/bootstrap.sh
  # needs it — so it is CORE here exactly as on Debian.
  local p
  for p in git curl wget xz unzip python3 jq; do
    if brew list --formula "$p" >/dev/null 2>&1; then
      ok "$p already installed"
    else
      brew install "$p" >/dev/null 2>&1 || die "brew install $p failed"
      ok "$p"
    fi
  done
  ok "base packages installed"
}

# ── BEST-EFFORT (darwin): the dev Homebrew layer + shell niceties ─────────────
# The macOS counterpart of tier_apt_dev. Two deliberate differences from the
# Debian body:
#   • NO fdfind/batcat aliasing. Debian renames those binaries to dodge package
#     conflicts; Homebrew installs `fd` and `bat` under their real names, so the
#     ~/.local/bin symlinks tier_apt_dev creates would be redundant at best and
#     would shadow the real binary with a stale link at worst.
#   • starship/uv come from brew rather than their curl installers — same
#     binaries, but brew can then upgrade them with everything else.
tier_brew_dev() {
  have brew || { warn "Homebrew not found — skipping the dev brew layer"; return 0; }
  info "Installing dev packages (brew)…"
  local p
  for p in ripgrep fd fzf tmux fish direnv git-delta bat starship uv gh; do
    if brew list --formula "$p" >/dev/null 2>&1; then
      ok "$p already installed"
    elif brew install "$p" >/dev/null 2>&1; then
      ok "$p"
    else
      warn "brew formula '$p' failed — skipping"
    fi
  done

  # delta: wire it into git only if it actually installed. Identical to the
  # Debian body — the formula is `git-delta`, the binary is `delta`.
  if have delta; then
    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true
    git config --global delta.line-numbers true
  fi

  # gh credential helper for HTTPS remotes (SSH remotes don't need it).
  have gh && git config --global --replace-all credential."https://github.com".helper '!gh auth git-credential'
  return 0
}

# ── BEST-EFFORT (darwin): GUI apps from Homebrew Cask ─────────────────────────
# The third brew tier. Casks are not formulas and the difference bites twice:
#
#   • `brew list --formula <cask>` NEVER matches, so the idempotency probe here
#     uses `brew list --cask`. With the wrong flag every re-run reinstalls.
#   • A cask carrying `binary` / shell-completion artifacts links them OUTSIDE
#     the Homebrew prefix (/usr/local/bin, /opt/homebrew/share/…) and shells out
#     to `sudo` to do it. With no TTY the password read fails and the cask
#     ROLLS THE WHOLE INSTALL BACK — app moved to the Caskroom, files purged.
#     `--no-binaries` does not dodge it (kubectl and the completions still
#     sudo-link). So: this tier only completes from an interactive terminal;
#     over SSH or from an agent it warns and moves on. Hence BEST-EFFORT, and
#     hence the install is NOT output-redirected like the formula loops above —
#     the sudo prompt has to be visible.
#
# docker-desktop is here rather than in a Nix module because air is a Mac: the
# unpaid Docker Desktop is what every other non-NixOS box already runs (server,
# the WSL distros), so one engine story covers the whole imperative tier.
tier_brew_cask() {
  have brew || { warn "Homebrew not found — skipping the cask layer"; return 0; }
  info "Installing GUI apps (brew --cask)…"
  local c
  for c in docker-desktop; do
    if brew list --cask "$c" >/dev/null 2>&1; then
      ok "$c already installed"
    elif brew install --cask "$c"; then
      ok "$c"
    else
      warn "cask '$c' failed — it needs an interactive sudo. Re-run from a terminal window: brew install --cask $c"
    fi
  done

  # Docker Desktop links the CLI on install, but the daemon only exists once the
  # app's first launch has installed its privileged helper — nothing headless can
  # do that, and until it happens `docker` is a client pointed at no socket.
  if [ -d /Applications/Docker.app ] && ! docker info >/dev/null 2>&1; then
    warn "Docker Desktop present but the daemon is down — launch it once: open -a Docker"
  fi
  return 0
}

# ── CORE 2: agent config (Claude Code) — the crown jewels ─────────────────────
# agents/bootstrap.sh symlinks the version-controlled config into ~/.claude (and
# mirrors it into any Orca-managed account profile). It only needs git + python3
# (both installed above) and has no Nix-only assumptions, so it works verbatim
# here. env -u CLAUDE_CONFIG_DIR forces the personal profile (mirrors
# `just agent-bootstrap`).
tier_agents_config() {
  info "Linking synced agent config (Claude Code)…"
  env -u CLAUDE_CONFIG_DIR bash "$REPO/agents/bootstrap.sh" || die "agents/bootstrap.sh failed"
  ok "agent config linked"
}

# ── CORE 3: git identity + basics (cheap, high-value; mirrors modules/home/me.nix) ──
tier_git_base() {
  info "Configuring git…"
  git config --global user.name  "Maxim Romanyuk"
  git config --global user.email "metheoryt@gmail.com"
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global push.autoSetupRemote true
  git config --global merge.conflictstyle diff3
  git config --global core.autocrlf input
  git config --global alias.st status
  git config --global alias.co checkout
  git config --global alias.br branch
  git config --global alias.up 'pull --rebase'
  git config --global alias.last 'log -1 HEAD'
  git config --global alias.graph "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
  ok "git configured"
}

# ── BEST-EFFORT: gortex code-intelligence daemon binary ───────────────────────
# Version is read from provision/gortex.version — one bare semver, whose own
# header explains why it is a data file. It used to be grepped out of
# `pkgs/gortex.nix`, which made a Nix package definition a live input to POSIX
# provisioning; that file went with the NixOS tree on 2026-08-01
# (docs/2026-08-01-nixos-harvest.md) and this pin was rehomed rather than lost.
#
# The asset name is resolved per platform here rather than pinned, because the
# upstream release ships darwin_arm64 and darwin_amd64 alongside linux_amd64 and
# this fleet now runs on all three. No hash is verified: the download is HTTPS
# from the GitHub release, which is the same trust root as the pin itself.
_gortex_asset() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64)   echo gortex_linux_amd64 ;;
    Darwin-arm64|Darwin-aarch64) echo gortex_darwin_arm64 ;;
    Darwin-x86_64)              echo gortex_darwin_amd64 ;;
    *)                          return 1 ;;
  esac
}

tier_gortex() {
  info "Installing gortex…"
  # First bare semver on a non-comment line, so the file can carry a header.
  GVER="$(grep -vE '^[[:space:]]*#' "$REPO/provision/gortex.version" 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  local asset
  if [ -z "$GVER" ]; then
    warn "couldn't parse a version from provision/gortex.version — skipping gortex"
  elif ! asset="$(_gortex_asset)"; then
    warn "no gortex release asset for $(uname -s)/$(uname -m) — skipping gortex"
  elif curl -fsSL "https://github.com/zzet/gortex/releases/download/v${GVER}/${asset}.tar.gz" \
         | tar -xz -C "$HOME/.local/bin" gortex 2>/dev/null; then
    chmod +x "$HOME/.local/bin/gortex"
    ok "gortex ${GVER} → ~/.local/bin/gortex"
  else
    warn "gortex download failed (v${GVER}) — install later or check the release URL"
  fi
}

# ── BEST-EFFORT: agent CLIs ───────────────────────────────────────────────────
# tier_agent_clis <cli>…: install the requested agent CLIs via their native
# installers (no Node). Unknown names warn and are skipped.
tier_agent_clis() {
  local c
  for c in "$@"; do
    case "$c" in
      claude)
        if have claude; then
          ok "claude already installed"
        else
          info "Installing Claude Code…"
          curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 \
            && ok "claude installed" \
            || warn "claude install failed — retry: curl -fsSL https://claude.ai/install.sh | bash"
        fi ;;
      *) warn "unknown agent CLI '$c' — skipped" ;;
    esac
  done
}

# ── BEST-EFFORT: git-autofetch (fetch-only refresh of all repos under $HOME) ──
# Mirrors modules/system/git-autofetch on the Nix fleet: a periodic `git fetch`
# — refs only, NEVER pull/merge/rebase and never touching a work tree — so
# `git status` / the prompt show an accurate "behind by N" without fetching
# first. The actual pull stays deliberate. Installs a small script, then
# schedules it via a systemd *user* timer when this distro runs systemd
# (modern WSL2 default), else a cron entry.
tier_autofetch() {
  info "Installing git-autofetch…"
  AF="$HOME/.local/bin/git-autofetch"
  cat > "$AF" <<'AUTOFETCH'
#!/usr/bin/env sh
# git-autofetch — fetch-only refresh of every git repo under $GIT_AUTOFETCH_ROOTS
# (default $HOME) so ahead/behind counts are accurate without fetching first.
# NEVER pulls/merges/rebases; never touches a working tree. Installed by
# tier_autofetch in provision/lib/tiers.sh (provision/linux.sh + provision/macos.sh);
# mirrors modules/system/git-autofetch on the Nix fleet.
#
# It DELIBERATELY diverges from that Nix module in one place — the af_timeout
# shim below. The module runs with pkgs.coreutils on its PATH, so plain
# `timeout` always resolves there. This script has to survive a bare macOS.
# Do not "resync" the two by deleting the shim.
set -u
: "${GIT_AUTOFETCH_ROOTS:=$HOME}"
: "${GIT_AUTOFETCH_TIMEOUT:=60}"                              # per-repo wall clock
export GIT_TERMINAL_PROMPT=0                                  # never block on auth
# ServerAlive* bounds a stall AFTER the handshake, which ConnectTimeout does not
# cover: a wedged session is torn down in ~30s at the transport layer. It does
# NOT replace the wall clock below — it does nothing for an https:// remote.
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

# af_timeout SECS CMD… — bound one fetch's wall clock, portably.
#
# macOS has NO timeout(1). It is GNU coreutils, not BSD, and coreutils is not
# installed by default — so the plain `timeout 60 git …` this script used to run
# failed with "command not found" on EVERY repo. That failure was invisible three
# times over: 2>/dev/null ate the message, `|| echo` turned it into an
# indistinguishable "fetch failed/skipped", and the script still exited 0. launchd
# reported a healthy job for a box that had never fetched anything. Hence both the
# shim and the all-failed exit at the bottom.
if command -v timeout >/dev/null 2>&1; then
  af_timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then                # coreutils via Homebrew
  af_timeout() { gtimeout "$@"; }
else
  af_timeout() {
    _secs="$1"; shift
    "$@" & _cmd=$!
    ( sleep "$_secs"; kill -TERM "$_cmd" 2>/dev/null ) & _watch=$!
    wait "$_cmd" 2>/dev/null; _rc=$?      # 143 when the watchdog fired
    kill -TERM "$_watch" 2>/dev/null      # TERM hits the subshell, not its
    wait "$_watch" 2>/dev/null || :       # `sleep` child — that one lingers
    return "$_rc"                         # until it expires. Harmless.
  }
fi

# Collect the repo list into a FILE, then read from it. `while read` on the right
# of a pipe runs in a subshell, so the counters below would be discarded and the
# all-failed exit could never fire.
_list="$(mktemp)" || exit 1
trap 'rm -f "$_list"' EXIT HUP INT TERM
for root in $GIT_AUTOFETCH_ROOTS; do
  [ -d "$root" ] || continue
  # -prune stops find descending into a repo's own .git; skip heavy vendored
  # trees. Match .git as dir (normal repo) or file (submodule/linked worktree).
  find "$root" -maxdepth 4 \
    \( -path '*/node_modules' -o -path '*/.cache' -o -name '.direnv' \) -prune -o \
    -name .git -prune -print 2>/dev/null >> "$_list"
done

_total=0
_failed=0
while IFS= read -r gitentry; do
  repo=$(dirname "$gitentry")
  # SKIP SHALLOW CLONES — fetching one is expensive and destroys its shallowness.
  # A `clone --depth 1` client can only offer its single commit during negotiation,
  # and its shallow boundary stops it claiming any ancestor, so the server resends
  # the whole history it cannot prove the client has. Measured on the since-removed
  # ~/.hermes/hermes-agent (upstream's install.sh did `clone --depth 1 --branch`):
  # a 60M / 1-commit clone became 350M with refs/remotes/origin/main legitimately
  # reaching 18914 commits. `git gc` cannot reclaim that — nothing is garbage, the
  # ref really does reach it all — so the damage is one-way.
  #
  # Nor is a shallow repo worth fetching: it is a vendored third-party install with
  # its own updater (install.sh re-fetches its own branch), not a checkout whose
  # ahead/behind you track. Skipping is not counted in _total, so a box holding only
  # shallow clones does not trip the all-failed exit below.
  if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    continue
  fi
  _total=$((_total + 1))
  af_timeout "$GIT_AUTOFETCH_TIMEOUT" git -C "$repo" fetch --all --prune --quiet 2>/dev/null \
    || { _failed=$((_failed + 1)); echo "fetch failed/skipped: $repo" >&2; }
done < "$_list"

# One unreachable remote stays a warning. EVERY repo failing is a broken install
# — missing binary, no credentials, no network — and must exit non-zero so the
# systemd unit / launchd job surfaces it instead of looking healthy.
if [ "$_total" -gt 0 ] && [ "$_failed" -eq "$_total" ]; then
  echo "git-autofetch: all $_total fetches failed" >&2
  exit 1
fi
AUTOFETCH
  chmod +x "$AF"
  ok "git-autofetch → ~/.local/bin/git-autofetch"

  _scheduled=""
  # SCHEDULED tier — Darwin branch. No systemd; per-user cron on macOS needs the
  # cron binary granted Full Disk Access in System Settings, which is not
  # scriptable, so launchd is the only install that works unattended.
  if _is_darwin; then
    if _launchd_periodic kz.cyphy.git-autofetch 600 "$AF"; then
      ok "git-autofetch scheduled — launchd LaunchAgent (every ~10 min)"
    else
      warn "git-autofetch installed but launchctl bootstrap failed — run ~/.local/bin/git-autofetch manually"
    fi
    return 0
  fi

  # Preferred: a systemd *user* timer. `show-environment` fails cleanly on a WSL
  # distro without systemd ("System has not been booted with systemd"), so it
  # doubles as the availability probe.
  if systemctl --user show-environment >/dev/null 2>&1; then
    _ud="$HOME/.config/systemd/user"; mkdir -p "$_ud"
    cat > "$_ud/git-autofetch.service" <<'UNIT'
[Unit]
Description=Fetch all git repos under HOME (refs only, no pull)
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/git-autofetch
UNIT
    cat > "$_ud/git-autofetch.timer" <<'UNIT'
[Unit]
Description=Periodic git fetch of all repos under HOME

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
UNIT
    if systemctl --user daemon-reload >/dev/null 2>&1 \
       && systemctl --user enable --now git-autofetch.timer >/dev/null 2>&1; then
      # Keep the user manager (and its timers) running without an open session.
      $SUDO loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
      _scheduled="systemd user timer (every ~10 min)"
    fi
  fi
  # Fallback: cron, if a crontab is available.
  if [ -z "$_scheduled" ] && have crontab; then
    _cur="$(crontab -l 2>/dev/null || true)"
    if printf '%s\n' "$_cur" | grep -qF "$AF"; then
      _scheduled="cron (already scheduled)"
    elif { printf '%s\n' "$_cur"; printf '%s\n' "*/10 * * * * $AF >/dev/null 2>&1"; } \
           | crontab - >/dev/null 2>&1; then
      _scheduled="cron (every 10 min)"
    fi
  fi
  if [ -n "$_scheduled" ]; then
    ok "git-autofetch scheduled — $_scheduled"
  else
    warn "git-autofetch installed but not scheduled (no systemd user manager or cron) — run ~/.local/bin/git-autofetch manually, or enable systemd in /etc/wsl.conf"
  fi
}

# ── BEST-EFFORT: multi-account SSH wiring + per-account commit identity ────────
# Per-box SSH keys + ~/.ssh/config for multiple GitHub accounts, so each remote
# uses the right key regardless of gh's active account. Used here to keep the
# `cyphy671` account (isolated repos, e.g. qaz-law) separate from `metheoryt`.
#
# NOT for a box whose existing GitHub auth is a key this tier does not know
# about: the generated block sets IdentitiesOnly on a fresh, unregistered key
# and would kill that box's only working auth. That is why the hub profile omits
# this tier — see the design spec's hazard 1.
#
# Declared as "host-alias:github-user". The FIRST entry owns the default
# `github.com` host; the rest get their alias (clone via git@<alias>:owner/repo).
# One ed25519 key per account is generated as ~/.ssh/id_<user>. Edit this list to
# add/remove accounts, or blank it to skip the whole section.
tier_ssh_accounts() {
  # "host-alias:github-user". The key path derives from the USER (id_<user>), so
  # several aliases may share one account's key — that is how github.com and
  # metheoryt.github.com stay one registered key, not two.
  #
  # `github.com` is not optional: the clone button, `gh repo clone`, READMEs and
  # submodule URLs all emit git@github.com, and without a block those fall back
  # to default key order instead of a pinned identity. The <user>.github.com
  # aliases are self-documenting synonyms — the account is legible in the URL.
  # Safe as names because *.github.com has no wildcard A record (verified
  # 2026-07-28: metheoryt.github.com / cyphy671.github.com / foo.github.com all
  # NXDOMAIN, while api.github.com resolves), so a missing block fails loudly
  # instead of connecting somewhere unintended.
  SSH_ACCOUNTS=(
    "github.com:metheoryt"             # canonical — what every GitHub URL uses
    "metheoryt.github.com:metheoryt"   # readable synonym for the default account
    "cyphy671.github.com:cyphy671"     # isolated account — size/limit blast-radius
  )
  if [ "${#SSH_ACCOUNTS[@]}" -gt 0 ]; then
    info "Wiring multi-account SSH…"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    _block="$(mktemp)"
    _need_register=""
    for _entry in "${SSH_ACCOUNTS[@]}"; do
      _alias="${_entry%%:*}"; _user="${_entry##*:}"
      _key="$HOME/.ssh/id_${_user}"
      if [ -e "$_key" ]; then
        ok "key ~/.ssh/id_${_user} exists"
      else
        # Key comment identifies the box. Was hardcoded "-wsl"; this tier now
        # also runs on macOS, where that label would be a lie.
        if ssh-keygen -t ed25519 -f "$_key" -C "${_user}@$(uname -n)" -N "" >/dev/null 2>&1; then
          ok "generated ~/.ssh/id_${_user}"
          _need_register="${_need_register} ${_user}"
        else
          warn "ssh-keygen for ${_user} failed"
          continue
        fi
      fi
      {
        printf 'Host %s\n'                 "$_alias"
        printf '    HostName github.com\n'
        printf '    User git\n'
        printf '    IdentityFile ~/.ssh/id_%s\n' "$_user"
        printf '    IdentitiesOnly yes\n\n'
      } >> "$_block"
    done
    # Replace our managed block in ~/.ssh/config (between markers), keep the rest.
    _cfg="$HOME/.ssh/config"; touch "$_cfg"
    _B="# >>> machines-bootstrap ssh accounts >>>"
    _E="# <<< machines-bootstrap ssh accounts <<<"
    _rest="$(mktemp)"
    awk -v b="$_B" -v e="$_E" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$_cfg" > "$_rest"
    { printf '%s\n' "$_B"; cat "$_block"; printf '%s\n' "$_E"; cat "$_rest"; } > "$_cfg"
    chmod 600 "$_cfg"
    rm -f "$_block" "$_rest"
    ok "wrote ~/.ssh/config account blocks"
    if [ -n "$_need_register" ]; then
      for _user in $_need_register; do
        warn "register id_${_user} on GitHub → run: gh auth login  (SSH → select ~/.ssh/id_${_user}.pub)"
      done
    fi
  fi

  # Author name/email per GitHub account, with NO fixed on-disk directory: git's
  # includeIf "hasconfig:remote.*.url:…" matches on the repo's remote URL, so ANY
  # repo cloned through an account's SSH alias (git@<alias>:owner/repo) authors its
  # commits with that account's identity, wherever it lives on disk. The default
  # github.com account keeps the global identity set above; list only the *other*
  # accounts here. Format "ssh-alias|author-name|author-email" — the alias must
  # match one in SSH_ACCOUNTS. Emails use GitHub's private noreply form
  # (<id>+<user>@users.noreply.github.com) so a real address is never leaked and
  # pushes aren't rejected by "keep my email address private". Needs git ≥ 2.36.
  GIT_IDENTITIES=(
    "cyphy671.github.com|cyphy671|259445360+cyphy671@users.noreply.github.com"
  )
  if [ "${#GIT_IDENTITIES[@]}" -gt 0 ]; then
    info "Wiring per-account commit identity…"
    _incdir="$HOME/.config/git"; mkdir -p "$_incdir"
    for _row in "${GIT_IDENTITIES[@]}"; do
      IFS='|' read -r _alias _name _email <<<"$_row"
      _idfile="$_incdir/identity-${_alias}"
      {
        printf '[user]\n'
        printf '\tname = %s\n'  "$_name"
        printf '\temail = %s\n' "$_email"
      } > "$_idfile"
      # Match on the remote URL; idempotent — add the include only if absent.
      _key="includeIf.hasconfig:remote.*.url:git@${_alias}:*/**.path"
      if ! git config --global --get-all "$_key" 2>/dev/null | grep -qxF "$_idfile"; then
        git config --global --add "$_key" "$_idfile"
      fi
      ok "commit identity for git@${_alias}: ${_name} <${_email}>"
    done
  fi
}

# ── BEST-EFFORT: outbound fleet SSH client config ─────────────────────────────
# The counterpart to tier_ssh_trust: that one makes this box ACCEPT fleet logins,
# this one lets it MAKE them (`ssh latitude`, `ssh hub`).
#
# On a NixOS host modules/home/ssh.nix generates ~/.ssh/config from fleet.json,
# and on a WSL distro provision/ssh-wsl.sh does the same. A macOS box has
# neither, and tier_ssh_accounts is NOT a substitute — it writes only the
# GitHub-account blocks, so without this tier ~/.ssh/config on the Mac contains
# no fleet hosts at all and `ssh latitude` falls back to the local account name
# with no identity file.
#
# Rather than a third renderer that would drift from the other two, this sources
# ssh-wsl.sh's pure helpers through its documented SSH_WSL_LIB_ONLY hook. Those
# functions are jq over fleet.json with no WSL assumptions; everything
# WSL-specific in that script (apt, systemd sshd, the key persisted on the
# Windows host) lives below the guard and never runs here.
#
# Deliberately NOT appending this box's pubkey to provision/fleet-authorized-keys:
# that is a one-time enrollment that dirties the repo and needs a commit, so it
# stays a manual step. This tier only ever touches ~/.ssh/.
tier_fleet_ssh() {
  info "Wiring outbound fleet SSH…"
  local helper="$REPO/provision/ssh-wsl.sh" fleet_json="$REPO/fleet.json"
  if [ ! -f "$helper" ] || [ ! -f "$fleet_json" ]; then
    warn "ssh-wsl.sh or fleet.json missing — skipping outbound fleet SSH config"
    return 0
  fi
  have jq || { warn "jq not found — skipping outbound fleet SSH config"; return 0; }

  # shellcheck source=provision/ssh-wsl.sh
  SSH_WSL_LIB_ONLY=1 source "$helper" || {
    warn "could not source ssh-wsl.sh helpers — skipping outbound fleet SSH config"
    return 0
  }

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  local key="$HOME/.ssh/id_fleet"
  if [ -e "$key" ]; then
    ok "fleet key ~/.ssh/id_fleet exists"
  # Comment is the LOGICAL fleet name, not `uname -n`: fleet-authorized-keys is
  # keyed that way because OS hostnames churn (see its header) and a Mac's can be
  # whatever DHCP last said. ssh_wsl_host_label came in with the source above.
  elif ssh-keygen -t ed25519 -f "$key" \
       -C "me@$(ssh_wsl_host_label "$(cat "$fleet_json")" "$(uname -n)")" \
       -N "" >/dev/null 2>&1; then
    ok "generated ~/.ssh/id_fleet"
    warn "ENROLLMENT NEEDED: append the line below to provision/fleet-authorized-keys, commit, and pull on the other members — until then no fleet box will accept this one:"
    printf '      %s\n' "$(cat "${key}.pub")" >&2
  else
    warn "ssh-keygen for the fleet key failed — skipping outbound fleet SSH config"
    return 0
  fi

  local cfg="$HOME/.ssh/config" block merged
  touch "$cfg"
  block="$(printf '%s\n%s\n%s' \
    "$CONFIG_MARKER_BEGIN" \
    "$(ssh_wsl_render_config "$(cat "$fleet_json")")" \
    "$CONFIG_MARKER_END")"
  merged="$(ssh_wsl_merge_config "$(cat "$cfg")" "$block")"
  printf '%s\n' "$merged" > "$cfg"
  chmod 600 "$cfg"
  ok "wrote fleet host blocks → ~/.ssh/config"
  return 0
}

# ── BEST-EFFORT: shell init (WSL-safe — no chsh) ──────────────────────────────
# tier_shell_init [--no-fish]: append PATH + starship/direnv hooks to ~/.bashrc,
# guarded so re-runs don't duplicate. We do NOT chsh (unreliable in WSL); to live
# in fish, add the exec line suggested at the end. --no-fish skips the fish seed
# (a lean server profile never installs fish).
tier_shell_init() {
  local want_fish=1
  [ "${1:-}" = "--no-fish" ] && want_fish=0
  BASHRC="$HOME/.bashrc"
  if ! grep -q 'machines-bootstrap' "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'EOF'

# ── machines-bootstrap ──────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"
command -v direnv   >/dev/null 2>&1 && eval "$(direnv hook bash)"
alias cc='claude'
alias ll='ls -alF'
# ────────────────────────────────────────────────────────────────────
EOF
    ok "updated ~/.bashrc"
  fi

  # macOS has defaulted to zsh since Catalina, and a login shell there never
  # reads ~/.bashrc — without this the Mac would get ~/.local/bin off PATH, no
  # starship, and no direnv, while the tier still reported success. Seeded in
  # ADDITION to ~/.bashrc, not instead of it: `bash -lc` still happens (agent
  # sessions, fd_run over ssh), and both files are guarded by the same marker.
  if _is_darwin; then
    ZSHRC="$HOME/.zshrc"
    if ! grep -q 'machines-bootstrap' "$ZSHRC" 2>/dev/null; then
      cat >> "$ZSHRC" <<'EOF'

# ── machines-bootstrap ──────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
# Homebrew's prefix differs by arch (/opt/homebrew on Apple Silicon,
# /usr/local on Intel) — let brew itself say which.
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v direnv   >/dev/null 2>&1 && eval "$(direnv hook zsh)"
alias cc='claude'
alias ll='ls -alF'
# ────────────────────────────────────────────────────────────────────
EOF
      ok "updated ~/.zshrc"
    fi
  fi

  # Minimal fish config (only if fish installed) — deliberately lean, not a copy
  # of modules/home/me.nix's full fish setup.
  if [ "$want_fish" -eq 1 ] && have fish; then
    mkdir -p "$HOME/.config/fish"
    FISHCFG="$HOME/.config/fish/config.fish"
    if ! grep -q 'machines-bootstrap' "$FISHCFG" 2>/dev/null; then
      cat >> "$FISHCFG" <<'EOF'
# ── machines-bootstrap ──
set -g fish_greeting ""
fish_add_path ~/.local/bin
command -v starship >/dev/null 2>&1; and starship init fish | source
command -v direnv   >/dev/null 2>&1; and direnv hook fish | source
alias cc='claude'
alias ll='ls -alF'
# ────────────────────────
EOF
      ok "seeded ~/.config/fish/config.fish"
    fi
  fi
  return 0
}

# ── BEST-EFFORT: fleet self-pull timer (Trigger B) — spec 2026-07-21 ──────────
# ~10-min ff-pull of every fleet-sync repo (provision/fleet-selfpull.sh). The
# pull fires the repo's post-merge hook, which fires convergence — this timer
# NEVER converges itself. systemd-user timer where available (mirrors the
# git-autofetch install above), else a cron fallback. Idempotent.
#
# tier_selfpull [fleet_roots]: a non-empty arg pins FLEET_ROOTS in the generated
# unit / cron line, so only those roots are scanned (hub: just ~/machines, so the
# vps repo that defines its live services is never auto-pulled). Unpinned,
# fleet-selfpull.sh defaults to "$HOME $HOME/my …" — i.e. it would find ~/vps.
# `%h` in the arg is expanded to $HOME HERE, for both schedulers: cron never
# expands specifiers, and a literal %h reaching either one silently scans nothing
# (the box then looks enrolled but never pulls).
tier_selfpull() {
  local roots="${1:-}"
  roots="${roots//%h/$HOME}"
  info "Installing fleet self-pull timer…"
  FSP="$REPO/provision/fleet-selfpull.sh"
  if [ ! -f "$FSP" ]; then
    warn "provision/fleet-selfpull.sh not found — skipping fleet self-pull timer"
  elif _is_darwin; then
    # SCHEDULED tier — Darwin branch. FLEET_ROOTS rides in as an `env` prefix in
    # ProgramArguments rather than an EnvironmentVariables dict, so the empty
    # (unpinned) case needs no separate plist shape. launchd has no
    # RandomizedDelaySec, and no KillMode problem either: it does not put the
    # job in a cgroup, so the detached converge the post-merge hook spawns
    # simply outlives this job — which is the behaviour KillMode=process buys
    # on the systemd side.
    if [ -n "$roots" ]; then
      _launchd_periodic kz.cyphy.fleet-selfpull 600 \
        /usr/bin/env "FLEET_ROOTS=$roots" bash "$FSP"
    else
      _launchd_periodic kz.cyphy.fleet-selfpull 600 /usr/bin/env bash "$FSP"
    fi \
      && ok "fleet-selfpull LaunchAgent installed" \
      || warn "could not load the fleet-selfpull LaunchAgent"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    _ud2="$HOME/.config/systemd/user"; mkdir -p "$_ud2"
    {
      printf '[Unit]\nDescription=Fleet self-pull (ff-only) of all fleet-sync repos\n\n'
      printf '[Service]\nType=oneshot\nTimeoutStartSec=8min\n'
      # The pull fires the repo's post-merge hook, which backgrounds converge.sh
      # with setsid — but setsid does not leave the unit's cgroup. Under the
      # default KillMode=control-group systemd SIGKILLs whatever is left there
      # the moment this oneshot finishes (~3s), so the converge is reaped before
      # it can rebuild/provision and Trigger B silently never applies anything.
      # KillMode=process limits the kill to the main process.
      printf 'KillMode=process\n'
      [ -n "$roots" ] && printf 'Environment=FLEET_ROOTS=%s\n' "$roots"
      printf 'ExecStart=/usr/bin/env bash %s\n' "$FSP"
    } > "$_ud2/fleet-selfpull.service"
    cat > "$_ud2/fleet-selfpull.timer" <<'UNIT'
[Unit]
Description=Periodic fleet self-pull

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    if systemctl --user daemon-reload >/dev/null 2>&1 \
       && systemctl --user enable --now fleet-selfpull.timer >/dev/null 2>&1; then
      ok "fleet-selfpull.timer (systemd-user) installed"
    else
      warn "could not enable fleet-selfpull.timer"
    fi
  elif have crontab; then
    local cron_env=""
    [ -n "$roots" ] && cron_env="FLEET_ROOTS='$roots' "
    if crontab -l 2>/dev/null | grep -qF "$FSP"; then
      ok "fleet-selfpull cron already present"
    elif { crontab -l 2>/dev/null; printf '*/10 * * * * sleep $((RANDOM %% 120)); %s/usr/bin/env bash %s >/dev/null 2>&1\n' "$cron_env" "$FSP"; } \
           | crontab - >/dev/null 2>&1; then
      ok "fleet-selfpull cron installed"
    else
      warn "could not install fleet-selfpull cron"
    fi
  else
    warn "fleet-selfpull installed but not scheduled (no systemd user manager or cron)"
  fi
  return 0
}

# ── BEST-EFFORT: dotfiles bootstrap for boxes that never reach the role ──────
# provision.sh's role dispatcher covers every fleet.json member. Self-declared
# WSL hosts run linux.sh directly and never see a role, so the tier list is
# their only path in. Same code, one call.
tier_dotfiles() {
  info "Bootstrapping dotfiles (bare repo)…"
  local name
  name="$(fleet_logical_name 2>/dev/null || true)"
  if [ -z "$name" ]; then
    warn "no logical fleet name (no fleet.local.json nickname, no fleet.json match) — skipping dotfiles"
    return 0
  fi
  # shellcheck source=provision/roles/dotfiles.sh
  source "$REPO/provision/roles/dotfiles.sh"
  role_dotfiles apply wsl "$name" || warn "dotfiles bootstrap reported an error"
  return 0
}

# ── BEST-EFFORT: dotfiles sync timer — spec 2026-07-28 §5.4 ──────────────────
# ~10-min tick of provision/dotfiles-sync.sh: commit tracked $HOME changes to
# this machine's branch, push, merge origin/main in (preflighted). Deliberately
# a plain systemd USER unit rather than a Nix module even on NixOS, so the same
# code path serves every POSIX box and NixOS retirement removes a case, not a
# mechanism. Precedent: agents/bootstrap.sh already deploys outside the nix
# generation for the same reason. Idempotent.
#
# TICK cadence matches tier_selfpull / git-autofetch (10 min) — deliberately
# aligned. COMMIT cadence is separate and lives in the script: a tick commits
# only once the tracked diff has settled (dotfiles-sync.sh sync_should_commit),
# so this timer interval is NOT the rate at which commits appear. Changing the
# script needs no re-provision — every scheduler here points at its absolute path.
# ── Passwordless sudo (server profile) ────────────────────────────────────────
# An always-on headless box is administered entirely over SSH, and every root task
# here — `--install`ing a unit, apt, setupcon, a converge rebuild — otherwise needs
# a human at a TTY to type a password. linux.sh already treats passwordless sudo as
# a first-class case (it picks `sudo -n` when it works and degrades to PRIV=0 when
# no root is reachable), so this tier is what makes the good branch true.
#
# Be honest about the trade rather than dressing it up: this is root for anything
# already running as this user, with no second factor. It is accepted here for the
# same reason base.nix accepts NOPASSWD nixos-rebuild — these are personal boxes
# whose SSH is keys-only and tailnet-bound — and it is NOT in the workstation or hub
# tier lists. Note also what it is not: sudo cannot see the tailnet. sudoers matches
# the local host, and a local sudo has no PAM rhost, so "passwordless only over the
# tailnet" is not expressible. The tailnet is a property of how you got here, not of
# the privilege check.
tier_sudo_nopasswd() {
  local user file tmp line
  user="${SUDO_USER:-$(id -un)}"
  if [ "$user" = root ]; then
    warn "cannot tell which user to grant passwordless sudo to (running as root with no SUDO_USER) — skipping"
    return 0
  fi
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping passwordless sudo for '$user'"
    return 0
  fi

  # SUDOERS_DIR exists so provision/tests/sudo-nopasswd.test.sh can exercise the
  # validate-then-install path against a temp directory; nothing sets it in anger.
  file="${SUDOERS_DIR:-/etc/sudoers.d}/$user"
  line="$user ALL=(ALL) NOPASSWD: ALL"
  if [ "$($SUDO cat "$file" 2>/dev/null)" = "$line" ]; then
    ok "passwordless sudo already configured for '$user'"
    return 0
  fi

  # Validate BEFORE installing. A syntactically broken file under /etc/sudoers.d
  # makes sudo refuse to run at all, and the only way back is a root shell — which
  # on a headless box means a trip to the physical console.
  tmp="$(mktemp)"
  printf '%s\n' "$line" > "$tmp"
  if ! $SUDO visudo -c -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "visudo rejected the drop-in for '$user' — leaving sudo untouched"
    return 0
  fi
  # No -o/-g: the install runs as root, so the file is root-owned already, and
  # naming the group explicitly would fail on any system whose root group is not
  # called "root" (macOS calls it wheel). 0440 is the part sudo actually checks —
  # it ignores a sudoers file that is group- or world-writable.
  $SUDO install -m 0440 "$tmp" "$file" || {
    rm -f "$tmp"
    warn "could not install $file"
    return 0
  }
  rm -f "$tmp"
  ok "passwordless sudo for '$user' ($file)"
}

tier_dotfiles_sync() {
  info "Installing dotfiles sync timer…"
  DFS="$REPO/provision/dotfiles-sync.sh"
  if [ ! -f "$DFS" ]; then
    warn "provision/dotfiles-sync.sh not found — skipping dotfiles sync timer"
  elif _is_darwin; then
    _launchd_periodic kz.cyphy.dotfiles-sync 600 /usr/bin/env bash "$DFS" \
      && ok "dotfiles-sync LaunchAgent installed" \
      || warn "could not load the dotfiles-sync LaunchAgent"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    _ud3="$HOME/.config/systemd/user"; mkdir -p "$_ud3"
    {
      printf '[Unit]\nDescription=Sync $HOME dotfiles to this machine'\''s branch\n\n'
      printf '[Service]\nType=oneshot\nTimeoutStartSec=5min\n'
      printf 'ExecStart=/usr/bin/env bash %s\n' "$DFS"
    } > "$_ud3/dotfiles-sync.service"
    cat > "$_ud3/dotfiles-sync.timer" <<'UNIT'
[Unit]
Description=Periodic dotfiles sync

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    if systemctl --user daemon-reload >/dev/null 2>&1 \
       && systemctl --user enable --now dotfiles-sync.timer >/dev/null 2>&1; then
      ok "dotfiles-sync.timer (systemd-user) installed"
    else
      warn "could not enable dotfiles-sync.timer"
    fi
  elif have crontab; then
    if crontab -l 2>/dev/null | grep -qF "$DFS"; then
      ok "dotfiles-sync cron already present"
    elif { crontab -l 2>/dev/null; printf '*/10 * * * * sleep $((RANDOM %% 120)); /usr/bin/env bash %s >/dev/null 2>&1\n' "$DFS"; } \
           | crontab - >/dev/null 2>&1; then
      ok "dotfiles-sync cron installed"
    else
      warn "could not install dotfiles-sync cron"
    fi
  else
    warn "dotfiles-sync installed but not scheduled (no systemd user manager or cron)"
  fi
  return 0
}

# ── BEST-EFFORT: inbound fleet SSH trust (ssh-server role) ────────────────────
# Merge provision/fleet-authorized-keys into ~/.ssh/authorized_keys so this box
# accepts inbound fleet logins (mirrors ssh-server.nix keyFiles / windows.ps1
# step 6 / ssh-wsl.sh step 4). Snapshot copy — re-run after a member joins OR
# LEAVES: the span is rewritten from fleet-authorized-keys each run, so a removed
# key is revoked here too (it used to only ever be appended). sshd itself is
# configured by ssh-wsl.sh (key-only); here we only ensure the authorized_keys
# trust so a bare linux.sh re-run keeps it.
tier_ssh_trust() {
  info "Ensuring inbound fleet SSH trust…"
  MESH_KEYS="$REPO/provision/fleet-authorized-keys"
  local helper="$REPO/provision/ssh-wsl.sh"
  if [ ! -f "$MESH_KEYS" ]; then
    warn "provision/fleet-authorized-keys not found — skipped inbound fleet trust"
    return 0
  fi
  if [ ! -f "$helper" ]; then
    warn "provision/ssh-wsl.sh not found — skipped inbound fleet trust"
    return 0
  fi

  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  local authk="$HOME/.ssh/authorized_keys" existing="" merged rc=0
  [ -f "$authk" ] && existing="$(cat "$authk")"

  # Sourced in a SUBSHELL on purpose. ssh-wsl.sh is a script, not a library: at
  # top level it runs `set -u` and defines its own info/ok/warn/die/have, which
  # would silently replace ours for every tier that runs after this one.
  # tier_fleet_ssh sources it in-process and gets away with it only because it is
  # darwin-only and near the end of that list. A subshell gets the one function
  # we want with none of the blast radius.
  merged="$(
    SSH_WSL_LIB_ONLY=1 . "$helper" >/dev/null 2>&1
    ssh_wsl_merge_authorized_keys "$existing" "$(cat "$MESH_KEYS")"
  )" || rc=$?

  # Nonzero = the merge refused (no key lines in fleet-authorized-keys) OR the
  # helper would not source. Either way we have no trustworthy span to write, and
  # writing a wrong one locks the fleet out of this box — so leave it alone.
  if [ "$rc" -ne 0 ]; then
    warn "could not build the fleet trust span (empty fleet-authorized-keys, or ssh-wsl.sh unreadable) — left $authk untouched"
  elif [ "$merged" = "$existing" ]; then
    ok "authorized_keys already trusts the fleet"
  else
    local tmp_ak; tmp_ak="$(mktemp)"
    printf '%s\n' "$merged" > "$tmp_ak"
    install -m600 "$tmp_ak" "$authk"
    rm -f "$tmp_ak"
    ok "rewrote fleet trust span → $authk (inbound trust)"
  fi
}
