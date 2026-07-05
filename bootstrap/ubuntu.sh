#!/usr/bin/env bash
# bootstrap/ubuntu.sh — provision a fresh Debian/Ubuntu box (especially a
# disposable WSL2 distro) into the fleet's PORTABLE dev layer:
#   • the git-synced Claude Code / Codex agent config (via agents/bootstrap.sh)
#   • the core CLI dev tools (gortex, claude, codex, ripgrep/fd/fzf, …)
#
# This is the "disposable distro" counterpart to the NixOS-WSL host
# (hosts/wsl/): imperative and apt-based, deliberately NOT a full reproduction
# of the Nix fleet. It installs a CORE tier (must succeed — the script aborts if
# these fail) and a BEST-EFFORT tier (nice-to-have; it warns and continues).
# If you want full, drift-free fleet parity, use the NixOS-WSL host instead —
# that's the whole point of the two-track design.
#
# Targets glibc apt distros: Debian 11+ / Ubuntu 22.04+. NOT Alpine/musl — the
# prebuilt gortex binary and the native claude/codex CLIs are glibc builds.
#
# Idempotent; safe to re-run. Usage inside a fresh Ubuntu/Debian WSL:
#   sudo apt-get update && sudo apt-get install -y git
#   git clone <this-repo> ~/nix
#   bash ~/nix/bootstrap/ubuntu.sh
#
# See bootstrap/README.md for base-distro guidance and post-install steps.
set -u

# ── Pretty output ─────────────────────────────────────────────────────────────
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
WARNINGS=0

# ── Locate the repo (this script lives in <repo>/bootstrap/) ──────────────────
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/agents/bootstrap.sh" ] || die "can't find agents/bootstrap.sh under $REPO — run this from inside the machines repo"

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "this script targets Debian/Ubuntu (apt-get not found). See bootstrap/README.md for other bases."
case "$(uname -m)" in
  x86_64 | amd64) : ;;
  *) die "gortex ships x86_64-linux only; this box is $(uname -m). See bootstrap/README.md." ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  have sudo || die "not root and sudo not found — install sudo or run as root"
  SUDO="sudo"
fi

mkdir -p "$HOME/.local/bin"

printf '\n\033[1mProvisioning %s from %s\033[0m\n\n' "$(uname -n)" "$REPO"

# ── CORE 1: base apt packages ─────────────────────────────────────────────────
info "Installing base packages (apt)…"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq || die "apt-get update failed"
# All of these are in Debian main / Ubuntu universe. Kept intentionally lean —
# extras (bat, fish, direnv, delta) are best-effort below.
$SUDO apt-get install -y --no-install-recommends \
  git curl wget ca-certificates xz-utils unzip \
  build-essential pkg-config \
  python3 python3-venv python3-pip \
  ripgrep fd-find fzf jq \
  || die "apt base install failed"
ok "base packages installed"

# fd-find installs the binary as `fdfind` on Debian/Ubuntu — add the friendly name.
have fdfind && ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"

# ── CORE 2: agent config (Claude + Codex) — the crown jewels ──────────────────
# agents/bootstrap.sh symlinks the version-controlled config into ~/.claude and
# ~/.codex. It only needs git + python3 (both installed above) and has no
# Nix-only assumptions, so it works verbatim here. env -u CLAUDE_CONFIG_DIR
# forces the personal profile (mirrors `just agent-bootstrap`).
info "Linking synced agent config (Claude + Codex)…"
env -u CLAUDE_CONFIG_DIR bash "$REPO/agents/bootstrap.sh" || die "agents/bootstrap.sh failed"
ok "agent config linked"

# ── CORE 3: git identity + basics (cheap, high-value; mirrors modules/home/me.nix) ──
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

# ── BEST-EFFORT: gortex code-intelligence daemon binary ───────────────────────
# Version is read from pkgs/gortex.nix so the disposable box stays pinned to the
# same release as the Nix fleet.
info "Installing gortex…"
GVER="$(grep -oE 'version = "[0-9]+\.[0-9]+\.[0-9]+"' "$REPO/pkgs/gortex.nix" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -z "$GVER" ]; then
  warn "couldn't parse gortex version from pkgs/gortex.nix — skipping gortex"
elif curl -fsSL "https://github.com/zzet/gortex/releases/download/v${GVER}/gortex_linux_amd64.tar.gz" \
       | tar -xz -C "$HOME/.local/bin" gortex 2>/dev/null; then
  chmod +x "$HOME/.local/bin/gortex"
  ok "gortex ${GVER} → ~/.local/bin/gortex"
else
  warn "gortex download failed (v${GVER}) — install later or check the release URL"
fi

# ── BEST-EFFORT: Claude Code + Codex CLIs (native installers, no Node needed) ──
if have claude; then
  ok "claude already installed"
else
  info "Installing Claude Code…"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 \
    && ok "claude installed" \
    || warn "claude install failed — retry: curl -fsSL https://claude.ai/install.sh | bash"
fi
if have codex; then
  ok "codex already installed"
else
  info "Installing Codex…"
  CODEX_NON_INTERACTIVE=1 curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null 2>&1 \
    && ok "codex installed" \
    || warn "codex install failed — retry: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
fi

# ── BEST-EFFORT: shell niceties ───────────────────────────────────────────────
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
# gh credential helper (only if gh is present — not installed by default here).
have gh && git config --global credential."https://github.com".helper '!gh auth git-credential'

# ── BEST-EFFORT: shell init (WSL-safe — no chsh) ──────────────────────────────
# Append PATH + starship/direnv hooks to ~/.bashrc, guarded so re-runs don't
# duplicate. We do NOT chsh (unreliable in WSL); to live in fish, add the exec
# line suggested at the end.
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

# Minimal fish config (only if fish installed) — deliberately lean, not a copy
# of modules/home/me.nix's full fish setup.
if have fish; then
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

Not installed by design (use the NixOS-WSL host for full parity): the declarative
dev toolchain (docker, language servers, the full fish/ghostty/GNOME setup).
EOF

exit 0
