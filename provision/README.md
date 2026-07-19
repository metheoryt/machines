# Non-Nix Linux / WSL provisioning (persisted or disposable)

Provision a **fresh, non-Nix Linux box** — any glibc apt Linux, persisted or
disposable — into this fleet's *portable* dev layer. It works the same whether
you're provisioning a throwaway WSL2 distro (ephemeral, `wsl --unregister` to
reset) or a long-lived daily driver: the **same git-synced Claude/Codex config**
the NixOS laptops run (via `agents/bootstrap.sh`, which produces identical
symlinks on any OS) plus the core CLI tools — installed imperatively with `apt`
+ official installers instead of `nixos-rebuild`.

It's deliberately *not* a reproduction of the full fleet: no declarative
guarantees, no `development.nix` toolchain, no `me.nix` desktop shell. That's the
trade for zero Nix and a box you can `wsl --unregister` and re-provision in
minutes, or keep running indefinitely.

## What it installs

- **CORE** (script aborts if these fail): apt base (`git`, `curl`, `python3`,
  `build-essential`, `ripgrep`, `fd`, `fzf`, `jq`); the synced agent config via
  `agents/bootstrap.sh`; `git config --global` identity + aliases.
- **Best-effort** (warn + continue): `gortex` (pinned to the version in
  `pkgs/gortex.nix`), `claude` + `codex` (native installers, no Node.js),
  `gh` (from GitHub's official apt repo — not in Ubuntu's default repos),
  `starship`, `direnv`, `fish`, `uv`, `git-delta`, `bat`. Shell hooks are
  appended to `~/.bashrc` (and a minimal `~/.config/fish/config.fish` if fish
  installed). Per-box SSH keys + `~/.ssh/config` + per-account commit identity
  for the declared GitHub accounts (see **Multi-account SSH** below).
  `git-autofetch` (fetch-only refresh of every repo under `$HOME`, mirroring
  `modules/system/git-autofetch` on the Nix fleet) — scheduled via a systemd
  *user* timer, or cron where systemd is off.

It deliberately does **not** reproduce the full `modules/home/me.nix` shell
experience or `development.nix` toolchain (docker, language servers, ghostty,
GNOME) — imperatively re-creating those would just re-introduce the config drift
a disposable box is meant to avoid.

## Usage

```bash
git clone https://github.com/<you>/machines ~/machines
bash ~/machines/provision/linux.sh
```

Then open a new shell (or `source ~/.bashrc`) and authenticate: `claude`, `codex`.

It's idempotent — re-run any time (e.g. after `git pull`) to pick up changes.

> **Not `just provision`.** The `provision.sh` dispatcher is manifest-driven off
> `fleet.json`, which declares no WSL machine — and it carries role executors only
> for `agents`, `dotfiles`, `repos`, and `mesh-*`. There is no `base` executor, so
> even with a manifest entry it would skip the apt base, `gortex`, `claude`/`codex`,
> the SSH keys, and `git-autofetch`. `linux.sh` is what installs those. Use it.

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

### Commit identity (author name/email)

The SSH key decides *which account receives a push*; the commit's author
name/email is separate. The script also wires per-account **commit identity** so
the two never drift — via the `GIT_IDENTITIES` array next to `SSH_ACCOUNTS`
(`ssh-alias|author-name|author-email`):

```bash
GIT_IDENTITIES=(
  "github-cyphy|cyphy671|259445360+cyphy671@users.noreply.github.com"
)
```

It keys off the **remote URL**, not a directory: git's
`includeIf "hasconfig:remote.*.url:git@<alias>:*/**"` applies the identity to any
repo whose remote uses that account's SSH alias, wherever it sits on disk. So a
repo cloned as `git@github-cyphy:cyphy671/qaz-law.git` authors commits as
`cyphy671`, while everything else keeps the global `metheoryt@gmail.com`. No
fixed clone directory, nothing to remember per repo. (Needs git ≥ 2.36; the
default `github.com` account is the global identity, so list only the *others*.)

Emails use GitHub's private **noreply** form
(`<numeric-id>+<user>@users.noreply.github.com`) so a real address is never
leaked into a corpus repo's history and pushes are never rejected by the
account's "keep my email address private" setting. The identity files land at
`~/.config/git/identity-<alias>`.

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

## Orca headless server (WSL)

Serve one Orca runtime per WSL2 distro, each a distinct Headscale tailnet node,
so the Orca desktop/mobile client drives repos that live natively on the distro's
Linux filesystem (not across the slow `\\wsl.localhost` 9P boundary). Design:
`docs/superpowers/specs/2026-07-15-orca-serve-wsl-design.md`.

Run **both scripts inside each distro**, in order:

    # 1. Join the fleet tailnet as this distro's own node (needs systemd + sudo).
    #    Easiest — self-service: mint a key over SSH to the control server and
    #    enroll in one shot (needs your SSH access to the VPS):
    bash ~/machines/provision/tailscale-wsl.sh --enroll   # prompts hostname on a TTY
    #    …or supply the key yourself (precedence high→low):
    export HEADSCALE_AUTHKEY='<reusable pre-auth key, headscale user fleet>'
    bash ~/machines/provision/tailscale-wsl.sh            # → wsl-<distro> @ 100.64.x.y
    bash ~/machines/provision/tailscale-wsl.sh --authkey-file provision/secrets/authkey
    bash ~/machines/provision/tailscale-wsl.sh            # reuse /etc/headscale/authkey
    #    Automation can name the node non-interactively:
    bash ~/machines/provision/tailscale-wsl.sh --enroll --hostname devbox

    # 2. Install Orca + autostart `orca serve` on :6768 (systemd-user + linger; also needs sudo)
    bash ~/machines/provision/orca-serve.sh

    # 3. Fleet SSH: key-only sshd + persisted fleet key + client config (needs sudo)
    bash ~/machines/provision/ssh-wsl.sh

Then read the pairing URL and add it on the client:

    journalctl --user -u orca-serve -f                  # prints orca://pair?… (SECRET)
    # on the Windows/mobile client:
    orca environment add --name <distro> --pairing-code '<orca://pair?…>'

Notes:

- **Per-distro identity.** Each distro runs its own `tailscaled` and gets a
  distinct `100.64.x.y` + MagicDNS name (`wsl-<distro>.gg.ez`), so every
  Orca server uses the default port `6768`. No `.wslconfig` mirrored networking,
  no `netsh portproxy` — inbound rides the VPS DERP relay through WSL's NAT.
- **Hostname** defaults to `wsl-<sanitized $WSL_DISTRO_NAME>`; override with
  `ORCA_TS_HOSTNAME`.
- **Self-service enrollment.** `--enroll` SSHes to the control server
  (`$HEADSCALE_SSH`, default `debian@cyphy.kz`) and mints a reusable, expiring
  pre-auth key (`$HEADSCALE_KEY_EXPIRY`, default `2160h`/90d; `$HEADSCALE_USER_ID`,
  default `1`) with `sudo headscale preauthkeys create` — no hand-pasted key.
  Needs the SSH user to have **passwordless sudo** on the control server (the
  headscale socket is group-restricted). Opt-in: without `--enroll` nothing
  SSHes. Re-running `--enroll` is a rotation, not a no-op: it mints a **fresh
  remote key each run** (older reusable keys linger on the control server until
  their expiry) and overwrites the persisted one. On an already-up node it
  rotates the key without re-running `tailscale up`, so a changed `--hostname`
  only takes effect on the next fresh enroll (e.g. after a rebuild), not
  immediately. Hostname precedence: `--hostname` → `$ORCA_TS_HOSTNAME` →
  interactive prompt (TTY only) → `wsl-<distro>`.
- **Zero-touch re-enroll.** `tailscale-wsl.sh` persists the resolved pre-auth
  key to `/etc/headscale/authkey` (`root:root 0600`) and installs a systemd
  *system* oneshot `tailscale-autoconnect.service`. At every boot it runs
  `tailscale status || tailscale up`, so a normal reboot (state persists in
  `/var/lib/tailscale`) is a no-op while a rebuilt/logged-out distro rejoins the
  tailnet hands-free — no re-pasted key. Key precedence for the *first* run:
  `--authkey-file <path>` → `$HEADSCALE_AUTHKEY` → the persisted key. Stash a key
  locally under the gitignored `provision/secrets/` for `--authkey-file`.
  Tradeoff: a reusable key sits root-readable on disk — use an *expiring* key and
  rotate it in Headscale.
- **Version** defaults to `latest`; pin with `ORCA_VERSION`.
- **Secrets** (`HEADSCALE_AUTHKEY`, the pairing URL) are never committed.
- Rebuilding a distro (`wsl --unregister`) leaves a stale Headscale node — prune
  with `headscale nodes delete` on the VPS.

## Fleet SSH (WSL)

Give a WSL2 distro a fleet SSH identity — its own key-only sshd, a persisted
ed25519 key trusted by the other boxes, and a merged `~/.ssh/config` so
`ssh latitude` / `ssh server` / `ssh hub` work from inside the distro. The
distro is a **leaf**: it reaches out to the fleet and is trusted by it, but is
**not** a `fleet.json` member (its OS hostname `g614jv` collides with the
`desktop` host, and the box is disposable). Design:
`docs/superpowers/specs/2026-07-17-ssh-wsl-fleet-design.md`.

Run **inside the distro, after `tailscale-wsl.sh`**:

    bash ~/machines/provision/ssh-wsl.sh

It:

- installs `openssh-server` and drops a key-only policy
  (`/etc/ssh/sshd_config.d/10-fleet.conf`: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`) — no lockout risk, the `wsl -d <distro>`
  console is always available;
- creates `~/.ssh/id_fleet` (ed25519) and **persists it on the Windows host**
  (`$FLEET_KEY_DIR`, default `/mnt/c/Users/<winuser>/.fleet`), restoring it on
  the next provision — so a `wsl --unregister` rebuild reuses the same key and
  its trust entry never goes stale. The store is **host-scoped**, so *every WSL
  distro on the same Windows host shares one key* — a per-host fleet identity,
  named after the host (`me@wsl-<host>`, mapping `uname -n` to the matching
  `fleet.json` member, e.g. `g614jv` → `me@wsl-desktop`), not after the distro;
- appends `id_fleet.pub` to `provision/fleet-authorized-keys` (if not already
  there). **Operator step:** commit + push, then re-provision the other boxes
  (`nixos-rebuild switch` / `windows.ps1`) so they trust the key;
- merges a marked fleet block into `~/.ssh/config`
  (`# >>> fleet-ssh (managed by ssh-wsl.sh) >>>` … `# <<< fleet-ssh <<<`),
  replacing only that block on re-run and leaving the rest (linux.sh's GitHub
  aliases) untouched.

Env: `FLEET_KEY_DIR` (persistence store), `FLEET_WIN_USER` (Windows user for the
default store path), `MACHINES_REPO` (repo clone; default `~/machines`).

Pruning: a rebuilt distro whose Windows key store was also wiped mints a *new*
key and appends a *new* line to `fleet-authorized-keys`. Persistence prevents
re-appends for the same distro+store, but a genuinely fresh leaf leaves the old
entry behind — delete the stale `me@<distro>-wsl` line from
`provision/fleet-authorized-keys` when retiring a leaf (mirrors pruning a stale
Headscale node on the VPS, above).

Tradeoff: the persisted private key lives on `/mnt/c` (drvfs), where unix `0600`
is not enforced — it is protected by Windows ACLs on `C:\Users\<winuser>`, not
unix perms. Weigh that against what the key unlocks: `fleet-authorized-keys` feeds
both NixOS `authorizedKeys.keyFiles` *and* Windows
`administrators_authorized_keys`, so `id_fleet` grants **administrator** SSH into
the fleet boxes. The fleet trusting the leaf is the point — just know the blast
radius if `C:\Users\<winuser>\.fleet` is ever read.
