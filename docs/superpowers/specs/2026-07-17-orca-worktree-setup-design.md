# Orca worktree-setup: global dispatcher in ~/machines

**Date:** 2026-07-17
**Status:** approved (design)

## Problem

Orca IDE spawns each task in its own git worktree at an untracked path
(`~/orca/workspaces/<repo>/<branch>`). A fresh worktree carries only committed
files, so it is missing the gitignored local config the app/tests need
(`.env`, `.claude/settings.local.json`), and a bare `docker compose run` from it
collides with the base stack (fixed `container_name`s), runs main's code instead
of the worktree's, and races on shared test DBs.

Orca lets you paste a script that runs when it spawns a new worktree in a
project. We want that wired to a **single, version-controlled source of truth**
that syncs across every machine, rather than pasted-and-forgotten per machine.

The isolation mechanics are already solved for the Claude subagent flow by the
pure-dev plugin's `worktree-agent` skill and its
`scripts/agent-worktree-setup.sh` (symlinks the gitignored config; emits a
collision-safe `docker compose -p <proj> run -v <wt>/src:/app/src -e <ns db>
pure-api-app pytest` command). This design reuses that script rather than
duplicating it.

## Decision

A **generic dispatcher in `~/machines`**, delegating repo-specific work. Chosen
over per-repo committed scripts (would duplicate generic logic and need a PR into
each work repo) and over pointing Orca directly at the plugin script (backend-api
-only, couples Orca config to the plugin path).

## Components

### 1. `~/machines/scripts/orca-worktree-setup.sh` (new — dispatcher)

Run by Orca on worktree spawn, from inside the new worktree. Flow:

1. Resolve worktree root + main checkout root from cwd via git
   (`--show-toplevel`, `--git-common-dir`), so it works from anywhere inside the
   worktree.
2. **Generic (universal):** symlink the default gitignored config set — `.env`,
   `.claude/settings.local.json` — from the main checkout into the worktree when
   present and not already there. Idempotent (dangling/existing symlink =
   already done).
3. **Delegation (repo extras):** exec the first delegate found —
   - `$repo_root/.orca/worktree-setup.sh` (a repo that opts in, committed), else
   - `$HOME/machines/scripts/orca-worktree.d/<main-basename>.sh` (machines-side
     registry).
4. **Always exit 0** — setup failure must never block Orca creating the
   worktree. Diagnostics to stderr, loudly.

Generic symlinking runs *before* delegation so config is linked even when the
delegate/plugin is absent on a given machine.

### 2. `~/machines/scripts/orca-worktree.d/backend-api.sh` (new — delegate)

Keyed by main-checkout basename `backend-api`. It:

- Guards that the pure-dev script exists
  (`$HOME/pure/claude-plugins/plugins/pure-dev/skills/worktree-agent/scripts/agent-worktree-setup.sh`);
  if missing, warn to stderr and exit 0 (config was already linked by the
  dispatcher).
- Runs the pure-dev script, capturing its stdout (the collision-safe test
  command). The pure-dev script's own symlink step re-runs harmlessly
  (idempotent).
- Persists that command as a runnable helper at
  `"$(git rev-parse --git-dir)/orca/run-tests.sh"` (`chmod +x`) — the
  per-worktree **private git dir**, so it never appears in `git status` — and
  prints the helper's path plus the command to stdout.

The pure-dev `agent-worktree-setup.sh` is **not modified** — it stays the single
source of truth for backend-api's compose specifics, shared with the Claude
subagent flow.

### 3. Orca per-project setting (manual, once per project per machine)

Paste into Orca's worktree-spawn script field:

```
bash "$HOME/machines/scripts/orca-worktree-setup.sh"
```

Identical string everywhere. Orca stores it in its own local sqlite
(`~/.config/orca`), which is machine-local and not nix-tracked — hence pasted
per machine, but the referenced script is the synced source of truth.

## Data flow

Orca spawn → `orca-worktree-setup.sh` (cwd = new worktree) → generic symlinks →
`orca-worktree.d/backend-api.sh` → pure-dev `agent-worktree-setup.sh` → command
captured → written to `<private-gitdir>/orca/run-tests.sh`. Developer later runs
that helper to test the worktree's code against the reused base stack with
namespaced DBs.

## Error handling

- Dispatcher and delegate are non-fatal (exit 0) on every failure path; Orca
  worktree creation must not be blocked.
- Missing plugin script → warn, config still linked by dispatcher.
- Missing main-checkout config files → skip silently (nothing to link).

## Assumption to validate

Orca runs the spawn script with **cwd inside the new worktree**. The agent-hooks
only expose `ORCA_WORKTREE_ID` (an id, not a path); the dispatcher relies on cwd
+ git resolution. Validate by spawning a test worktree in Orca and confirming the
symlinks + helper appear. If Orca instead runs from the project root or a temp
dir, switch the dispatcher to consume an Orca-provided path env var.

## Testing / verification

1. Run `orca-worktree-setup.sh` from this backend-api worktree; confirm it
   symlinks `.env` + `.claude/settings.local.json`, delegates to backend-api.sh,
   and writes `<private-gitdir>/orca/run-tests.sh` containing the correct
   `-p backend_api`, worktree `src` mount, and namespaced `DATABASES_POSTGRES_*`
   / `TEST_NAMESPACE` values.
2. One real Docker run: execute the emitted command scoped to a single test
   (`… pytest --reuse-db -k <one test> -p no:cacheprovider` or similar) to prove
   the namespaced DB is created/used and the run reuses the base stack.

## Out of scope

- Generalizing the delegate for other repos (add an `orca-worktree.d/<repo>.sh`
  when a second repo needs it).
- Capturing Orca's per-project setting itself in git (Orca-local sqlite).
- Any change to the pure-dev plugin script.
