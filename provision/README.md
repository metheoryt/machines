# Non-Nix provisioning (Linux / WSL / macOS)

> **Two entry points, and neither calls the other.**
>
> | | What it is | Invocation |
> |---|---|---|
> | `provision/linux.sh` · `provision/macos.sh` | **tier drivers** — install the toolchain. Tier bodies are shared in `provision/lib/tiers.sh`; the driver only picks the ordered list for this box's profile. | `bash provision/linux.sh` |
> | `provision/provision.sh` | the **role front door** — reads `fleet.json`, loops `roles[]` into `role_<name>` from `provision/roles/*.sh`. | `bash provision/provision.sh --machine <m> --dry-run\|--apply` |
>
> Run the driver first, the front door second. `provision.sh` takes **flags**, not
> positionals — a bare `provision.sh air` exits 2 with `unknown arg: air`.

Provision a **fresh, non-Nix box** — any glibc apt Linux (persisted or
disposable) or macOS — into this fleet's *portable* dev layer. It works the same whether
you're provisioning a throwaway WSL2 distro (ephemeral, `wsl --unregister` to
reset) or a long-lived daily driver: the **same git-synced Claude Code config**
the NixOS laptops run (via `agents/bootstrap.sh`, which produces identical
symlinks on any OS) plus the core CLI tools — installed imperatively with `apt`
+ official installers instead of `nixos-rebuild`.

It's deliberately *not* a reproduction of the full fleet: no declarative
guarantees, no `development.nix` toolchain, no `me.nix` desktop shell. That's the
trade for zero Nix and a box you can `wsl --unregister` and re-provision in
minutes, or keep running indefinitely.

## What it installs

- **CORE** (script aborts if these fail): apt base (`git`, `curl`, `python3`,
  `build-essential`, `ripgrep`, `fd`, `fzf`, `jq`, `tmux`); the synced agent config via
  `agents/bootstrap.sh`; `git config --global` identity + aliases.
- **Best-effort** (warn + continue): `gortex` (pinned to the version in
  `pkgs/gortex.nix`), `claude` (native installer, no Node.js),
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

Then open a new shell (or `source ~/.bashrc`) and authenticate: `claude`.

It's idempotent — re-run any time (e.g. after `git pull`) to pick up changes.

> **Not `just provision`.** The `provision.sh` dispatcher is manifest-driven off
> `fleet.json`, which declares no WSL machine — and it carries role executors only
> for `agents`, `dotfiles`, `repos`, and `mesh-*`. There is no `base` executor, so
> even with a manifest entry it would skip the apt base, `gortex`, `claude`,
> the SSH keys, and `git-autofetch`. `linux.sh` is what installs those. Use it.

## Multi-account SSH

The script generates a per-box ed25519 key per declared GitHub account and writes
a managed block in `~/.ssh/config`, so each remote uses the right key
independently of which account `gh` is currently switched to. The accounts live
in the `SSH_ACCOUNTS` array near the top of that section (`host-alias:github-user`):

```bash
SSH_ACCOUNTS=(
  "github.com:metheoryt"             # canonical — what every GitHub URL uses
  "metheoryt.github.com:metheoryt"   # readable synonym for the default account
  "cyphy671.github.com:cyphy671"     # isolated account — size/limit blast-radius
)
```

The key path derives from the **user** (`id_<user>`), so several aliases can share
one account's key — that is how `github.com` and `metheoryt.github.com` stay a
single registered key rather than two.

`github.com` is **not optional**: the clone button, `gh repo clone`, READMEs and
submodule URLs all emit `git@github.com`, and without that block those clones fall
back to default key order instead of a pinned identity. The `<user>.github.com`
aliases are self-documenting synonyms — the account is legible in the URL. They are
safe as names because `*.github.com` has no wildcard A record (verified 2026-07-28),
so a missing block fails loudly rather than connecting somewhere unintended.

Clone accordingly — the alias in the URL is what picks the account:

```bash
git clone git@github.com:metheoryt/repo.git              # personal (canonical)
git clone git@metheoryt.github.com:metheoryt/repo.git    # same account, explicit
git clone git@cyphy671.github.com:cyphy671/laws.git      # isolated account
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
  "cyphy671.github.com|cyphy671|259445360+cyphy671@users.noreply.github.com"
)
```

It keys off the **remote URL**, not a directory: git's
`includeIf "hasconfig:remote.*.url:git@<alias>:*/**"` applies the identity to any
repo whose remote uses that account's SSH alias, wherever it sits on disk. So a
repo cloned as `git@cyphy671.github.com:cyphy671/laws.git` authors commits as
`cyphy671`, while everything else keeps the global `metheoryt@gmail.com`. No
fixed clone directory, nothing to remember per repo. (Needs git ≥ 2.36; the
default `github.com` account is the global identity, so list only the *others*.)

Because the match is on the **alias string**, renaming an alias without updating
`GIT_IDENTITIES` in the same commit silently drops the identity: already-cloned
repos keep the old URL, stop matching, and author as the default account with no
error. `provision/tests/ssh-accounts.test.sh` guards the pairing.

Emails use GitHub's private **noreply** form
(`<numeric-id>+<user>@users.noreply.github.com`) so a real address is never
leaked into a corpus repo's history and pushes are never rejected by the
account's "keep my email address private" setting. The identity files land at
`~/.config/git/identity-<alias>`.

> Isolation rationale: `cyphy671` is a separate personal account used to keep
> certain repos (e.g. a large corpus like `qaz-law`) off the main account, to
> limit blast radius. Separate key + separate remote = the two never cross.

## macOS

### One command, fresh Mac (`just provision-mac`)

```bash
git clone https://github.com/<you>/machines ~/machines
cd ~/machines

# the pre-auth key (provision/secrets/ is gitignored)
mkdir -p provision/secrets
printf '%s' '<hskey-…>' > provision/secrets/authkey

just provision-mac air --dry-run                              # preview, touches nothing
just provision-mac air --authkey-file provision/secrets/authkey
```

Nothing else is required first — not even Homebrew. One sudo prompt up front,
then four stages:

| # | Stage | Does |
|---|---|---|
| 1 | `macos-prep.sh` | `scutil` hostname · Homebrew bootstrap · Remote Login |
| 2 | `tailscale-mac.sh` | standalone cask · join Headscale · verify IP vs `fleet.json` |
| 3 | `macos.sh` | the tier list (toolchain, agent config, gortex, fleet SSH, launchd) |
| 4 | `provision.sh --apply` | roles: `agents`, `dotfiles`, `repos` |

The machine name is an **argument, not detected** — stage 1 is what sets the
hostname, so detection cannot work before it runs. It is validated against
`fleet.json` (must exist, must be `platform: darwin`) before anything mutates,
so a typo fails fast instead of renaming your Mac.

**Mint the key on hub:**

```bash
ssh hub 'sudo headscale preauthkeys create --user 1 --expiration 2h'
```

There is deliberately **no `--authkey` flag** — argv is world-readable through
`ps`, so an inline key is scrapeable by any local process while the run lasts.
Use the file or `HEADSCALE_AUTHKEY`. (`tailscale-wsl.sh` omits it for the same
reason.)

**Two things stay manual afterwards**, both printed by the chain when it
finishes: `gh auth login` to register the SSH keys (`tier_ssh_accounts` writes
`IdentitiesOnly` on fresh keys, so git-over-SSH fails until you do), and
appending `~/.ssh/id_fleet.pub` to `provision/fleet-authorized-keys` so other
members accept this box.

Each stage is independently re-runnable when only one thing needs redoing:

```bash
bash provision/macos-prep.sh air
bash provision/tailscale-mac.sh --hostname air --authkey-file provision/secrets/authkey
bash provision/macos.sh
bash provision/provision.sh --machine air --apply
```

### The tier driver alone (`provision/macos.sh`)

`provision/macos.sh` is the Darwin sibling of `linux.sh` — same driver shape,
**same tier library** (`provision/lib/tiers.sh`), different package manager.
Both Apple Silicon and Intel work. Use it directly when the Mac is already
enrolled and you only want the toolchain refreshed:

```bash
MACHINES_TIERS_DRY_RUN=1 bash ~/machines/provision/macos.sh   # inspect the plan
bash ~/machines/provision/macos.sh                            # apply
```

Then open a new shell (or `source ~/.zshrc`) and authenticate: `claude`.
Idempotent — re-run any time.

**What differs from the Linux path, and why:**

| | Linux (`linux.sh`) | macOS (`macos.sh`) |
|---|---|---|
| Packages | `tier_apt_min` / `tier_apt_dev` | `tier_brew_min` / `tier_brew_dev` |
| GUI apps | — | `tier_brew_cask` — Docker Desktop; the one tier needing an interactive sudo |
| Root | `sudo` probe → `PRIV=0` degrades to warn | none — Homebrew refuses sudo and owns its prefix |
| `fd` / `bat` | installed as `fdfind`/`batcat`, symlinked to friendly names | real names already; **no aliasing** |
| Scheduling | systemd user timer, cron fallback | **launchd** LaunchAgents |
| Shell hooks | `~/.bashrc` (+ fish) | `~/.zshrc` **and** `~/.bashrc` (+ fish) |
| `gortex` | `gortex_linux_amd64`, x86_64 only | `gortex_darwin_arm64` / `_amd64` |

Everything else — the synced agent config, git identity, the agent CLIs,
multi-account SSH, inbound fleet SSH trust — is the *same tier body* running on
both. Fix it once, both platforms get it.

**`tier_brew_cask` is the one tier that needs a terminal.** A cask links binaries
into `/usr/local/bin` through `sudo`; with no TTY the password read fails and the
cask rolls the entire install back. So provisioning a fresh Mac **over SSH, or
from an agent, will skip Docker Desktop with a warning** — that is by design, not
a bug. Re-run the named command from a terminal window on the box, then launch
the app once so it installs its privileged helper.

**Scheduling.** macOS has no systemd, and per-user `cron` needs the cron binary
granted Full Disk Access in System Settings (not scriptable), so the scheduled
tiers install LaunchAgents into `~/Library/LaunchAgents/` instead:

```bash
launchctl list | grep kz.cyphy
#   kz.cyphy.git-autofetch     every 10 min
#   kz.cyphy.fleet-selfpull    every 10 min
```

`launchctl bootout` runs before every `bootstrap`, so re-provisioning reloads a
changed plist rather than silently keeping the old one.

**Not installed**, same trade as the Linux path: the declarative
`development.nix` toolchain and the full `me.nix` desktop shell. Docker Desktop,
the company VPN, and `tsh` are separate manual installs.

**Roles are a separate step.** `macos.sh` is the *tier driver*; it does not read
`fleet.json` roles. After it finishes, run the role front door:

```bash
bash provision/provision.sh --machine air --apply
```

> Never run `provision.sh --apply` from inside a git worktree. The `agents` role
> runs `agents/bootstrap.sh`, which repoints `~/.claude` at
> *whatever checkout it is invoked from* — from a worktree that means your live
> agent config starts pointing into a temporary directory. Run it from the main
> clone.

## Choosing a base distro

Targets **glibc apt** distros. Recommended:

- **Debian** — leanest; smallest footprint for a disposable box.
- **Ubuntu** — most WSL-tested; smoothest interop. Good default.

Avoid:

- **Alpine / musl** — the prebuilt `gortex` binary (patchelf'd for glibc in the
  Nix fleet) and the native `claude` CLI are glibc builds; they won't
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

## WSL distro on the fleet tailnet

Enroll a WSL2 distro as its own Headscale tailnet node so it's reachable across
the fleet — its repos live natively on the distro's Linux filesystem, not across
the slow `\\wsl.localhost` 9P boundary. (Orca itself now runs on the Windows host
and opens the WSL project directly; the old per-distro `orca serve` runtime was
removed 2026-07-21.)

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

    # 2. Fleet SSH: key-only sshd + persisted fleet key + client config (needs sudo)
    bash ~/machines/provision/ssh-wsl.sh

Notes:

- **Per-distro identity.** Exactly one distro per Windows host runs `tailscaled`
  and owns the tailnet node; others share that node's IP and use distinct ports.
  No `.wslconfig`
  mirrored networking, no `netsh portproxy` — inbound rides the VPS DERP relay
  through WSL's NAT.
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
- **Secrets** (`HEADSCALE_AUTHKEY`) are never committed.
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
  `fleet.json` member, e.g. `g614jv` → `me@desktop-wsl`), not after the distro;
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

## Self-declaring as a fleet host (`provision-wsl`)

Half-provision a WSL distro as a first-class, self-declaring fleet host in one
shot. It never becomes a `fleet.json` entry (its OS hostname collides with its
Windows parent, and it's disposable) — but `/ship` and kb-refresh discover and
reach it automatically once it's declared:

    just provision-wsl <nickname>
    # equivalently, from inside the distro:
    bash ~/machines/provision/provision-wsl.sh <nickname>

Chain (each step already documented above; idempotent, safe to re-run):

1. `tailscale-wsl.sh --hostname <nickname>` — enroll on the tailnet as
   `<nickname>.gg.ez`.
2. `ssh-wsl.sh` — fleet SSH identity (client key + server).
3. `linux.sh` — software + timers; also merges
   `provision/fleet-authorized-keys` into `~/.ssh/authorized_keys`
   (inbound fleet SSH trust, idempotent).
4. `fleet-local.sh --nickname <nickname>` — writes the gitignored
   `fleet.local.json` self-declaration (`{nickname, fleet:true, platform,
   dispatch}`) at the repo root. `--no-tailscale` (step 1 skipped) makes
   `provision-wsl.sh` pass `--dispatch parent` here automatically — no
   separate manual step.
5. `wsl-fixes.sh` — wslopen + binfmt watchdog.

`<nickname>` is the `fleet.local.json` nickname always, and the tailnet node
name only for a `dispatch:direct` distro (at most one per Windows host — WSL2
distros share one network namespace). A `dispatch:parent` distro has no node
of its own and is reached through its Windows parent instead.

**Discovery is automatic, no `fleet.json` edit needed.** `/ship`
(`fleet-pull.sh`) and kb-refresh (`fleet-gather.sh`) both source the shared
`agents/plugin/skills/lib/fleet-dispatch.sh` helper, which — for every Windows
`fleet.json` member — enumerates its WSL distros (`wsl -l -q`) and reads each
one's `$HOME/machines/fleet.local.json`; any distro with `.self.fleet == true`
is pulled: directly at `<nickname>.gg.ez` if `dispatch:direct`, or as
`wsl.exe -d <distro>` through its Windows parent if `dispatch:parent`. A
distro that ran `provision-wsl` is reachable on the very next `/ship` or
kb-refresh run. (This WSL-discovery path is implemented but not yet exercised
end-to-end on a live box; the Windows-native dispatch path in
`fleet-dispatch.sh` — reaching `desktop`/`server`'s own
`C:\Users\<winuser>\machines` clone — has been.)
