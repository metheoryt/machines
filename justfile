# Justfile for fleet management — provisioning, agent config, checks.
# Run `just --list` to see all available commands.
#
# THIS FILE LOST 28 OF ITS 33 RECIPES ON 2026-08-01, with the NixOS tree they
# drove (tag `nixos-final`, docs/2026-08-01-nixos-harvest.md). Everything under
# build/ update/ maintenance/ was `nixos-rebuild` or `nix-store` against a flake
# that built `latitude5520`, a machine that no longer exists — so those recipes
# could not run on any box in the fleet. That included `just quick`, which
# AGENTS.md documented as THE validation gate: it hard-exits 1 when there is no
# flake.nix, so it did not degrade, it failed. `just test` is now the bash suite
# rather than `nixos-rebuild test`, which also retires a genuine footgun — the two
# meanings of "test" were one typo apart.

# On Windows there is no POSIX `sh` on PATH, so just can't run backtick
# assignments or bash recipe bodies. Point it at Git Bash. Ignored on
# Linux/macOS, which use the default `sh`. If Git is installed elsewhere, either
# fix this path or skip just entirely and run the PS bootstrap:
#   provision\windows.ps1
set windows-shell := ['C:/Program Files/Git/bin/bash.exe', '-cu']

# Default recipe — show help.
#
# GENERATED from the recipes themselves, never hand-maintained. This used to be a
# hardcoded block of @echo lines that had to be updated by hand whenever a recipe
# landed; it drifted until 24 of 41 recipes were undocumented. Every recipe now
# carries [group('…')] + [doc('…')] attributes, so `just --list` IS the help and
# cannot fall behind.
#
# Adding a recipe: give it both attributes. provision/tests/justfile.test.sh
# fails the build if either is missing.
[private]
default:
    @just --list --list-heading $'🚀 Fleet Management — `just <recipe>`\n' --list-prefix '  '

repo_dir := justfile_directory()

# ── dev ───────────────────────────────────────────────────────────────────────

# The bash test suite — the repo's ONLY gate since the Nix one was deleted.
#
# `just test` used to be `nixos-rebuild test`, so the suite had no recipe at all
# and AGENTS.md had to warn readers that the obvious name did something else
# entirely. Both problems close here.
#
# Runs every suite in the repo. Keep the glob rather than a hand-listed set: a
# new *.test.sh must be picked up without editing this recipe, or coverage
# silently stops growing.
[group('dev')]
[doc('Run the bash test suite (the repo validation gate)')]
test:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{repo_dir}}
    fail=0; ran=0
    for t in provision/tests/*.test.sh provision/*.test.sh \
             agents/tests/*.test.sh scripts/*.test.sh; do
      [ -f "$t" ] || continue
      ran=$((ran + 1))
      printf '\n\033[1m== %s\033[0m\n' "$t"
      bash "$t" || { fail=$((fail + 1)); printf '\033[31mFAILED: %s\033[0m\n' "$t"; }
    done
    printf '\n────────────────────────────\n'
    if [ "$fail" = 0 ]; then
      printf '\033[32m✅ all %s suites passed\033[0m\n' "$ran"
    else
      printf '\033[31m❌ %s of %s suites failed\033[0m\n' "$fail" "$ran"
    fi
    exit "$fail"

# ── fleet ─────────────────────────────────────────────────────────────────────

# Fleet front door: detect this machine and show its provisioning plan.
# Pass extra args through, e.g. `just provision --machine hub` or `--apply`.
# Relative path (not {{repo_dir}}): just runs recipes with cwd = justfile dir,
# and on Windows the absolute path is a backslash path bash mangles
# (C:Users… → not found) — same reason agent-bootstrap stays relative.
[group('fleet')]
[doc('Fleet front door — plan or apply roles for a machine')]
provision *ARGS:
    bash provision/provision.sh {{ARGS}}

# <machine> is a darwin member of fleet.json (e.g. `air`) — an argument rather
# than detected, because stage 1 is what SETS the hostname. One sudo prompt up
# front, then: hostname, Homebrew, tailnet, toolchain, roles.
# Pre-auth key: `--authkey-file provision/secrets/authkey` (gitignored) or
# $HEADSCALE_AUTHKEY. Preview with `--dry-run`.
[group('fleet')]
[doc('Provision THIS Mac as a fleet member, end to end')]
provision-mac machine *ARGS:
    bash provision/provision-mac.sh {{machine}} {{ARGS}}

# Half-provision THIS WSL distro as a self-declaring, ephemeral fleet host.
# <nickname> = tailnet node name (also its fleet.local.json nickname). Run from
# inside the distro.
[group('provision')]
[doc('Provision THIS WSL distro as a self-declared fleet host (add --no-tailscale for a second distro)')]
provision-wsl nickname *args:
    bash provision/provision-wsl.sh {{nickname}} {{args}}

# ── agents ────────────────────────────────────────────────────────────────────

# Bootstrap personal agent config (~/.claude + Orca-managed account profiles).
# Relative path (not {{repo_dir}}) for the Windows reason above. No-just
# fallbacks: `bash agents/bootstrap.sh`, or on Windows provision\windows.ps1.
[group('fleet')]
[doc('Link personal agent config (~/.claude + Orca profiles)')]
agent-bootstrap:
    @echo "🔗 Bootstrapping agent config (personal ~/.claude)..."
    @env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh

# Bootstrap a secondary profile ~/.claude-<postfix> (e.g. `just agent-bootstrap-profile pure`).
# Links the shared set + settings.<postfix>.json; machine-local settings.local.json untouched.
[group('fleet')]
[doc('Link a secondary agent profile ~/.claude-<postfix>')]
agent-bootstrap-profile postfix:
    @echo "🔗 Bootstrapping agent config (~/.claude-{{postfix}})..."
    @CLAUDE_CONFIG_DIR="$HOME/.claude-{{postfix}}" bash agents/bootstrap.sh

# Mirror ~/.claude into every Orca-managed account profile
# (~/.local/share/orca/claude-accounts/<uuid>/auth). Once per Orca auth;
# idempotent, and `just agent-bootstrap` already runs it at the end of a personal
# run. Pass a dir to target one account, `--dry-run` to preview.
[group('fleet')]
[doc('Mirror the base Claude profile into Orca-managed account profiles')]
agent-sync-orca *args:
    @echo "🔗 Syncing base Claude profile into Orca-managed profiles..."
    @bash agents/orca-profile-sync.sh {{args}}

# Move an Orca account profile into ~/.claude-profiles/<name> and leave a symlink
# in Orca's tree, so transcripts and sessions outlive the account dir. Once per
# account, with Orca CLOSED — it refuses to relocate a profile with a live session.
# `--status` shows every pairing; `--relink` re-heals a link Orca replaced.
[group('fleet')]
[doc('Move an Orca account profile into $HOME and link it back')]
agent-link-orca *args:
    @bash agents/orca-profile-link.sh {{args}}

# Copy Orca's live account profiles OUT to ~/.claude-profiles/<name> so their
# transcripts and sessions survive Orca dropping the account dir. One-way rsync,
# archive semantics (no deletions propagate), regenerable trees excluded. Runs at
# the end of every agent-bootstrap; `--restore <name>` copies a snapshot back.
[group('fleet')]
[doc('Harvest Orca account profiles out to $HOME (backup)')]
agent-harvest-orca *args:
    @bash agents/orca-profile-harvest.sh {{args}}

# Force the machine-local `gortex install --no-claude-md` wiring: per-profile
# skills/agents/hooks + user MCP config. bootstrap.sh does this on its own now —
# the recipe exists for the REWIRE case, which is what you want after
# `just update-gortex` bumps the binary. (It used to be the NixOS escape hatch,
# since home-manager activation skipped the wiring to stay fast; that skip is
# inert with no Nix host left.)
[group('fleet')]
[doc('Force a gortex rewire (skills/agents/hooks + MCP) — run after a version bump')]
gortex-setup:
    @echo "🧠 Rewiring gortex (machine-local skills/agents/hooks + MCP)..."
    @GORTEX_REWIRE=1 env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh

# ── update ────────────────────────────────────────────────────────────────────

# Bump provision/gortex.version to the latest upstream release. Every box installs
# the version this pins via tier_gortex, and a change to the pin is a reprovision
# trigger in scripts/converge.sh — so commit + push the bump and convergence
# carries it to the fleet.
[group('update')]
[doc('Bump the pinned gortex release')]
update-gortex:
    @echo "📦 Checking for new gortex release..."
    bash {{repo_dir}}/scripts/update-gortex.sh

# ── info ──────────────────────────────────────────────────────────────────────

[group('info')]
[doc('Show system status')]
status:
    @echo "📊 System Status"
    @echo "=================="
    @echo "Hostname: $(hostname)"
    @echo "Kernel:   $(uname -s) $(uname -r)"
    @echo "Uptime:   $(uptime)"
    @echo ""
    @echo "💾 Memory:"
    @free -h 2>/dev/null || vm_stat 2>/dev/null | head -5
    @echo ""
    @echo "💿 Disk:"
    @df -h / 2>/dev/null
    @echo ""
    @echo "🔋 Battery:"
    @if command -v acpi >/dev/null 2>&1; then acpi; \
     elif command -v pmset >/dev/null 2>&1; then pmset -g batt; \
     else echo "not available"; fi

[group('info')]
[doc('Show hardware information')]
hardware:
    @echo "🖥️ Hardware Information"
    @echo "======================="
    @lscpu 2>/dev/null | grep -E "Model name|Architecture|CPU\(s\):|Thread|Core" \
      || sysctl -n machdep.cpu.brand_string 2>/dev/null
    @echo ""
    @echo "Storage:"
    @lsblk -f 2>/dev/null || diskutil list 2>/dev/null | head -20

# Quick health check: failed units, disk pressure. Its Nix-store verification
# went with the flake — there is no store to verify.
[group('info')]
[doc('Quick system health check')]
health:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "🏥 System Health Check"
    echo "======================"
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl --failed --quiet 2>/dev/null; then
        echo "❌ failed systemd units:"; systemctl --failed --no-pager
      else
        echo "✅ no failed systemd units"
      fi
      echo "--- timers due next ---"
      systemctl list-timers --no-pager --no-legend 2>/dev/null | head -5
    else
      echo "⏭  no systemd on this box"
    fi
    use="$(df / | awk 'NR==2 {print $5}' | tr -d '%')"
    if [ "${use:-0}" -gt 90 ]; then echo "⚠️  / is ${use}% full"; else echo "✅ / at ${use}%"; fi

[group('info')]
[doc('System logs from the last hour')]
logs:
    @journalctl --system --since "1 hour ago" --no-pager 2>/dev/null \
      || log show --last 1h 2>/dev/null | tail -50

[group('info')]
[doc('Live resource monitor (htop)')]
monitor:
    @htop 2>/dev/null || top
