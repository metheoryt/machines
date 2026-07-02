# Claude Code config (version-controlled)

The Claude Code user config — skills, agents, commands, statusline and a
committed per-profile `settings.json` — lives here and is **symlinked into both
`~/.claude` (personal) and `~/.claude-work` (work)** so the same setup is reused
on every machine (Windows 11 / Git Bash, macOS, Linux).

Because `~/.claude` is the *user-level* config, these skills/plugins/agents are
active in **every repo** you open Claude Code in — not just this one. And since
the links point straight at this repo's working tree, editing a file in
`~/.claude` from *any* repo edits the tracked file here; **commit from this repo
and pull on the other machines to propagate.** (See *Updating* below.)

## What's tracked

> **Note:** `AGENTS.md` is the canonical instruction file; `CLAUDE.md` (both here
> and at the repo root) is an in-repo symlink → `AGENTS.md`, because Claude Code
> reads `CLAUDE.md` while Codex reads `AGENTS.md` — one source, each tool reads
> its own filename. Mentions of "`CLAUDE.md`" below refer to that same shared
> content.

| Path | Linked into `~/.claude` as | Notes |
|---|---|---|
| `settings.personal.json` | `~/.claude/settings.json` | personal profile config (committed) |
| `settings.work.json` | `~/.claude-work/settings.json` | work profile config (committed; no secret). The Sentry secret is NOT here — it lives in each work repo's project-scope `.claude/settings.local.json` (gitignored), which Claude reads natively. A config-dir-root `settings.local.json` is NOT read. |
| `statusline-command.sh` | `statusline-command.sh` | compact status line |
| `balance-refresh.py` | `balance-refresh.py` | spend calculator (statusline depends on it) |
| `AGENTS.md` | `CLAUDE.md` | canonical global instructions; memory stores load via the `global-memory-load.sh` hook, not imports (see below); `agents/CLAUDE.md` is a symlink → it, and `~/.codex/AGENTS.md` links here too |
| `memory/global.md` | `memory/global.md` | global persistent memory store |
| `hosts/<host>.md` | `host-memory.md` | per-host memory, chosen by hostname |
| `skills/update-balance/` | `skills/update-balance` | per-entry link |
| `subagents/quick-tasks.md` | `agents/quick-tasks.md` | per-entry link — source lives in `subagents/`, target dir is the tool-dictated `agents/` |
| `commands/` | `commands/` (per-entry) | empty for now (`.gitkeep`) |

`skills/`, `subagents/` and `commands/` are linked **entry-by-entry**, so any
machine-local skill/agent you drop directly into `~/.claude` keeps working
alongside the tracked ones. (The source dir is `subagents/` — named that way
because `agents/` at the repo root is already this whole config tree; the
symlinks still land in the tool-dictated `~/.claude/agents/`.)

### Codex (`~/.codex`) — same setup, shared content

Codex is Claude-Code-compatible, so it reuses **this** config as its source of
truth rather than a separate copy. The tool-agnostic content here — `memory/`,
`hooks/`, `skills/`, and the canonical `AGENTS.md` — is symlinked into **both**
`~/.claude` and `~/.codex`. Only the format-divergent files live under
`agents/codex/` (`hooks.json`, `subagents/*.toml`) and link into `~/.codex`
alone — the `.toml` subagent defs land at `~/.codex/agents/*.toml`, the same
tool-dictated target dirname Claude uses, just read by a different tool.
Machine-local Codex state (`config.toml`, `auth.json`, sessions, caches) is
git-ignored (`agents/codex/.gitignore`) and never tracked. Both `bootstrap.sh`
and `modules/home/codex.nix` produce the identical `~/.codex` tree — the same
dual-mechanism model as the Claude side.

## What's NOT tracked (and never copy in)

Secrets, transcripts, caches and auto-regenerated state stay machine-local in
`~/.claude` and are git-ignored (`.gitignore` here lists them all):
`.credentials.json`, `.env`, `settings.local.json`, `projects/`, `sessions/`,
`tasks/`, `plans/`, `history.jsonl`, `file-history/`, `shell-snapshots/`,
`paste-cache/`, `downloads/`, `chrome/`, `session-env/`, `backups/`, `cache/`,
`stats-cache.json`, the various `*-cache`/`.last-*` state files, and the
balance/budget runtime files (`api-balance*.json`, `anchor.json`,
`spend-*.json`, …).

**Plugins are NOT symlinked.** They're already portable via `settings.json`
(`enabledPlugins` + `extraKnownMarketplaces` — no absolute paths). The
`plugins/` tree holds machine-specific absolute paths and is rebuilt on launch,
so a fresh machine re-installs the declared plugins automatically.

## Memory & knowledge base (three scopes)

Two distinct things load into every session:

- **Instructions** you curate by hand, in the always-loaded `CLAUDE.md` /
  `AGENTS.md`.
- **Persistent memories** Claude records itself (preferences, confirmed
  feedback, learned context). A "memory store" is just a markdown file injected
  every session by the `global-memory-load.sh` SessionStart hook — so it's read
  each session and appended to over time. (This replaced `CLAUDE.md` `@import`s,
  which only Claude Code resolved; the hook works for Codex too.)

| Scope | Instructions (curated) | Memories (Claude-written) | Synced |
|---|---|---|---|
| **Global** | `CLAUDE.md` | `memory/global.md` | everywhere |
| **Per-host** | `hosts/<host>.md` (one file holds both) | per host |
| **Per-project** | each repo's own `CLAUDE.md` | that repo's `.claude/memory/project.md` (or `CLAUDE.local.md`) | per repo |

The `global-memory-load.sh` SessionStart hook injects `memory/global.md`,
`memory/practices.md`, and `host-memory.md` into every session — so all three
load regardless of cwd, in both Claude Code and Codex (it derives the config dir
from its own path, so the one script serves `~/.claude` and `~/.codex`).
`host-memory.md` is a symlink to `hosts/<hostname>.md` chosen per machine
(`ME-G614JV`, `g16`, `latitude5520`, …) — a host with no file yet gets an empty
stub seeded by `bootstrap.sh`. The per-project store
(`<repo>/.claude/memory/project.md`) is loaded by the sibling
`project-memory-check.sh` SessionStart hook from whatever repo you're in (merged
with global + per-host), which also offers to start tracking it in repos that
don't have one yet (silence per-repo with an empty `.claude/memory/.skip`).
`CLAUDE.md` also carries a *"Recording a memory — pick the scope"* section
telling Claude which file to append to; since `CLAUDE.md` outranks the default
system prompt, that overrides the harness's built-in per-project memory dir.

**These memory files are git-tracked** — a memory is committed when *you* commit
(not auto-committed each write), and that commit + push + pull is how memories
sync across machines. The native fallback store
(`~/.claude/projects/<encoded>/memory/`) stays gitignored and machine-local.
Never put secrets in any tracked memory file.

> The global `CLAUDE.md` keeps the gortex block inside its
> `<!-- gortex:rules:start/end -->` markers; the memory section is appended
> *after* the end marker so gortex's regeneration leaves it intact.

## Set up on a new machine

```bash
git clone <this repo> ~/nix      # or wherever you keep it
bash ~/nix/agents/bootstrap.sh
```

`bootstrap.sh` honors `$CLAUDE_CONFIG_DIR` (defaults to `~/.claude`), backs up
any existing real file to `<name>.bak` before linking, and is idempotent.

### Per-profile bootstrap

From this repo, prefer the `just` recipes over calling the script directly:

- `just agent-bootstrap` — the **personal** profile: `~/.claude` + `~/.codex`,
  forced personal even if `$CLAUDE_CONFIG_DIR` is set elsewhere in your shell
  (`env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh`).
- `just agent-bootstrap-work` — a **secondary** profile, e.g. `~/.claude-work`
  (invoked as `ccw`): links the SHARED set (`AGENTS.md`→`CLAUDE.md`, `memory/`,
  `hosts/`→`host-memory.md`, `hooks/`, `skills/`, `subagents/`, `commands/`,
  `statusline-command.sh`, `balance-refresh.py`) **plus** the committed
  `settings.work.json` → `settings.json`. It never touches the machine-local
  `settings.local.json` (which holds the profile's Sentry secret) or its Codex
  config (`CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh`).
  On NixOS this profile is also managed by `just switch` (see the nix section).

Direct invocation, if you need something other than those two: `bash
agents/bootstrap.sh` (personal) or `CLAUDE_CONFIG_DIR=<dir> bash
agents/bootstrap.sh` (any other profile — SHARED set + `settings.work.json`).

### Windows note — Developer Mode

On Windows the script sets `MSYS=winsymlinks:nativestrict` so Git Bash creates
**real native symlinks**. That requires one of:

- **Developer Mode ON** — Settings → Privacy & security → For developers → *Developer Mode*; **or**
- run the Git Bash shell **as Administrator**.

Without one of those, `ln -s` falls back to copies and the "edit-anywhere"
behavior breaks. Enable Developer Mode and re-run `bootstrap.sh`.

### Linux / macOS — the nix way (optional)

This repo is a home-manager flake, so `modules/home/claude.nix` declares the
identical symlinks via `mkOutOfStoreSymlink`. It's imported by
`modules/home/me.nix`, so a normal rebuild wires them up:

```bash
just switch        # or: sudo nixos-rebuild switch --flake .#<host>
```

It assumes the repo is checked out at `~/nix`; edit the `claude = …` path in
`modules/home/claude.nix` if you clone elsewhere. home-manager backs up any
pre-existing real file (`backupFileExtension = "backup"`). `bootstrap.sh` and
the nix module produce the same links — use whichever you prefer on Linux/macOS;
**Windows must use `bootstrap.sh`.**

## Updating (from every repo)

The links are live, so the loop is just normal git:

1. Edit a skill/agent/statusline/etc. — either here, or via `~/.claude/...`
   while working in *any* other repo (it's the same file through the symlink).
2. `cd ~/nix && git add agents/ && git commit && git push`.
3. On the other machines: `git pull`. Edits to already-linked files are live
   immediately (no step). New *files* need their symlink created — but that's
   now automatic (see below).

### When do I re-run `bootstrap.sh`?

Almost never — only **once per new non-nix machine** (the clone step above).
After that first run installs the git-hook auto-refresh, you don't re-run it by
hand:

- **Non-nix machines (Windows/macOS):** `bootstrap.sh` points this clone's
  `core.hooksPath` at `agents/git-hooks/`, so `post-merge` / `post-rewrite` /
  `post-checkout` re-link automatically after every `git pull` /
  `pull --rebase` / checkout. Silent when nothing changed; prints a one-liner
  when it links a new entry. (If *you* already set a custom `core.hooksPath`,
  bootstrap won't touch it — re-run bootstrap manually after adding files.)
- **NixOS laptops:** `just switch` owns the links; the git hooks no-op there.

**No manual sync between the two mechanisms.** Both `bootstrap.sh`
(`link_entries_into`) and `modules/home/claude.nix` (`linkEntries` via
`readDir`) auto-discover everything under `hooks/`, `skills/`, `subagents/`,
`commands/` (source dirs — they land in the tool-dictated `~/.claude/agents/`).
Drop a new file in one of those dirs and commit it — nothing else to wire up.
(nix reads git-*tracked* files, so commit the new entry for `switch` to see it;
`bootstrap.sh` reads the working tree and links it right away.)

---

## Global budget across devices (shared ledger)

Individual Anthropic accounts have no Admin API / cost report, so to show the
**same remaining-credit number on every device** the statusline aggregates
per-device spend through a **cloud-synced folder** (OneDrive / Dropbox / Drive —
**not** git; git isn't real-time and would conflict on every write).

### Enable it

Point every device at the **same synced folder** via `CLAUDE_BUDGET_DIR`:

| OS | Example |
|---|---|
| Windows | `setx CLAUDE_BUDGET_DIR "%USERPROFILE%\OneDrive\claude-budget"` |
| macOS | `export CLAUDE_BUDGET_DIR="$HOME/Library/CloudStorage/OneDrive-Personal/claude-budget"` |
| Linux | `export CLAUDE_BUDGET_DIR="$HOME/Dropbox/claude-budget"` |

Create the folder once; it'll fill in automatically. **Do not commit it.**

### How it works

Files in `$CLAUDE_BUDGET_DIR`:

- `anchor.json` — `{"balance": <usd>, "set_at": <epoch>}` — one shared anchor.
- `spend-<device>.json` — `{"device","set_at","spent","computed_at"}` — one per
  device. Device id = hostname sanitized to `[A-Za-z0-9_-]`.

`balance-refresh.py` selects its mode automatically, in priority order:

1. `$ANTHROPIC_ADMIN_KEY` set → **admin** mode (org-wide Cost Report; 🌐/🥷).
2. else `$CLAUDE_BUDGET_DIR` set → **shared** mode: compute this device's spend
   since `anchor.json`'s `set_at` (same transcript scan as local mode) and write
   it atomically to `spend-<device>.json`.
3. else → **local** mode (single-device estimate).

The statusline, in shared mode, reads `anchor.json` and sums `spent` across all
`spend-*.json` whose `set_at` matches the anchor (stale files from before the
last re-anchor count as 0 until that device catches up). It shows
`🔗🏦<remaining>↘<summed-spend>`. A leading `~` means this device hasn't reported
into the ledger yet.

### Re-anchoring (top-up / correct)

Use the `update-balance` skill (or run the worker directly). When
`$CLAUDE_BUDGET_DIR` is set it writes `anchor.json` to the synced folder and
clears every `spend-*.json` so all devices recompute against the new anchor.

```bash
"$PY" ~/.claude/skills/update-balance/update-balance.py <dollars>
# where $PY resolves a working python3/python — see skills/update-balance/SKILL.md
```

### Convergence

The number converges as fast as your cloud provider syncs the folder (seconds to
a minute, typically). Until a device's `spend-<device>.json` syncs in, its spend
counts as 0, so the figure is a slight over-estimate of remaining, never under.
