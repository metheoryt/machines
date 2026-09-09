# Claude Code config (version-controlled)

The Claude Code user config — skills, agents, commands, statusline and a
committed per-profile `settings.json` — lives here and is **symlinked into every
profile** so the same setup is reused on every machine (Windows 11 / Git Bash,
macOS, Linux). The profile set is a **registry driven by the committed settings
files**: `settings.json` → `~/.claude` (personal), and each
`settings.<postfix>.json` → `~/.claude-<postfix>` (e.g. `settings.pure.json` →
`~/.claude-pure`, the work profile). Add a `settings.<postfix>.json` and that
profile is provisioned automatically — no wiring edit.

Because `~/.claude` is the *user-level* config, these skills/plugins/agents are
active in **every repo** you open Claude Code in — not just this one. And since
the links point straight at this repo's working tree, editing a file in
`~/.claude` from *any* repo edits the tracked file here; **commit from this repo
and pull on the other machines to propagate.** (See *Updating* below.)

## What's tracked

> **Who owns what (2026-07-28).** Dotfiles' work-tree is `$HOME`, so any file
> whose rightful home is a path under `$HOME` is tracked **in the dotfiles repo,
> at that path** — not here: `~/.claude/CLAUDE.md`,
> `~/.claude/memory/{global.md,personality/}`, `~/.claude/host-memory.md`,
> `~/.claude/skills/{gortex-align,update-balance,worktree-agent}/`,
> `~/.claude/statusline-command.sh`, `~/.claude/balance-refresh.py`. This repo
> keeps what has **no** `$HOME` path: `bootstrap.sh`, the tests, and the
> fleet-coupled plugin (`ship`, `kb-refresh`, `lib`, `orca-setup`, `orca-repair` —
> all tested, all reading `fleet.json`).
>
> **One deployer per path.** Dotfiles owns everything inside `~/.claude` listed
> above. `bootstrap.sh` owns each `~/.claude-<postfix>` and the Orca-managed
> account profiles, and it
> links those **at the primary profile** (`$PRIMARY_DIR`, always `~/.claude`),
> never at this repo. `retire_link()` clears a link left over from the old
> arrangement and refuses to delete a real file; `link_if_present()` skips a
> fan-out whose primary source is not in place yet.
>
> Exception: `settings.json` stays `copy_managed` from this repo, because Orca and
> Claude both write the live file and the stamp logic keeps that machine-local.
>
> The former canonical `agents/AGENTS.md` (and its `agents/CLAUDE.md` symlink) are
> gone — that content is now `~/.claude/CLAUDE.md` on dotfiles `main`. The
> repo-root `AGENTS.md`/`CLAUDE.md` pair is unrelated: it is *this repo's* own
> instruction file and stays.

| Path | Linked into `~/.claude` as | Notes |
|---|---|---|
| `settings.json` | `~/.claude/settings.json` | personal profile config (committed) |
| `settings.<postfix>.json` | `~/.claude-<postfix>/settings.json` | one secondary profile per file (registry). `settings.pure.json` → `~/.claude-pure` (work; committed, no secret). The Sentry secret is NOT here — it lives in each work repo's project-scope `.claude/settings.local.json` (gitignored), which Claude reads natively. A config-dir-root `settings.local.json` is NOT read. |
| `subagents/` | `agents/<entry>` | linked entry-by-entry, so machine-local agents coexist |
| `plugin/` | `skills/cyphy` | whole-directory symlink — the "cyphy" skills-directory plugin (`skills/`, `agents/` [was `subagents/`], `hooks/hooks.json`), discovered by Claude Code as `cyphy@skills-dir`: live, in place, no copy-to-cache, no install/update step |

`plugin/` is linked as **one whole directory** (`~/.claude/skills/cyphy`, and
`~/.claude-<postfix>/skills/cyphy` in each secondary profile) — Claude Code discovers its
`.claude-plugin/plugin.json` and loads it as `cyphy@skills-dir`. Skills and
subagents load namespaced under the plugin (e.g. `/cyphy:ship`). A
machine-local skill/agent dropped directly into `~/.claude/skills/` or
`~/.claude/agents/` still works fine alongside it — it's just not part of
`cyphy`.

## Session hooks

Seven scripts under `plugin/hooks/`, registered in `plugin/hooks/hooks.json`.
None of them was described anywhere until 2026-09-09, which is how one of them
became a delete candidate in `docs/2026-09-09-feature-inventory.md` on the
strength of scoring zero prose lines. A hook changes how every session behaves;
it needs a line here more than a script does.

| Hook | Event | What it does | Mute |
|---|---|---|---|
| `global-memory-load.sh` | SessionStart ×2 | Injects `memory/core.md` verbatim plus an INDEX of the other stores (path, size, `##` headings with line numbers). Two registrations because the stdout cap is per invocation. Takes the config dir as `$1` from the caller. | — |
| `project-memory-check.sh` | SessionStart | Loads the repo's `.claude/memory/project.md`, and offers to start tracking one where it does not exist. | — |
| `gortex-onboard-check.sh` | SessionStart | Reports whether the cwd's repo is indexed by the gortex daemon. | — |
| `worktree-workflow.sh` | SessionStart | Injects the git conventions for a session running inside a worktree. | — |
| `register-reinject.sh` | UserPromptSubmit | Re-states the reply register (`memory/core.md` § Register) each turn, because a rule stated once at session start decays. | — |
| `dotfiles-offer.sh` | PostToolUse (Edit/Write/NotebookEdit) | Surfaces a just-touched file that has no other home as a tracking candidate, deduped per session. Its rules live in the hook, not in prose — see `$HOME/CLAUDE.md` for the decision it hands you. | — |
| `prose-hedge-check.sh` | PostToolUse (Edit/Write) | Greps a prose deliverable (`*.md` under `docs/`/`specs/`, or named `*spec*`/`*design*`/`*tech-solution*`) for two phrase classes: a **hedge** the author wrote instead of resolving the question, and an **absolute negative** ("X does not exist") — the shape that is cheap to check and expensive to get wrong. Non-blocking by design: the phrases are legitimate often enough that a gate would train the reader to dismiss it. Born from the CFT-5051 review, where three of eight corrections sat behind the author's own hedges. Skips `memory/`, `CLAUDE.md` and `AGENTS.md` — a note to self is allowed to be tentative. | `PROSE_HEDGE_CHECK_OFF=1` |

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
  which only Claude Code resolved; the hook is tool-agnostic.)

**Every store below lives in the dotfiles repo now, at its real `$HOME` path.**
None of them is in this repo; `bootstrap.sh` only fans the other profiles out at
the primary. Editing one is a plain write to a dotfiles-tracked file.

| Scope | Instructions (curated) | Memories (Claude-written) | Where it is tracked |
|---|---|---|---|
| **Global** | `~/.claude/CLAUDE.md` | `~/.claude/memory/global.md` + `memory/personality/*.md` | dotfiles `main` — shared, byte-identical everywhere |
| **Per-host** | `~/.claude/host-memory.md` (one file holds both) | dotfiles **machine branch** — host-local, never on `main` |
| **Per-project** | each repo's own `CLAUDE.md` | that repo's `.claude/memory/project.md` (or `CLAUDE.local.md`) | per repo |

The `global-memory-load.sh` SessionStart hook injects `memory/global.md`,
the `memory/personality/` facets (`tone.md`, `habits.md`, `values.md`,
`practices.md`), and `host-memory.md` into every session — so all of them
load regardless of cwd. The hook takes the config dir as an argument rather than
deriving it, so one script serves every profile.
`host-memory.md` is a **real file on this machine's dotfiles branch** — no
hostname lookup and no stub seeding. It replaced `hosts/<host-id>.md`, whose
`$HOST_ID` scheme keyed on OS-hostname *identity* rather than machine and had
drifted to 7 files for 5 boxes; dotfiles is already branch-per-machine, so it
needs no host id at all. The per-project store
(`<repo>/.claude/memory/project.md`) is loaded by the sibling
`project-memory-check.sh` SessionStart hook from whatever repo you're in (merged
with global + per-host), which also offers to start tracking it in repos that
don't have one yet (silence per-repo with an empty `.claude/memory/.skip`).
`CLAUDE.md` also carries a *"Recording a memory — pick the scope"* section
telling Claude which file to append to; since `CLAUDE.md` outranks the default
system prompt, that overrides the harness's built-in per-project memory dir.

**These memory files are git-tracked in the dotfiles repo** — so unlike before,
they ARE committed automatically: the 10-minute `dotfiles-sync` timer commits
tracked `$HOME` changes to this machine's branch and pushes. It debounces, so one
editing burst is one commit rather than one per tick (see
`provision/dotfiles-sync.sh`, `sync_should_commit`). Getting a memory onto `main`
so every box sees it is still manual: `/dotfiles-promote`. The native fallback
store (`~/.claude/projects/<encoded>/memory/`) stays gitignored and
machine-local.
Never put secrets in any tracked memory file.

> The global `CLAUDE.md` keeps the gortex block inside its
> `<!-- gortex:rules:start/end -->` markers; the memory section is appended
> *after* the end marker so gortex's regeneration leaves it intact.

## Set up on a new machine

```bash
git clone <this repo> ~/machines      # or wherever you keep it
bash ~/machines/agents/bootstrap.sh
```

`bootstrap.sh` honors `$CLAUDE_CONFIG_DIR` (defaults to `~/.claude`), backs up
any existing real file to `<name>.bak` before linking, and is idempotent.

### Per-profile bootstrap

From this repo, prefer the `just` recipes over calling the script directly:

- `just agent-bootstrap` — the **personal** profile `~/.claude` (and, at the end
  of the run, every Orca-managed account profile), forced personal even if
  `$CLAUDE_CONFIG_DIR` is set elsewhere in your shell
  (`env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh`).
- `just agent-bootstrap-profile <postfix>` — a **secondary** profile
  `~/.claude-<postfix>`, e.g. `pure` → `~/.claude-pure` (invoked as `ccp`):
  links this repo's shared set (`plugin/` as the `cyphy` whole-directory link, and
  `subagents/` entry-by-entry) **plus** the dotfiles-owned content sourced from the
  PRIMARY profile, not from here (`~/.claude/CLAUDE.md`, `~/.claude/memory/*`,
  `~/.claude/host-memory.md`, `~/.claude/statusline-command.sh`,
  `~/.claude/balance-refresh.py`) **plus** the committed
  `settings.<postfix>.json` → `settings.json` (falls back to the primary
  `settings.json` if that file isn't committed). It never touches the
  machine-local `settings.local.json` (which holds the profile's Sentry secret)
  (`CLAUDE_CONFIG_DIR="$HOME/.claude-<postfix>" bash agents/bootstrap.sh`).
  **Deprecated** — driving extra profiles through `$CLAUDE_CONFIG_DIR` is on its
  way out; only `settings.json` is committed today, and Orca's account profiles
  are handled by the mirror below instead.
  On NixOS every registered profile is also managed by `just switch` (see the nix section).

Direct invocation, if you need something other than those recipes: `bash
agents/bootstrap.sh` (personal) or `CLAUDE_CONFIG_DIR=<dir> bash
agents/bootstrap.sh` (any other profile — SHARED set + the matching
`settings.<postfix>.json`).

### Orca-managed profiles — retired 2026-09-09

Orca runs Claude Code against a **per-account** config dir it creates at login
and owns, keyed by an Orca-internal id:

```
~/.local/share/orca/claude-accounts/<orca-profile-id>/auth
```

Three scripts used to manage that dir — `orca-profile-sync.sh` (mirror the
primary profile in), `orca-profile-harvest.sh` (archive it out to
`~/.claude-profiles/<name>` so transcripts outlived it), `orca-profile-link.sh`
(relocate it into `$HOME` and symlink Orca's dir back). **All three are deleted,
along with their three suites: 1,809 lines.** Orca's own account switcher is what
the fleet uses now, so the state they managed is not produced any more — checked
2026-09-09: `claude-accounts` was an EMPTY directory on air (created 4 Aug, never
populated), absent on g15, and no box had a `~/.claude-profiles`.

Their reasoning is in git — `git log --diff-filter=D -- 'agents/orca-profile-*'`
— and it was reasoning, not accretion: `review/2026-08-03-path-ledger.md` rows
134-136 examined all three and marked each *keep*, because sync was the only one
that pushed config in, harvest was an archive with no `--delete`, and
`bootstrap.sh` ran `link --relink` then sync then harvest in that order so a
re-auth broken link was healed before sync wrote into it. They were not
redundant. They were answering a question the fleet stopped asking.

#### Never bootstrap an Orca dir as a secondary profile

**This is the one piece that survived the deletion, and it changed shape.** An
account dir's basename is `auth`, so the `.claude-<postfix>` convention resolves
`POSTFIX=auth`, finds no `settings.auth.json`, and falls back to deploying the
**tracked baseline** into a directory this repo does not own. `bootstrap.sh`
detects the account dir (its `.orca-managed-claude-auth` marker, or the canonical
path) and **now refuses, exit 3**. It used to redirect to the mirror — that
destination is gone, and deleting the scripts without keeping the check would
have turned the incident below back on silently. The scripts were the redirect's
destination, never its reason.

This is what went wrong on 2026-08-01: `git-hooks/_refresh-claude-config` runs
bootstrap after every pull/checkout/rebase and passed the shell's own
`CLAUDE_CONFIG_DIR` straight through. Inside an Orca terminal that is the
account dir, so a single `git stash` round-trip re-seeded that profile's
`settings.json` from the baseline and moved the merged file into
`.bootstrap-bak`. Both ends are still closed — the hook drops the variable, and
bootstrap refuses the dir even when invoked by hand from an Orca terminal.

### Windows note — Developer Mode

On Windows the script sets `MSYS=winsymlinks:nativestrict` so Git Bash creates
**real native symlinks**. That requires one of:

- **Developer Mode ON** — Settings → Privacy & security → For developers → *Developer Mode*; **or**
- run the Git Bash shell **as Administrator**.

Without one of those, `ln -s` falls back to copies and the "edit-anywhere"
behavior breaks. Enable Developer Mode and re-run `bootstrap.sh`.

### Gortex (code-intelligence MCP server)

`bootstrap.sh` also brings up [gortex](https://github.com/zzet/gortex):

- **Binary.** On Windows it installs gortex if missing (upstream PowerShell
  installer; floats to latest — re-run it to upgrade). Everywhere else the
  binary comes from `tier_gortex`, which installs the release pinned in
  `provision/gortex.version`, so bootstrap installs nothing there. (This used to
  read "on NixOS the binary is declarative, `pkgs/gortex.nix`" — that tree was
  deleted 2026-08-01 and none of those files exist.)
- **Machine-local wiring.** It runs `gortex install --no-claude-md`, which
  regenerates the profile's gortex skills/agents/hooks + user MCP config.
  `--no-claude-md` is load-bearing: it keeps gortex's rule block OUT of the
  shared, git-tracked `AGENTS.md` (reached via the `~/.claude/CLAUDE.md`
  symlink), so bootstrap never mutates the fleet-synced instruction file. The
  generated artefacts are machine-local and never committed — gortex owns them.
- **Idempotent.** Re-running bootstrap skips the wiring when the profile is
  already wired; `GORTEX_REWIRE=1` forces a refresh (e.g. after an upgrade).
- **Hooks are merged into `settings.json` afterwards** (`gortex_merge_hooks`).
  `gortex install` writes them to the profile's `settings.local.json`, and
  **Claude Code does not read a user-scope `settings.local.json` at all** —
  probed 2026-07-31: a marker hook and an `env` entry placed in
  `~/.claude/settings.local.json` neither fired nor applied, while the identical
  hook in `~/.claude/settings.json` did. Only `settings.json` is user scope; the
  `.local.json` variant is a *project*-scope thing. Until this step existed, no
  gortex hook had ever run on this fleet. The merge copies (never moves — a
  rewire rewrites `settings.local.json`, and the "already wired" marker greps
  it), appends only what is missing, preserves order, and runs on **every**
  bootstrap, because `copy_managed` re-seeds `settings.json` whenever the
  committed baseline changes and would otherwise drop the hooks.
- **Note that this is a live behaviour change.** Gortex's own default is
  `--hook-mode deny`: the `PreToolUse` hook blocks `Read` / `Grep` / `Glob`
  against *indexed* source outright. That is the documented intent (see the
  global `CLAUDE.md` rule block), but it only started actually happening once
  the hooks reached a file Claude Code reads. **This fleet does not run that
  default** — `bootstrap.sh` pins `GORTEX_HOOK_MODE=nudge`, which lets the call
  through and appends guidance instead. Override per run with
  `GORTEX_HOOK_MODE=deny just gortex-setup`, or drop the `PreToolUse` entry
  from the profile's `settings.json` to silence it entirely.
- **Changing the posture is a rewire, and the merge must converge for it to
  take.** `gortex hook` and `gortex hook --mode=nudge` are different strings, so
  an append-only merge that dedups by equality keeps BOTH; Claude Code then
  applies the most restrictive verdict and the bare entry's default `deny` wins,
  silently. `gortex_merge_hooks` replaces a gortex entry in place rather than
  appending beside it, which is what makes `GORTEX_REWIRE=1` actually change
  behaviour.
- **No daemon-start step** — `gortex mcp` (from `.mcp.json`) brings the daemon
  up per session automatically.

On **NixOS**, home-manager activation runs bootstrap too, but the wiring step is
skipped there (kept fast/offline); run it once from a login shell with
`just gortex-setup`. Bump the pinned version with `just update-gortex` (also run
by `just update`), then `just switch`.

### Linux / macOS — the nix way (optional)

This repo is a home-manager flake, so `modules/home/claude.nix` declares the
identical symlinks via `mkOutOfStoreSymlink`. It's imported by
`modules/home/me.nix`, so a normal rebuild wires them up:

```bash
just switch        # or: sudo nixos-rebuild switch --flake .#<host>
```

It assumes the repo is checked out at `~/machines`; edit the `agents = …` path in
`modules/home/claude.nix` if you clone elsewhere. home-manager backs up any
pre-existing real file (`backupFileExtension = "backup"`). `bootstrap.sh` and
the nix module produce the same links — use whichever you prefer on Linux/macOS;
**Windows must use `bootstrap.sh`.**

## Updating (from every repo)

The links are live, so the loop is just normal git:

1. Edit a skill/agent/statusline/etc. — either here, or via `~/.claude/...`
   while working in *any* other repo (it's the same file through the symlink).
2. `cd ~/machines && git add agents/ && git commit && git push`.
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
  The hook runs bootstrap under `env -u CLAUDE_CONFIG_DIR`, so it always targets
  the **primary** profile no matter which profile the pulling shell belongs to —
  see the Orca section below for the bug that taught us this.
- **NixOS laptops:** `just switch` owns the links; the git hooks no-op there.

**No manual sync between the two mechanisms.** Both `bootstrap.sh`
(`link_entries_into`) and `modules/home/claude.nix` (`linkEntries` via
`readDir`) auto-discover everything under `hooks/`, `skills/` and `subagents/`
(a source dir — it lands in the tool-dictated `~/.claude/agents/`). A
`commands/` dir was documented here and carried a `.gitkeep` for six weeks
without ever holding a file; it was deleted 2026-09-09. Adding one back is
creating the dir and dropping a file in — nothing to wire.
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
