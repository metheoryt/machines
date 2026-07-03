# Cyphy Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package `agents/skills`, `agents/subagents`, `agents/hooks`, `agents/commands` into one Claude Code skills-directory plugin named `cyphy`, living at `agents/plugin/`, symlinked whole into `~/.claude/skills/cyphy` and `~/.claude-work/skills/cyphy` — replacing today's four entry-by-entry symlink loops with one directory symlink per profile.

**Architecture:** `git mv` the four source dirs under `agents/plugin/` (subagents → `agents/plugin/agents`, the plugin-convention name), add `agents/plugin/.claude-plugin/plugin.json`, add a declarative `agents/plugin/hooks/hooks.json` that replaces the hook wiring currently living in `settings.personal.json`/`settings.work.json`. Fix `global-memory-load.sh` to take its config dir as an explicit `$1` argument (it currently derives it from its own path depth, which breaks once the script is nested two levels deeper inside the plugin). `bootstrap.sh` and `modules/home/claude.nix` collapse to one whole-directory link each; Codex (`agents/codex/`, `modules/home/codex.nix`) keeps its current entry-by-entry model, only repointed at the new `agents/plugin/skills`/`agents/plugin/hooks` source paths.

**Tech Stack:** bash (bootstrap.sh, hook scripts), Nix/home-manager (`modules/home/claude.nix`, `codex.nix`), JSON (plugin.json, hooks.json, settings.json).

## Global Constraints

- No `version` key in `agents/plugin/.claude-plugin/plugin.json` — skills-directory plugins have no install/update flow, so a version string would be inert and misleading.
- Every directory move uses `git mv` to preserve history (per the design's Non-goals/Migration section).
- Codex must remain structurally unaffected — same entry-by-entry symlinks, same `~/.codex/hooks/*.sh`/`~/.codex/skills/*` layout, same `agents/codex/hooks.json`/`subagents/*.toml` split. Only its `hooks.json` content changes (the memory-load hook now passes an explicit config-dir argument), and the *source* paths its links read from move under `agents/plugin/`.
- Work profile (`~/.claude-work`) gets all three shared hooks once `cyphy` loads there (user decision: extend, don't preserve the current 1-hook asymmetry) — `settings.work.json` keeps only its own work-specific `echo` SessionStart hook (the session-naming-rule), nothing else.
- Hook script behavior must be otherwise byte-identical — only `global-memory-load.sh` needs a code change (config-dir argument). `gortex-onboard-check.sh` and `project-memory-check.sh` don't reference a config dir at all (verified by reading both — they use `$HOME` and the git repo root, not `$BASH_SOURCE` path depth), so they move as-is with no code change.

---

### Task 1: Restructure `agents/` into `agents/plugin/` + plugin manifest

**Files:**
- Move: `agents/skills/` → `agents/plugin/skills/`
- Move: `agents/subagents/` → `agents/plugin/agents/`
- Move: `agents/commands/` → `agents/plugin/commands/`
- Move: `agents/hooks/` → `agents/plugin/hooks/`
- Create: `agents/plugin/.claude-plugin/plugin.json`

**Interfaces:**
- Produces: `agents/plugin/` as the plugin root every later task references (`agents/plugin/hooks/hooks.json`, `agents/plugin/hooks/global-memory-load.sh`, etc).

- [ ] **Step 1: Move the four directories with `git mv`**

```bash
cd /home/me/gh/nix
mkdir -p agents/plugin
git mv agents/skills agents/plugin/skills
git mv agents/subagents agents/plugin/agents
git mv agents/commands agents/plugin/commands
git mv agents/hooks agents/plugin/hooks
```

- [ ] **Step 2: Create the plugin manifest**

Create `agents/plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "cyphy",
  "description": "Personal Claude Code workflow: gortex skills, quick-tasks subagent, and memory-loading hooks — synced across machines and profiles.",
  "author": {
    "name": "Maxim Romanyuk"
  }
}
```

- [ ] **Step 3: Verify the resulting tree**

```bash
find agents/plugin -maxdepth 3 | sort
```

Expected output includes (order may vary):
```
agents/plugin
agents/plugin/.claude-plugin
agents/plugin/.claude-plugin/plugin.json
agents/plugin/agents
agents/plugin/agents/quick-tasks.md
agents/plugin/commands
agents/plugin/commands/.gitkeep
agents/plugin/hooks
agents/plugin/hooks/global-memory-load.sh
agents/plugin/hooks/gortex-onboard-check.sh
agents/plugin/hooks/project-memory-check.sh
agents/plugin/skills
agents/plugin/skills/gortex-align
agents/plugin/skills/update-balance
```

And confirm the old locations are gone:

```bash
ls agents/skills agents/subagents agents/commands agents/hooks 2>&1
```

Expected: `No such file or directory` for all four.

- [ ] **Step 4: Commit**

```bash
git add -A agents/plugin agents/skills agents/subagents agents/commands agents/hooks
git commit -m "$(cat <<'EOF'
agents: restructure skills/agents/hooks/commands into agents/plugin/

Groundwork for packaging them as the "cyphy" Claude Code skills-directory
plugin. git mv preserves history; plugin.json added, no version key (no
install/update flow applies to skills-directory plugins).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Fix `global-memory-load.sh` config-dir derivation + add both `hooks.json` files

**Files:**
- Modify: `agents/plugin/hooks/global-memory-load.sh`
- Create: `agents/plugin/hooks/hooks.json`
- Modify: `agents/codex/hooks.json`

**Interfaces:**
- Consumes: `agents/plugin/hooks/global-memory-load.sh`'s prior behavior (reads `$config_dir/memory/global.md`, `$config_dir/memory/practices.md`, `$config_dir/host-memory.md` — unchanged), from Task 1's move.
- Produces: `global-memory-load.sh <config_dir>` CLI contract (config dir as `$1`, required) — relied on by both `hooks.json` files below and by Task 7's manual verification.

- [ ] **Step 1: Rewrite `global-memory-load.sh` to take `config_dir` as `$1`**

Replace the full contents of `agents/plugin/hooks/global-memory-load.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook — inject the synced global + practices + per-host memory
# stores into the session.
#
# Replaces the `@memory/...` imports that used to sit at the end of AGENTS.md /
# CLAUDE.md. Claude Code resolves `@file` imports, but Codex (and most other
# AGENTS.md readers) do not — so the stores are loaded through this SessionStart
# hook instead, a mechanism both tools share. Fires for EVERY session,
# independent of whether cwd is a git repo; the sibling project-memory-check.sh
# handles the per-repo store.
#
# Takes the config dir as $1 (e.g. "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" or
# "${CODEX_CONFIG_DIR:-$HOME/.codex}"), passed explicitly by the caller's
# hooks.json — NOT derived from this script's own path, because the same file
# is symlinked at different nesting depths for different callers (directly
# under <config_dir>/hooks/ for Codex; under <config_dir>/skills/cyphy/hooks/
# for the Claude Code cyphy plugin).
set -u

config_dir="${1:?config dir required (pass \${CLAUDE_CONFIG_DIR:-\$HOME/.claude} or similar)}"

emit() {
  # $1 = file path, $2 = header shown before its contents
  [ -s "$1" ] || return 0                       # skip missing / empty stores
  grep -q '[^[:space:]]' "$1" 2>/dev/null || return 0  # skip whitespace-only
  printf '%s\n\n' "$2"
  cat "$1"
  printf '\n'
}

emit "$config_dir/memory/global.md" \
  "Global memory (synced, git-tracked, loaded every session) — treat as your loaded memory:"
emit "$config_dir/memory/practices.md" \
  "Code practices (synced, git-tracked, loaded every session):"
emit "$config_dir/host-memory.md" \
  "Per-host memory for THIS machine (synced, git-tracked, loaded every session):"
```

- [ ] **Step 2: Manually verify the new argument contract**

```bash
mkdir -p /tmp/cyphy-test-config/memory
echo "global fact" > /tmp/cyphy-test-config/memory/global.md
echo "practice fact" > /tmp/cyphy-test-config/memory/practices.md
echo "host fact" > /tmp/cyphy-test-config/host-memory.md
bash agents/plugin/hooks/global-memory-load.sh /tmp/cyphy-test-config
```

Expected output:
```
Global memory (synced, git-tracked, loaded every session) — treat as your loaded memory:

global fact

Code practices (synced, git-tracked, loaded every session):

practice fact

Per-host memory for THIS machine (synced, git-tracked, loaded every session):

host fact

```

- [ ] **Step 3: Verify the missing-argument case fails loudly**

```bash
bash agents/plugin/hooks/global-memory-load.sh; echo "exit=$?"
```

Expected: a `parameter not set`/`config dir required` error on stderr and `exit=1` (nonzero) — NOT a silent no-op. This is the correctness check that catches a caller forgetting to pass the argument.

- [ ] **Step 4: Clean up the scratch dir**

```bash
rm -rf /tmp/cyphy-test-config
```

- [ ] **Step 5: Create `agents/plugin/hooks/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gortex-onboard-check.sh\""
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/global-memory-load.sh\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\""
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/project-memory-check.sh\""
          }
        ]
      }
    ]
  }
}
```

`gortex-onboard-check.sh` and `project-memory-check.sh` don't take the config-dir argument — they weren't reading it before the move either (confirmed: they resolve everything from `$HOME` and the git repo root under `cwd`, not the script's own path).

- [ ] **Step 6: Update `agents/codex/hooks.json`** to pass the same explicit argument to `global-memory-load.sh`

Current content:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.codex/hooks/gortex-onboard-check.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.codex/hooks/global-memory-load.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.codex/hooks/project-memory-check.sh\""
          }
        ]
      }
    ]
  }
}
```

Change only the middle `command` line:

```json
          {
            "type": "command",
            "command": "bash \"$HOME/.codex/hooks/global-memory-load.sh\" \"${CODEX_CONFIG_DIR:-$HOME/.codex}\""
          },
```

- [ ] **Step 7: Validate both JSON files parse**

```bash
python3 -m json.tool agents/plugin/hooks/hooks.json >/dev/null && echo OK
python3 -m json.tool agents/codex/hooks.json >/dev/null && echo OK
```

Expected: `OK` printed twice.

- [ ] **Step 8: Commit**

```bash
git add agents/plugin/hooks/global-memory-load.sh agents/plugin/hooks/hooks.json agents/codex/hooks.json
git commit -m "$(cat <<'EOF'
agents: pass config dir explicitly to global-memory-load.sh; add cyphy hooks.json

global-memory-load.sh derived its config dir from its own path depth, which
only worked because it always lived at <config_dir>/hooks/. Now nested at
<config_dir>/skills/cyphy/hooks/ for the Claude Code plugin (still flat for
Codex), so it takes the config dir as an explicit $1 instead. Both hooks.json
files (new cyphy plugin one, existing Codex one) pass it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Strip hook wiring from `settings.personal.json` and `settings.work.json`

**Files:**
- Modify: `agents/settings.personal.json`
- Modify: `agents/settings.work.json`

**Interfaces:**
- Consumes: `agents/plugin/hooks/hooks.json` from Task 2 (registers SessionStart once `cyphy` loads — these settings files must stop double-registering the same hooks).

- [ ] **Step 1: Remove the entire `"hooks"` key from `agents/settings.personal.json`**

Current file:

```json
{
  "env": {},
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/gortex-onboard-check.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/global-memory-load.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/project-memory-check.sh\""
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline-command.sh\"",
    "refreshInterval": 180
  },
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true
  },
  "advisorModel": "opus",
  "autoUpdatesChannel": "latest",
  "tui": "fullscreen",
  "voice": {
    "enabled": true,
    "mode": "hold"
  },
  "agentPushNotifEnabled": true,
  "voiceEnabled": true
}
```

New file (the `"hooks"` block is gone; everything else unchanged):

```json
{
  "env": {},
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline-command.sh\"",
    "refreshInterval": 180
  },
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true
  },
  "advisorModel": "opus",
  "autoUpdatesChannel": "latest",
  "tui": "fullscreen",
  "voice": {
    "enabled": true,
    "mode": "hold"
  },
  "agentPushNotifEnabled": true,
  "voiceEnabled": true
}
```

- [ ] **Step 2: Trim `agents/settings.work.json`'s `"hooks"` block down to just its own session-naming-rule hook**

Current `"hooks"` block:

```json
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"SESSION NAMING RULE: If you are generating a recap of a resumed session, check whether the session already has a user-assigned name (it will appear in the status line or system context as a quoted name the user explicitly chose). Auto-generated names like long hex strings, random word pairs, or anything that looks machine-generated do not count. If the session appears unnamed or has an auto-generated name, end your recap with a clearly separated block:\\n---\\nSuggested rename: `/rename <3-5-word-kebab-case-topic>`\\n---\\nDerive the topic slug from the main task discussed in the session. Keep it lowercase-hyphenated, no generic words like \\\"session\\\" or \\\"work\\\".\"}}'",
            "statusMessage": "Loading session context..."
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude-work/hooks/global-memory-load.sh\""
          }
        ]
      }
    ]
  },
```

Replace with (drop the second hook object — `cyphy` now registers `global-memory-load.sh`, plus `gortex-onboard-check.sh` and `project-memory-check.sh` which the work profile did not run before; this is the user-confirmed "extend to all 3" choice):

```json
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"SESSION NAMING RULE: If you are generating a recap of a resumed session, check whether the session already has a user-assigned name (it will appear in the status line or system context as a quoted name the user explicitly chose). Auto-generated names like long hex strings, random word pairs, or anything that looks machine-generated do not count. If the session appears unnamed or has an auto-generated name, end your recap with a clearly separated block:\\n---\\nSuggested rename: `/rename <3-5-word-kebab-case-topic>`\\n---\\nDerive the topic slug from the main task discussed in the session. Keep it lowercase-hyphenated, no generic words like \\\"session\\\" or \\\"work\\\".\"}}'",
            "statusMessage": "Loading session context..."
          }
        ]
      }
    ]
  },
```

(Every other key in `settings.work.json` — `statusLine`, `enabledPlugins`, `extraKnownMarketplaces`, `tui`, `voice`, etc — is untouched.)

- [ ] **Step 3: Validate both JSON files parse**

```bash
python3 -m json.tool agents/settings.personal.json >/dev/null && echo OK
python3 -m json.tool agents/settings.work.json >/dev/null && echo OK
```

Expected: `OK` printed twice.

- [ ] **Step 4: Commit**

```bash
git add agents/settings.personal.json agents/settings.work.json
git commit -m "$(cat <<'EOF'
agents: drop settings.json hook wiring now that cyphy registers it

cyphy's hooks/hooks.json (Task 2) registers all three SessionStart hooks once
the plugin loads, so settings.personal.json/settings.work.json no longer need
to wire them by hand. settings.work.json keeps its own session-naming-rule
hook, which isn't part of the shared set. Work profile now gets all three
shared hooks instead of just global-memory-load.sh (confirmed choice — the
1-hook asymmetry looked incidental, not deliberate policy).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Collapse `bootstrap.sh`'s four entry-by-entry loops into one plugin symlink

**Files:**
- Modify: `agents/bootstrap.sh`

**Interfaces:**
- Consumes: `agents/plugin/` (Task 1), the existing `link()` and `link_entries_into()` bash functions already defined in this file (unchanged).
- Produces: `$CLAUDE_DIR/skills/cyphy` symlink (personal + work profiles) and `$CODEX_DIR/skills`/`$CODEX_DIR/hooks` entry links repointed at `agents/plugin/skills`/`agents/plugin/hooks`.

- [ ] **Step 1: Replace the personal/work-profile entry-by-entry block**

Current (this file's final entry-linking block before the Codex section):

```bash
# Entry-by-entry links (each skill subdir / agent file / command / hook).
link_entries_into "$SRC_DIR/skills"   "$CLAUDE_DIR/skills"
link_entries_into "$SRC_DIR/subagents" "$CLAUDE_DIR/agents"
link_entries_into "$SRC_DIR/commands" "$CLAUDE_DIR/commands"
link_entries_into "$SRC_DIR/hooks"    "$CLAUDE_DIR/hooks"
```

Replace with:

```bash
# cyphy plugin: one whole-directory symlink replaces the four entry-by-entry
# loops above. skills/agents/commands/hooks all live inside agents/plugin/ now,
# discovered by Claude Code as a skills-directory plugin (cyphy@skills-dir) —
# live, in place, no copy-to-cache, no install/update step.
mkdir -p "$CLAUDE_DIR/skills"
link "$SRC_DIR/plugin" "$CLAUDE_DIR/skills/cyphy"
```

- [ ] **Step 2: Repoint the Codex section's source paths**

Current (inside the `if [ "$IS_PERSONAL" -eq 1 ]; then ... fi` Codex block):

```bash
  link_entries_into "$SRC_DIR/skills"       "$CODEX_DIR/skills"
  link_entries_into "$SRC_DIR/hooks"        "$CODEX_DIR/hooks"
  link_entries_into "$CODEX_SRC/subagents"  "$CODEX_DIR/agents"
```

Replace with (Codex keeps its own entry-by-entry model — only the source directory moved):

```bash
  link_entries_into "$SRC_DIR/plugin/skills" "$CODEX_DIR/skills"
  link_entries_into "$SRC_DIR/plugin/hooks"  "$CODEX_DIR/hooks"
  link_entries_into "$CODEX_SRC/subagents"   "$CODEX_DIR/agents"
```

- [ ] **Step 3: Shellcheck / syntax-check the script**

```bash
bash -n agents/bootstrap.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add agents/bootstrap.sh
git commit -m "$(cat <<'EOF'
agents: bootstrap.sh links cyphy as one directory symlink

Replaces the four entry-by-entry loops (skills/subagents/commands/hooks) for
the Claude Code side with a single link into ~/.claude/skills/cyphy (and
~/.claude-work/skills/cyphy). Codex keeps its entry-by-entry model, repointed
at the new agents/plugin/skills and agents/plugin/hooks source paths.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Update `modules/home/claude.nix` and `modules/home/codex.nix`

**Files:**
- Modify: `modules/home/claude.nix`
- Modify: `modules/home/codex.nix`

**Interfaces:**
- Consumes: `agents/plugin/` (Task 1) — same symlink targets as Task 4, expressed as Nix `home.file` entries instead of bash `link()` calls.
- Produces: `~/.claude/skills/cyphy` and `~/.claude-work/skills/cyphy` symlinks via `mkOutOfStoreSymlink`, matching what `bootstrap.sh` produces on non-NixOS machines.

- [ ] **Step 1: Replace `claude.nix`'s `linkEntries` calls with one plugin link**

Current `profileFiles` function:

```nix
  # Link each entry inside a source subdir into <profileDir>/<targetSub>/ individually.
  # targetSub and srcSub differ only for subagents (source `subagents/`, target the
  # tool-dictated `agents/`). srcDir is the in-tree literal (enumeration only).
  linkEntries = profileDir: targetSub: srcSub: srcDir:
    lib.mapAttrs'
    (name: _:
      lib.nameValuePair "${profileDir}/${targetSub}/${name}" {
        source = link "${agents}/${srcSub}/${name}";
      })
    (lib.filterAttrs (name: _: name != ".gitkeep") (builtins.readDir srcDir));

  # All shared links for one profile dir (".claude" or ".claude-work"),
  # parameterized by which committed settings file becomes settings.json.
  # settings.local.json is intentionally NOT managed here — it stays machine-local
  # (personal: gortex hooks; work: PURE_SENTRY_TOKEN secret), owned by neither
  # this module nor bootstrap.sh.
  profileFiles = profileDir: settingsFile:
    {
      "${profileDir}/settings.json".source = link "${agents}/${settingsFile}";
      "${profileDir}/statusline-command.sh".source = link "${agents}/statusline-command.sh";
      "${profileDir}/balance-refresh.py".source = link "${agents}/balance-refresh.py";
      # AGENTS.md is canonical; <profile>/CLAUDE.md links straight to the real file.
      "${profileDir}/CLAUDE.md".source = link "${agents}/AGENTS.md";
      "${profileDir}/memory/global.md".source = link "${agents}/memory/global.md";
      "${profileDir}/memory/practices.md".source = link "${agents}/memory/practices.md";
      "${profileDir}/host-memory.md".source = link "${agents}/hosts/${osConfig.networking.hostName}.md";
    }
    // linkEntries profileDir "hooks" "hooks" ../../agents/hooks
    // linkEntries profileDir "skills" "skills" ../../agents/skills
    // linkEntries profileDir "agents" "subagents" ../../agents/subagents
    // linkEntries profileDir "commands" "commands" ../../agents/commands;
in {
  home.file =
    profileFiles ".claude" "settings.personal.json"
    // profileFiles ".claude-work" "settings.work.json";
}
```

Replace with (drop the now-unused `linkEntries` helper entirely; add one `skills/cyphy` entry to the base attrset):

```nix
  # All shared links for one profile dir (".claude" or ".claude-work"),
  # parameterized by which committed settings file becomes settings.json.
  # settings.local.json is intentionally NOT managed here — it stays machine-local
  # (personal: gortex hooks; work: PURE_SENTRY_TOKEN secret), owned by neither
  # this module nor bootstrap.sh.
  profileFiles = profileDir: settingsFile:
    {
      "${profileDir}/settings.json".source = link "${agents}/${settingsFile}";
      "${profileDir}/statusline-command.sh".source = link "${agents}/statusline-command.sh";
      "${profileDir}/balance-refresh.py".source = link "${agents}/balance-refresh.py";
      # AGENTS.md is canonical; <profile>/CLAUDE.md links straight to the real file.
      "${profileDir}/CLAUDE.md".source = link "${agents}/AGENTS.md";
      "${profileDir}/memory/global.md".source = link "${agents}/memory/global.md";
      "${profileDir}/memory/practices.md".source = link "${agents}/memory/practices.md";
      "${profileDir}/host-memory.md".source = link "${agents}/hosts/${osConfig.networking.hostName}.md";
      # cyphy plugin: one whole-directory symlink replaces the four per-entry
      # linkEntries calls that used to wire skills/agents/commands/hooks
      # individually — they all live inside agents/plugin/ now, discovered by
      # Claude Code as a skills-directory plugin (cyphy@skills-dir).
      "${profileDir}/skills/cyphy".source = link "${agents}/plugin";
    };
in {
  home.file =
    profileFiles ".claude" "settings.personal.json"
    // profileFiles ".claude-work" "settings.work.json";
}
```

- [ ] **Step 2: Repoint `codex.nix`'s `linkEntries` source paths**

Current:

```nix
    // linkEntries "skills" agents "skills" ../../agents/skills
    // linkEntries "hooks" agents "hooks" ../../agents/hooks
    // linkEntries "agents" codex "subagents" ../../agents/codex/subagents;
```

Replace with (Codex's `linkEntries` helper and entry-by-entry model are unchanged — only the source paths move):

```nix
    // linkEntries "skills" agents "plugin/skills" ../../agents/plugin/skills
    // linkEntries "hooks" agents "plugin/hooks" ../../agents/plugin/hooks
    // linkEntries "agents" codex "subagents" ../../agents/codex/subagents;
```

- [ ] **Step 3: Syntax-check both modules**

```bash
nix-instantiate --parse modules/home/claude.nix >/dev/null && echo "claude.nix OK"
nix-instantiate --parse modules/home/codex.nix >/dev/null && echo "codex.nix OK"
```

Expected: both `OK` lines printed. If `nix-instantiate` isn't on `PATH` in the execution environment, fall back to `just quick` (repo's fast syntax-only check) or `nix flake check` from the repo root.

- [ ] **Step 4: Commit**

```bash
git add modules/home/claude.nix modules/home/codex.nix
git commit -m "$(cat <<'EOF'
nix: link cyphy as one directory symlink in claude.nix; repoint codex.nix

Mirrors the bootstrap.sh change: claude.nix's four per-entry linkEntries
calls collapse into one "${profileDir}/skills/cyphy" symlink to agents/plugin.
The now-unused linkEntries helper is removed from claude.nix. codex.nix keeps
its entry-by-entry model, repointed at agents/plugin/skills and
agents/plugin/hooks.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Update `README.md` and `AGENTS.md` docs

**Files:**
- Modify: `agents/README.md`
- Modify: `agents/AGENTS.md`

**Interfaces:**
- None — documentation only, no code interfaces produced or consumed.

- [ ] **Step 1: Replace the three per-entry table rows in `agents/README.md`**

Current rows (inside the "What's tracked" table):

```markdown
| `skills/update-balance/` | `skills/update-balance` | per-entry link |
| `subagents/quick-tasks.md` | `agents/quick-tasks.md` | per-entry link — source lives in `subagents/`, target dir is the tool-dictated `agents/` |
| `commands/` | `commands/` (per-entry) | empty for now (`.gitkeep`) |
```

Replace with:

```markdown
| `plugin/` | `skills/cyphy` | whole-directory symlink — the "cyphy" skills-directory plugin (`skills/`, `agents/` [was `subagents/`], `hooks/hooks.json`, `commands/`), discovered by Claude Code as `cyphy@skills-dir`: live, in place, no copy-to-cache, no install/update step |
```

- [ ] **Step 2: Replace the entry-by-entry explanation paragraph**

Current paragraph, right after the table:

```markdown
`skills/`, `subagents/` and `commands/` are linked **entry-by-entry**, so any
machine-local skill/agent you drop directly into `~/.claude` keeps working
alongside the tracked ones. (The source dir is `subagents/` — named that way
because `agents/` at the repo root is already this whole config tree; the
symlinks still land in the tool-dictated `~/.claude/agents/`.)
```

Replace with:

```markdown
`plugin/` is linked as **one whole directory** (`~/.claude/skills/cyphy`,
`~/.claude-work/skills/cyphy`) — Claude Code discovers its
`.claude-plugin/plugin.json` and loads it as `cyphy@skills-dir`. Skills and
subagents load namespaced under the plugin (e.g. `/cyphy:update-balance`). A
machine-local skill/agent dropped directly into `~/.claude/skills/` or
`~/.claude/agents/` still works fine alongside it — it's just not part of
`cyphy`.
```

- [ ] **Step 3: Update the Codex subsection's description of shared content**

Current text:

```markdown
Codex is Claude-Code-compatible, so it reuses **this** config as its source of
truth rather than a separate copy. The tool-agnostic content here — `memory/`,
`hooks/`, `skills/`, and the canonical `AGENTS.md` — is symlinked into **both**
`~/.claude` and `~/.codex`. Only the format-divergent files live under
`agents/codex/` (`hooks.json`, `subagents/*.toml`) and link into `~/.codex`
alone — the `.toml` subagent defs land at `~/.codex/agents/*.toml`, the same
tool-dictated target dirname Claude uses, just read by a different tool.
```

Replace with:

```markdown
Codex is Claude-Code-compatible, so it reuses **this** config as its source of
truth rather than a separate copy. The tool-agnostic content — `memory/`,
`plugin/hooks/`, `plugin/skills/`, and the canonical `AGENTS.md` — is
symlinked into `~/.codex` entry-by-entry, same as always; only Claude's own
wiring changed (a whole-directory `cyphy` plugin symlink instead of
entry-by-entry). Only the format-divergent files live under `agents/codex/`
(`hooks.json`, `subagents/*.toml`) and link into `~/.codex` alone — the
`.toml` subagent defs land at `~/.codex/agents/*.toml`, the same tool-dictated
target dirname Claude uses, just read by a different tool.
```

- [ ] **Step 4: Update the SHARED-tier sentence in `agents/AGENTS.md`**

This same text is read by both `agents/AGENTS.md` and the repo-root `CLAUDE.md` (a symlink to `AGENTS.md`) and `agents/CLAUDE.md` (also a symlink) — one edit covers all three.

Current text:

```markdown
The memory stores (`memory/global.md`, `memory/practices.md`, and the per-host
`host-memory.md`) are git-tracked in this repo (`agents/`) and belong to the
SHARED tier — along with `AGENTS.md`(→`CLAUDE.md`), `hosts/`(→`host-memory.md`),
`hooks/`, `skills/`, `subagents/`, `commands/`, `statusline-command.sh`, and
`balance-refresh.py` — so they're symlinked into **every** profile bootstrapped:
`~/.claude`, `~/.codex`, and secondary profiles like `~/.claude-work`.
```

Replace with:

```markdown
The memory stores (`memory/global.md`, `memory/practices.md`, and the per-host
`host-memory.md`) are git-tracked in this repo (`agents/`) and belong to the
SHARED tier — along with `AGENTS.md`(→`CLAUDE.md`), `hosts/`(→`host-memory.md`),
`statusline-command.sh`, and `balance-refresh.py` as loose files, plus
`plugin/` (skills, subagents as its `agents/`, hooks, commands — packaged as
the `cyphy` skills-directory plugin) as one whole-directory link — so they're
symlinked into **every** profile bootstrapped: `~/.claude`, `~/.codex`, and
secondary profiles like `~/.claude-work`.
```

- [ ] **Step 5: Commit**

```bash
git add agents/README.md agents/AGENTS.md
git commit -m "$(cat <<'EOF'
docs: describe the cyphy plugin restructuring in README/AGENTS.md

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Rollout and live verification

> **Note for whoever executes this task:** every step here mutates real, live
> dotfiles under `~/.claude`, `~/.claude-work`, and `~/.codex` on the machine
> it's run on. Run it yourself (or have a human confirm each step) rather than
> letting an unattended agent run it — this is exactly the kind of
> hard-to-reverse, machine-state-affecting action that warrants a checkpoint.

**Files:** none (verification only — no repo files change in this task unless a problem surfaces, in which case fix it in the relevant earlier task and re-commit there).

- [ ] **Step 1: Re-run bootstrap for the personal profile**

```bash
env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh
```

Expected: ends with `failed=0`, and a line `+ linked: ... -> .../agents/plugin` (or `= already linked` on a re-run) for `~/.claude/skills/cyphy`.

- [ ] **Step 2: Re-run bootstrap for the work profile**

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh
```

Expected: same `failed=0`, with the `Secondary profile —` banner and a link line for `~/.claude-work/skills/cyphy`.

- [ ] **Step 3: (NixOS only) Rebuild to pick up the `claude.nix`/`codex.nix` changes**

```bash
just switch
```

Expected: completes without errors; `~/.claude/skills/cyphy` and `~/.codex/skills/*` resolve through the Nix-managed symlinks afterward.

- [ ] **Step 4: Confirm the symlink targets**

```bash
readlink -f ~/.claude/skills/cyphy
readlink -f ~/.claude-work/skills/cyphy
ls ~/.codex/skills ~/.codex/hooks
```

Expected: both `readlink -f` calls resolve into this repo's `agents/plugin`; `~/.codex/skills` and `~/.codex/hooks` still list the individual entries (`gortex-align`, `update-balance`, `global-memory-load.sh`, etc) as before.

- [ ] **Step 5: Validate the plugin structure, if the `claude` CLI is available**

```bash
claude plugin validate ./agents/plugin
```

Expected: no schema errors. (Skip if `claude` isn't on `PATH` in this environment — the symlink checks above are the load-bearing verification.)

- [ ] **Step 6: Start a fresh Claude Code session and confirm SessionStart output**

Start (or restart) Claude Code from this repo, or run `/reload-plugins` in an existing session, then check that the session's initial context includes:
- The global/practices/host-memory blocks (same content as before this change).
- The gortex-onboard nudge (if applicable on this machine/repo).
- `cyphy@skills-dir` listed under `/context` → Custom Agents / Plugins, or via `claude plugin list`.

- [ ] **Step 7: Repeat Step 6 for the work profile**

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
```

Confirm SessionStart now emits gortex-onboard-check and project-memory-check output too (the newly-extended behavior), not just the memory blocks.

- [ ] **Step 8: If everything checks out, no further commit is needed** — Tasks 1-6 already committed the actual changes. This task is verification only.

---

## Self-Review Notes

- **Spec coverage:** all five spec sections (directory layout, `hooks.json`, hook-script fix, bootstrap/Nix changes, migration/rollout) map to Tasks 1, 2, 3–5, and 7 respectively. The one place this plan **diverges from the spec's literal text**: the spec's Risks section claimed the config-dir fix applies to "all three hook scripts" — rereading `gortex-onboard-check.sh` and `project-memory-check.sh` shows neither derives a config dir from its path (they use `$HOME` and the git repo root only), so only `global-memory-load.sh` needed the code change. Task 2 implements the correct, narrower scope.
- **Type/contract consistency:** `global-memory-load.sh <config_dir>` is the one new "interface" introduced (Task 2) and both consumers (`agents/plugin/hooks/hooks.json`, `agents/codex/hooks.json`) call it with that exact one-argument contract.
- **No placeholders:** every step has literal file content or literal commands with expected output; no "TBD"/"handle appropriately" language.
