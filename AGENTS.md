# AGENTS.md

This file provides guidance to Claude Code and other agents working in this
repository. The repo-root `CLAUDE.md` is a **symlink to this file** — edit
`AGENTS.md`, never create a second real file at the `CLAUDE.md` path.

**On a Windows-native checkout, check that the link survived before trusting
anything below.** `git` refuses to check a symlink out while `core.symlinks` is
false — Git for Windows' installer default, in the *system* config, so every
fresh clone inherits it — and renders it instead as a **9-byte regular file
holding the text `AGENTS.md`**. Nothing reports this: `git status` calls such a
tree clean, because index and worktree agree under that mode. So an agent there
loads nine bytes and no instructions, silently (it did, for four weeks, until
2026-08-03). `provision/windows.ps1` step 2 now sets `core.symlinks` and repairs
an already-broken link; `provision/tests/windows-core-symlinks.test.sh` guards
the tracked shape. The one-command check is `wc -c CLAUDE.md` — it must match
`AGENTS.md`, not read 9.

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
- **g15 / g513ie** — ASUS ROG **G15** 2023 (model G513IE), Ryzen 7 4800H,
  31 GB, RTX 3050 Ti, Windows 11 Pro, tailnet `100.64.0.3`. **Was `server` until
  2026-08-27** — renamed because the word had stopped naming anything: latitude
  holds the services role, and `server` is ALSO the `linux.sh` profile latitude
  runs, so one token meant two things in one manifest. **Back in `fleet.json`
  since 2026-08-27** as the **personal-projects host**, roles `base,
  ssh-server, agents, dotfiles, repos` — its own `~/.claude` is the point, so a
  personal Claude account needs no Orca profile juggling. The 2026-08-01
  decommission (`docs/fleet-roadmap.md` P2) is history; what it did is not undone
  — `hosts/server/` stays deleted and Forgejo stays wiped (inspection found zero
  repositories; it was never used).
- **The Linux side of `g15` is a WSL distro, not a reinstall.** Windows 11 was
  deliberately kept: C: holds ~416 GB nobody has reviewed, so a native Debian
  install would have to start with that review, and the box already had an empty
  `Ubuntu-26.04` WSL2 distro and 607 GB free. It is provisioned as the
  self-declared fleet host **`g15-wsl`** (`dispatch:direct`, its own tailnet
  node — Windows `g15` keeps node 3), so it never appears in `fleet.json`. If
  the Windows layer turns out to be friction, the target is Debian 13 trixie like
  latitude; that decision is now deferrable rather than blocking.
- **Reach `g15` as `methe@g15.gg.ez`, naming the user** — its Windows user is
  `methe`, and with the member block restored the bare `ssh g15` alias works from
  any box that has re-provisioned since. Reach the Linux side directly at
  `g15-wsl.gg.ez` (user `me`). `server.gg.ez` no longer resolves.

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
# THE validation gate. NOT every *.test.sh in the repo — see below. It prints
# its own count on the last line; trust that over any number written down here.
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

for t in $(just _test-suites); do bash "$t"; done   # the gate's own suite list
```

**Ask `_test-suites`, never a glob of your own.** That private recipe is the one
definition of what the gate runs — a recursive `find` for `*.test.sh` — and both
`just test` and `provision/tests/justfile.test.sh` consume it, so they cannot
disagree. Untracked suites are included on purpose: a test you just wrote should
run before you commit it.

This replaced a hand-listed set of four directories in `49497bd` (review item 7),
and the failure it fixed is worth remembering: the four dirs reached 30 of 40
tracked suites, while the gate printed "all 28 suites passed" and **every reader
took that for the repo — this file included, which is why it said so until
2026-08-13.** The ten unreached suites were all green when finally run, so the
cost was false confidence rather than a hidden regression. That is the argument
for the assertion, not against it: ten passing was luck, and luck is what a gate
exists to replace.

One file is still outside the gate by decision: `test_distill.py` needs pytest,
which is not in the fleet toolchain. Hence `justfile.test.sh`'s stray-name
assertion covers `.sh` only.

Don't write the suite count into prose — it moved three times on 2026-08-03
alone, and a stale count in a doc is how "27 suites" and "28 suites" ended up in
this same file. `just test` prints the count it actually ran; that is the number.

**The suite is GREEN as of 2026-08-03, 0 failures.** Keep it that way:
it is the only validation the repo has since the Nix gate went, and a red suite
gives no signal at all. The three long-standing failures were fixed that day, and
what they turned out to be is worth knowing: `provision-wsl.test.sh` had been
reporting a **real bug in shipped code** for weeks (an unbraced `"$var…"` that is
fatal under `set -u` in a UTF-8 locale — it also broke `just provision --apply`),
while the two `orca-profile-*` suites were **macOS-portability bugs in the tests**
(BSD `wc -l` pads its count; `/var` resolves to `/private/var`). Treating a red
count as a baseline is how the first one stayed unread — see
`docs/fleet-roadmap.md` P4.

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
  darwin_arm64, darwin_amd64). It untars the pinned release **unconditionally,
  with no version comparison**, so the pin is authoritative: a box updated out of
  band (`gortex upgrade`) is silently reverted to the pin by the next provision
  run for any reason. Fix a drift by bumping the pin, never by teaching the tier
  to disobey it.
- **`tier_gortex_autoupdate`** — the counterpart, and the only tier in the
  `server` profile that workstation lacks. It installs a weekly timer running
  `provision/gortex-autoupdate.sh`, which bumps `provision/gortex.version` to the
  newest upstream release (≥48h old) and pushes the commit; every other box then
  installs it through its own `tier_gortex`, because the pin is a
  `_touches_driver` trigger in `converge.sh`. **It installs no binary anywhere** —
  publisher and installer are deliberately separate, which is what keeps the fleet
  on one version and makes rollback a `git revert`. It is on **latitude only**:
  two writers race on the push and strand a commit, so if a different box should
  publish, MOVE the tier rather than copying it. Pinned by
  `provision/gortex-autoupdate.test.sh` (14 cases, all about what it can commit
  or push) and the single-writer assertions in `provision/tests/tiers.test.sh`.

**Four roles have no executor at all**: `base`, `ssh-server`, `backup-hub` and
`backup-client`. `provision/roles/` holds only `agents`, `dotfiles` and `repos` —
there is no stub file for the other four, they fall through `provision.sh`'s
fallback arm. The capability exists in hand-rolled forms elsewhere
(`windows.ps1` step 6, `tier_ssh_trust`), which is why this can read as done. It
is not — roadmap P3.

Since 2026-08-05 that gap is **declared, not silent**: `provision.sh` carries a
`PLANNED_ROLES` list naming those four, and a role that is neither implemented
nor named there makes `--apply` exit 1. Before that, `just provision --machine
latitude --apply` reported success while doing nothing for four of its seven
roles. **Implementing a role means DELETING its name from `PLANNED_ROLES`** —
leave it in and the new executor is never demanded of a box that lacks it.

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
`fleet-gather.sh`; it also handles the Windows-native members by dispatching
through Git Bash via PowerShell's call operator, keyed on `platform: windows` in
`fleet.json` — which since 2026-08-27 means `desktop` **and** `g15` again (`g15`
was out of the manifest between 2026-08-01 and 2026-08-27, when `desktop` was the
only one).

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

`hosts/desktop/windows/` carries install/reinstall + backup scripts.
(`hosts/server/` was deleted with the decommission — git history has it.)

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
  `hosts/<dir>`: `latitude` / `desktop` / `hub` / `air` / `g15`. Role-based
  where a role exists (`desktop`, `hub`), model-based otherwise (`latitude`,
  `air`, `g15`) — the rule is *stable and human*, not *role*. **`g15` was
  `server` until 2026-08-27, the only logical name ever renamed**, and it was
  renamed precisely because the role it named had moved to latitude. A rename
  moves the tailnet node, the dotfiles branch and `fleet-authorized-keys` in the
  same change, or it moves nothing.
- **OS hostname** — `detect.hostname` in `fleet.json` — the hardware model,
  lowercased: `latitude5520`, `g614jv`, `g513ie`, `27608`. Note `g15` (logical,
  the marketing model) and `g513ie` (OS hostname, the SKU) are the two layers of
  the same box, not a violation of the rule.
- `hub`/`27608` is the VPS special-case: no laptop model, so its OS hostname
  is just the VPS ID, not a model code.
- The G15's *live* OS hostname is `g513ie` — renamed from `methe-server` via
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
