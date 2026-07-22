#!/usr/bin/env bash
# provision/linux.sh — provision a fresh Debian/Ubuntu box (especially a
# disposable WSL2 distro) into the fleet's PORTABLE dev layer:
#   • the git-synced Claude Code / Codex agent config (via agents/bootstrap.sh)
#   • the core CLI dev tools (gortex, claude, codex, ripgrep/fd/fzf, …)
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

# ── Locate the repo (this script lives in <repo>/provision/) ──────────────────
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/agents/bootstrap.sh" ] || die "can't find agents/bootstrap.sh under $REPO — run this from inside the machines repo"

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

printf '\n\033[1mProvisioning %s from %s\033[0m\n\n' "$(uname -n)" "$REPO"

# ── CORE 1: base apt packages ─────────────────────────────────────────────────
# Requires root. When none is reachable non-interactively (PRIV=0, e.g. a
# converge run on a box whose user needs an interactive sudo password), SKIP
# rather than die — this is the "skips what it can't do" contract the post-merge
# hook documents. A first, privileged run (interactive or root) still installs.
if [ "$PRIV" -eq 0 ]; then
  warn "no root available non-interactively — skipping apt base install (assuming a prior privileged run set up the base tier). Re-run with a TTY or as root to (re)install."
else
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
fi

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

# ── BEST-EFFORT: git-autofetch (fetch-only refresh of all repos under $HOME) ──
# Mirrors modules/system/git-autofetch on the Nix fleet: a periodic `git fetch`
# — refs only, NEVER pull/merge/rebase and never touching a work tree — so
# `git status` / the prompt show an accurate "behind by N" without fetching
# first. The actual pull stays deliberate. Installs a small script, then
# schedules it via a systemd *user* timer when this distro runs systemd
# (modern WSL2 default), else a cron entry.
info "Installing git-autofetch…"
AF="$HOME/.local/bin/git-autofetch"
cat > "$AF" <<'AUTOFETCH'
#!/usr/bin/env sh
# git-autofetch — fetch-only refresh of every git repo under $GIT_AUTOFETCH_ROOTS
# (default $HOME) so ahead/behind counts are accurate without fetching first.
# NEVER pulls/merges/rebases; never touches a working tree. Installed by
# provision/linux.sh; mirrors modules/system/git-autofetch on the Nix fleet.
set -u
: "${GIT_AUTOFETCH_ROOTS:=$HOME}"
export GIT_TERMINAL_PROMPT=0                                  # never block on auth
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
for root in $GIT_AUTOFETCH_ROOTS; do
  [ -d "$root" ] || continue
  # -prune stops find descending into a repo's own .git; skip heavy vendored
  # trees. Match .git as dir (normal repo) or file (submodule/linked worktree).
  find "$root" -maxdepth 4 \
    \( -path '*/node_modules' -o -path '*/.cache' -o -name '.direnv' \) -prune -o \
    -name .git -prune -print 2>/dev/null \
  | while IFS= read -r gitentry; do
      repo=$(dirname "$gitentry")
      timeout 60 git -C "$repo" fetch --all --prune --quiet 2>/dev/null \
        || echo "fetch failed/skipped: $repo" >&2
    done
done
AUTOFETCH
chmod +x "$AF"
ok "git-autofetch → ~/.local/bin/git-autofetch"

_scheduled=""
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

# ── BEST-EFFORT: multi-account SSH wiring ─────────────────────────────────────
# Per-box SSH keys + ~/.ssh/config for multiple GitHub accounts, so each remote
# uses the right key regardless of gh's active account. Used here to keep the
# `cyphy671` account (isolated repos, e.g. qaz-law) separate from `metheoryt`.
#
# Declared as "host-alias:github-user". The FIRST entry owns the default
# `github.com` host; the rest get their alias (clone via git@<alias>:owner/repo).
# One ed25519 key per account is generated as ~/.ssh/id_<user>. Edit this list to
# add/remove accounts, or blank it to skip the whole section.
SSH_ACCOUNTS=(
  "github.com:metheoryt"    # personal — default host
  "github-cyphy:cyphy671"   # isolated personal account (qaz-law etc.)
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
      if ssh-keygen -t ed25519 -f "$_key" -C "${_user}@$(uname -n)-wsl" -N "" >/dev/null 2>&1; then
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

# ── BEST-EFFORT: per-account commit identity ──────────────────────────────────
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
  "github-cyphy|cyphy671|259445360+cyphy671@users.noreply.github.com"
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

# ── BEST-EFFORT: fleet self-pull timer (Trigger B) — spec 2026-07-21 ──────────
# ~10-min ff-pull of every fleet-sync repo (provision/fleet-selfpull.sh). The
# pull fires the repo's post-merge hook, which fires convergence — this timer
# NEVER converges itself. systemd-user timer where available (mirrors the
# git-autofetch install above), else a cron fallback. Idempotent.
info "Installing fleet self-pull timer…"
FSP="$REPO/provision/fleet-selfpull.sh"
if [ ! -f "$FSP" ]; then
  warn "provision/fleet-selfpull.sh not found — skipping fleet self-pull timer"
elif systemctl --user show-environment >/dev/null 2>&1; then
  _ud2="$HOME/.config/systemd/user"; mkdir -p "$_ud2"
  cat > "$_ud2/fleet-selfpull.service" <<EOF
[Unit]
Description=Fleet self-pull (ff-only) of all fleet-sync repos

[Service]
Type=oneshot
TimeoutStartSec=8min
ExecStart=/usr/bin/env bash $FSP
EOF
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
  if crontab -l 2>/dev/null | grep -qF "$FSP"; then
    ok "fleet-selfpull cron already present"
  elif { crontab -l 2>/dev/null; printf '*/10 * * * * sleep $((RANDOM %% 120)); /usr/bin/env bash %s >/dev/null 2>&1\n' "$FSP"; } \
         | crontab - >/dev/null 2>&1; then
    ok "fleet-selfpull cron installed"
  else
    warn "could not install fleet-selfpull cron"
  fi
else
  warn "fleet-selfpull installed but not scheduled (no systemd user manager or cron)"
fi

# ── BEST-EFFORT: inbound fleet SSH trust (ssh-server role) ────────────────────
# Merge provision/fleet-authorized-keys into ~/.ssh/authorized_keys so this box
# accepts inbound fleet logins (mirrors ssh-server.nix keyFiles / windows.ps1
# step 7 / ssh-wsl.sh step 4). Snapshot copy — re-run after a new member joins.
# Idempotent by key body. sshd itself is configured by ssh-wsl.sh (key-only);
# here we only ensure the authorized_keys trust so a bare linux.sh re-run keeps it.
info "Ensuring inbound fleet SSH trust…"
MESH_KEYS="$REPO/provision/fleet-authorized-keys"
if [ ! -f "$MESH_KEYS" ]; then
  warn "provision/fleet-authorized-keys not found — skipped inbound fleet trust"
else
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  AUTHK="$HOME/.ssh/authorized_keys"
  tmp_ak="$(mktemp)"
  # keep existing lines; append each fleet key whose body (2nd field) is absent.
  awk '
    function blank(s){ return s ~ /^[[:space:]]*$/ }
    FNR==NR { if (blank($0)) next; print; if ($1 !~ /^#/ && $2 != "") have[$2]=1; next }
    blank($0) || $1 ~ /^#/ { next }
    $2 != "" && !($2 in have) { print; have[$2]=1 }
  ' "$AUTHK" "$MESH_KEYS" 2>/dev/null > "$tmp_ak" || cat "$MESH_KEYS" > "$tmp_ak"
  if [ -f "$AUTHK" ] && cmp -s "$tmp_ak" "$AUTHK"; then
    ok "authorized_keys already trusts the fleet"
  else
    install -m600 "$tmp_ak" "$AUTHK"
    ok "installed fleet keys → $AUTHK (inbound trust)"
  fi
  rm -f "$tmp_ak"
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

Not installed by design (only a NixOS host gets these): the declarative dev
toolchain (docker, language servers, the full fish/ghostty/GNOME setup).
EOF

exit 0
