# OS-agnostic profile/home-state provisioning — one deployer, husk retired

**Date:** 2026-07-18
**Status:** approved (design)

## Problem

Agent-profile config (`~/.claude`, each `~/.claude-<postfix>`, `~/.codex`) is
linked into place by **three** implementations of the same "one-hop symlink the
repo's `agents/` files into the live profile dir" logic:

- **`agents/bootstrap.sh`** — bash, cross-platform (Windows Git Bash / macOS /
  non-Nix Linux). One profile per invocation (`CLAUDE_CONFIG_DIR`), plus the
  Codex block on the personal `~/.claude` run.
- **`modules/home/claude.nix`** — a home-manager activation script that loops the
  committed `settings*.json` and reimplements the same ~10 `ln -sfn` links per
  profile.
- **`modules/home/codex.nix`** — a *third* pattern: a mix of `home.file` /
  `mkOutOfStoreSymlink` entries **and** its own activation script for the mutable
  memory stores.

Three copies of one intent drift. They **already have**: an empirical
`DRY_RUN=1 bash agents/bootstrap.sh` on `latitude5520` (which mutates nothing)
shows bootstrap resolves this host as `latitude5520` and would **seed a new
`agents/hosts/latitude5520.md` stub and repoint `~/.claude/host-memory.md` at
it** — away from the curated `agents/hosts/latitude.md` the live nix links use.
`agents/hosts/` carries the same disease for g16: both `g614jv.md` and
`ME-G614JV.md` exist. bootstrap's `host_id()` (sanitized `hostname`) and
claude.nix's `${hostname}` specialArg disagree on what a host's memory file is
called. The duplication has already produced a latent data-loss bug (running the
"other" deployer clobbers the curated per-host memory link).

Separately, the machine still carries a **dead `~/.dotfiles` bare-repo husk**:
0 tracked files, yet a stale `~/CLAUDE.md` (documenting the retired
bare-`$HOME` model) sits at the home root and is loaded into every session as
"project instructions" because the working directory is under `$HOME`. Home
Manager owns the home config now; the bare-repo model is fully superseded.

## Scope

**One spec, two clearly-separated halves** — kept distinct because they
**propagate differently**:

- **Half A (code)** — collapse the three link implementations into one. Spreads
  to every machine by `git pull`.
- **Half B (home-state)** — retire the `~/.dotfiles` husk + stale `~/CLAUDE.md`.
  This is per-machine local state; deleting it on one box does nothing for the
  others, so it is a **per-machine cleanup checklist**, not a repo edit.

### Out of scope

- Orca's worktree lifecycle and its `main`↔`origin` syncing.
- The Pure work-repo PR flow (`pure-dev`) — governed separately.
- chezmoi or any other third-party dotfile manager (the old
  `2026-07-08-...-dotfiles-chezmoi` direction is not revived).
- Any non-agent home-state (shell rc, editor config, etc.).
- A configurable profile set beyond the existing committed-`settings*.json`
  registry.

## Half A — one deployer (nix invokes bootstrap)

`agents/bootstrap.sh` becomes **the** deployer. The nix modules stop
reimplementing links and instead **invoke** it.

### `modules/home/claude.nix`

Replace the per-profile `ln -sfn` block with a loop that, per committed
`settings*.json`, calls bootstrap once:

```
for setsrc in "${agents}"/settings.json "${agents}"/settings.*.json; do
  [ -e "$setsrc" ] || continue
  base="$(basename "$setsrc" .json)"
  if [ "$base" = settings ]; then prof="$HOME/.claude"
  else prof="$HOME/.claude-''${base#settings.}"; fi
  CLAUDE_CONFIG_DIR="$prof" MACHINES_HOST_ID="${hostname}" \
    $DRY_RUN_CMD bash "${agents}/bootstrap.sh"
done
```

- The personal `~/.claude` invocation runs bootstrap's Codex block, so
  **`codex.nix`'s link logic folds away entirely** — its `home.file` /
  `mkOutOfStoreSymlink` entries and its `linkCodexMemory` activation script are
  removed. Home Manager GCs the old store-routed links after `writeBoundary`;
  bootstrap recreates them one-hop-direct, matching claude.nix's rationale
  (writable one-hop links, live edits, no EROFS on Claude's settings writer).
- Viability is high and measured: on `latitude5520`, 19 of 23 links already
  match between the two deployers.

### Single-source host-naming (folded in)

The drift's root cause is two independent host-id derivations. Fix: **one
source.**

- `bootstrap.sh` takes the host id from **`MACHINES_HOST_ID`** when set
  (nix passes `${hostname}` — the same value nix uses for everything else),
  falling back to its existing `host_id()` (`COMPUTERNAME` → `hostname`,
  sanitized) only when the env var is absent (Windows/non-Nix). nix and bash now
  compute the **identical** filename with zero mapping table.
- **Canonical filename = the raw `hostname`/config value** (e.g. `latitude5520`,
  `g16`). The curated content in the short-named files is migrated to the
  canonical name; the duplicate/stale files are removed:
  - `agents/hosts/latitude.md` → `agents/hosts/latitude5520.md` (move content).
  - g16: reconcile `g614jv.md` / `ME-G614JV.md` to the canonical NixOS
    `hostname` for that box (`g16`), preserving the real content, deleting the
    stale duplicate. The Windows install name (`ME-G614JV`) keeps its own file
    only if the Windows profile genuinely needs a distinct one; otherwise it is
    consolidated. (The plan resolves each host's canonical name against
    `flake.nix`/`hostname` and the file that actually holds content.)
- Removing this env indirection also removes bootstrap's dependency on the
  `hostname` binary inside home-manager activation.

### Incidental fixes surfaced by the DRY_RUN diff

- **Exclude `hooks/tests/` from hook linking.** bootstrap's `link_entries_into`
  currently links every entry under `plugin/hooks/` into `~/.codex/hooks/`,
  including the `tests/` directory and the test scripts. Skip `tests` (and
  non-hook files) so only runtime hooks are linked.
- **`settings.json` convergence.** On this host `~/.claude/settings.json` is a
  real file, not the one-hop link (Claude's own writer or a prior nix generation
  left it so). After the switch to bootstrap-as-deployer, bootstrap's
  backup-then-link makes it the one-hop link like every other profile; the
  displaced real file lands in `.bootstrap-bak`. Acceptance requires this to
  converge.

### Home-manager activation validity (the thing to verify before merge)

bootstrap must run cleanly inside home-manager activation:
- **PATH:** after `MACHINES_HOST_ID` removes the `hostname` dependency, the
  surface is coreutils + findutils (`mkdir ln mv rm readlink basename dirname
  find tr`), all present in HM activation. `git` is only used by
  `install_git_hooks`, which already returns early on `/etc/NIXOS`.
- **Dry-run:** `$DRY_RUN_CMD bash bootstrap.sh` echoes the invocation under
  `home-manager build`/`--dry-run`; a real activation runs it. (bootstrap's own
  `DRY_RUN` env is separate and not used by nix.)
- **GC ordering:** the loop runs `entryAfter ["writeBoundary"]` so HM has already
  removed prior store-routed links before bootstrap recreates them.

## Half B — retire the `~/.dotfiles` husk (per-machine checklist)

Per-machine home-state. **Just delete — history is disposable** (no `git bundle`
archive). Run this checklist on **each** machine independently:

**Per machine — g16, homeserver (Windows), latitude5520:**

1. Confirm the husk is dead: `git --git-dir=$HOME/.dotfiles --work-tree=$HOME
   ls-files` prints **0** tracked files (and nothing in the shell rc still
   sources from it).
2. `rm -rf ~/.dotfiles`.
3. Delete the stale `~/CLAUDE.md` (the bare-repo doc). Confirmed safe: the live
   deployer writes `~/.claude/CLAUDE.md` (→ `AGENTS.md`) — a **different path** —
   so nothing regenerates `~/CLAUDE.md`.
4. Remove the `dotfiles` fish alias from `~/.config/fish/config.fish` (and any
   other shell that defines it).
5. **Verify:** a fresh agent session no longer loads the bare-repo `~/CLAUDE.md`
   as project instructions; `~/.claude` links remain intact
   (`DRY_RUN=1 bash agents/bootstrap.sh` reports `would-link=0`).

On Windows the equivalents are the PowerShell/Git-Bash paths; the plan spells
out the Windows variant. Latitude5520 is done first (it is the machine at hand);
g16 and homeserver are ticked off when next in front of them — the checklist
lives in this spec and its completion is tracked per box.

## Data flow

- **`just switch` on a NixOS host** → `claude.nix` activation loops
  `settings*.json` → per profile, `CLAUDE_CONFIG_DIR=<prof>
  MACHINES_HOST_ID=<hostname> bash bootstrap.sh` → one-hop links for the shared
  set + per-profile `settings.json`; the `~/.claude` run also links `~/.codex`.
  No second link implementation runs.
- **`bash agents/bootstrap.sh` on Windows/macOS** → unchanged entry point; now
  the *only* implementation, so nix and non-nix machines produce byte-identical
  link topology (same host filename via the shared canonical rule).
- **Any session under `$HOME`** → no longer picks up a stray `~/CLAUDE.md` (Half
  B); only `~/.claude/CLAUDE.md` (→ `AGENTS.md`) and repo-local `CLAUDE.md`
  apply.

## Error handling / safety

- bootstrap already backs up any displaced real file into `.bootstrap-bak` and
  restores on symlink failure; that safety net now also covers the nix path.
- Half A is idempotent and re-runnable; a failed activation leaves live config
  intact (backups restored).
- Half B's `rm -rf ~/.dotfiles` is per-machine and guarded by step 1 (0 tracked
  files) — never delete a husk that still tracks files.
- Host-file migration is a `git mv` (content preserved); the old link target
  disappears only after the new canonical file exists.

## Testing / verification

1. **DRY_RUN convergence (Half A).** On `latitude5520` after `just switch`:
   `DRY_RUN=1 CLAUDE_CONFIG_DIR=$HOME/.claude bash agents/bootstrap.sh` reports
   `would-link=0 would-back-up=0` — the nix path and bootstrap now produce the
   identical topology. Repeat for a secondary profile if one exists locally.
2. **Host-naming single-source.** `~/.claude/host-memory.md`,
   `~/.codex/host-memory.md`, and (on a rebuilt nix host) the nix-made link all
   point at `agents/hosts/<hostname>.md` with `<hostname>` identical between
   bash and nix. No `latitude.md`/`latitude5520.md` split remains.
3. **Codex folded in.** `codex.nix` no longer contains link logic; `~/.codex`
   after `just switch` has the same entries as before (AGENTS.md, hooks.json,
   memory, personality, host-memory, skills, hooks *excluding* `tests/`,
   subagents).
4. **tests/ excluded.** `~/.codex/hooks/` contains no `tests` dir and no test
   scripts after a run.
5. **Nix activation runs bootstrap cleanly.** `just build` / a real `just
   switch` on a nix host completes with no PATH/`hostname` errors.
6. **Husk retired (Half B, per machine).** After the checklist on a box: `ls
   ~/.dotfiles` → absent; `ls ~/CLAUDE.md` → absent; a new session's loaded
   instructions no longer include the bare-repo doc; `~/.claude` links intact.
