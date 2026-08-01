# machines — personal machine fleet

Config, provisioning, and data-backup for a small fleet of physical machines —
**Debian, Windows and macOS.** Each host carries its ops scripts under
`hosts/<name>/<platform>/`; the shared behaviour lives in the cross-platform
provisioner under `provision/`.

> **There is no NixOS host left.** The flake and its 22 modules were deleted
> 2026-08-01 and live in the annotated tag `nixos-final`. If you came looking for
> `just switch`, `nix flake check` or `just quick`, read
> `docs/2026-08-01-nixos-harvest.md` — it records what that tree knew, what was
> already ported, and the two files in it that were live provisioning inputs
> rather than Nix packaging.

- **latitude** — Dell Latitude 5520, Intel Tiger Lake, **Debian 13 trixie**. The
  always-on **services host**: immich, servarr, speedtest, tugtainer, and the
  restic REST backup hub. Never sleeps, by design.
- **air** — MacBook, the **primary dev box**.
- **hub** — Debian VPS at `cyphy.kz`; Headscale control server + AmneziaWG VPN hub.
- **desktop** (`g614jv` WSL / `ME-G614JV` native) — ASUS ROG G16 2024, RTX 4060;
  **Windows-only**. Its former NixOS install `g16` was retired 2026-07-08.
- ~~**server**~~ — ASUS ROG **G15** 2023 (model **G513IE**), RTX 3050 Ti,
  Windows 11, OS hostname `g513ie`. **Left `fleet.json` 2026-08-01**; its services
  moved to latitude. Still powered on, reachable as
  `methe@server.gg.ez` (name the user — the bare alias dies at air's next provision
  run), . Forgejo was wiped from it 2026-08-01 (never
  used, zero repos) and its Docker state holds nothing unique; `C:` is the only
  drive left and is unreviewed — see `docs/fleet-roadmap.md` P2 before wiping it.
  It used to run the cyphy.kz platform, defined in the sibling **`vps`** repo —
  that repo owns the *services*; `machines` owns the *machines* + their backups.

Top-level layout: `hosts/<host>/<platform>/` (per-machine ops scripts),
`provision/` (the cross-platform provisioner + tier library), `agents/` (agent
config, plugin, bootstrap), `scripts/` (convergence engine + version bumper),
`docs/` (`fleet-roadmap.md` is the live backlog), `install-media/` (shared Win11
answer file + Ventoy config).

## Onboarding — start here

| Box kind | One command |
|---|---|
| **macOS** — air | `just provision-mac air` |
| **Debian / any glibc Linux** | `bash provision/linux.sh` |
| **Windows** — ME-G614JV | `provision\windows.ps1` (`-Work` adds the work profile) |
| **WSL** — self-declaring fleet host | `just provision-wsl <nickname>` |

All of them link your synced agent config for you (via `agents/bootstrap.sh`); to
re-link only that, run `bash agents/bootstrap.sh` (or `just agent-bootstrap`). To
clone your repos into the `~/my` · `~/pure` · `~/cyphy671` layout, run
`bash provision/repos.sh <groups>` (e.g. `my cyphy671` on a personal box, `pure`
on a work box).

For a Linux dev environment on Windows, `provision/linux.sh` provisions a
persisted or disposable Debian/Ubuntu WSL box with the portable layer (synced
agent config + CLI tools) — a peer of `install-media/`.

## Common Commands

`just --list` is the full menu (16 recipes).

| Command | Description |
|---|---|
| `just test` | **The validation gate** — runs every `*.test.sh` in the repo |
| `just provision --machine <m> --dry-run` | Show a machine's provisioning plan |
| `just provision-mac <machine>` | Provision THIS Mac end to end |
| `just provision-wsl <nickname>` | Self-declare THIS WSL distro as a fleet host |
| `just agent-bootstrap` | Link `~/.claude` (+ mirror into Orca profiles) |
| `just gortex-setup` | Force a gortex rewire (run after a version bump) |
| `just update-gortex` | Bump `provision/gortex.version` |
| `just status` | Host, kernel, uptime, memory, disk, battery |
| `just health` | Failed units, next timers, disk pressure |
| `just hardware` / `just logs` / `just monitor` | Hardware, recent logs, live monitor |

`just test` used to be `nixos-rebuild test`, so the suite had no recipe at all.
All 28 suites pass as of 2026-08-01 (roadmap P4). Keep it green — it is the
repo's only gate, and a red suite gives no signal.

## Architecture

### The provisioner

`provision/` is the cross-platform provisioner and, since the modules were
deleted, where behaviour lives.

- `provision.{sh,ps1}` — the role front door, driven by `fleet.json`.
- `lib/tiers.sh` — the `tier_*` functions: the portable implementation of what
  the NixOS modules used to declare. Several name the module they replaced; that
  provenance is deliberate, not stale.
- `linux.sh` / `macos.sh` — tier drivers. Both run the same tier bodies; only the
  driver path differs.
- `roles/*.{sh,ps1}` — role executors. Only `agents`, `dotfiles` and `repos` are
  implemented; `ssh-server`, `base` and `backup-client` are stubs that print a
  plan (roadmap P3).
- `gortex.version` — the pinned gortex release, installed by `tier_gortex` into
  `~/.local/bin` on every box.
- `statusboard/` — the console dashboard (a local VT/tmux board, Linux-only).

See `provision/README.md` for usage and base-distro guidance.

### Convergence

`scripts/converge.sh` applies pulled state on each box after a fast-forward pull,
routing by OS class. A change to a *provisioning-relevant* path triggers a
reprovision; a content-only pull does not. `scripts/converge.test.sh` asserts the
gates, including that `fleet.json` and `provision/gortex.version` count on both
the linux and darwin tiers — `fleet.json` had silently counted on no box at all
between latitude leaving NixOS and 2026-08-01.

### Host scripts

**`hosts/latitude/debian/`** — the services host's recurring jobs:
`mirror-refresh.sh` (immich library → mirror), `archive-mirror.sh` (the closed
1970–2024 archive → its second drive), and `install-timers.sh` + `systemd/` to
install both as system timers. Read the headers first — they record decisions the
code cannot show you.

**`hosts/desktop/windows/`** — install/reinstall +
backup scripts.

## Hardware Notes

### Battery charge limiting

The laptops cap charging via `charge-upto`, installed by `tier_battery_limit`:

```bash
charge-upto 80         # ceiling, applied now and persisted
charge-upto 100        # effectively disable the limit
```

Writing `charge_control_end_threshold` alone is **not enough on a Dell** — the EC
honours it only in Custom charge mode and boots in `[Fast]`, so a naive
implementation displays a limit it is not enforcing. `charge-upto` writes the mode
too, and takes a floor as well as a ceiling so the cell holds steady instead of
cycling down and back. latitude runs 80–85% because it is on AC 24/7 as the
services host.

## Worktree dispatchers

`worktree-setup.sh` / `worktree-teardown.sh` (fleet root) are tool-agnostic hooks
for the git-worktree lifecycle. Run with CWD = the worktree, no arguments.

- **Orca IDE:** point the *Create worktree* hook at
  `~/machines/agents/worktree-setup.sh` and the *Delete worktree* hook at
  `~/machines/agents/worktree-teardown.sh` (absolute paths; the fleet repo path is
  stable across machines).
- **Manual:** run `wt-setup` / `wt-teardown` from inside a worktree — thin
  `~/.local/bin` wrappers that exec the scripts above, tracked in the dotfiles repo
  on `main` so every box has them (their bodies are `$HOME`-relative, and
  `~/.local/bin` is on `PATH` on all six). Override the checkout location with
  `MACHINES_ROOT`. The scripts themselves stay here rather than moving to dotfiles:
  they are tested (`agents/tests/worktree-dispatcher.test.sh`) and read repo state,
  and only the *invocation* needed shortening — you run these from inside whatever
  worktree you are in, never from `~/machines`, which is also why a `just` recipe
  would be the wrong shape.
- **Orca takes the wrappers too** — `wt-setup` / `wt-teardown` in its *Setup
  script* / *Archive script* fields, which is what `/orca-setup` now prints. Orca
  shell-interprets that field, and its own `PATH` includes `~/.local/bin` (measured
  on air by reading the running process's environment), so a bare command name
  resolves. If a hook ever fails with *command not found* on some box, use
  `"$HOME/.local/bin/wt-setup"` — same wrapper, no `PATH` dependency. The long
  `bash "$HOME/machines/agents/worktree-setup.sh"` form still works and
  `/orca-setup` reports it as `LEGACY`, not as a conflict, so nothing needs
  re-pasting.

**What they do.** Setup: gortex-`track`s the worktree (`--as-worktree --name
<main-basename>-<worktree-basename>`) *first*, then runs the repo's own setup
script. The explicit `--name` matters: `--as-worktree` alone defaults the graph
prefix to the directory basename, and Orca lays worktrees out as
`~/orca/workspaces/<repo>/<branch-leaf>`, so every repo's `agenda` worktree would
fight over one `agenda` prefix. Teardown: runs the repo's own teardown script
*first*, then `gortex untrack`s the worktree and reconciles (prunes any tracked
path missing on disk — catches worktrees removed outside the IDE).

Both read the tracked-repo list from the **daemon** (`gortex repos --json`), never
from a config file on disk. They used to default to `~/.config/gortex/config.yaml`,
which is not where gortex keeps its global config (`~/.gortex/config.yaml`) — the
file never existed, so the coverage guard failed *closed* and no worktree was ever
tracked, with a single misleading `main checkout not covered by gortex` line to show
for it. Every test injected the config path, so the default branch was never
exercised.

**gortex coupling is guarded and personal.** Every gortex action is gated on
`gortex daemon status`; with the daemon down or gortex absent the gortex step is a
silent no-op, so committed work repos and non-gortex teammates are unaffected.
gortex is `track`ed only when the *main* checkout is already covered by the daemon.

**Repo-local script candidates** (first executable match wins, then stop):
`.orca/` → `docker/` → `.worktree/` → `scripts/`, basename
`worktree-setup.sh`/`setup.sh` (or `-teardown.sh`/`teardown.sh`). backend-api ships
`docker/worktree-setup.sh` + `docker/worktree-teardown.sh`; they carry no gortex
references.

**Caveat:** reconcile prunes *any* tracked path gone from disk, including a
temporarily-unmounted drive — re-track it on return.
