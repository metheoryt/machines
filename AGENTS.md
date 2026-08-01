# AGENTS.md

This file provides guidance to Claude Code and other agents working in this
repository. The repo-root `CLAUDE.md` is a **symlink to this file** — edit
`AGENTS.md`, never create a second real file at the `CLAUDE.md` path.

## Repository Overview

Config, provisioning, and data-backup for a small machine fleet — **Debian,
Windows and macOS. There is no NixOS host left.** The flake and its 22 modules
were deleted 2026-08-01; see *The NixOS tree is gone* below before reaching for
`nixos-rebuild`, `nix flake check` or `just quick`, none of which exist here now.

- **latitude** — Dell Latitude 5520, Intel Tiger Lake, **Debian 13 trixie**, OS
  hostname `latitude5520`, tailnet `100.64.0.8`. The **always-on services host**:
  immich, servarr, speedtest, tugtainer, and the restic REST backup hub. Roles
  `base, ssh-server, agents, dotfiles, repos, backup-hub, backup-client`.
  Reinstalled from NixOS during the 2026-07/08 fleet migration.
- **air** — MacBook, `platform: darwin`, tailnet `100.64.0.7`, roles `base,
  ssh-server, agents, dotfiles, repos`. The **primary dev box**. Provisioned with
  `just provision-mac air` plus the dotfiles role.
- **hub** — Debian VPS at `cyphy.kz` (tailnet `100.64.0.1`), a first-class
  `fleet.json` member (roles `base, ssh-server, agents, dotfiles,
  backup-client`); runs the Headscale control server + the AmneziaWG VPN hub.
  Services live in the sibling `vps` repo.
- **desktop / g614jv / ME-G614JV** — ASUS ROG G16 2024, RTX 4060; **Windows-only**
  (WSL hostname `g614jv`, native `ME-G614JV`), tailnet `100.64.0.4`. Its former
  NixOS install `g16` was retired 2026-07-08; `hosts/desktop/` holds only
  `windows/`. `desktop-wsl` (`100.64.0.6`) is a self-declared WSL host on it.
- **server / g513ie** — ASUS ROG **G15** 2023 (model G513IE), RTX 3050 Ti,
  Windows 11, tailnet `100.64.0.3`. **Being decommissioned** — its services moved
  to latitude and its containers are stopped. Still reachable and still holds the
  only copies of some things, so do not prune it from `fleet.json` before the
  remaining Caddy routes are repointed (see `docs/fleet-roadmap.md` P2).

The repo also carries Windows install/reinstall + backup scripts
(`hosts/desktop/windows/`) and shared Win11 install media (`install-media/`).

**`machines` / `vps` boundary:** `machines` owns the *machines* — provisioning
and data backup across Debian, Windows and macOS. The sibling **`vps`** repo owns
the *services* (Immich, Forgejo, the cyphy.kz platform, the restic profiles).
Machine here, services there.

### The NixOS tree is gone

Deleted 2026-08-01 in `f3d63b2`, after the last Nix host was reinstalled as
Debian. Preserved in the annotated tag **`nixos-final`**, and reviewed on the way
out — **read `docs/2026-08-01-nixos-harvest.md` before restoring anything from
it.** Two findings there matter beyond the cleanup:

- `modules/system/ssh-server.nix` was the only written spec for the `ssh-server`
  role, which is still an unimplemented stub. Its firewall shape (port 22 on
  `tailscale0` only, plus one explicit `192.168.8.0/24` carve-out) is not
  guessable and is written up in the harvest.
- Two files in that tree were **live inputs to POSIX provisioning**, not Nix
  packaging, and were rehomed rather than deleted: the gortex pin is now
  `provision/gortex.version`, and `fleet.json` became a reprovision trigger in
  `scripts/converge.sh`'s driver gate — it had silently been a trigger on no box
  at all since latitude left NixOS.

`converge.sh` still *detects* a `nixos` box class on purpose: folding it into
`linux` would run the apt driver on a Nix box and abort. It now refuses
explicitly and records a failure rather than advancing `converged-rev`.

## Common Commands

All commands run from repo root. `just --list` is the full menu (16 recipes,
down from 33 — the other 28 were `nixos-rebuild`/`nix-store` wrappers).

```bash
# THE validation gate. Runs every *.test.sh in the repo (27 suites).
# NOTE: `just test` used to be `nixos-rebuild test`. It is the suite now.
just test

just status                             # host, kernel, uptime, memory, disk, battery
just health                             # failed units, next timers, disk pressure
just hardware | just logs | just monitor
```

### Fleet / provisioning (every platform)

```bash
# Role front door — flag syntax; a bare positional exits 2
just provision --machine <machine> --dry-run
just provision --machine <machine> --apply

just provision-mac <machine>            # provision THIS Mac end to end
just provision-wsl <nickname>           # self-declare THIS WSL distro
                                        #   (--no-tailscale for a second distro)

just agent-bootstrap                    # link ~/.claude (+ mirror into Orca profiles)
just agent-bootstrap-profile <postfix>  # provision ~/.claude-<postfix>
just agent-sync-orca                    # populate Orca's per-account profiles from
                                        #   ~/.claude (also runs at agent-bootstrap)
just agent-harvest-orca                 # copy Orca's live account profiles OUT to
                                        #   ~/.claude-profiles/<name> (backup; runs at
                                        #   agent-bootstrap); --restore <name>
just agent-link-orca <name>             # ALTERNATIVE to harvesting: move the profile to
                                        #   ~/.claude-profiles/<name> + symlink it back
                                        #   (once per account, Orca CLOSED);
                                        #   --status / --relink
just gortex-setup                       # force a gortex rewire (run after a bump)

just update-gortex                      # bump provision/gortex.version
```

`update-orca` and `update-rustdesk` are gone — they wrote only into
`modules/home/*-bin.nix` and nothing else read those files.

### Tests

`just test` is the gate. To run one file, or the loop by hand:

```bash
bash provision/tests/roles.test.sh      # prints ALL PASS, nonzero on failure

for t in provision/tests/*.test.sh provision/*.test.sh \
         agents/tests/*.test.sh scripts/*.test.sh; do bash "$t"; done
```

**Three suites fail at HEAD and have for a while** — `provision-wsl.test.sh`,
`orca-profile-harvest.test.sh`, `orca-profile-link.test.sh`. They reproduce in a
clean worktree and are not fallout from recent work. Since the Nix gate is gone
this suite is the only validation the repo has, so a red suite gives no signal:
greening these three is `docs/fleet-roadmap.md` P4.

## Architecture

### Top-level directories

| Dir | What it is |
|---|---|
| `provision/` | Cross-platform provisioner — `provision.{sh,ps1}` role front door, `roles/*.{sh,ps1}` executors, `lib/` manifest readers (`fleet.sh`, `Fleet.psm1`, `tiers.sh`), `linux.sh`/`macos.sh` tier drivers, `statusboard/`, `gortex.version` (the pinned gortex release), `tests/`. See `provision/README.md`. |
| `agents/` | Version-controlled agent config — `plugin/` (skills, subagents, hooks, commands), `subagents/`, `git-hooks/`, `bootstrap.sh`, `orca-profile-sync.sh` (populates Orca's per-account profiles from `~/.claude`), `orca-profile-harvest.sh` (one-way rsync of the live account profiles out to `~/.claude-profiles/<name>` so transcripts outlive Orca's dir), `orca-profile-link.sh` (the stronger alternative — relocates the profile and symlinks it back), `worktree-{setup,teardown}.sh`, `tests/`. See `agents/README.md` and `agents/docs/git-workflow.md`. |
| `scripts/` | `converge.sh` (convergence engine) + `converge.test.sh`, `update-gortex.sh` (bumps the pin). |
| `hosts/` | Per-machine, per-platform ops scripts: `hosts/<name>/<platform>/`. |
| `docs/` | `fleet-roadmap.md` is the live backlog; `superpowers/plans/` holds plans and specs. |
| `install-media/` | Shared Win11 install media. |

### The provisioner is the whole story now

With the modules gone, **`provision/lib/tiers.sh` is where behaviour lives**.
Its `tier_*` functions are the portable reimplementation of what the NixOS
modules used to declare, and several carry comments naming the module they
replaced — that provenance is deliberate, not stale. Two of them are worth
knowing about because they encode hardware traps the Nix versions got wrong:

- **`tier_battery_limit`** — caps the charge level. Writing
  `charge_control_end_threshold` is *not* enough on a Dell: the EC honours it
  only in Custom charge mode and comes up in `[Fast]`, so the old NixOS module
  displayed a limit it was not enforcing. This one writes the mode too, and adds
  a start/floor threshold so the cell holds steady instead of cycling.
- **`tier_gortex`** — installs the release named in `provision/gortex.version`
  into `~/.local/bin`, resolving the asset per platform (linux_amd64,
  darwin_arm64, darwin_amd64).

The `ssh-server`, `base` and `backup-client` role executors under
`provision/roles/` are **unimplemented stubs** that print "not yet implemented
(skipped)"; only `agents`, `dotfiles` and `repos` are real. The capability exists
in hand-rolled forms elsewhere (`windows.ps1` step 6, `tier_ssh_trust`), which is
why this can read as done. It is not — roadmap P3.

### Fleet networking / tailnet architecture

The fleet transport is a self-hosted **Headscale tailnet** (`cc.cyphy.kz`,
MagicDNS suffix `gg.ez`, CGNAT `100.64.0.0/10`); `fleet.json` (repo root) is
the machine manifest. The old AmneziaWG mesh was retired from the repo
2026-07-17 (AmneziaWG survives only as the VPS's obfuscated VPN for RU
relatives).

Two separate LANs. Same-LAN pairs get direct P2P (~3ms); cross-LAN pairs relay
through our own DERP — expected and accepted.

Self-declared WSL hosts are first-class fleet hosts that never appear in
`fleet.json`: each carries a gitignored `fleet.local.json`
(`{nickname, fleet:true, platform, dispatch}`), written by
`provision/fleet-local.sh` as step 4 of `just provision-wsl <nickname>` (chain:
`tailscale-wsl.sh → ssh-wsl.sh → linux.sh → fleet-local.sh → wsl-fixes.sh`).
Its Windows parent discovers it live via `wsl -l -q` + reading each distro's
`fleet.local.json`. Only a `dispatch:direct` distro (the one that owns the
tailnet node, at most one per Windows host — WSL2 distros share one network
namespace) is reached directly at `<nickname>.gg.ez`; every other distro is
`dispatch:parent`, reached as `wsl.exe -d <distro>` through its Windows
parent — not through a `fleet.json` entry either way. The shared dispatch primitive
`agents/plugin/skills/lib/fleet-dispatch.sh` (`fd_probe`/`fd_run`/
`fd_wsl_hosts`) is sourced by both `/ship`'s `fleet-pull.sh` and kb-refresh's
`fleet-gather.sh`; it also handles the Windows-native members (`desktop`,
`server`) by dispatching through Git Bash via PowerShell's call operator,
keyed on `platform: windows` in `fleet.json`.

**Gotcha:** a self-declared WSL host has no `fleet.json` entry, so the generated
`~/.ssh/config` has no `Host` block for its bare name — only the catch-all
`Host *.gg.ez`. From `air`, `ssh desktop-wsl` falls through to the default
identity and fails; `ssh desktop-wsl.gg.ez` works.

### Host configurations

`hosts/<name>/<platform>/` — per-machine ops scripts, no build system.

**`hosts/latitude/debian/`** — the services host's recurring jobs. All three are
worth reading headers-first; they record decisions that are not re-derivable
from the code.

- `mirror-refresh.sh` — `/mnt/immich` → `/mnt/immich-mirror`. Why live PGDATA is
  excluded (an rsync of a running postgres dir is a torn copy that *looks* like a
  backup), why `-H` is mandatory, why `--delete` is off.
- `archive-mirror.sh` — the closed 1970–2024 archive → `/mnt/xs`. Records the
  exfat verification (no hardlinks, no illegal filenames, exfat's size ceiling is
  far above FAT32's remembered 4 GiB), why the *source* dock is the flaky one, and
  why `--partial-dir` rather than `--append-verify`.
- `install-timers.sh` + `systemd/` — installs both as system timers. It **copies**
  units into `/etc/systemd/system` rather than symlinking, so a `git pull` cannot
  change what root runs on a timer without review.

The Windows hosts carry install/reinstall + backup scripts under
`hosts/<name>/windows/`.

### Key patterns

- **Behaviour goes in a `tier_*` function** in `provision/lib/tiers.sh`, driven by
  `linux.sh` / `macos.sh`. Both drivers run the same tier bodies; only the driver
  path differs.
- **Roles are declared in `fleet.json`** and executed by `provision/roles/<role>.{sh,ps1}`.
  A role with no executor degrades to a printed plan rather than failing.
- **Mount every external drive by UUID, never by `/dev/sdX`.** Every letter
  reshuffles across a reboot on latitude (five bus-powered USB drives plus a card
  reader race to enumerate) and one enclosure reports a fake serial.
- **Verify a scheduled job by firing its schedule, not by running the script.**
  `mirror-refresh.sh -go` passed by hand for weeks while every timer run reported
  `Failed` — its last command was falsy under `-go`. `systemctl start <unit>` then
  `systemctl show -p Result` is the check that would have caught it.
- **A non-interactive ssh PATH on Debian excludes `/usr/sbin` and `/sbin`.**
  Scripts that call `findmnt`, `blkid` or `smartctl` must
  `export PATH=/usr/sbin:/sbin:/usr/bin:/bin`.

## Hardware Context

### Two-layer hostname convention

- **Logical name** — the fleet key / SSH alias / tailnet node / repo
  `hosts/<dir>` — role-based and stable: `latitude` / `desktop` / `server` /
  `hub` / `air`.
- **OS hostname** — `detect.hostname` in `fleet.json` — the hardware model,
  lowercased: `latitude5520`, `g614jv`, `g513ie`, `27608`.
- `hub`/`27608` is the VPS special-case: no laptop model, so its OS hostname
  is just the VPS ID, not a model code.
- The server's *live* OS hostname is `g513ie` — renamed from `methe-server` via
  `Rename-Computer` + reboot on the box, verified live 2026-07-20.
- **Self-declared WSL hosts add a third identity, outside this two-layer
  scheme entirely**: they are not a `fleet.json` member, so there's no
  logical-name/OS-hostname pair — just a `fleet.local.json` nickname. Note
  `{{ .Hostname }}` in a template on WSL expands to the *Windows* hostname, not
  the distro nickname.

### latitude5520 (Dell Latitude 5520) — the services host

Verified live 2026-08-01. This block was materially wrong until then: it
described the NixOS install's LUKS root, ZRAM swap and S3 sleep, none of which
survived the Debian reinstall.

- OS: **Debian 13 trixie**. No Nix at any path.
- CPU: Intel 11th Gen Tiger Lake. GPU: Intel integrated only.
- **Root is unencrypted ext4** — a deliberate decision for a plugged-in home
  machine that must boot unattended. Do not re-raise it.
- Swap: a **14.9 GB partition** (not ZRAM), ~1.7 GB in use against 23 GB RAM.
- **It never sleeps, by design.** `HandleLidSwitch`, `HandleLidSwitchDocked`,
  `HandleLidSwitchExternalPower` and `IdleAction` are all `ignore` in
  `/etc/systemd/logind.conf`, *and* `sleep.target` / `suspend.target` /
  `hibernate.target` are masked. Closing the lid must not take immich and the
  backup timers down with it. Do not "restore" the old laptop power management.
- Battery charge window 80–85% via `/usr/local/bin/charge-upto` +
  `/etc/default/charge-upto`, installed by `tier_battery_limit`. A laptop held at
  100% on AC 24/7 swells its cell, which is the whole point.
- Five external USB drives on two docks. The dock carrying `immich-2024` and
  `immich-mirror` is the flaky one — it logged 24 `usb 4-2: reset` events in one
  day under load. Guard by UUID and expect mid-run drops.
- No Docker prune timer. 18 images / ~15 GB, only 3% reclaimable, so the gap is
  currently free. If one is ever added it **must never gain `--volumes`**: three
  of the seven volumes are live immich/postgres data.
