# provision/lib/tiers.sh — the provisioning tiers (source me; do not execute).
# Bodies moved verbatim out of provision/linux.sh; that script is now the driver
# that resolves a profile (fleet.json "profile") and picks a tier list.
# The profile → tier-list table that selects among these lives in the driver.
# Consumers: provision/linux.sh. Requires the driver's helpers (info/ok/warn/die/
# have) and globals (REPO, SUDO, PRIV, WARNINGS, APT_UPDATED) to be set BEFORE
# sourcing.
#
# Testable: this file only DEFINES functions, so `TIERS_LIB_ONLY=1 source` (or a
# plain source) loads them without running any tier.
# shellcheck shell=bash

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
  $SUDO apt-get install -y --no-install-recommends \
    build-essential pkg-config \
    python3-venv python3-pip \
    ripgrep fd-find fzf \
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

# ── CORE 2: agent config (Claude + Codex) — the crown jewels ──────────────────
# agents/bootstrap.sh symlinks the version-controlled config into ~/.claude and
# ~/.codex. It only needs git + python3 (both installed above) and has no
# Nix-only assumptions, so it works verbatim here. env -u CLAUDE_CONFIG_DIR
# forces the personal profile (mirrors `just agent-bootstrap`).
tier_agents_config() {
  info "Linking synced agent config (Claude + Codex)…"
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
# Version is read from pkgs/gortex.nix so the disposable box stays pinned to the
# same release as the Nix fleet.
tier_gortex() {
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
      codex)
        if have codex; then
          ok "codex already installed"
        else
          info "Installing Codex…"
          CODEX_NON_INTERACTIVE=1 curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null 2>&1 \
            && ok "codex installed" \
            || warn "codex install failed — retry: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
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

# ── BEST-EFFORT: inbound fleet SSH trust (ssh-server role) ────────────────────
# Merge provision/fleet-authorized-keys into ~/.ssh/authorized_keys so this box
# accepts inbound fleet logins (mirrors ssh-server.nix keyFiles / windows.ps1
# step 7 / ssh-wsl.sh step 4). Snapshot copy — re-run after a new member joins.
# Idempotent by key body. sshd itself is configured by ssh-wsl.sh (key-only);
# here we only ensure the authorized_keys trust so a bare linux.sh re-run keeps it.
tier_ssh_trust() {
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
}
