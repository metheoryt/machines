# Fleet self-healing sync + auto-convergence

**Date:** 2026-07-21
**Status:** design, approved for planning

## Problem

`/ship` today is push-only: commit → merge-back → push origin → `fleet-pull.sh`
SSHes every *other* member and `git pull --ff-only`. Two gaps:

1. **Push only reaches boxes reachable at ship time.** A sleeping Windows laptop
   gets `SKIP unreachable` and silently stays behind until someone ships again or
   pulls by hand. There is no background convergence.
2. **No automatic post-update tuning.** A change often needs per-host action
   (re-symlink agent config, regenerate SSH config, restart a daemon, rebuild
   NixOS). Today that is done by hand, connecting to each box directly.

Goal: a change lands on every fleet member on its own — instantly where possible,
eventually always — and each box **applies the pulled state automatically** after
it updates.

## Non-goals

- **No setup skill, no delegate convention, no separate repo.** All three are reuse
  machinery with zero current reuse (convergence has exactly one consumer —
  `machines`; `vps` is ruled out as single-node/dev-in-place). So convergence lives
  **inline in `machines`** as `scripts/converge.sh`, wired only into `machines`.
  Deferred until a *second* repo genuinely needs post-update action, at which point
  the cheap generalizations become worthwhile — a `.fleet/on-update.sh` delegate
  convention, a `/fleet-onupdate-setup` skill (mirror of `/orca-setup`), and/or
  extracting the hook+timer mechanics into a shared repo. Each is a **code move,
  not a redesign** — the knowledge is captured here — so building any of them now
  would be carrying cost for a maybe.


- **No new migration format.** The convergent, idempotent, per-os/per-role
  provisioner already exists (`provision/`). We add the *trigger*, not a new DSL.
- **No local version mutation.** Convergence *applies* the pulled state; it never
  runs `nix flake update`, `apt upgrade` beyond what provision already does, or
  anything that mutates a tracked file (see Reproducibility below).
- **No transport change.** git over the tailnet stays the truth. No OneDrive /
  Drive (corrupts `.git`, no atomicity, silent conflicts).
- **No periodic `nix flake update`.** A deliberate input bump is a separate,
  committed, shipped maintenance step — out of scope here.

## Architecture: two pull sources, one convergence, two OS-tier triggers

```
                 ┌─ /ship -> fleet-pull.sh SSH fan-out -> git pull --ff-only  [reachable boxes]
 a pull happens ─┤
                 └─ per-OS self-pull timer            -> git pull --ff-only  [offline catch-up]
                                    |
             every pull rewrites .git/ORIG_HEAD to the pre-pull commit and
             fires the OS-TIER convergence trigger:
                                    |
   non-nix ─ committed post-merge git hook (core.hooksPath, bootstrap-wired) ─┐
   NixOS   ─ root machines-converge.path unit (watches .git/ORIG_HEAD)         ┤
                                    |                                          │
             both run  scripts/converge.sh  DETACHED / privileged  ───────────┘
                                    |
             converge.sh self-gates (primary worktree, on main), computes its
             own range = <last-converged rev>..HEAD from .machines/, routes
             per-OS (NixOS branch = nixos-rebuild switch against committed lock)
                                    |
             writes converged-rev + last-converge status to .machines/ + journal
```

Both pull sources do the *same* `git pull --ff-only origin main`. `--ff-only`
(not `rebase`) is mandatory — a `rebase` fires `post-rewrite`, not `post-merge`,
so the non-nix hook would miss it. Empirically verified: a fast-forward pull
rewrites `.git/ORIG_HEAD` to the pre-pull commit — the non-nix `post-merge` hook
and the NixOS `machines-converge.path` unit both hook off *that write*, so both
`/ship`'s direct pull and the timer's pull trigger convergence.

**The trigger splits by OS tier, matching the repo's existing bootstrap-vs-nix
split** (bootstrap owns non-nix wiring; nix owns nix). It is decoupled from
*which process pulled*: converge.sh derives its range from the last-converged
rev in `.machines/`, not from a synchronously captured `ORIG_HEAD`, so a
coalesced double-fire (hook + timer) or an already-up-to-date no-op pull is
harmless and self-correcting.

## Components

### 1a. Non-nix trigger — the committed `post-merge` hook

- **Extends the existing hook mechanism**, it does not add a parallel one. The
  repo already ships `agents/git-hooks/` (dashed) with `post-merge`,
  `post-rewrite`, `post-checkout` entrypoints that `exec _refresh-claude-config`
  (re-links Claude config after a pull). `agents/bootstrap.sh`'s
  `install_git_hooks()` already sets `git config core.hooksPath
  <abs>/agents/git-hooks` in the `machines` clone. Convergence is a **second job**
  added to that same `post-merge`.
  - **Restructure `post-merge`, don't append:** it is currently
    `exec "$(dirname "$0")/_refresh-claude-config"`, and `exec` replaces the
    process — nothing after it runs. The new `post-merge` must *run* the refresh
    (drop the `exec`) and *then* fire convergence. (`post-rewrite`/`post-checkout`
    are untouched — a rebase/checkout must not converge.)
- **Scope: non-nix only.** `install_git_hooks()` already early-returns on NixOS
  (`[ -e /etc/NIXOS ] && return 0`) so `core.hooksPath` is never set there — a
  deliberate choice to avoid racing home-manager's symlink activation. NixOS
  therefore does **not** use this hook; its trigger is §1b. Git-for-Windows runs
  `.sh` hooks under its bundled `sh`, so the one hook covers every non-nix box.
- **Self-gates** — belong in `converge.sh` (§2), not duplicated per trigger. The
  hook fires unconditionally; `converge.sh` is the single place that checks
  primary-worktree + on-`main`. (`core.hooksPath` is per-repo and shared across a
  repo's worktrees, so the gate — not the wiring — enforces "worktrees push/ship
  freely, but never converge.")
- **Fires convergence detached, returns immediately** (an inline converge would
  make every `/ship` block minutes-per-box). No synchronous range capture — the
  detached job derives its range from `.machines/` (§2). Routing:
  - Windows: `schtasks /run /tn machines-converge` — fires the SYSTEM/admin task
    (§2). It must be `schtasks`, **not** a hook-spawned `Start-Process`: the latter
    inherits the pulling user's token and would run `provision/windows.ps1` without
    the privilege the design keeps out of the pulling user.
  - **WSL / non-systemd Linux:** no root unit — background `converge.sh` directly
    (its privilege is passwordless-sudo-or-user scope; it skips steps it can't
    perform and logs). On a WSL box `converge.sh` runs `provision/linux.sh`, never
    `nixos-rebuild`.
  - **non-nix Linux *with* systemd** (rare in this fleet): if a root
    `machines-converge.service` was installed by `provision/linux.sh`,
    `systemctl start --no-block machines-converge.service`; else background as WSL.

### 1b. NixOS trigger — a root `machines-converge.path` unit

NixOS gets no git hook (§1a), and an `ExecStartPost` on the `self-update.nix` pull
service **does not work**: (1) that service runs as `User = me`, so it lacks the
privilege to `nixos-rebuild`; and (2) — fatal — `ExecStartPost` only fires when
*the timer's own pull* advances `HEAD`. When `/ship` SSHes latitude and pulls it
directly, `HEAD` is already advanced, so the timer's next pull is "up-to-date" and
the service `exit 0`s before `ExecStartPost` would run — the **common case (change
shipped while latitude is up) never converges.**

Instead, a trigger **decoupled from which process pulled**, all-root, no
polkit/sudo:

- `modules/system/self-update.nix` (or a sibling module) declares:
  - `systemd.paths.machines-converge` with `pathConfig.PathModified =
    "<repo>/.git/ORIG_HEAD"` → `Unit = machines-converge.service`.
  - `systemd.services.machines-converge` — **root** oneshot, `ExecStart = bash
    <repo>/scripts/converge.sh`.
- Git rewrites `.git/ORIG_HEAD` on **every** pull (verified), so the path unit
  fires for both `/ship`'s direct pull and the timer's pull — parity with the
  Windows hook→`schtasks` path. It runs as root regardless of the `me`-owned
  writer, so `nixos-rebuild switch` gets its privilege natively. (Fallback if a
  path unit proves fiddly: a root `machines-converge.timer` polling `HEAD` vs the
  converged rev in `.machines/` — eventual, dead-simple, defensible given
  blast-radius = 1 box.)
- **`self-update.nix` stays a pure pull backend.** Commit 6b2333f's removal of the
  `ExecStartPost` converge step stays correct — its only error was assuming the
  git hook reaches NixOS. The fix is to *add* this separate trigger, **not** to
  move converge back into the pull service.

Considered and deferred: `~/my/vps` — single-node, developed in place on the server,
so it is its own source of truth and rarely pulls; an auto-converge-on-pull trigger
has no value there (YAGNI). Sibling repos are therefore pull-only (below).

### 2. Convergence: generic plumbing + `scripts/converge.sh`

Split responsibilities so no OS knowledge leaks into the plumbing:

- **Plumbing** = the systemd unit (`machines-converge.service`) / Windows Scheduled
  Task. It only: grants privilege, detaches, and runs `scripts/converge.sh`.
  - **Detached:** an inline hook would make every `/ship` block minutes-per-box,
    serially, with output swallowed by `fleet-pull.sh`'s `>/dev/null`.
    Fire-and-forget removes that regression.
  - **Privileged:** the Linux unit runs as **root**; the Windows task runs as
    **SYSTEM/admin**. The pull stays an unprivileged user action. This is how
    `nixos-rebuild switch` / `provision/windows.ps1` get privilege **without**
    wiring passwordless sudo for the pulling user. `converge.sh` assumes it is
    privileged.

- **`scripts/converge.sh`** (POSIX sh, committed) owns **all** policy — including
  the **self-gates** (every trigger fires it unconditionally; it is the single
  place they live):
  ```sh
  # only the primary worktree — a linked worktree never converges
  [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] || exit 0
  # only the deploy branch
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || exit 0
  ```
  It then computes its **own range** and routes (idempotent, "sync software but
  skip already-applied one-time settings"):
  - **Range = `<last-converged rev>..HEAD`.** Read the last successfully-converged
    rev from `.machines/` (§5); `HEAD` is read now. This is deliberately *not* a
    synchronously-captured `ORIG_HEAD`: the NixOS path-unit trigger carries no
    range, and reading last-converged-rev also survives coalesced trigger events
    and the up-to-date/no-op pull. First run (no record) ⇒ treat the whole tree as
    changed (full converge). On success, write the new `HEAD` as the converged rev.
  - **NixOS** (`[ -e /etc/NIXOS ]`): `nixos-rebuild switch --flake .#$(hostname)`
    **against the committed `flake.lock`** — applies exactly the software/config the
    shipper committed and tested. Gate the heavy rebuild on that range actually
    touching `*.nix` / `flake.*`; otherwise skip (symlinked config — Claude config,
    memory — is already live from the pull).
  - **Linux / WSL / non-nix:** `bash provision/linux.sh` (or the manifest-driven
    `provision.sh` role executors). Each step is check-then-act; software install
    no-ops cheaply when present.
  - **Windows** (Git-for-Windows `uname` = `MINGW*`/`MSYS*`): `powershell -File
    provision/windows.ps1`.

  Consolidating the `linux.sh`-vs-`provision.sh`-vs-`nixos-rebuild` routing in one
  committed script keeps the hook and the unit/task fully generic.

Constraint — **convergence must never dirty the tracked tree.** `bootstrap.sh`
symlinks and provision writes config; every write must target a gitignored path
(`.machines/`, below) or somewhere outside the repo. If convergence ever modifies a
tracked file, the clean-tree gate permanently disables all future auto-pulls on that
box. The plan must assert/verify this.

### 3. Per-OS self-pull timer (Trigger B)

One logical job — "for each fleet-sync repo, if safe, `git pull --ff-only`" — three
backends, mirroring the proven `git-autofetch` / `self-update.nix` deployment:

| OS | backend | installed by |
|----|---------|--------------|
| NixOS | systemd system timer | retarget `modules/system/self-update.nix` |
| Windows (`desktop`, `server`) | Task Scheduler | `provision/windows.ps1` (mirror `git-autofetch.ps1` registration) |
| WSL leaf / non-nix Linux | systemd-user timer → cron fallback | `provision/linux.sh` (mirror inlined autofetch) |

Timer behavior:
- **Scope: all fleet-sync repos.** Scan roots (git-autofetch style) and pull every
  personal fleet-sync repo. **Exclude work repos** (`origin` matching
  `thepureapp/`) — same exclusion `/ship` enforces.
- Per-repo safety gates (identical to `fleet-pull.sh` remote-script + `self-update.nix`):
  on `main`, clean tree, has a tracked upstream, and the pull is a fast-forward.
  Any gate fails → skip that repo (log, continue).
- The timer only performs the ff-pull. **Convergence is the OS-tier trigger's job**
  (§1a/§1b) — only the `machines` repo has a trigger wired, so only `machines`
  converges. Sibling repos get the fresh checkout and nothing more.
- **Interval + jitter:** ~10 min (matches autofetch), `Persistent=true` so a box
  that was off catches up on wake. Jitter so boxes don't hit GitHub together:
  systemd `RandomizedDelaySec`, Task Scheduler `RandomDelay`, cron `sleep $((RANDOM % N))`.

### 4. Convergence status surface

Detached convergence + git discarding the hook's exit code = a failed provision or
rebuild is otherwise invisible, which would defeat the whole "stop hand-tuning"
premise. So:
- Each converge run writes a `last-converge` record into `.machines/` (below):
  `rev`, `ok|fail`, `timestamp`, one-line reason. Full output → journal
  (`journalctl -u machines-converge` / Task Scheduler history).
- `fleet-pull.sh` reads that record back per member (over the same SSH it already
  uses) and adds a column, so `/ship`'s table shows convergence status alongside the
  pull result. (Optional follow-up: a standalone `/fleet-status`.)

### 5. `.machines/` — gitignored per-host state root

A single gitignored directory at the `machines` repo root that doubles the repo as
its own config/runtime root (à la `~/.config`), giving a **uniform path on every
OS** — no `~/.local/state` vs `%LOCALAPPDATA%` divergence.

- **Contents:** `converged-rev` (the last successfully-converged `HEAD`, the low
  end of converge.sh's range — §2), `last-converge` (status record: `rev`,
  `ok|fail`, `timestamp`, reason), plus any per-host config, caches, and runtime
  files convergence or other tooling needs. (`last-converge.rev` may double as
  `converged-rev` — one record suffices; the plan picks the exact file layout.)
- **Gitignored** (`.gitignore`: `/.machines/`) — so writes into it are invisible to
  `git status --porcelain` / `git diff` and **never trip the clean-tree gate**. This
  is precisely why it is a safe convergence write-target.
- **Per-host by construction:** not synced by git, so each box owns its own
  `.machines/`. Correct for state/caches/host-config. "Transferable" = a known,
  uniform layout you can copy/back-up/seed between boxes *deliberately*, not one git
  drags around.
- **Worktree note:** each working tree has its own `.machines/`, but convergence only
  runs in the primary checkout (§2 gate), so the primary's `.machines/` is
  authoritative; tooling that reads host state should resolve the primary checkout,
  not a linked worktree.
- **Clean split:** committed code (`scripts/converge.sh` + `agents/git-hooks/` +
  the nix converge units) vs gitignored state (`.machines/`). The committed/ignored
  boundary keeps the "never dirty the tree" constraint (§2) structural rather than a
  thing to remember.

## Edge cases / semantics

- **Deploy branch = `main`.** Convergence and timer-pull only act when the primary
  checkout is on `main`.
- **Not on `main`** (feature branch): skip both — leave WIP alone.
- **No remote / no tracked upstream:** skip gracefully, log, `exit 0`.
- **Linked worktree:** may push and ship, never converges (hook git-dir≠common-dir
  gate).
- **Dirty tree:** skip the pull entirely (never clobber WIP) — existing gate.
- **Diverged (non-ff):** skip loudly. Note this is a **behavior change** in
  `self-update.nix`: it currently auto-rebases; switching to `--ff-only` means a
  diverged box now *skips and logs* instead of silently rebasing — the safer
  behavior for a sync repo. (`--ff-only`, not `rebase`, is also required so the
  non-nix `post-merge` hook fires; the NixOS trigger watches `ORIG_HEAD`, which a
  rebase-pull also rewrites, but `--ff-only` is the fleet-wide rule regardless.)

## Reproducibility (why convergence never mutates versions)

- Non-nix boxes have no lockfile — latest-at-run-time drift is the accepted
  tradeoff of that layer.
- Nix boxes pin every version in `flake.lock`. A local `nix flake update` would
  (1) dirty a **tracked** file → kill the clean-tree gate, (2) diverge each box's
  lock, (3) auto-deploy untested upstream bumps. Convergence therefore rebuilds
  **against the committed lock** only. Software bumps for nix happen once, at ship
  time: `nix flake update` → commit `flake.lock` → `/ship` → every box rebuilds to
  those exact versions.

## Auto-rebuild risk (accepted)

Auto `nixos-rebuild switch` reverses `self-update.nix`'s deliberate no-rebuild
stance — warranted now that `.nix` config lives in this repo. Safety:
- `nixos-rebuild switch` build-gates the switch natively: a non-building config
  never half-applies.
- Residual risk: a config that *builds* but breaks reachability (SSH / firewall /
  network) auto-deploys before you notice — "silently behind" becomes
  "unreachable," which may need physical access to recover.
- **Blast radius today = 1 box** (`latitude` is the only NixOS member), which lowers
  urgency. Spec records the risk; `switch` stays gated behind a successful build.
  (Future option: `nixos-rebuild test` first, or a boot-fallback generation.)

## `self-update.nix` changes

- Retarget default `repo` from stale `/home/me/nix` to the real checkout
  (`~/machines`).
- `rebase` → `pull --ff-only` (see Diverged, above).
- **No converge trigger *inside* the pull service — but NixOS DOES get a converge
  trigger** (§1b), just as a *separate* unit. The `User = me` pull service stays a
  pure pull backend; convergence is fired by the root `machines-converge.path` unit
  watching `.git/ORIG_HEAD` (§1b). Do **not** add an `ExecStartPost` converge step:
  besides lacking root, it fires only on the timer's *own* HEAD-advancing pull, so
  it misses `/ship`'s direct pull (up-to-date ⇒ `exit 0`) — the common case. The
  path unit is decoupled from which process pulled and covers both. This is the
  fix commit 6b2333f pointed at but got wrong (it assumed the git hook reaches
  NixOS); 6b2333f's `ExecStartPost` removal itself stays correct.
- The new `machines-converge.path` + `machines-converge.service` (root) can live in
  `self-update.nix` or a sibling module — the plan decides. Enabled on `latitude`
  alongside `services.nixRepoAutoPull`.

## Reused precedent (all in-repo)

- `agents/plugin/skills/ship/fleet-pull.sh` — ff-only, skip-if-unsafe pull; safety
  gates and URL normalization to reuse.
- `modules/system/self-update.nix` — NixOS timer + clean/branch gates (the module
  the nix converge units attach to).
- `modules/system/git-autofetch/` — the cross-OS timer deployment template
  (systemd / `.ps1` Scheduled Task / provision-inlined user timer).
- `agents/git-hooks/` + `agents/bootstrap.sh` — the existing `core.hooksPath`
  mechanism (`post-merge` → `_refresh-claude-config`); convergence extends
  `post-merge`, bootstrap already wires it (non-nix only).
- `provision/` — the idempotent per-os/per-role convergence substrate
  (`linux.sh`, `windows.ps1`, manifest-driven `provision.sh`).
