# Enrolling `hub` into fleet convergence — tiered `provision/linux.sh`

**Date:** 2026-07-25
**Status:** design, approved for planning

## Problem

`hub` (the Debian 12 VPS at `cyphy.kz`, tailnet `100.64.0.1`, OS hostname
`27608`) is already a first-class `fleet.json` member with roles
`base, ssh-server, agents, dotfiles, backup-client` — but **none of those roles
was ever applied on the box**. Verified live 2026-07-25:

- no `~/machines` clone (only `~/vps` and `~/caddy`),
- no global git identity, no `core.hooksPath`,
- `~/.claude` is a *standalone* Claude install (real dirs, own
  `.credentials.json`, 22-byte `settings.json` = `{"theme":"dark"}`) — no repo
  symlinks, so none of the synced memory / CLAUDE.md / plugin config reaches it,
- no systemd-user timers, no crontab, `Linger=no`,
- `claude` **is** present (`~/.local/bin/claude` → version 2.1.156).

So `hub` never tracks `machines` and never converges: a change shipped from any
other member never lands there. Goal: `hub` ff-pulls `machines` on its own and
applies the pulled state, using the convergence machinery that already exists —
without dragging a workstation dev layer onto a 960 MB production VPS.

Live facts that shape the design: `SUDO_NOPASSWD` for `debian`, systemd user
manager running, GitHub SSH works as `metheoryt` via `~/.ssh/id_rsa`,
`~/.ssh/config` **empty**, 12 G free disk, running services `headscale`,
`caddy`, `docker`/`containerd`, `tailscaled`. **`jq` is NOT installed** (but
`python3` is).

## Non-goals

- **No new convergence mechanism.** `agents/git-hooks/post-merge` (job 1 relink,
  job 2 detached converge) + `scripts/converge.sh`'s `linux)` branch +
  `provision/fleet-selfpull.sh` already implement Trigger A/B for a
  non-systemd-root Linux box. We add a *tier selection*, not a new trigger.
- **No service management.** `hub`'s live services (headscale, caddy, docker
  stacks) stay owned by the sibling `vps` repo. `machines` convergence never
  touches them.
- **No `~/vps` auto-pull.** Decided: `hub`'s `fleet-selfpull` is restricted to
  `~/machines`. The repo that defines `hub`'s live services stays a deliberate
  manual pull, so compose files never drift on disk with nothing applying them.
  (Today `~/vps` double-skips anyway — it sits on a feature branch and carries
  untracked `vps/rustdesk/data/` — but that is accident, not policy.)
- **No `dotfiles` / `repos` role application on `hub`.** Out of scope; this spec
  covers tracking + auto-update only.
- **No `nix` on `hub`.** It stays an apt box; `converge.sh` classes it `linux`.

## Honest value statement

The payoff is narrow but real, and worth stating so it is not over-read:

- every pull relinks the synced agent config (memory tiers, `CLAUDE.md`,
  `cyphy` plugin, statusline) — Claude sessions on `hub` stop being amnesiac,
- `~/.ssh/authorized_keys` refreshes when a new fleet member joins,
- git identity/aliases match the rest of the fleet.

RAM is **not** a constraint: provisioning is disk-bound and the gortex daemon is
never started. The reason for a lean tier is blast radius and recurring churn,
not memory.

## Hazards this design must neutralize

1. **Network lockout (blocker).** `provision/linux.sh:315-361` generates
   `~/.ssh/id_metheoryt` + `~/.ssh/id_cyphy671` and writes a managed block
   setting `Host github.com → IdentityFile ~/.ssh/id_metheoryt` with
   `IdentitiesOnly yes`. `hub`'s working GitHub auth is `id_rsa` and its
   `~/.ssh/config` is empty, so after that block lands ssh offers only a brand-new
   unregistered key: GitHub access dies — killing the very ff-pull being enabled,
   on a box reached over the network. The `ssh_accounts` tier MUST NOT run on
   `hub`.
2. **Recurring churn.** `converge.sh`'s `touches_linux()` matches
   `^pkgs/gortex\.nix$`, which is bumped routinely. Every gortex bump therefore
   re-runs the whole 532-line provisioner on a box that will never run gortex.
   The lean tier makes that re-run cheap (see Follow-ups for removing it).
3. **Self-defeating dirty tree.** `agents/bootstrap.sh:295-311` seeds
   `agents/hosts/<host_id>.md` **inside the repo** when absent. On `hub` that
   creates untracked `agents/hosts/27608.md`, which is not gitignored → the tree
   is permanently dirty → `selfpull_one` returns `SKIP dirty` forever and
   auto-update never fires again. The stub must be committed **before**
   `bootstrap.sh` first runs there.
4. **`jq` bootstrap order.** `provision/lib/fleet.sh` requires `jq`, which `hub`
   lacks. Profile resolution must not hard-depend on it.

Non-hazards, checked: the `ssh_trust` tier's awk merge is additive, and even its
`cat "$MESH_KEYS" > "$tmp_ak"` fallback preserves access because
`provision/fleet-authorized-keys` contains latitude's key
(`me-nixos-latitude5520`). `bootstrap.sh` maintains `settings.json` via
`copy_managed`, which backs up `hub`'s existing real file and never touches
`.credentials.json`.

## Design

### 1. Tier decomposition of `provision/linux.sh`

New sourced library **`provision/lib/tiers.sh`**: each of today's sections
becomes a `tier_<name>` function, **bodies moved verbatim**. `linux.sh` becomes a
thin driver: preamble → resolve profile → run that profile's tier list → summary.

The shared preamble (kept in `linux.sh`, not a tier): pretty-output helpers,
`REPO` resolution, apt/arch preconditions, the `SUDO`/`PRIV` probe,
`mkdir -p ~/.local/bin`, and — new — `export PATH="$HOME/.local/bin:$PATH"`.
That export matters under a detached converge: a non-login shell does not carry
`~/.local/bin`, so every `have <tool>` probe reads false and the installers for
`claude`, `gortex`, `starship`, `uv` re-run on each fire (verified live on `hub`:
`command -v claude` is empty while `~/.local/bin/claude` exists). `WARNINGS`
stays a driver-level global that tiers increment through `warn`.

| tier | contents (all bodies unchanged) | `workstation` | `hub` |
|---|---|---|---|
| `apt_min` | `git curl wget ca-certificates xz-utils unzip jq python3` | ✓ | ✓ |
| `apt_dev` | `build-essential pkg-config python3-venv python3-pip ripgrep fd-find fzf`; extras `fish direnv git-delta bat`; `starship`; `uv`; `gh` + credential helper; delta git wiring; `fd`/`bat` friendly-name symlinks | ✓ | ✗ |
| `agents_config` | `agents/bootstrap.sh` (CORE — `die` on failure) | ✓ | ✓ |
| `git_base` | global identity, `init.defaultBranch`, `pull.rebase`, aliases | ✓ | ✓ |
| `agent_clis` | `claude` installer, `codex` installer | ✓ | claude only |
| `gortex` | pinned binary from `pkgs/gortex.nix` | ✓ | ✗ |
| `ssh_accounts` | `SSH_ACCOUNTS` keygen + `~/.ssh/config` managed block + `GIT_IDENTITIES` `includeIf` | ✓ | ✗ (hazard 1) |
| `shell_init` | `~/.bashrc` machines-bootstrap block; fish `config.fish` seed | ✓ | bashrc only |
| `autofetch` | `~/.local/bin/git-autofetch` + systemd-user timer / cron + linger | ✓ | ✓ |
| `selfpull` | `fleet-selfpull` service+timer / cron | ✓ (default `FLEET_ROOTS`) | ✓ with `FLEET_ROOTS=%h/machines` |
| `ssh_trust` | merge `provision/fleet-authorized-keys` into `authorized_keys` | ✓ | ✓ |

Two tiers take a parameter rather than forking their body:

- `tier_agent_clis <clis…>` — `workstation` passes `claude codex`, `hub` passes
  `claude`.
- `tier_selfpull [roots]` — when `roots` is non-empty the generated
  `fleet-selfpull.service` gains `Environment=FLEET_ROOTS=<roots>` (and the cron
  fallback exports it inline). `hub` passes `%h/machines` (systemd) /
  `$HOME/machines` (cron). Empty = today's behavior (`FLEET_ROOTS` unset → the
  script's own default scan roots).
- `tier_shell_init [--no-fish]` — `hub` passes `--no-fish`; with `apt_dev`
  skipped, `fish`/`starship`/`direnv` are absent anyway, so the guarded `have`
  checks already no-op. The flag makes the intent explicit rather than incidental.

Profile → tier list lives in one table in `linux.sh`, so a third profile is one
list, not a code path.

The two tier lists, in execution order:

```
workstation: apt_min apt_dev agents_config git_base gortex \
             agent_clis(claude codex) shell_init autofetch \
             ssh_accounts selfpull ssh_trust
hub:         apt_min agents_config git_base agent_clis(claude) \
             shell_init(--no-fish) autofetch selfpull(%h/machines) ssh_trust
```

Ordering constraints that are part of the contract: `apt_min` first (bootstrap
needs git + python3); `apt_dev` before `shell_init` (the bashrc block hooks
starship/direnv) and before `git_base`'s delta wiring — kept inside `apt_dev`
where it already is; `gh` + its credential helper stay together inside `apt_dev`.

One deliberate reordering vs today's script: the extras now inside `apt_dev`
(`fish direnv git-delta bat`, `starship`, `uv`, `gh`) today run *after* the
gortex and claude/codex installers. Hoisting them ahead is behavior-neutral —
those sections are mutually independent (nothing in `gortex` or `agent_clis`
consumes starship/uv/gh, and the delta/gh git wiring lives with its own install).
Otherwise the `workstation` run must produce today's result on a WSL box.

### 2. Profile resolution — explicit `fleet.json` field (option A, chosen)

Add to `fleet.json` under `hub`:

```json
"profile": "hub"
```

Absent field = `workstation`. Only `hub` gets a non-default value now.

Add to `provision/lib/fleet.sh`:

```
fleet_profile <machine>   # .machines[$m].profile // "workstation"
```

`linux.sh` resolves in this order:

1. `MACHINES_PROFILE` env var (explicit override; also the escape hatch for a box
   absent from `fleet.json`, and what the tests use),
2. `fleet.json` lookup by detected OS hostname (`27608` → machine `hub` →
   profile `hub`),
3. default `workstation` — this is what every WSL distro hits, since WSL hosts
   are self-declared via `fleet.local.json` and never appear in `fleet.json`.

**Resolution must survive a missing `jq`** (hazard 4). Two independent
mitigations, both specified:

- a small `_fleet_json_read` helper used by the resolution path: prefer `jq`,
  else `python3 -c` (`json` from stdlib; `python3` is present on every Debian /
  Ubuntu target and in `apt_min`), else return empty → `workstation` + a `warn`
  naming the fallback that was taken;
- `apt_min` runs as the unconditional first tier in every profile, so a
  privileged first run installs `jq` for every subsequent run.

Resolution is echoed in the run banner: `profile: hub (from fleet.json)` /
`(from MACHINES_PROFILE)` / `(default)`.

### 3. `converge.sh` must learn the new paths (required, not optional)

`scripts/converge.sh:66-70`'s `touches_linux()` matches exactly:

```
^provision/linux\.sh$|^provision/fleet-selfpull\.sh$|^pkgs/gortex\.nix$|^agents/bootstrap\.sh$
```

Once the tier bodies live in `provision/lib/tiers.sh`, a tiers-only change matches
nothing, so the `linux)` branch takes the
`write_status "$high" ok "linux: no provisioning-relevant change"` path **and
advances `converged-rev`** — a permanent silent skip, on `hub` and on every WSL
box, not a delayed apply. The same change puts `provision/lib/fleet.sh` on the
profile-resolution path.

So the **same commit** must extend the regex with:

```
^provision/lib/tiers\.sh$|^provision/lib/fleet\.sh$
```

`converge.test.sh` cannot catch this by staying green — it has no knowledge of
`tiers.sh` — so the test additions in §Testing carry the regression guard.

### 4. Committed prerequisites

- `agents/hosts/27608.md` — commit the stub in the same change (hazard 3),
  content matching the shape `bootstrap.sh` would have written (`# Host: 27608`,
  the standard comment block, `## Notes`).
- `fleet.json` — `"profile": "hub"` on the `hub` entry.

### 5. Enrollment on `hub` (one-time, manual, ordered)

Run **after** the repo change is pushed, so the clone already carries the stub
and the profile field:

1. `git clone git@github.com:metheoryt/machines.git ~/machines`
   (`id_rsa` already authenticates as `metheoryt`).
2. `bash ~/machines/provision/linux.sh` **with a TTY** — the first run needs the
   interactive/`sudo -n` path for `apt_min`. Expect banner
   `profile: hub (from fleet.json)`.
3. Verify, in order:
   - `git -C ~/machines status --porcelain` → empty (clean-tree gate holds),
   - `git -C ~/machines config --local core.hooksPath` → the repo's
     `agents/git-hooks`,
   - `systemctl --user list-timers` → `fleet-selfpull.timer`,
     `git-autofetch.timer` present and scheduled,
   - `systemctl --user cat fleet-selfpull.service` → contains
     `Environment=FLEET_ROOTS=%h/machines`,
   - `loginctl show-user debian | grep Linger` → `Linger=yes`,
   - `~/.ssh/config` still empty **and** `ssh -T git@github.com` still greets
     `metheoryt` (hazard 1 did not fire),
   - `readlink ~/.claude/CLAUDE.md` → into `~/machines/agents`, and
     `~/.claude/.credentials.json` still present.
4. End-to-end: ship a trivial commit from another member, wait ≤ ~12 min, then
   check `~/machines/.machines/last-converge` on `hub` shows
   `status=ok reason=linux: …`.

### 6. Error handling

Unchanged from today's contract, and inherited by the tiers because their bodies
move verbatim: `apt_min` is CORE and `die`s when privileged (skips with a `warn`
when `PRIV=0`, i.e. under a detached converge with no reachable root);
`agents_config` is CORE and `die`s; every other tier warns and continues.
`converge.sh` records `fail` in `.machines/last-converge` without advancing
`converged-rev`, so a failed run retries the same range next fire.

## Testing

Existing tests that must keep passing unchanged:
`agents/git-hooks/post-merge.test.sh`, `provision/fleet-selfpull.test.sh`,
`provision/tests/fleet-local.test.sh`. `scripts/converge.test.sh` keeps its
current cases and gains one (case 6 below).

New `provision/tests/tiers.test.sh` (bash, no root, no network — same shape as
the existing `*.test.sh`):

1. **Profile resolution precedence** — `MACHINES_PROFILE` beats `fleet.json`;
   `fleet.json` hostname match resolves `27608` → `hub`; unknown hostname →
   `workstation`; `jq`-absent path (stub `jq` off `PATH`) still resolves via
   `python3`.
2. **Tier lists** — a dry-run/plan mode of `linux.sh` (`MACHINES_TIERS_DRY_RUN=1`,
   printing the resolved tier names and exiting) asserts: `workstation` prints
   today's full ordered list; `hub` omits `apt_dev`, `gortex`, `ssh_accounts`;
   both start with `apt_min` and include `agents_config`.
3. **`ssh_accounts` never runs under `hub`** — the regression guard for hazard 1,
   asserted on the dry-run list and by confirming no `~/.ssh/config` write in a
   sandboxed `HOME`.
4. **`selfpull` roots parameterization** — generated unit text contains
   `Environment=FLEET_ROOTS=%h/machines` for `hub` and no `FLEET_ROOTS` line for
   `workstation`.
5. **Library-only sourcing** — `TIERS_LIB_ONLY=1 . provision/lib/tiers.sh` loads
   the functions without executing anything (mirrors `CONVERGE_LIB_ONLY` /
   `FLEET_SELFPULL_LIB_ONLY`).

Added to `scripts/converge.test.sh` (guards §3, which the existing cases cannot):

6. **`touches_linux` covers the new paths** — a range touching only
   `provision/lib/tiers.sh` (and one touching only `provision/lib/fleet.sh`) must
   take the provision branch, not the `no provisioning-relevant change` skip.

**Nix gate.** `modules/system/fleet.nix:11` reads `fleet.json` via
`fromJSON (readFile …)`, and `modules/home/ssh.nix` renders its host blocks from
it — so adding `"profile": "hub"` **is** an input change to latitude's evaluation
even though no `.nix` file is edited. Per project convention that gate runs only
on a NixOS member: after the change lands, on `latitude`, run
`nix build --dry-run '.#nixosConfigurations.latitude.config.system.build.toplevel'`.
Low risk that an extra key breaks anything — the point is that nothing else in
this change would tell us if it did.

`just quick` adds little here beyond that dry-build; the behavioral gate is the
test scripts plus the §5 verification on the box.

## Follow-ups (explicitly out of scope)

- Make `touches_linux()` **profile-aware** so a `pkgs/gortex.nix` bump stops
  re-running provisioning on a profile with no `gortex` tier (hazard 2). Deferred
  by decision, not oversight — the lean run is fast, and §3 already touches that
  regex for the paths the refactor *requires*, so this is only the extra
  conditional.
- `agents/settings.json` declares marketplace `pure-team` at
  `/home/me/pure/claude-plugins`, which does not exist on `hub` → a plugin-load
  warning in Claude sessions there. Cosmetic; gating it is a separate change.
- Applying `hub`'s `dotfiles` role, and reconciling `~/vps` (feature branch +
  untracked `vps/rustdesk/data/`) if it should ever auto-pull.
