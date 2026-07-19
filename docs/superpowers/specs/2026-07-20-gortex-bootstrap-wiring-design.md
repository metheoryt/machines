# Design: wire gortex into machine bootstrap

<!-- Status: approved (brainstorm) — 2026-07-20 -->

## Problem

`gortex` (code-intelligence engine + MCP server) was installed **by hand** on
`g513ie`. Bringing it up on a machine currently takes three manual steps —
install the binary, run `gortex install` (machine-local MCP/skills/agents/hooks
wiring), and have a daemon available. Nothing in this repo's bootstrap
provisions gortex, so every fleet member is a manual setup and drifts.

Goal: on the three `agents`-role workstations — `latitude` (NixOS),
`desktop` + `server` (Windows) — gortex's **binary** comes up automatically
through the existing bootstrap mechanisms, and its **machine-local wiring** is
(re)generated idempotently, **without** mutating the shared fleet-synced
`agents/AGENTS.md` and **without** committing any generated artifact.

`hub` (Debian VPS) is **out of scope** by decision — a 288 MB binary + graph
indexing is not worth it on a small always-on VPS.

## Constraints and established facts (verified this session)

- **The repo already treats gortex as a per-machine tool whose config is
  machine-local.** Commit `4a4ec52 docs(spec): drop gortex agents from repo —
  gortex owns them` is the standing decision: generated skills/agents are **not**
  committed; `gortex install` regenerates them per machine. `settings.local.json`
  (never committed, per `agents/.gitignore`) holds the gortex hooks with a
  hardcoded per-OS absolute binary path.
- **`gortex install` has the exact controls we need** (verified via `--help`):
  - `--no-claude-md` — skip merging the rule block into `~/.claude/CLAUDE.md`
    (which symlinks to `agents/AGENTS.md`). **Load-bearing:** without it,
    bootstrap would re-mutate the shared, git-tracked `AGENTS.md` on every run.
  - `--agents claude-code` — configure only the Claude Code adapter.
  - `--yes` — non-interactive (implied when stdin isn't a TTY).
  - `--hooks/--no-hooks`, `--hook-mode {deny|enrich|consult-unlock|nudge}` —
    hook posture (default `deny`, matching the current machine-local setup).
  - `--start` — start the daemon detached (we do **not** use this; see below).
- **`gortex mcp` auto-manages the daemon** (verified via `--help`):
  `--no-daemon` is a deprecated no-op — "the embedded server is used
  automatically when no daemon is available". The `.mcp.json` `gortex mcp`
  launch therefore brings up the daemon per session. **No daemon-start step is
  needed in bootstrap.**
- **No Nix package/flake exists** for gortex (verified against `docs/installation.md`).
  NixOS install must be a custom derivation over the GitHub release tarball.
- **Pure Nix cannot "float"** — a fixed-output derivation needs a pinned
  version + sha256. Decision: `latitude` gets **pinned + documented bump**;
  the Windows boxes float naturally (re-run installer to upgrade).
- **The Windows boxes have no Nix** (project memory) — the `gortex.nix`
  `nix build --dry-run` gate must run on `latitude` after a `git pull`, never here.
- **Windows installer facts** (verified): PowerShell installer
  `irm https://get.gortex.dev/install.ps1 | iex` lands the binary at
  `%LOCALAPPDATA%\Programs\gortex\gortex.exe` and edits user PATH (the PATH edit
  is **not** visible mid-session — reference the absolute path within the same run).
- **`bootstrap.sh` is currently a pure config-symlinker** — it installs no
  binaries. It already has a NixOS-gate idiom (`[ -e /etc/NIXOS ] && return 0`
  in `install_git_hooks`) and re-runs on every `git pull` via `core.hooksPath`.

## Non-goals

- Per-repo `gortex init` / committing `.mcp.json` / daemon repo-tracking — that
  is the `gortex-align` skill's job, per repo. (This repo's own `.mcp.json` is
  untracked and stays that way here; tracking it is a separate `gortex-align` pass.)
- Provisioning `hub`.
- Changing the hook posture, or committing any generated skill/agent/hook.

## Design

### 1. Binary install — per platform

**Windows (`desktop`, `server`)** — a new install-if-missing step in
`bootstrap.sh`, gated to Windows (`IS_WINDOWS=1`, already computed at the top):

- If `gortex` is not already resolvable (PATH **or** the known absolute path
  `$LOCALAPPDATA/Programs/gortex/gortex.exe`), run:
  `powershell -NoProfile -Command "irm https://get.gortex.dev/install.ps1 | iex"`.
- **Install-if-missing, not every run** — otherwise every `git pull` re-downloads.
- Within the same bootstrap run, reference the binary by its absolute path
  (`$LOCALAPPDATA/Programs/gortex/gortex.exe`), since the installer's PATH edit
  is not visible to the current process.
- Floats naturally: re-running the installer upgrades in place.

**NixOS (`latitude`)** — a new `modules/home/gortex.nix`:

- A derivation fetching `gortex_linux_<arch>.tar.gz` (exact asset name confirmed
  from the releases page at implementation; docs show `gortex_${OS}_${ARCH}.tar.gz`)
  from GitHub releases at a **pinned version + sha256**, unpacked, with
  `autoPatchelfHook` (+ `stdenv.cc.cc.lib`/`glibc` as needed for the CGO binary),
  exposing `bin/gortex`. Added to the home profile's `home.packages`.
- Imported into the home configuration alongside the other `modules/home/*`.
- **`bootstrap.sh` does NOT install the binary on NixOS** — nix owns it there.
- **Float = bump**: upgrading is editing the version + sha256 in `gortex.nix`.
  A `just gortex-bump [version]` helper automates the hash refresh
  (`nix-prefetch-url` / a failing-build hash capture), so a bump is one command
  + a `switch`. Pin the current baseline at the version live on the fleet
  (`v0.60.0` as of writing).

### 2. Machine-local wiring — all three boxes, in `bootstrap.sh`

After the binary is resolvable, an idempotent wiring step guarded by the binary's
presence:

```sh
gortex install --yes --agents claude-code --no-claude-md
```

- `--no-claude-md` guarantees `agents/AGENTS.md` is never touched → no shared-file
  mutation, no fleet-wide ping-pong across floating versions, no merge conflicts.
- Regenerates machine-local skills/agents/hooks per machine → nothing generated
  is committed (upholds `4a4ec52`).
- **No `--start`** — `gortex mcp` (from `.mcp.json`) brings the daemon up per
  session.
- **Runs from a normal shell, not nix activation.** Mirroring the existing
  `install_git_hooks` gate, the wiring step **skips under NixOS home-manager
  activation** (`[ -e /etc/NIXOS ]`) to keep activation fast/offline-safe; on
  `latitude` it runs when `bootstrap.sh` is invoked from a login shell (or a
  `just gortex-setup` helper). On Windows/macOS/non-Nix Linux it runs inline.
- **Idempotency guard:** to avoid re-running `gortex install` on every `git pull`,
  the step no-ops when the wiring already exists (e.g. a gortex entry already in
  the profile's `~/.claude.json` / the gortex hooks already present in
  `settings.local.json`), with an env override (`GORTEX_REWIRE=1`) to force a
  refresh after an upgrade. Exact detection predicate chosen at implementation.

### 3. Shared `AGENTS.md` — undo the accidental rewrite

The working tree currently has `agents/AGENTS.md` gutted (−162/+26) by the manual
`gortex install` run (it merged its rule block through the
`~/.claude/CLAUDE.md → agents/AGENTS.md` symlink). The original is safe in git
history.

- **Restore `agents/AGENTS.md` to `HEAD`** so the curated, shared gortex
  documentation is preserved.
- `--no-claude-md` guarantees bootstrap never redoes this.
- Commit the restore **independently** so the −162 deletion never rides along in
  an unrelated commit.

### 4. Documentation

- A short note in `agents/README.md` (or the repo README's bootstrap section)
  describing the gortex bootstrap behavior and the `just gortex-bump` /
  `just gortex-setup` helpers.
- Per-host memory / project memory updated as warranted (the `latitude`
  validation deferral; the bump workflow).

## Components and boundaries

| Unit | Responsibility | Platform | Depends on |
|------|----------------|----------|------------|
| `modules/home/gortex.nix` | Declarative gortex **binary** (pinned tarball derivation) | NixOS only | GitHub release asset + sha256 |
| `bootstrap.sh` › `ensure_gortex_binary` | Install binary if missing | Windows only | PowerShell installer |
| `bootstrap.sh` › `ensure_gortex_wired` | `gortex install --no-claude-md` idempotently | all (skipped in nix activation) | binary present |
| `just gortex-bump` | Refresh pinned version+hash in `gortex.nix` | dev convenience | nix |
| `just gortex-setup` | Run the wiring step on NixOS from a login shell | NixOS convenience | binary present |
| `agents/AGENTS.md` restore | Undo the manual-install rewrite | shared | git history |

## Validation plan

- **Windows (`g513ie`, here):** dry-run + real run of `bootstrap.sh`; confirm the
  binary step no-ops (already installed), the wiring step runs/no-ops correctly,
  and `agents/AGENTS.md` is untouched by a bootstrap run.
- **NixOS (`latitude`):** defer `nix build --dry-run '.#...gortex...'` and a real
  `switch` to `latitude` after a `git pull` — cannot be validated on Windows.
- **Idempotency:** run `bootstrap.sh` twice; second run reports no changes.
- **Shared-file safety:** assert `git diff --stat agents/AGENTS.md` is empty after
  a bootstrap run.

## Risks / open implementation details

- **CGO binary under `autoPatchelfHook`** — may need extra runtime libs; resolved
  empirically on `latitude` at build time.
- **Exact release asset name + arch string** — confirm from the releases page
  when writing `gortex.nix`.
- **Wiring idempotency predicate** — the precise "already wired" check is chosen
  at implementation; must be cheap and robust across gortex versions.
- **`gortex install` network use** — it may fetch skill content; the NixOS-
  activation skip avoids doing that during `switch`.
