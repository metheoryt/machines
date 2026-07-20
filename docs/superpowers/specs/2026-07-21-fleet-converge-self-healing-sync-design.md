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

- **No new migration format.** The convergent, idempotent, per-os/per-role
  provisioner already exists (`provision/`). We add the *trigger*, not a new DSL.
- **No local version mutation.** Convergence *applies* the pulled state; it never
  runs `nix flake update`, `apt upgrade` beyond what provision already does, or
  anything that mutates a tracked file (see Reproducibility below).
- **No transport change.** git over the tailnet stays the truth. No OneDrive /
  Drive (corrupts `.git`, no atomicity, silent conflicts).
- **No periodic `nix flake update`.** A deliberate input bump is a separate,
  committed, shipped maintenance step — out of scope here.

## Architecture: two triggers, one convergence

```
TRIGGER A (instant):  /ship -> fleet-pull.sh SSH fan-out -> git pull --ff-only   [reachable boxes]
TRIGGER B (eventual): per-OS timer            -> git pull --ff-only              [catches offline boxes]
                                    |
              both do a real ff merge -> fire committed post-merge hook
                                    |
              hook self-gates (primary worktree, on main) then fires a
              DETACHED converge job (does not block the pull)
                                    |
                          converge = per-OS idempotent provisioner
                          + NixOS: nixos-rebuild switch against the committed lock
                                    |
                          writes last-converge result (gitignored) + journal
```

Both trigger paths do the *same* `git pull --ff-only origin main`. Empirically
verified: `post-merge` fires on a fast-forward pull and `ORIG_HEAD` is set to the
pre-pull commit, so `git diff --name-only ORIG_HEAD HEAD` path-gating is reliable.
`--ff-only` (not `rebase`) is mandatory — `rebase` fires `post-rewrite`, not
`post-merge`, and would not trigger convergence. This unifies push + pull onto one
hook.

## Components

### 1. Committed `post-merge` hook

- Lives in a committed dir, e.g. `agents/githooks/post-merge` (POSIX sh).
- Wired via `git config core.hooksPath agents/githooks`, set once by
  `agents/bootstrap.sh` (runs per profile on every OS already). Git-for-Windows
  runs `.sh` hooks under its bundled `sh`, so one hook covers all boxes.
- **Self-gates** (all must pass, else `exit 0`):
  ```sh
  # only the primary worktree — a linked worktree never converges
  [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] || exit 0
  # only the deploy branch
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || exit 0
  ```
  `core.hooksPath` is per-repo (shared across worktrees), so the guard is what
  enforces "worktrees push/ship freely, but never converge."
- **Fires convergence detached** and returns immediately:
  - Linux/NixOS: `systemctl start --no-block machines-converge.service`
  - Windows: `schtasks /run /tn machines-converge` (or detached `Start-Process`)
- Only `machines` carries the hook. Sibling repos are pull-only (below).

### 2. Convergence job (detached, root)

Why detached + root:
- **Detached:** an inline hook would make every `/ship` block minutes-per-box,
  serially, with output swallowed by `fleet-pull.sh`'s `>/dev/null`. Fire-and-forget
  removes that regression.
- **Root oneshot:** the converge unit runs as root; the pull stays a user action.
  This is how `nixos-rebuild switch` gets its privilege **without** wiring
  passwordless sudo for the pulling user.

What it runs (per OS, idempotent, "sync software but skip already-applied one-time
settings"):
- **Linux / WSL / non-nix:** the existing per-os provisioner (`provision/linux.sh`
  or the manifest-driven `provision.sh` role executors). Each step is
  check-then-act; software install no-ops cheaply when present.
- **NixOS:** `nixos-rebuild switch` **against the committed `flake.lock`** — applies
  exactly the software/config the shipper committed and tested. Gate the heavy
  rebuild on the merge actually touching `*.nix` / `flake.*`
  (`git diff --name-only ORIG_HEAD HEAD`); otherwise skip it (config that is
  symlinked — Claude config, memory — is already live from the pull).

Constraint — **convergence must never dirty the tracked tree.** `bootstrap.sh`
symlinks and provision writes config; every write must target a gitignored or
out-of-repo path. If convergence ever modifies a tracked file, the clean-tree gate
(below) permanently disables all future auto-pulls on that box. The plan must
assert/verify this.

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
- The timer only performs the ff-pull. **Convergence is the hook's job** — only the
  `machines` repo has the hook, so only `machines` converges. Sibling repos get the
  fresh checkout and nothing more.
- **Interval + jitter:** ~10 min (matches autofetch), `Persistent=true` so a box
  that was off catches up on wake. Jitter so boxes don't hit GitHub together:
  systemd `RandomizedDelaySec`, Task Scheduler `RandomDelay`, cron `sleep $((RANDOM % N))`.

### 4. Convergence status surface

Detached convergence + git discarding the hook's exit code = a failed provision or
rebuild is otherwise invisible, which would defeat the whole "stop hand-tuning"
premise. So:
- Each converge run writes a `last-converge` record to a **gitignored** path
  (e.g. `~/.local/state/machines/last-converge` / a Windows equivalent):
  `rev`, `ok|fail`, `timestamp`, one-line reason. Full output → journal
  (`journalctl -u machines-converge` / Task Scheduler history).
- `fleet-pull.sh` reads that record back per member and adds a column, so `/ship`'s
  table shows convergence status alongside the pull result. (Optional follow-up: a
  standalone `/fleet-status`.)

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
  behavior for a sync repo.

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
- Add the detached-converge trigger (`ExecStartPost` or fold into the converge unit)
  gated on `*.nix`/`flake.*` change.

## Reused precedent (all in-repo)

- `agents/plugin/skills/ship/fleet-pull.sh` — ff-only, skip-if-unsafe pull; safety
  gates and URL normalization to reuse.
- `modules/system/self-update.nix` — NixOS timer + clean/branch gates.
- `modules/system/git-autofetch/` — the cross-OS timer deployment template
  (systemd / `.ps1` Scheduled Task / provision-inlined user timer).
- `agents/bootstrap.sh` — per-profile installer; wires `core.hooksPath`.
- `provision/` — the idempotent per-os/per-role convergence substrate.
