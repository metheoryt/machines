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
  ssh-server, agents, dotfiles, repos`. Called **the primary dev box** here since
  the 2026-07 migration, and that label is doubtful: every `pure` work repo moved
  off it to `desktop-wsl` by 2026-08-02 (`~/pure` was found absent on air that
  day) and has not moved back. Not re-verified since — air is frequently asleep
  and was unreachable again on 2026-09-11 — so check the box before trusting
  either the label or this caveat. Provisioned with
  `just provision-mac air` plus the dotfiles role. It runs a **pre-release macOS
  27 (Tahoe)**, which Homebrew says out loud it does not support — bottles come
  tagged `arm64_tahoe` and `brew doctor` opens with the unsupported-version
  warning. Expect brew oddities here and do not file them as box faults; equally,
  do not let that become a blanket excuse, because "environmental" is the label
  this repo has already been burned by (see the suite section below).
- **hub** — Debian VPS at `cyphy.kz` (tailnet `100.64.0.1`), a first-class
  `fleet.json` member (roles `base, ssh-server, agents, dotfiles,
  backup-client`); runs the Headscale control server + the AmneziaWG VPN hub.
  Services live in the sibling `vps` repo.
- **desktop / g614jv / ME-G614JV** — ASUS ROG G16 2024, RTX 4060; **Windows-only**
  (WSL hostname `g614jv`, native `ME-G614JV`), tailnet `100.64.0.4`. Its former
  NixOS install `g16` was retired 2026-07-08; `hosts/desktop/` holds only
  `windows/`. `desktop-wsl` (`100.64.0.6`) is a self-declared WSL host on it.
  **The Windows side carries almost nothing — only `machines`.** Every working
  repo on this machine lives inside `desktop-wsl`, deliberately: it is Linux on
  ext4, which is where developing on them is less painful. So "on desktop" as a
  place to find a repo means the distro, not the Windows profile, and anything
  enumerating this box's repos has to go through the distro.
- **g15 / g513ie** — ASUS ROG **G15** 2023 (model G513IE), Ryzen 7 4800H,
  31 GB, RTX 3050 Ti, **Ubuntu 26.04 resolute**, tailnet `100.64.0.10`. **Was
  `server` until 2026-08-27** — renamed because the word had stopped naming
  anything: latitude holds the services role, and `server` is ALSO the `linux.sh`
  profile latitude runs, so one token meant two things in one manifest. **Back in
  `fleet.json` since 2026-08-27** as the **personal-projects host**, roles `base,
  ssh-server, agents, dotfiles, repos, backup-client` — its own `~/.claude` is
  the point, so a
  personal Claude account needs no Orca profile juggling. The 2026-08-01
  decommission (`docs/fleet-roadmap.md` P2) is history; what it did is not undone
  — `hosts/server/` stays deleted and Forgejo stays wiped (inspection found zero
  repositories; it was never used).
- **Windows and the `g15-wsl` distro are GONE — reinstalled 2026-09-07.** This
  entry described a Windows 11 box with an Ubuntu WSL distro inside it
  (`dispatch:direct`, tailnet node 3, never in `fleet.json`) for the whole day
  after that stopped being true, which is the trap this file keeps warning about.
  The design is
  `docs/superpowers/specs/2026-09-07-g15-linux-migration-design.md`; it named
  Debian 13 and the box shipped Ubuntu because the ≥6.19 kernel the asus-linux
  stack needs is there out of the box (live: `7.0.0-31-generic`). Consequences
  that bite elsewhere:
  - **Its `fleet.json` platform is `debian`, on an Ubuntu box, deliberately.**
    Every posix role executor allowlists `wsl|debian|darwin` (it was
    `nixos|wsl|debian|darwin` until 2026-09-09) and its
    fallback prints "no posix executor for platform 'X' (skipped)" and returns
    **0** — so `platform: ubuntu` would have skipped `dotfiles`, `repos` and
    `backup-client` while `--apply` reported success. The token is a class name
    meaning "posix, not darwin, not WSL"; renaming it fleet-wide is five role
    files plus suites, and is roadmap work, not a rename to do in passing.
  - **`repo_groups` in the manifest is per-machine** and g15 declares `["my"]`
    only. `pure` and `cyphy671` are not wanted there.
  - Reach it as **`me@g15.gg.ez`** — its entry carries no `ssh` block at all,
    because `ssh.user` defaults to `me`. It was `methe@` under Windows, so a box
    that has not re-provisioned since still has the old user and a stale host key
    (`accept-new` refuses a CHANGED key — `ssh-keygen -R` is the fix, and no
    provision run does it for you).
  - `g15-wsl.gg.ez` and `server.gg.ez` no longer resolve. Headscale nodes 3
    (renamed `g15-retired`) and 9 (`g15-wsl`) are dead and still listed.
  - **Orca runs natively now, so `provision/orca-serve.sh` must NOT autostart
    here** — see its header. A headless `serve` holds Electron's
    one-instance-per-userData lock and the desktop app cannot open at all. The
    script gates that on WSL since `63472aa`; the box was in exactly that state
    for a day.

The repo also carries the Windows reinstall bootstrap and runbook
(`hosts/desktop/windows/`) and shared Win11 install media (`install-media/`).
**It carries no backup or restore script** — `backup.ps1` and `restore.ps1` were
both deleted 2026-07-31 (`1080828`), so Phase 1 (preserve) and the automatic half
of Phase 4 (restore repos, `.ssh` + perms, Downloads, the vault) are manual.
`install.ps1` is the `irm … | iex` one-liner: git, clone, then hand off to
`provision/windows.ps1`. It pointed at the deleted `restore.ps1` until
2026-09-09 and threw unconditionally; `provision/tests/windows-bootstrap.test.sh`
now asserts every path it hands off to is tracked.

**`machines` / `vps` boundary:** `machines` owns the *machines* — provisioning
and data backup across Debian, Windows and macOS, **including the restic
profiles and their schedules** (`backup/<identity>/`, moved out of `vps` on
2026-09-01). The sibling **`vps`** repo owns the *services* (Immich, the
cyphy.kz platform, and the restic REST **server** container latitude's hub runs).
Machine here, services there — the daemon that stores the backups is a service,
what each box chooses to back up is a machine fact.

This paragraph used to claim both halves at once — `machines` owned "data
backup", `vps` owned "the restic profiles" — and that contradiction is what sent
a whole round of backup work to the wrong repo. It also listed Forgejo, wiped
2026-08-01. If you catch this file asserting two incompatible things, the
contradiction is the bug; do not pick the half that suits the task.

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

All commands run from repo root. `just --list` is the full menu — ask it rather
than trusting a number written here. It said "16 recipes" long after that stopped
being true; the count moves whenever anyone adds a recipe, which is the same trap
this file already documents for the suite count below. What is
worth recording is the shape, not the size: the menu shrank hard when the NixOS
tree went, because 28 of the old recipes were `nixos-rebuild` / `nix-store`
wrappers.

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

just agent-bootstrap                    # link ~/.claude
just agent-bootstrap-profile <postfix>  # provision ~/.claude-<postfix>
just gortex-setup                       # force a gortex rewire (run after a bump)

just update-gortex                      # bump provision/gortex.version
```

`update-orca` and `update-rustdesk` are gone — they wrote only into
`modules/home/*-bin.nix` and nothing else read those files.

**`agent-sync-orca` / `agent-harvest-orca` / `agent-link-orca` are gone too,
2026-09-09, with the three `agents/orca-profile-*.sh` scripts behind them.** They
mirrored `~/.claude` into Orca's per-account config dirs, archived those dirs out
to `~/.claude-profiles/<name>`, and relocated one into `$HOME` with a symlink
back. **Orca's own account switcher is what the fleet uses now**, so the state
they managed is not produced any more:
`~/.local/share/orca/claude-accounts` was EMPTY on air and absent on g15 when
that was checked on 2026-09-09, and no box had a `~/.claude-profiles` at all.
One thing survived the deletion on purpose — **`bootstrap.sh` still detects an
Orca account dir and now REFUSES it (exit 3) rather than redirecting to the
mirror.** Reaching the secondary-profile fallback with `CLAUDE_CONFIG_DIR` set to
`…/claude-accounts/<uuid>/auth` deploys the tracked baseline into a directory
this repo does not own; that happened on 2026-08-01. The scripts were the
redirect's destination, not its reason.

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

**Nothing is outside the gate any more.** `test_distill.py` was, for needing
pytest which the fleet toolchain lacks — 11 assertions on `distill.py`, the
distiller `fleet-gather.sh` pushes to every box over ssh, never run by anything.
It is now `tests/distill_cases.py` plus a `distill.test.sh` wrapper: the only
pytest feature it used was the `tmp_path` fixture, and the file supplies that
from `tempfile` itself. `justfile.test.sh`'s stray-name assertion still covers
`.sh` only, but now because that is the whole population, not because one file
is excused.

Don't write the suite count into prose — it moved three times on 2026-08-03
alone, and a stale count in a doc is how "27 suites" and "28 suites" ended up in
this same file. `just test` prints the count it actually ran; that is the number.

**The suite was GREEN, 0 failures, as of 2026-09-11** — the count that used to
stand here recorded four different values in nine days while at most two suites
were ever added or removed, so most of that movement was miscounting, not the
repo changing. There is no way to reconcile it after the fact, which is the whole
argument three paragraphs up for not writing counts into prose. Keep the
paragraph anyway: green-or-red is the only validation the repo has since the Nix
gate went, and a red suite gives no signal at all. For the count itself, trust
only what `just test` prints in front of you.

**"Known environmental failure" is not a category — it is an unread bug report.**
Two suites carried that label for a month (`expansion-multibyte.test.sh` and
`fleet-ssh-config-ps.test.sh`) and were repeated as a baseline in session after
session. Neither was environmental. The PowerShell one needed
`-ExecutionPolicy Bypass`: without it the default policy refused the unsigned
`.ps1` before the module loaded, and the `SecurityError` read as "PowerShell is
broken on this box". The other was reporting a **real unbraced expansion** in
`provision/backup-client.sh`, shipped the day before — while its own premise check
was correctly reporting that the bash behaviour the rule was built on **does not
exist**. Both are fixed; the second is written up in `docs/fleet-roadmap.md` P4.

**One of this file's own claims went with it.** This paragraph used to state, as
settled fact, that an unbraced `"$var…"` is *"fatal under `set -u` in a UTF-8
locale"*. Measured 2026-09-02 on bash 5.3.9 / 5.2.37 / 5.2.15 under `C`, `C.utf8`
and `en_US.utf8`, as `bash -c` and as a script file: it is not, anywhere. bash's
identifier scan is ASCII-only in every build, so no locale could ever have made it
so. The brace rule is kept anyway — it costs two characters and the original
failure's real cause is still unknown — but it is style plus defence-in-depth, not
a reproduced bash bug. **If you are about to repeat a mechanism from this file in a
commit message, that is the moment to measure it.**

## Architecture

### Top-level directories

| Dir | What it is |
|---|---|
| `provision/` | Cross-platform provisioner — `provision.{sh,ps1}` role front door, `roles/*.{sh,ps1}` executors, `lib/` manifest readers (`fleet.sh`, `Fleet.psm1`, `tiers.sh`), `linux.sh`/`macos.sh` tier drivers, `statusboard/`, `gortex.version` (the pinned gortex release), `tests/`. See `provision/README.md`. |
| `agents/` | Version-controlled agent config — `plugin/` (skills, subagents, hooks, commands), `subagents/`, `git-hooks/`, `bootstrap.sh`, `worktree-{setup,teardown}.sh`, `tests/`. The three `orca-profile-*.sh` scripts were deleted 2026-09-09 (see *Common Commands* above). See `agents/README.md` and `agents/docs/git-workflow.md`. |
| `scripts/` | `converge.sh` (convergence engine) + `converge.test.sh`, `update-gortex.sh` (bumps the pin). |
| `hosts/` | Per-machine, per-platform ops scripts: `hosts/<name>/<platform>/`. |
| `docs/` | `fleet-roadmap.md` is the live backlog; `superpowers/plans/` holds plans and specs. |
| `backup/` | The fleet's restic profiles, one dir per **identity** — `backup/<identity>/` where identity is a `fleet.json` machine (`latitude`) or a `fleet.local.json` nickname (`desktop-wsl`), one flat namespace. Each dir ships `profiles.yaml` plus its own `install-tasks.sh` / `.ps1` — and inherits the shared `backup/base.yaml`, installed by `backup/restic-install.sh` / `.bat` — because scope is not derivable by the caller: latitude's profiles are `schedule-permission: system` and need sudo, a WSL client is user-scope and must NOT be root. Moved here from `vps` 2026-09-01. |
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
  **All of that is Dell-specific and inert on the ASUS box**: measured on g513ie
  2026-09-08, `BAT0` exposes `charge_control_end_threshold` and nothing else — no
  start threshold, no `charge_types` — so the mode write never happens and
  `CHARGE_START` has nothing to write to. The ceiling still applies (85, unit
  enabled, exit 0).
  **On BOTH posix profiles since 2026-09-08, and the axis is mains, not
  profile** — latitude (`server`) and g15 (`workstation`) both live on AC.
  `workstation` used to omit it as "a laptop someone carries", which described
  `air` and was untrue of both workstation laptops the fleet has. `air` is
  excluded by being darwin: `macos.sh` has no battery tier and could not share
  this one, which writes `/sys` nodes macOS lacks. It needs root, so on a box
  with no NOPASSWD sudo (g15) it warns and skips on every non-interactive run —
  applying it there means `bash provision/linux.sh` at that keyboard.
- **`tier_lid_ignore`** — the other half of the same hardware story, and it exists
  because the 2026-08-03 review found the flagship gap: latitude's no-lid-sleep
  config was a hand-written `/etc/systemd/logind.conf.d/99-server.conf` that
  **nothing in the repo wrote**, so a reinstall following the repo produced a
  services host that suspends on a lid close, silently. On **both posix profiles**
  for the mains reason above. It writes two keys — the other two latitude's hand
  file sets are systemd defaults already — and it **masks no sleep target**, so a
  deliberate `systemctl suspend` still works on a box someone sits at. It gates on
  `/proc/acpi/button/lid` rather than on a platform check (absent in a WSL distro
  and on the VPS, so both are no-ops), and it **reloads** logind rather than
  restarting it: `CanReload=yes` on both fleet systemds, and a restart is the one
  that can take a live graphical session with it.
- **`tier_oom_guard`** / **`tier_sysrq`** — the two halves of the 2026-09-09
  lockout, and **workstation-profile only**. A 23 GB scratchpad script froze g15
  twice in fifteen minutes; the first time the box came back only on the power
  button. The mechanism is the part worth carrying: the kernel OOM killer never
  fired, because grinding an 8 GB **disk** swapfile keeps global reclaim
  reporting progress — **more swap buys a longer freeze, not more headroom**. So
  `MemorySwapMax` is the load-bearing key of the drop-in `tier_oom_guard` writes
  at `/etc/systemd/system/user-.slice.d/`, not the two memory ceilings beside it
  (60% / 75% of `MemTotal`, floor 8 GiB, both computed at provision time).
  `systemd-oomd` is not an alternative: it was monitoring `user@1000.service` at
  50% pressure / 20 s throughout and never acted, and it kills whole cgroups.
  **Writing the file is not owning the value**: `/etc/sysctl.d` is applied in
  lexical order, last setting wins, and the incident-night hand fix on g15 was
  named `60-sysrq.conf` — which sorts AFTER the tier's `60-fleet-sysrq.conf` and
  therefore overrides it. Found still in place 2026-09-11, harmless only because
  the two values agree. `tier_sysrq` now warns about any competing file (and
  deletes none — the 99-server.conf precedent); `tier_oom_guard` does the same
  for a user-scope `*.slice.d` drop-in, which a `systemctl show
  user-<UID>.slice` readback cannot see at all.
  The `user-.slice` template **cannot reach `system.slice`**, which is what makes
  the ceiling safe to install unattended — immich and postgres are structurally
  out of range. `tier_sysrq` sets `kernel.sysrq=1` so `Alt+SysRq+F` and `REISUB`
  work at all; g15's value was 176, i.e. every bit except signalling.
  **Both omit `server`, each for its own reason** — the ceiling because
  latitude's user-slice peak has never been measured and a guessed `MemoryMax`
  on the services host is an incident, the hatch because an escape hatch needs a
  human at that keyboard. Measure latitude before "fixing" the asymmetry.
- **`tier_gortex`** — installs the release named in `provision/gortex.version`
  into `~/.local/bin`, resolving the asset per platform (linux_amd64,
  darwin_arm64, darwin_amd64). It untars the pinned release **unconditionally,
  with no version comparison**, so the pin is authoritative: a box updated out of
  band (`gortex upgrade`) is silently reverted to the pin by the next provision
  run for any reason. Fix a drift by bumping the pin, never by teaching the tier
  to disobey it.
- **`tier_docker`** — installs the engine from Docker's own apt repo on the
  `workstation` profile, and encodes two fleet traps rather than a hardware one.
  It **never upgrades**: `apt-get install -y docker-ce` against an older
  installed package would restart dockerd, and latitude runs immich on one — so
  the tier is inert wherever `dockerd` exists, which is what lets it live in a
  driver's tier list. And it **skips a WSL distro**, where Docker Desktop owns
  the engine and `provision/wsl-fixes.sh` owns the CLI behind a `dpkg-divert`;
  the WSL check reads `/proc/version`, never `$WSL_DISTRO_NAME` alone (sshd does
  not set it, and that failure direction installs a daemon). It probes
  `dists/<codename>/Release` before writing the apt source, because a source
  naming an unpublished suite breaks every later `apt-get update` on the box.
  Pinned by `provision/tests/docker-tier.test.sh` (8 live branch cases, A–H —
  Case H, a failed key fetch, was added in `787882b`).
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

**Two roles have no executor at all**: `base` and `ssh-server`.
`provision/roles/` holds `agents`, `dotfiles`, `repos` and — since 2026-09-01 —
`backup-client` (`.sh` **and** `.ps1`) and `backup-hub`. For the remaining two
there is **no stub file of any kind**: nothing of theirs prints "not yet
implemented", that message comes from `provision.sh`'s absent-function arm. The
capability exists in hand-rolled forms elsewhere (`windows.ps1` step 6,
`tier_ssh_trust`), which is why this can read as done. It is not — roadmap P3.

Since 2026-08-05 that gap is **declared, not silent**: `provision.sh` carries a
`PLANNED_ROLES` list naming them, and a role that is neither implemented nor
named there makes `--apply` exit 1. Before that, `just provision --machine
latitude --apply` reported success while doing nothing for four of its seven
roles. **Implementing a role means DELETING its name from `PLANNED_ROLES`** —
leave it in and the new executor is never demanded of a box that lacks it. Done
twice so far, both on 2026-09-01, by the two backup roles.

**The Windows front door has the same guard since 2026-09-02** — it went a month
without one. `provision.ps1` resolves roles through a `$RoleExecutors` map, and a
role missing from it used to print "not yet implemented (skipped)" and leave
`$rc` at **0**: provisioned nothing, reported success. It now carries
`-PlannedRoles`, defaulting to `base ssh-server`, and an undeclared role with no
map entry fails `-Apply`. **A parameter, not an environment variable, and that is
not a style choice** — on Windows `$env:X = ''` *removes* the variable, so
"declared as empty", the lever the posix suite pulls with
`MACHINES_PLANNED_ROLES=""`, cannot be expressed in the environment at all.
Adding an executor for a Windows role still means adding its map entry; the
difference is that forgetting is now loud.

It also gained the **unknown-machine** gate the posix side has had since
2026-08-01. Without it `Get-FleetRoles` returned `$null`, `foreach` over `$null`
iterated zero times, and `-Machine typo` exited **0** having printed no roles at
all. `Test-FleetMachine` in `Fleet.psm1` closes it, exit 2, message for message
with `provision.sh`. Both arms are pinned by
`provision/tests/provision-ps-guards.test.sh`, which asserts the exit codes
rather than the messages and was mutation-tested against each guard's removal.

One trap that bit while writing it: **`Write-Error` cannot implement a guard
here.** `$ErrorActionPreference` is `Stop`, so it throws and the process exits 1
before ever reaching `exit 2` — the pre-existing `no machine selected` arm had
been doing exactly that. Use plain stderr, then `exit`.

### Fleet networking / tailnet architecture

The fleet transport is a self-hosted **Headscale tailnet** (`cc.cyphy.kz`,
MagicDNS suffix `gg.ez`, CGNAT `100.64.0.0/10`); `fleet.json` (repo root) is
the machine manifest. The old AmneziaWG mesh was retired from the repo
2026-07-17 (AmneziaWG survives only as the VPS's obfuscated VPN for RU
relatives).

**One LAN, not two.** Every member except `hub` sits behind the same router —
some on wifi, some on cable — and gets direct P2P. Measured with `tailscale
ping` on 2026-09-07 from `desktop-wsl`: latitude direct via 192.168.8.155 in
2 ms, g15 direct via 192.168.8.170 in 3 ms, hub direct via its public IP in
6 ms. Throughput follows: 99 MB/s desktop-wsl -> latitude over the tailnet.

This paragraph used to say "two separate LANs… cross-LAN pairs relay through our
own DERP — expected and accepted", and that sentence did real damage: it is why
a migration design initially wrote latitude off as a 7-hour target when it is
the fastest one in the fleet. **"Expected and accepted" is how a stale
measurement survives** — if you catch a relayed pair, measure it before
accepting it.

**The one genuine exception was `g15-wsl`, destroyed 2026-09-07 — but the
property outlives the distro and applies to any NATed WSL2 distro.** A distro in
NAT networking mode cannot punch through to another NATed peer, so `tailscale
ping` reported `direct connection not established` and the pair sat on DERP at
3.3 MB/s. `desktop-wsl` has no such problem: its `.wslconfig` sets
`networkingMode=mirrored`, so it holds a real LAN address. **Do not reach for
mirrored as the fix** — it also exposes the Windows Tailscale adapter inside the
distro, and a box with both a Windows tailnet node and a distro node then has two
routes to fight over (the warning is written out in desktop's own `.wslconfig`).
Two routes that do work from a NATed distro: reach it through its Windows host's
sshd over the LAN (44 MB/s), or have it push outbound to a LAN peer, which NAT
permits.

Self-declared WSL hosts are first-class fleet hosts that never appear in
`fleet.json`: each carries a gitignored `fleet.local.json`
(`{nickname, fleet:true, platform, dispatch, parent}`), written by
`provision/fleet-local.sh` as step 4 of `just provision-wsl <nickname>` (chain:
`tailscale-wsl.sh → ssh-wsl.sh → linux.sh → fleet-local.sh → wsl-fixes.sh`).
Its Windows parent discovers it live via `wsl -l -q` + reading each distro's
`fleet.local.json`. Only a `dispatch:direct` distro (the one that owns the
tailnet node, at most one per Windows host — WSL2 distros share one network
namespace) is reached directly at `<nickname>.gg.ez`; every other distro is
`dispatch:parent`, reached as `wsl.exe -d <distro>` through its Windows
parent — not through a `fleet.json` entry either way. The shared dispatch primitive
`agents/plugin/skills/lib/fleet-dispatch.sh` (`fd_probe`/`fd_run`/
`fd_wsl_hosts`) is sourced by both `/ship`'s `fleet-pull.sh` and memory-harvest's
`fleet-gather.sh`; it also handles the Windows-native members by dispatching
through Git Bash via PowerShell's call operator, keyed on `platform: windows` in
`fleet.json` — which means **`desktop` and only `desktop`**. `g15` was a Windows
member from 2026-08-27 until the 2026-09-07 reinstall; its manifest platform is
`debian` now, so it is dispatched as a posix member like any other.

**A WSL distro cannot ssh to its own Windows host** (proven 2026-08-30: from
`desktop-wsl`, `desktop.gg.ez:22` times out, while the same address answers
from `latitude`). So for exactly one Windows member — the one the calling box
runs on — `fd_probe`/`fd_run` skip the network and invoke Git Bash through WSL
interop instead. Which member that is is **declared**, in `fleet.local.json`'s
`self.parent` (`fleet-local.sh --parent <alias>`, threaded through
`provision-wsl.sh`). Two things it deliberately is NOT:

- **Not inferred from a hostname.** `detect.hostname` is the *WSL* name on
  `desktop` (`g614jv`) and the *native* name on `g15` (`g513ie`), so no single
  comparison is right for both — a match on one box is a coincidence.
- **Not gated on `$WSL_DISTRO_NAME`.** sshd does not set it, so a `/ship`
  started over ssh *into* the distro read it empty and fell back to the
  network. The gate is `/proc/sys/fs/binfmt_misc/WSLInterop` — the binfmt
  handler that makes a `.exe` executable at all, i.e. the actual precondition.
- **Not a fallback on a failed ssh.** From `desktop-wsl`, `ssh g15` also fails
  whenever `g15` is asleep; falling back there would run the script against
  *desktop's* Windows clone and print it as a green `g15` row. A right-looking
  row on the wrong machine is worse than `SKIP unreachable`.

`fd_wsl_hosts` is deliberately left on ssh: it only enumerates a parent's
distros, and making it interop-aware would unmask a second bug — `fleet-pull`'s
`self_alias()` reads `fleet.json` by tailnet IP, so a self-declared WSL host is
`self: unknown` and would try to pull itself.

**Gotcha:** a self-declared WSL host has no `fleet.json` entry, so the generated
`~/.ssh/config` has no `Host` block for its bare name — only the catch-all
`Host *.gg.ez`. From `air`, `ssh desktop-wsl` falls through to the default
identity and fails; `ssh desktop-wsl.gg.ez` is the form that resolves.

**But `desktop-wsl` answers on port 2222, not 22** — and until 2026-09-07 it
answered on neither, for five weeks, while this file said it worked.
`.wslconfig` puts that distro in `networkingMode=mirrored`, so it shares the
Windows adapters and its `ssh.socket` lost the bind on `0.0.0.0:22` to the
Windows OpenSSH server. systemd reported that as `Dependency failed for
ssh.service` on every boot from 2026-08-29 on, and nothing looked. A drop-in at
`/etc/systemd/system/ssh.socket.d/override.conf` moves it to 2222, spelling out
**both address families**: a bare `ListenStream=2222` bound only `[::]:2222`
here, and an IPv4 client got `Connection refused` rather than a timeout, which
is a different symptom from the firewall's. Reaching it from another box over
the LAN also needs an inbound Windows firewall rule (`New-NetFirewallRule
-LocalPort 2222 -RemoteAddress 192.168.8.0/24`), because in mirrored mode the
Windows firewall governs the distro's ports; over the tailnet no rule is needed.
The override is **tracked since 2026-09-07** at
`hosts/desktop/wsl/ssh-socket-override.conf` (`01cc091`) — copy it, do not
rewrite it from scratch — but **nothing provisions it**: `wsl-fixes.sh` is the
named owner and carries no `2222`/`ssh.socket` arm yet, so reprovisioning
desktop-wsl still does not restore it.

**And it was declared `dispatch:direct` until 2026-08-31, which is how those five
weeks stayed quiet.** `fd_probe` keys on that field, so every fleet-wide run
(`/ship`, memory-harvest) resolved the name, got refused, and printed
`SKIP unreachable` while the run itself stayed green — a successful `tailscale
ping` proves nothing about reachability here. It is `dispatch:parent` now,
reached as `wsl.exe -d desktop-wsl` through `desktop`. Two consequences of
mirrored mode that follow from this: the distro's own tailnet node
(`100.64.0.6`) is still registered but no longer load-bearing, and reverting
`networkingMode` is not the fix — besides the route fight above, NAT breaks the
WSL projects' reach to the VPN-only `10.99.x` hosts, which is why mirrored was
chosen in the first place (its `.wslconfig` comment records that).

### Host configurations

`hosts/<name>/<platform>/` — per-machine ops scripts, no build system.

**`hosts/latitude/debian/`** — the services host's recurring jobs and its boot
guards. All of them are worth reading headers-first; they record decisions that
are not re-derivable from the code.

- `mirror-refresh.sh` — `/mnt/immich` → `/mnt/immich-mirror`. Why live PGDATA is
  excluded (an rsync of a running postgres dir is a torn copy that *looks* like a
  backup), why `-H` is mandatory, why `--delete` is off.
- `archive-mirror.sh` — the closed 1970–2024 archive → **`/mnt/immich-2024-backup`**
  (the HGST; it was `/mnt/xs` until that stick left the box 2026-09-09, and the
  header records why). Destination is ext4 now, so the exfat concessions are
  history — kept in the header because the exfat verification itself (no
  hardlinks, no illegal filenames, exfat's ceiling far above FAT32's remembered
  4 GiB) is what proved them unnecessary. Also records why the *source* dock was
  the flaky one through July–August, and why `--partial-dir` rather than
  `--append-verify`.
- `install-timers.sh` + `systemd/` — installs all **three** as system timers
  (`mirror-refresh`, `archive-mirror`, `restic-hub-selfcheck`). It **copies**
  units into `/etc/systemd/system` rather than symlinking, so a `git pull` cannot
  change what root runs on a timer without review.
- `install-docker-ordering.sh` — the three guards that keep containers from
  starting before the host is ready. **Read this one before touching anything
  about latitude's mounts, docker, or a compose file that binds `/mnt`.** Its
  `MOUNTS` array is a live-derived fact, not a preference: see the bind-source
  race in *Key patterns* below.
- `restic-hub-selfcheck.sh` — the third timer, and the only thing that catches the
  restic REST hub serving an **empty bind**. It must run as root: the repo dirs
  under `/mnt/spare320/restic-rest/` are `drwx------ root:root`, so an unprivileged
  run reports healthy repos as MISSING; it exits **2** for non-root, distinct from
  **1** for a real check failure, and `role_backup_hub` sudo-wraps it.
- `disk-acceptance.sh` — the two-gate intake for a new drive (`identity`, on the
  shop's return clock, strictly before `surface`/`badblocks -w`, on the warranty
  clock). The order is the point: the 2026-07-30 fraud sold a 2015 HGST as a new
  6 TB WD Purple, and a surface test alone passes such a drive.
- `smart-long.sh`, `migrate-restic-wd8.sh`, `migrate-servarr-wd8.sh` — one-shot
  and periodic helpers. The two migrators share a two-pass shape (bulk rsync live,
  short delta under a stopped stack, `verify`, then `cutover` flips the compose
  `.env`); container-side bind paths never change, so the *arr databases need no
  edits on a host-disk move.

**`hosts/g15/ubuntu/`** — the personal-projects host, reinstalled from Windows 11
on 2026-09-07. Its `README.md` says why the directory is `ubuntu/` while the
manifest says `debian` (the manifest token is a platform *class*). Also holds
`compose.override.yml` + `install-compose-override.sh` for qaz-code, and
`rustdesk-seed.sh`.

`hosts/desktop/windows/` carries `install.ps1`, the reinstall runbook and
`winget-packages.json` — **no backup or restore script** (see *Repository
Overview*: both were deleted 2026-07-31). `hosts/desktop/wsl/` carries the
`ssh.socket` 2222 drop-in and its README.
(`hosts/server/` was deleted with the decommission — git history has it.)

### Key patterns

- **Behaviour goes in a `tier_*` function** in `provision/lib/tiers.sh`, driven by
  `linux.sh` / `macos.sh`. Both drivers run the same tier bodies; only the driver
  path differs.
- **Roles are declared in `fleet.json`** and executed by `provision/roles/<role>.{sh,ps1}`.
  A role with no executor fails `--apply` with rc=1 unless it is named in
  `provision.sh`'s `PLANNED_ROLES`; a dry run prints the same warning and still
  exits 0, because a preview writes nothing.
- **Mount every external drive by UUID, never by `/dev/sdX`.** Every letter
  reshuffles across a reboot on latitude (five external USB devices plus a card
  reader race to enumerate) and one enclosure reports a fake serial. Only one of
  the five is bus-powered — the XS2000 stick; the four spinners sit in two
  self-powered Ugreen CM198 docks (measured 2026-09-07, correcting a
  "bus-powered" claim this file and `project.md` both carried).
- **Docker CREATES a missing bind source, and that is the fleet's most expensive
  failure mode.** A container that starts before its disk mounts does not error —
  it silently gets an empty auto-created dir on the root filesystem, the disk then
  mounts over the top, and the host looks perfectly healthy while the service
  serves nothing. It has now happened twice: servarr on 2026-08-03 (Jellyfin
  playback 404'd for a day) and immich-2024 on 2026-09-03 (five days of ENOENT on
  every 2007–2024 photo download, with the container reporting `(healthy)` and
  IntegrityService logging ~20,400 missing files nightly to nobody). The guards
  live in `hosts/latitude/debian/install-docker-ordering.sh`; two rules follow
  from them:
    - **Adding a `/mnt` bind to any compose file means adding that mount to
      `MOUNTS`.** The second incident happened because the array excluded
      immich-2024 on the belief that it "belongs to the rsync timers" — true of
      its other job, false about who binds it, and never re-checked. Derive the
      list from live binds, never from what a disk is *for* — and derive it from
      **`.Mounts`, not `.HostConfig.Binds`**. This file said `.HostConfig.Binds`
      until 2026-09-10, and that recipe cannot find the mount it was written
      about: immich's compose uses the long `volumes:` syntax, so
      `docker inspect -f '{{json .HostConfig.Binds}}' immich_server` returns
      **`null`** while `.Mounts` holds 22 bind entries, 19 of them year-dirs
      under `/mnt/immich-2024`. A remedy that reproduces its own incident is
      worse than no remedy. The working form is
      `docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}}{{println}}{{end}}'`,
      filtered to `bind`.
    - **The mountpoint dirs underneath the mounts are `chattr +i`.** That is
      deliberate: it turns Docker's auto-mkdir into EPERM so a missing disk stops
      the container visibly instead of emptying it invisibly. A mount still covers
      an immutable dir (measured), and `lsattr` at the mountpoint path shows no
      `i` while mounted — you are reading the mounted fs, not the frozen inode.
      Never `chattr -i` one by hand. `-off` is the symmetric revert of the whole
      installation — but it is the WRONG tool for retiring one mountpoint, and
      that trap is now closed. It also strips the DNS pin from `daemon.json` and
      restarts dockerd, bouncing immich and postgres to unfreeze a directory.
      **Retiring a mount is: delete it from `MOUNTS`, run the script.** Since
      2026-09-10 `add` unfreezes any frozen `/mnt/*` dir that is not in the
      array, so removal and addition are the same one action. Before that,
      deleting a name left its mountpoint immutable forever with nothing in the
      repo saying so — the array and the disk could disagree indefinitely.
    - **A stale fstab line used to switch this whole guard off**, and the fix is
      worth knowing because it changes what a red run means. `fstab_apply`
      refused its candidate whenever `findmnt --verify` reported anything at all,
      anywhere in `/etc/fstab` — and an unplugged removable drive reports as
      `[E] unreachable on boot required source`. So one dead entry disabled the
      ordering guard for every other mount; the `/mnt/xs` line had to be
      commented out for exactly that reason. The gate now compares candidate
      against current and refuses only findings its own edit introduced. It still
      refuses outright on `rc >= 2`: util-linux 2.41's `findmnt --verify`
      SEGFAULTS (139) on an fstab entry with fewer than three fields, and a
      crashed checker emits no findings to compare — "unknown" is not "fine".
      `provision/tests/docker-ordering.test.sh` covers the decisions (28 cases);
      the root-only halves — `chattr`, the bind mount of `/`, `systemctl` — are
      not and cannot be there.
- **A failed `Condition*` is `Result=success`, so never gate a backup
  DESTINATION on one.** systemd *skips* a unit whose condition fails rather than
  failing it, and the timer then reports success forever. `mirror-refresh.service`
  carried `ConditionPathIsMountPoint=/mnt/immich-mirror` to "skip cleanly when a
  dock is unplugged"; on 2026-09-10 that disk dropped off the bus at 16:30 and
  the job reported success for 90 minutes while nothing was mirrored, found by
  looking rather than by any alert. Both mirror units are Condition-free now and
  check their mounts **by UUID inside the script** — `findmnt -no SOURCE` only
  proves *something* is mounted, and `/mnt/immich-mirror` is not in `MOUNTS`, so
  nothing else stands between an absent destination and half a terabyte written
  onto `/`. **A missing mount is remounted once (`nofail` is boot-only); a wrong
  one is never touched, and a mountpoint a container binds into is never
  `umount`ed** — clearing a stale mount that way is for copy destinations only.
  Measured 2026-09-10: `/mnt/immich` and `/mnt/immich-2024` both carry live
  binds, `/mnt/immich-mirror` and `/mnt/immich-2024-backup` carry none. So
  `mirror-refresh.sh` never `umount`s at all and `archive-mirror.sh` does so
  only for its destination. `umount` on a bound tree usually fails `EBUSY`, but
  "usually fails" is not a guard.
- **Two failures must not share one exit status.** `flock -n` returns **1** on a
  lock conflict and both mirror scripts used 1 for "the mount is wrong", so a
  routine collision and a vanished backup disk were the same `ExecMainStatus`.
  The convention on the shared `/var/lock/latitude-mirror.lock` is now
  **75 = lock held** (`flock -E 75`), **78 = mount is not the expected
  filesystem**, everything else rsync's — change one number and you change the
  other. `provision/tests/latitude-timer-units.test.sh` pins both this and the
  Condition rule (mutation-tested, 7/7).
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
- **It never sleeps, by design**, and since 2026-09-08 half of that is
  reproducible. The lid half is `tier_lid_ignore`, on both posix profiles:
  `HandleLidSwitch` and `HandleLidSwitchExternalPower` `ignore` in
  `/etc/systemd/logind.conf.d/99-fleet-lid.conf` (`HandleLidSwitchDocked` and
  `IdleAction` are already `ignore` upstream, so the tier does not write them).
  Closing the lid must not take immich and the backup timers down with it. The
  OTHER half — `sleep.target` / `suspend.target` / `hibernate.target` **masked** —
  is still a hand-edit, and stays one on purpose: never sleeping AT ALL is a
  services-host decision, and masking those targets on a box someone sits at also
  kills the GNOME suspend menu. **This box also still carries the hand-written
  `/etc/systemd/logind.conf.d/99-server.conf`** the tier supersedes — identical
  values, so nothing changes, and the tier warns about it by name until it is
  deleted (P6). Do not "restore" the old laptop power management.
- Battery charge window 80–85% via `/usr/local/bin/charge-upto` +
  `/etc/default/charge-upto`, installed by `tier_battery_limit`. A laptop held at
  100% on AC 24/7 swells its cell, which is the whole point.
- Five external USB drives on two docks, and **two different failures that must
  not be conflated.** `disconnect` on BOTH docks in the same second is mains —
  eight such events 2026-07-29..09-10, the docks' cheap 12 V bricks dying on a
  dip the laptop's own battery rides through (`ACPI: AC Adapter (off-line)`
  fired exactly once in that window, and not at a drop). This is the one that
  recurs; a UPS on the dock bricks closes the class, spreading copies across
  docks does not — the wall takes both at once. `reset` on ONE dock under load
  is link or enclosure: 25 of them on `4-2` in the 31.07→02.08 storm, whence
  `UDMA_CRC_Error_Count` 144 on `sdf`. **That storm has not recurred since
  17.08** — 16 TB through 4-2 in 26 h with zero CRC and zero resets — so do not
  read "4-2 is the flaky dock" as a standing property. Guard by UUID and expect
  mid-run drops either way. Topology as of 2026-09-10: `u4-1` spare320 +
  `/mnt/immich-2024-backup`, `u4-2` wd8 + immich-2024, `u3-2.4` immich-mirror in
  the NS1066 stopgap.
- No Docker prune timer. 18 images / ~15 GB, only 3% reclaimable, so the gap is
  currently free. If one is ever added it **must never gain `--volumes`**: three
  of the seven volumes are live immich/postgres data.
