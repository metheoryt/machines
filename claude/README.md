# Claude Code config (version-controlled)

The Claude Code user config — skills, agents, commands, statusline and
`settings.json` — lives here and is **symlinked into `~/.claude`** so the same
setup is reused on every machine (Windows 11 / Git Bash, macOS, Linux).

Because `~/.claude` is the *user-level* config, these skills/plugins/agents are
active in **every repo** you open Claude Code in — not just this one. And since
the links point straight at this repo's working tree, editing a file in
`~/.claude` from *any* repo edits the tracked file here; **commit from this repo
and pull on the other machines to propagate.** (See *Updating* below.)

## What's tracked

| Path | Linked into `~/.claude` as | Notes |
|---|---|---|
| `settings.json` | `settings.json` | statusline path is portable (`$HOME`) |
| `statusline-command.sh` | `statusline-command.sh` | compact status line |
| `balance-refresh.py` | `balance-refresh.py` | spend calculator (statusline depends on it) |
| `skills/update-balance/` | `skills/update-balance` | per-entry link |
| `agents/quick-tasks.md` | `agents/quick-tasks.md` | per-entry link |
| `commands/` | `commands/` (per-entry) | empty for now (`.gitkeep`) |

`skills/`, `agents/` and `commands/` are linked **entry-by-entry**, so any
machine-local skill/agent you drop directly into `~/.claude` keeps working
alongside the tracked ones.

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

## Set up on a new machine

```bash
git clone <this repo> ~/nix      # or wherever you keep it
bash ~/nix/claude/bootstrap.sh
```

`bootstrap.sh` honors `$CLAUDE_CONFIG_DIR` (defaults to `~/.claude`), backs up
any existing real file to `<name>.bak` before linking, and is idempotent.

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
2. `cd ~/nix && git add claude/ && git commit && git push`.
3. On the other machines: `git pull`. New files need `bootstrap.sh` (or a nix
   rebuild) re-run to create their links; edits to already-linked files are
   picked up with no extra step.

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
