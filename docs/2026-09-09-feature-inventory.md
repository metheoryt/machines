# Feature inventory — what `machines` costs to keep

**2026-09-09.** A survey, not a plan. No code changed. Baseline: `just test`
green, **54 suites, 0 failures**, run at the start of this survey.

## Why the columns are what they are

The stated goal is a repo that is *not overwhelmed with features and things that
need to be remembered*. Code size does not measure that. So each row carries six
columns, and the one that maps to the actual complaint is the prose column.

| Column | Source |
|---|---|
| **impl** | `wc -l` of the subsystem's non-test files |
| **test** | `wc -l` of its `*.test.sh` / `test_*.py` |
| **live prose** | matching lines in `AGENTS.md`, `README.md`, `.claude/memory/project.md`, `docs/fleet-roadmap.md`, `provision/README.md`, `agents/README.md` — the surface a session or a human actually loads |
| **archive prose** | matching lines in `docs/superpowers/**`, `docs/2026-*`, `docs/fleet-mesh-history.md`, `review/` — written once, auto-loaded by nothing |
| **hosts** | which fleet members exercise it, derived from `fleet.json` roles and the live tier plans (`MACHINES_TIERS_DRY_RUN=1` per profile) |
| **last / c30** | `git log -1` and commits in the last 30 days over the subsystem's files |

Every number is from the tree or from `git log`. **Nothing is sourced from our own
prose**, deliberately: `AGENTS.md` records its own text asserting false things
repeatedly (two LANs, the `set -u` multibyte claim, "28 suites", the
machines-vs-vps contradiction, "known environmental failure"). Where prose and
tree disagree here, the disagreement is logged as a finding.

The 22 rows partition **every** tracked `.sh`/`.ps1`/`.py`/`.psm1` file plus the
`justfile` and the four git hooks — verified by set difference, no file claimed
twice, none unclaimed.

## Baseline

| | lines |
|---|---|
| implementation | 17,418 |
| tests | 10,026 (0.58 × impl) |
| **live prose** | **5,916** across 6 files |
| archive prose | 45,111 across 94 plans/specs + 3,394 in other docs |

Two numbers worth separating before anyone quotes them together. The 45k of
plans and specs is **two thirds of the repo's markdown and is loaded by nothing** —
deleting it cuts disk and grep noise, not remembered surface. The remembered
surface is the 5,916 lines, of which `.claude/memory/project.md` is 3,136 and
`AGENTS.md` is 600.

## The table

Sorted by live prose — remembered cost, highest first.

| subsystem | impl | test | live | arch | hosts | last | c30 |
|---|---:|---:|---:|---:|---|---|---:|
| wsl | 1172 | 775 | **330** | 1647 | desktop (1 distro) | 09-08 | 5 |
| orca | 2350 | 1063 | **175** | 564 | air, g15, desktop | 09-07 | 5 |
| windows-provision | 784 | 169 | 163 | 869 | desktop | 09-08 | 6 |
| tailscale † | 163 | 0 | 124 | 988 | all 5 | 07-27 | 0 |
| backup-restic | 611 | 284 | 101 | 519 | latitude, g15, hub, desktop-wsl | 09-08 | 11 |
| gortex-pin | 409 | 305 | 97 | 332 | latitude publishes; air, g15 consume | 09-03 | 5 |
| dotfiles-sync | 967 | 807 | 96 | 1126 | all 5 | 08-29 | 4 |
| role-frontdoor | 1429 | 725 | 87 | 537 | all 5 | 09-08 | 16 |
| converge | 397 | 619 | 83 | 498 | 4 posix | 08-03 | **0** |
| tiers-engine | 1830 | 847 | 67 | 226 | 4 posix | 09-08 | 8 |
| worktree | 334 | 378 | 62 | 346 | dev boxes | 08-01 | **0** |
| agent-bootstrap | 800 | 370 | 50 | 335 | all 5 | 09-08 | 8 |
| ssh-trust | 41 | 219 | 27 | 78 | all 5 | 09-07 | 4 |
| g15-staging | 484 | 450 | 27 | 190 | **none — g15-wsl is deleted** | 09-07 | 6 |
| ship-dispatch | 378 | 683 | 23 | 328 | all 5 | 08-30 | 2 |
| latitude-hostops | 1207 | 147 | 23 | 66 | latitude | 09-08 | 4 |
| test-infra | 258 | 295 | 20 | 55 | repo | 09-07 | 2 |
| memory-hooks | 317 | 290 | 17 | 207 | all 5 | 08-24 | 2 |
| kb-refresh | 610 | 406 | 16 | 244 | all 5 | 08-03 | **0** |
| git-hooks | 86 | 46 | 14 | 102 | all 5 | 08-01 | **0** |
| statusboard | **3856** | **1822** | **11** | 17 | **latitude only** | 09-08 | 3 |
| prose-hedge | 107 | 101 | **0** | 0 | all 5 | 09-02 | 1 |

† **The `tailscale` row's impl is not comparable.** Only `tailscale-mac.sh` is
filed here; the rest of the transport lives inside `tier_fleet_ssh`,
`tailscale-wsl.sh` (counted under wsl) and `fleet-ssh-config.ps1` (counted under
windows-provision). Its 124 live and 988 archive prose lines are the real signal:
networking is the repo's most-described cross-cutting concern and has no single
owner file.

## Verdicts

### Delete — no consumer exists

**`g15-staging`, 934 lines (484 impl + 450 test).** A one-shot Windows→Linux
payload move for a migration that completed 2026-09-07. Its own header says
*"RUNS ON g15-wsl, AS ROOT"* — a distro deleted the same day. Every path it
encodes (NAT-mode DERP throughput, port 2222 to desktop, uid 999 pgdata) is
already written into `AGENTS.md` and the design spec. Six commits in the last 30
days, all of them the migration itself. Nothing calls it; nothing can.

**`prose-hedge`, 208 lines.** A session hook with **zero** lines describing it in
any tracked prose, live or archive. It is the only row that scores 0. Either it
earns a sentence or it goes; an undocumented hook that rewrites how replies read
is exactly the class of thing that "needs to be remembered" and isn't.

Cold-surface residue, small but worth one sweep: `g15-wsl` is still named in 11
tracked files and `nixos-rebuild` / `/etc/NIXOS` in 10, five weeks after the last
Nix host went. Most are comments; the live ones are dead branches
(`agents/bootstrap.sh:547,704`, `agents/git-hooks/_refresh-claude-config:15`) for
a platform with zero hosts. `scripts/converge.sh`'s `nixos` arm is the deliberate
exception — it refuses explicitly, and folding it into `linux` would run the apt
driver on a Nix box. Keep that one.

### Replace with off-the-shelf

**`statusboard` — 5,678 lines, 20% of all shell in the repo, for one host.**
The extreme outlier on every axis: highest code, near-lowest prose (11 live
lines), a single consumer (`server` profile → latitude), and a display *nobody
sits at*. `tier_rapl_read` exists solely to widen a root-only energy counter so
the board's power row works, and `statusboard-gui.sh` is 749 lines of kiosk
compositor plumbing. **netdata** covers the whole surface — disks, SMART, temps,
RAPL power — zero-config from apt, with its own systemd unit; the kiosk becomes a
browser in kiosk mode on tty1. This is the single largest code win in the repo
and it touches one machine. What must be carried across, not lost: the
per-host disk config (`disks.latitude5520.conf`) encodes UUID-keyed identity for
five external drives on two docks, one of which reports a fake serial. Roadmap P6
already flags `SB_PARKS` as keyed by `sd` node — which is the bug this repo's own
mount rule forbids, and an argument for retiring rather than fixing it.

**`converge` (+ `fleet-selfpull`) — 1,016 lines, test 1.6× impl, zero commits in
30 days.** It pulls the repo, decides whether the change touches a driver,
reprovisions, records `converged-rev`, writes a status file. That is
`ansible-pull`. Off-the-shelf here also brings the change detection and the
status reporting the 619 test lines currently defend by hand.

**`tiers-engine` → Ansible is the highest-risk item on the board, and should be
proposed as "port the loop, keep the traps."** All 24 tier functions are live —
the union across the four profile plans is exactly 24, no dead tiers. But the
tier bodies exist *because* the declarative version got the hardware wrong: the
Dell charge-mode write (the EC honours a threshold only in Custom mode and boots
in `[Fast]`), `tier_docker`'s never-upgrade rule plus its `/proc/version` WSL gate
and `dists/<codename>/Release` probe, `tier_lid_ignore`'s reload-not-restart.
Ansible replaces the driver loop and idempotence; it carries none of that
knowledge. Any proposal that reads "replace `tiers.sh`" is the 2026-08-01 failure
repeated.

### Consolidate — several mechanisms, one need

**`orca` — 3,413 lines (2350 impl + 1063 test), second-largest row.** Three
scripts solve one problem: `orca-profile-sync.sh` (439) pushes config *into*
Orca's per-account profiles, `orca-profile-harvest.sh` (377) copies them *out* as
backup, `orca-profile-link.sh` (308) relocates a profile to `$HOME` and symlinks
it back. `AGENTS.md` already calls link *"the stronger alternative"* to
harvesting — because once a profile is a symlink into `$HOME`, both the push and
the backup are structurally unnecessary. All three were last touched
2026-08-01, together; 1,124 impl + 685 test lines, plus 579 archive doc lines and
95 in `project.md`. Adopting link per-account retires the other two. Cheapest
real win in the repo after the deletes.

**`worktree` + `orca-setup` + `ship-dispatch`.** Three separate answers to "get a
change onto every box / into an isolated tree", all cold (worktree and kb-refresh
at zero commits in 30 days) and carrying 2,000 lines with tests *larger than*
implementation in two of the three. Not a delete — `/ship` is used — but a
candidate for one dispatch primitive instead of three.

### Keep as-is

`role-frontdoor` (16 commits in 30 days — the live centre of the repo),
`backup-restic` (already off-the-shelf: restic + resticprofile; the homegrown
residue is install-tasks and cron escaping), `latitude-hostops` (1,207 lines that
encode the Docker bind-source race — the fleet's most expensive failure mode,
twice), `ssh-trust`, `memory-hooks`, `test-infra`, `gortex-pin`.

`dotfiles-sync` (1,774 lines, 1,222 prose) has **no credible off-the-shelf
replacement** — chezmoi and yadm both lack the debounced auto-commit timer that is
the point — so it stays, but its test-to-impl ratio (0.83 for a git-commit timer)
marks it for a later look.

## Explicitly rejected

**54 bash suites → bats-core.** The most legible refactor available and the least
valuable: it removes zero feature surface, changes zero remembered facts, and
risks the only validation the repo has since the Nix gate went. Named here so it
is not picked up later as low-hanging fruit.

**Deleting `docs/superpowers/plans/`** as a simplification win. It is 45,111
lines and auto-loaded by nothing. Roadmap P5 already tracks it ("45 plans, none
marked done" — now 48 plans + 46 specs). Marking them done is worth doing; it is
not feature reduction.

## Findings — where prose and tree disagree

1. `AGENTS.md` says `hosts/desktop/windows/` carries "install/reinstall + backup
   scripts". There are no backup scripts there: `install.ps1`, a runbook, a
   winget manifest.
2. `AGENTS.md` and `README.md` still reference `hosts/server/`, `nixos-rebuild`,
   `nix flake check` and `just quick` as things a reader might reach for. All
   four are gone; the file warns about them in prose while the surrounding text
   still names them.
3. `hosts/g15/staging/stage.sh` documents itself as running on a host that no
   longer exists, and its test suite passes anyway — the suite tests the script's
   argument handling, not its premise.
4. The `tailscale` row's implementation is spread across four subsystems with no
   owner file, which is why it accumulates the second-highest archive prose
   (988 lines) in the repo.

## Scope boundary

In scope: this repo, including `.claude/memory/project.md` (3,136 lines).
**Out of scope:** `~/.claude/memory/core.md`, `global.md`, the personality facets
and `~/.claude/host-memory.md`. Those are dotfiles-tracked, a different repo —
and `AGENTS.md` records that exactly this boundary confusion "sent a whole round
of backup work to the wrong repo."

## Bottom line

| bucket | impl | test | total |
|---|---:|---:|---:|
| delete outright | 591 | 551 | **1,142** |
| replace with off-the-shelf (statusboard + converge) | 4,253 | 2,441 | **6,694** |
| consolidate (orca) | 816 | 494 | **1,310** |
| **reachable without touching `tiers.sh`** | 5,660 | 3,486 | **9,146** |

9,146 of 27,444 lines — a third of the executable repo — is reachable by three
independent moves, none of which touches the tier bodies where the hardware
knowledge lives. The highest-risk item (`tiers.sh` → Ansible) is therefore not
needed to make the repo materially smaller, and should be decided separately.

Remembered surface is a different axis and moves differently: the wins there are
the four findings above, retiring the `wsl` row's 330 live prose lines down to the
one distro that still exists, and marking the 94 plans done.
