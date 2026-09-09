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

**`g15-staging`, 934 lines (484 impl + 450 test) — DELETED 2026-09-09.** A one-shot Windows→Linux
payload move for a migration that completed 2026-09-07. Its own header says
*"RUNS ON g15-wsl, AS ROOT"* — a distro deleted the same day. Every path it
encodes (NAT-mode DERP throughput, port 2222 to desktop, uid 999 pgdata) is
already written into `AGENTS.md` and the design spec. Six commits in the last 30
days, all of them the migration itself. Nothing calls it; nothing can.

**One live fact had to be carried out before it went**, and it is the reason a
delete this obvious still needs a read. `identity-snapshot.txt` was the only
tracked file recording that the dotfiles branch `origin/g15-wsl` holds
host-local files present on no other branch — and that its second copy,
`latitude:/mnt/immich-mirror/g15-staging/home-me`, went in the staging cleanup
that freed 105 GB. The branch is the last copy. That is now roadmap P6. The
snapshot's other two claims had both gone stale in the meantime — it said
`methe@g15` was kept (it was removed) and `me@g15-wsl` removed (it was
*renamed* to `me@g15`, the same key body, because deleting it would have revoked
g15 from the whole fleet). A record that asserts wrong things is what this
survey exists to cut.

**`prose-hedge`, 208 lines — RESOLVED 2026-09-09: kept and documented, not
deleted.** Reading it changed the verdict. It is registered and live
(`agents/plugin/hooks/hooks.json`), fires only on prose deliverables, is
non-blocking by design, and exists because the CFT-5051 tech solution came back
with three of eight corrections sitting behind hedges the author had written
himself. Its zero prose score was real — re-verified under both `prose` and
`hedge` across the six live-prose files — but the defect was the missing
documentation, not the hook. All seven session hooks now have a line in
`agents/README.md`, which is where the gap actually was: **none** of them was
described anywhere.

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
compositor plumbing. **netdata** is the candidate — disks, SMART, temps
and RAPL power, zero-config from apt with its own systemd unit — with the kiosk
becoming a browser in kiosk mode on tty1. This is the single largest code win in
the repo and it touches one machine.

**But it is a candidate, not a measurement, and it is the only load-bearing claim
in this document not sourced from the tree.** Corrected 2026-09-09, and both
halves of the correction shrink it:

- **The 749 kiosk lines mostly survive a substitution.** The first draft asked
  whether a browser kiosk beats 749 lines "on a box with no X session" — a false
  premise, from prose rather than the tree. `tier_statusboard` installs
  **cage + foot + tmux + fonts-jetbrains-mono + btop + polkitd**, and
  `statusboard-gui.sh` is not display plumbing to be replaced: it is the argument
  for *why the kiosk is a login session* (cage must hold a logind seat to become
  DRM master, so it runs from an autologin getty, and the hook deliberately does
  not `exec` so a crash lands on a diagnosable tty1 prompt rather than a black
  screen — "which this box has already been through twice"). A browser under cage
  inherits the seat, the getty, the failure mode and the font. What a substitution
  actually removes is **the 3,044-line board**, not the 749-line kiosk.
- **RAPL is still unprobed.** Does netdata read `energy_uj` without the
  group-widening `tier_rapl_read` performs? The tier chgrps *only the parent
  domains* and re-runs on every boot and resume, because a sysfs mode is a
  property of the live kernel object. If netdata cannot read it as its own user,
  that tier survives the replacement whole.

**The third option is RETIRE, and it costs least.** Not "keep" and not "replace":
delete the board and install nothing. It needs no daemon, no browser and no
probe, and it banks 5,678 rather than 5,678 minus netdata minus a browser. The
case for it is churn, measured: **43 commits touch `provision/statusboard/`, and
roughly 40 of them are fixes** — the VT ramp, the chart polarity, the comma
locale, the tmux split geometry, the twice-black console. That is the highest
fix-to-feature ratio in the repo, spent on a panel on one box. It also carries an
open bug that is not fixable as designed: roadmap P6 has `SB_PARKS` keyed by `sd`
node — the identity error this repo's own mount rule forbids — and getting it
wrong costs load cycles on a drive already past 639k of them. Retiring closes
that item by deletion.

This is a decision, not a measurement, and it is the user's: nobody has said the
board is unwanted, and it was still being committed to on 2026-09-08. What must
be carried across if it goes either way: `disks.latitude5520.conf` encodes
UUID-keyed identity for five external drives on two docks, one of which reports a
fake serial.

**`converge` (+ `fleet-selfpull`) — 1,016 lines, test 1.6× impl, zero commits in
30 days.** It pulls the repo, decides whether the change touches a driver,
reprovisions, records `converged-rev`, writes a status file. That is
`ansible-pull`. Off-the-shelf here also brings the change detection and the
status reporting the 619 test lines currently defend by hand.

One constraint the replacement relocates rather than removes: converge fires
`linux.sh` detached with no controlling terminal, so on a box without
passwordless sudo (g15) the driver takes its `PRIV=0` path and privileged tiers
warn-and-skip. `ansible-pull` inherits exactly that, and it will be the first
thing to surface on execution.

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
it back. All three were last touched 2026-08-01, together; 1,124 impl + 685 test
lines, plus 579 archive doc lines and 95 in `project.md`. The row's own
`last commit 2026-09-07 / 5 commits in 30 days` belongs to
`provision/orca-serve.sh` (11 commits, live), not to these three, which have 1–2
commits each and have been frozen for 38 days.

**Retracted 2026-09-09 — the repo already adjudicated this and the answer was
no.** The first draft argued that "once a profile is a symlink into `$HOME`, both
the push and the backup are structurally unnecessary", reading `AGENTS.md`'s
*"the stronger alternative"* as *the superseding one*. `review/2026-08-03-path-ledger.md`
rows 134–136 examined all three per-path five weeks earlier, marked each **keep**,
and gave the mechanism reasons — which the code confirms:

- **`sync` is the only one that pushes config IN** (curated skills/commands
  symlinked, `settings.json` merged rather than linked). Relocating a profile does
  not populate it; `orca-profile-link.sh` itself prints
  *"nothing to do; populate it with: bash agents/orca-profile-sync.sh"*.
- **`harvest` is an archive, not a copy**: a one-way rsync with **no `--delete`**,
  so it deliberately keeps files the live profile has deleted, and it detects an
  already-relocated profile and no-ops rather than rsyncing a directory into
  itself. A symlink gives you one live copy; that is not the same artifact.
- **`bootstrap.sh` runs all three, in order** — `link --relink` first so a
  re-auth-broken link is healed *before* `sync` writes into it, then `harvest`
  last. They are mutually aware, not accreted.

So the 1,310 is not a consolidation win. The live question is upstream of the
scripts and only the user can answer it: **is a multi-account Orca still a need?**
`AGENTS.md` records g15 rejoining the fleet on 2026-08-27 precisely so *"a
personal Claude account needs no Orca profile juggling"* — which, if that is now
how it works everywhere, retires all three rather than merging two of them.

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
5. **This is the repo's second inventory, and the first one moved almost
   nothing.** `review/2026-08-03-path-ledger.md` (120 KB, 240 paths, one verdict
   each, produced 2026-08-03) tallies *delete 6, needs-decision 11, merge 2,
   rewrite 86, keep 135*. Checked against the tree today: **18 of those 19
   actionable paths still exist** — only `statix.toml` was actioned, five weeks
   ago. The eleven `needs-decision` rows are all parked on the same sentence,
   some form of *"that is the user's call, not mine"*: `.gemini/settings.json`
   (no box installs the Gemini CLI), `test_distill.py` (pytest is not in the
   fleet toolchain), `agents/plugin/commands/.gitkeep` (a documented extension
   point never populated), and five stale plans/specs. The bottleneck this repo
   has is not measurement — it already had a finer-grained inventory than this
   one. It is that nothing decides.

## Scope boundary

In scope: this repo, including `.claude/memory/project.md` (3,136 lines).
**Out of scope:** `~/.claude/memory/core.md`, `global.md`, the personality facets
and `~/.claude/host-memory.md`. Those are dotfiles-tracked, a different repo —
and `AGENTS.md` records that exactly this boundary confusion "sent a whole round
of backup work to the wrong repo."

## Bottom line

| bucket | impl | test | total | confidence |
|---|---:|---:|---:|---|
| delete — `g15-staging`, provably dead | 484 | 450 | **934** | ✅ done 09-09 |
| ~~delete — `prose-hedge`~~ | — | — | — | kept + documented |
| consolidate — Orca triplicate | 816 | 494 | **1,310** | **contested — a prior review says no** |
| replace — `converge` → `ansible-pull` | 397 | 619 | **1,016** | strong candidate |
| retire *or* replace — `statusboard` | 3,856 | 1,822 | **5,678** | contested (see above) |
| **reachable without touching `tiers.sh`** | 5,553 | 3,385 | **8,938** | |

8,938 of 27,444 lines — a third of the executable repo — is nominally reachable
without touching the tier bodies where the hardware knowledge lives. **But after
the 2026-09-09 corrections above, only 934 of it is done and only 1,016 is still
a clean candidate.** The 1,310 was retracted (a prior review examined it and said
keep) and the 5,678 is a decision the user owns, not a measurement. That is the
honest state, and the drop from a 8,938 headline to 1,950 actionable lines is the
finding, not a setback: two of the three "wins" dissolved on contact with the
tree and the repo's own earlier review.

Which leaves the real conclusion. The lines are not the constraint —
`review/2026-08-03-path-ledger.md` proved five weeks ago that this repo can
inventory itself down to 240 paths and still move only one of them. **Every
remaining item is blocked on a decision, and the decisions are all the same
shape:** is the multi-account Orca still a need; is the panel on latitude worth
its 43 commits; does `.gemini/settings.json` have a user. The highest-risk item
(`tiers.sh` → Ansible) is not needed to make the repo materially smaller and
should be decided separately.

Remembered surface is a different axis and moves differently, and it is where the
uncontested wins are: the five findings above, retiring the `wsl` row's 330 live
prose lines down to the one distro that still exists, and marking the 94 plans
done.
