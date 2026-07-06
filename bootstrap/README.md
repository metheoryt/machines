# Disposable-distro bootstrap

Provision a **fresh, non-Nix Linux box** — most often a throwaway WSL2 distro —
into this fleet's *portable* dev layer, without NixOS. It's the low-maintenance
way to get a Linux dev environment on a Windows machine: the **same git-synced
Claude/Codex config** the NixOS laptops run (via `agents/bootstrap.sh`, which
produces identical symlinks on any OS) plus the core CLI tools — installed
imperatively with `apt` + official installers instead of `nixos-rebuild`.

It's deliberately *not* a reproduction of the full fleet: no declarative
guarantees, no `development.nix` toolchain, no `me.nix` desktop shell. That's the
trade for zero Nix and a box you can `wsl --unregister` and re-provision in
minutes.

## What it installs

- **CORE** (script aborts if these fail): apt base (`git`, `curl`, `python3`,
  `build-essential`, `ripgrep`, `fd`, `fzf`, `jq`); the synced agent config via
  `agents/bootstrap.sh`; `git config --global` identity + aliases.
- **Best-effort** (warn + continue): `gortex` (pinned to the version in
  `pkgs/gortex.nix`), `claude` + `codex` (native installers, no Node.js),
  `gh` (from GitHub's official apt repo — not in Ubuntu's default repos),
  `starship`, `direnv`, `fish`, `uv`, `git-delta`, `bat`. Shell hooks are
  appended to `~/.bashrc` (and a minimal `~/.config/fish/config.fish` if fish
  installed). Per-box SSH keys + `~/.ssh/config` for the declared GitHub accounts
  (see **Multi-account SSH** below).

It deliberately does **not** reproduce the full `modules/home/me.nix` shell
experience or `development.nix` toolchain (docker, language servers, ghostty,
GNOME) — imperatively re-creating those would just re-introduce the config drift
a disposable box is meant to avoid.

## Usage

Inside a fresh Ubuntu/Debian WSL distro:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/machines ~/nix
bash ~/nix/bootstrap/ubuntu.sh
```

Then open a new shell (or `source ~/.bashrc`) and authenticate: `claude`, `codex`.

It's idempotent — re-run any time (e.g. after `git pull`) to pick up changes.
Meant to be **exercised, not trusted**: smoke-test in a throwaway distro
(`wsl --unregister <name>` to reset).

## Multi-account SSH

The script generates a per-box ed25519 key per declared GitHub account and writes
a managed block in `~/.ssh/config`, so each remote uses the right key
independently of which account `gh` is currently switched to. The accounts live
in the `SSH_ACCOUNTS` array near the top of that section (`host-alias:github-user`):

```bash
SSH_ACCOUNTS=(
  "github.com:metheoryt"    # personal — the default host
  "github-cyphy:cyphy671"   # isolated personal account (e.g. qaz-law)
)
```

The **first** entry owns the default `github.com` host; the rest get their alias.
Clone accordingly:

```bash
git clone git@github.com:metheoryt/repo.git        # personal (default key)
git clone git@github-cyphy:cyphy671/qaz-law.git    # isolated account (its own key)
```

Keys land at `~/.ssh/id_<user>` and must be **registered on the matching account**
(the script can't — uploading needs an interactive scope grant). Easiest path, per
account:

```bash
gh auth login          # GitHub.com → SSH → "select existing key" → ~/.ssh/id_<user>.pub
```

(the login flow carries the `admin:public_key` scope, so it uploads without a
separate `gh auth refresh`). Or paste `~/.ssh/id_<user>.pub` at
`github.com/settings/keys`. The script prints a reminder for any key it just
generated. `gh` itself stays logged into every account; `gh auth switch --user
<name>` picks which one `gh pr`/`gh issue` act as.

> Isolation rationale: `cyphy671` is a separate personal account used to keep
> certain repos (e.g. a large corpus like `qaz-law`) off the main account, to
> limit blast radius. Separate key + separate remote = the two never cross.

## Choosing a base distro

Targets **glibc apt** distros. Recommended:

- **Debian** — leanest; smallest footprint for a disposable box.
- **Ubuntu** — most WSL-tested; smoothest interop. Good default.

Avoid:

- **Alpine / musl** — the prebuilt `gortex` binary (patchelf'd for glibc in the
  Nix fleet) and the native `claude`/`codex` CLIs are glibc builds; they won't
  run under musl.
- **Arch (ArchWSL)** — works (glibc), but rolling; you'd swap the `apt` blocks
  for `pacman`. Not wired up here.

Only `x86_64` is supported (gortex ships `linux_amd64` only).

## Getting a fresh WSL distro

```powershell
wsl --install -d Ubuntu          # or: -d Debian
wsl --list --online              # see available distros
wsl --unregister <name>          # nuke a disposable distro back to zero
```
