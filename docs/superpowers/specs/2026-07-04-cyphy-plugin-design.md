# Design: package `agents/` skills+agents+hooks as the "cyphy" skills-directory plugin

**Date:** 2026-07-04
**Status:** approved (pending spec review)

## Problem

`agents/` is a hand-rolled symlink tree (see
`2026-07-02-agents-rename-per-profile-bootstrap-design.md`): `bootstrap.sh` and
`modules/home/claude.nix`/`codex.nix` each walk `skills/`, `subagents/`,
`commands/`, `hooks/` entry-by-entry and symlink every file individually into
`~/.claude` (and `~/.claude-work`, `~/.codex`). Claude Code's native plugin
system now offers a package format for exactly this kind of thing (namespacing,
a manifest, `claude plugin validate`) — worth adopting for the part of the tree
that's genuinely "plugin-shaped" (skills/agents/hooks/commands), while keeping
memory and settings outside it, since those can never be plugin payload (see
Non-goals).

## Goals

- Wrap `skills/`, `subagents/` (→ plugin-convention `agents/`), `hooks/`,
  `commands/` in a single Claude Code plugin named **cyphy**, loaded as a
  **skills-directory plugin** (`cyphy@skills-dir`) — discovered live in place,
  no copy-to-cache, no install/update step. Personal-scope (`~/.claude/skills/`,
  `~/.claude-work/skills/`), so no workspace-trust gate applies.
- Collapse today's four `link_entries_into` loops (skills/subagents/commands/hooks)
  into **one** whole-directory symlink per profile.
- Fix the hook scripts' config-dir derivation so it works regardless of nesting
  depth (needed because the plugin adds two path segments under the scripts).
- Preserve exactly what already works: live edit-anywhere, git-tracked sync,
  Codex support.

## Non-goals

- **Full marketplace distribution (copy-to-cache).** Investigated and rejected:
  `/plugin install` copies the plugin into `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`,
  so edits require `/plugin marketplace update` + reinstall instead of taking
  effect on git pull. Wrong fit for a personal, actively-edited setup; revisit
  only if this ever needs to be shared/installed by someone else.
- **Folding memory into the plugin.** `memory/global.md`, `memory/practices.md`,
  `hosts/*.md` are Claude-authored and mutated at runtime, and git-synced by the
  user's own commit+push+pull cadence. A real plugin's `${CLAUDE_PLUGIN_ROOT}`
  is a versioned/ephemeral path (old versions are GC'd ~7 days after an update),
  so memory content living there risks silent loss. They stay exactly where
  they are: loose files linked straight into `~/.claude/memory/` and
  `~/.claude/host-memory.md`, read by the plugin's hook via an explicit
  config-dir argument (see below) rather than by living inside the plugin.
- **Folding in `settings.json`, `statusline-command.sh`, `balance-refresh.py`.**
  Not plugin-shape content (`settings.json` is user/profile identity;
  `plugin.json`'s own `settings.json` support is currently limited to `agent`
  and `subagentStatusLine` keys — no top-level `statusLine` override). Stay
  linked as loose files, unchanged.
- **Changing Codex.** `@skills-dir` plugin discovery is a Claude-Code-only
  mechanism. `~/.codex` keeps its current entry-by-entry symlinks
  (`agents/codex/hooks.json`, `agents/codex/subagents/*.toml`), untouched except
  for the shared hook-script arg-passing fix (§ below), which benefits both
  tools identically.

## Directory layout (after)

```
agents/
├── AGENTS.md / CLAUDE.md → AGENTS.md   (unchanged)
├── memory/{global,practices}.md         (unchanged — outside the plugin)
├── hosts/<hostname>.md                  (unchanged)
├── settings.personal.json               (unchanged, minus its "hooks" block — see below)
├── settings.work.json                   (unchanged, minus its "hooks" block)
├── statusline-command.sh / balance-refresh.py   (unchanged)
├── bootstrap.sh / git-hooks/            (updated — see below)
├── codex/                               (unchanged except hooks.json arg-passing)
└── plugin/                              (NEW — this is the whole "cyphy" plugin root)
    ├── .claude-plugin/
    │   └── plugin.json                  {"name": "cyphy", "description": "...", "author": {...}}  — no "version" key
    ├── skills/
    │   ├── gortex-align/
    │   └── update-balance/
    ├── agents/                          (was top-level subagents/ — plugin's own agents dir)
    │   └── quick-tasks.md
    ├── hooks/
    │   ├── hooks.json                   NEW — declarative, replaces settings.*.json's "hooks" block
    │   ├── global-memory-load.sh        (config-dir now taken as $1, not derived from path depth)
    │   ├── gortex-onboard-check.sh      (same fix)
    │   └── project-memory-check.sh      (same fix)
    └── commands/                        (unchanged, currently empty/.gitkeep)
```

`agents/plugin/` becomes the one thing symlinked whole: `agents/plugin` →
`~/.claude/skills/cyphy` (and `~/.claude-work/skills/cyphy`). Claude Code finds
`.claude-plugin/plugin.json` inside it and loads `cyphy@skills-dir` next
session — live, in place.

## `plugin/hooks/hooks.json` (new)

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gortex-onboard-check.sh\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\""},
          {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/global-memory-load.sh\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\""},
          {"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/project-memory-check.sh\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\""}
        ]
      }
    ]
  }
}
```

`settings.personal.json` and `settings.work.json` each drop their `"hooks"` key
entirely — `cyphy` registers SessionStart itself once loaded. (`statusLine`,
`enabledPlugins`, and everything else in those files is untouched.)

## Hook script fix: explicit config-dir argument

Today `global-memory-load.sh` derives `config_dir` from its own path
(`dirname(dirname($BASH_SOURCE))`), assuming it lives at
`<config_dir>/hooks/<script>.sh`. That's one level too shallow once the script
is nested at `<config_dir>/skills/cyphy/hooks/<script>.sh`. Since the *same*
file is also symlinked into Codex's flat `~/.codex/hooks/` (where the old math
still holds), path-depth inference can't serve both layouts at once.

Fix: each script takes `config_dir` as `$1` instead of deriving it, e.g.:

```bash
config_dir="${1:?config dir required}"
```

Both `agents/plugin/hooks/hooks.json` (above) and `agents/codex/hooks.json`
pass it explicitly (`"${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` /
`"${CODEX_CONFIG_DIR:-$HOME/.codex}"`), so the same three scripts serve both
tools' differing directory depths uniformly. Applies to all three hook scripts
(`global-memory-load.sh`, `gortex-onboard-check.sh`, `project-memory-check.sh`).

## `bootstrap.sh` / Nix module changes

Replace the four `link_entries_into` calls for skills/subagents/commands/hooks
with one directory-level `link`:

```bash
link "$SRC_DIR/plugin" "$CLAUDE_DIR/skills/cyphy"
```

`memory/`, `hosts/` stay on `link_entries_into`/individual `link` calls exactly
as today (unaffected — they're outside `plugin/`).

Same substitution in `modules/home/claude.nix` (and `codex.nix` keeps its own
existing per-entry links into `~/.codex/skills`/`hooks`/`agents`, since Codex
doesn't participate in the plugin restructuring — only its hook-script argument
passing changes).

Net effect: `bootstrap.sh` loses the four per-entry loops for this content;
the git-hooks auto-relink machinery (`post-merge`/`post-rewrite`/`post-checkout`)
becomes unnecessary for anything under `plugin/` specifically — a directory
symlink doesn't go stale when new files appear inside it — but stays needed for
`memory/`/`hosts/`, which remain entry-by-entry.

## Migration / rollout

1. `git mv agents/skills agents/plugin/skills`, `git mv agents/subagents agents/plugin/agents`,
   `git mv agents/commands agents/plugin/commands`, `git mv agents/hooks agents/plugin/hooks`
   (preserve history).
2. Add `agents/plugin/.claude-plugin/plugin.json` (`name: "cyphy"`, no `version`).
3. Add `agents/plugin/hooks/hooks.json`; apply the `$1`-argument fix to all
   three hook scripts; update `agents/codex/hooks.json` to pass its config dir
   explicitly too.
4. Strip the `"hooks"` block from `settings.personal.json` and `settings.work.json`.
5. Update `bootstrap.sh` (collapse the four loops to one `link` call) and
   `modules/home/claude.nix` similarly.
6. Update `README.md` / `AGENTS.md` self-docs to describe the plugin split.
7. Re-run `agent-bootstrap` (personal) and `agent-bootstrap-work`; on NixOS,
   `just switch`. Restart Claude Code (or `/reload-plugins`) so `cyphy@skills-dir`
   loads. Confirm SessionStart still emits the memory blocks and the onboarding
   check, and that `/plugin list` (or `/context`) shows `cyphy@skills-dir` with
   its skills/agents namespaced accordingly (`/cyphy:update-balance`, etc.).
8. Validate: `just quick` / `nix flake check`; `claude plugin validate ./agents/plugin`.

## Risks

- **Skill/agent invocation names change** (namespaced under `cyphy:` once
  loaded as a plugin, e.g. `/cyphy:update-balance` instead of `/update-balance`).
  Acceptable one-time behavior change; note it in README so it isn't a surprise.
- **Hook script argument change** must land in the same commit as both
  `hooks.json` files, or SessionStart breaks on whichever tool updates first.
  Mitigation: change the scripts to require `$1` and update both `hooks.json`
  files together; test both profiles before committing.
- **Project-scope caveat doesn't apply here** (personal-scope `~/.claude/skills/`
  has no trust-dialog gate and loads in every project) — confirmed from docs,
  not a risk, but worth remembering if a project-scope variant is ever
  considered later.
