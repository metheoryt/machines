# Unified Profile Settings Sharing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `~/.claude` and `~/.claude-work` a clean three-tier config model — committed per-profile `settings.json` (personal/work), machine-local `settings.local.json` (gortex hooks / Sentry secret), Nix managing both profiles.

**Architecture:** Split the two divergent `settings.json` files into two committed files (`settings.personal.json`, `settings.work.json`), each a complete profile config with the small common base inlined. The one secret (`PURE_SENTRY_TOKEN`) moves to work's machine-local `settings.local.json`, reunited at load via Claude's `env` deep-merge. `modules/home/claude.nix` is refactored to link both profiles via a shared helper; `bootstrap.sh` mirrors it for non-Nix machines. `settings.local.json` is owned by neither mechanism.

**Tech Stack:** Nix (home-manager, `mkOutOfStoreSymlink`), bash, jq, JSON. NixOS hosts g16 + latitude5520.

**Spec:** `docs/superpowers/specs/2026-07-02-unified-profile-settings-sharing-design.md`

## Global Constraints

- **Never commit the secret.** `PURE_SENTRY_TOKEN` must appear only in machine-local `~/.claude-work/settings.local.json`, never in any tracked file. Verify with grep before every commit.
- **Never print the secret.** Move it with `jq` file-to-file; never `cat`/`echo` its value.
- **This is a config/Nix repo — no unit-test harness.** Each change step is followed by a concrete verification command with expected output, then a commit. (TDD's failing-test-first does not apply.)
- **Prefer gortex tools** (`edit_file`, `read_file`, `write_file`) over Read/Edit/Write for tracked files in this repo.
- **Format Nix with alejandra** (`just fmt`) before committing any `.nix` change.
- **`backupFileExtension = "backup"`** is already set on both hosts (`hosts/*/configuration.nix`) — `just switch` auto-backs-up conflicting real files. If a stale `*.backup` already exists at a target path, remove it first.
- **End every commit message** with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: Split settings into committed personal/work files + migrate secret

**Files:**
- Rename: `agents/settings.json` → `agents/settings.personal.json` (content unchanged)
- Create: `agents/settings.work.json` (generated from the live work settings, minus `env`)
- Create (machine-local, **not** committed): `~/.claude-work/settings.local.json` (the `env` block with the secret)

**Interfaces:**
- Produces: `agents/settings.personal.json` (→ `~/.claude/settings.json`), `agents/settings.work.json` (→ `~/.claude-work/settings.json`), consumed by Task 2 (claude.nix) and Task 4 (bootstrap.sh).

- [ ] **Step 1: Move the secret into work's machine-local `settings.local.json` (file-to-file, never printed)**

```bash
cd /home/me/gh/nix
# Preserve the current env block (the secret) into the machine-local slot.
jq '{env: .env}' "$HOME/.claude-work/settings.json" > "$HOME/.claude-work/settings.local.json"
```

- [ ] **Step 2: Verify the secret landed in the local file and is valid JSON**

```bash
jq -e '.env.PURE_SENTRY_TOKEN | type == "string" and length > 0' "$HOME/.claude-work/settings.local.json"
jq -r '.env | keys | join(", ")' "$HOME/.claude-work/settings.local.json"
```
Expected: exit 0 (prints `true`), then `PURE_SENTRY_TOKEN`. The token value is never displayed.

- [ ] **Step 3: Generate the committed work settings from the live file, dropping `env` and making the statusLine path portable**

```bash
cd /home/me/gh/nix
jq 'del(.env) | .statusLine.command = "bash \"$HOME/.claude-work/statusline-command.sh\""' \
  "$HOME/.claude-work/settings.json" > agents/settings.work.json
```
(`del(.env)` removes the only secret-bearing key; the SessionStart echo hook and everything else is copied verbatim, avoiding hand-retyping the long session-naming string.)

- [ ] **Step 4: Rename the personal settings file**

```bash
cd /home/me/gh/nix
git mv agents/settings.json agents/settings.personal.json
```

- [ ] **Step 5: Verify both committed files are valid JSON and contain NO secret**

```bash
cd /home/me/gh/nix
jq -e . agents/settings.personal.json > /dev/null && echo "personal OK"
jq -e . agents/settings.work.json > /dev/null && echo "work OK"
# Must print nothing (no secret in tracked files):
grep -rn "PURE_SENTRY_TOKEN" agents/settings.personal.json agents/settings.work.json || echo "clean: no secret tracked"
# Sanity: work file has its plugins and no env key
jq -r '.enabledPlugins | keys | join(", ")' agents/settings.work.json
jq -e 'has("env") | not' agents/settings.work.json && echo "work has no env block"
```
Expected: `personal OK`, `work OK`, `clean: no secret tracked`, the pure/sentry plugin list, `true` + `work has no env block`.

- [ ] **Step 6: Commit (tracked files only — the local file must NOT be staged)**

```bash
cd /home/me/gh/nix
git add agents/settings.personal.json agents/settings.work.json
git status --short   # confirm ~/.claude-work/settings.local.json is NOT listed
git commit -m "$(cat <<'EOF'
feat: split agent settings into committed personal/work files

Rename settings.json -> settings.personal.json and add settings.work.json
(generated from the live work profile minus the Sentry secret, with a
portable $HOME statusline path). The PURE_SENTRY_TOKEN secret now lives in
machine-local ~/.claude-work/settings.local.json and is reunited at load via
Claude's env deep-merge.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Refactor `claude.nix` to manage both profiles

**Files:**
- Modify: `modules/home/claude.nix` (full rewrite of the `let`/`home.file` body)

**Interfaces:**
- Consumes: `agents/settings.personal.json`, `agents/settings.work.json` (Task 1).
- Produces: `home.file` entries for both `.claude/*` and `.claude-work/*`. `settings.local.json` is deliberately absent (machine-local).

- [ ] **Step 1: Rewrite `modules/home/claude.nix`**

Replace the file body (keep the top comment block; update it to say it manages both profiles and that `settings.local.json` is intentionally machine-local) with:

```nix
{
  config,
  osConfig,
  lib,
  ...
}: let
  # Repo agents/ dir on this machine (fish helpers cd to ~/nix, which is the flake).
  agents = "${config.home.homeDirectory}/nix/agents";
  link = config.lib.file.mkOutOfStoreSymlink;

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

- [ ] **Step 2: Format**

```bash
cd /home/me/gh/nix && just fmt
```

- [ ] **Step 3: Verify syntax and full evaluation**

```bash
cd /home/me/gh/nix
just quick
just build
```
Expected: `just quick` passes; `just build` evaluates and builds without error (proves both profiles' `home.file` set is well-formed — build does NOT activate, so it's safe regardless of the current `~/.claude-work` state).

- [ ] **Step 4: Verify both profiles are declared in the built config**

```bash
cd /home/me/gh/nix
nix eval --raw ".#nixosConfigurations.$(hostname).config.home-manager.users.me.home.file.\".claude/settings.json\".source"
nix eval --raw ".#nixosConfigurations.$(hostname).config.home-manager.users.me.home.file.\".claude-work/settings.json\".source"
```
Expected: first resolves to a path ending `agents/settings.personal.json`, second to `agents/settings.work.json`.

- [ ] **Step 5: Commit**

```bash
cd /home/me/gh/nix
git add modules/home/claude.nix
git commit -m "$(cat <<'EOF'
feat: manage both ~/.claude and ~/.claude-work in claude.nix

Extract a profileFiles helper and call it for both profiles so `just switch`
links the work profile too. settings.local.json is left machine-local
(gortex hooks / Sentry secret), owned by neither mechanism.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Activate on this host and verify runtime

**Files:** none (activation + verification only; no commit).

**Interfaces:**
- Consumes: Tasks 1–2 output.

- [ ] **Step 1: Clear any stale backup files that would block activation**

```bash
# Only remove backups if present (harmless if none). Never touch settings.local.json.
for f in settings.json statusline-command.sh balance-refresh.py CLAUDE.md host-memory.md; do
  rm -f "$HOME/.claude-work/$f.backup"
done
```

- [ ] **Step 2: Activate**

```bash
cd /home/me/gh/nix && just switch
```
Expected: switch succeeds. Existing real `~/.claude-work/settings.json` (and any other conflicting files) are renamed to `*.backup` and replaced with symlinks into the repo.

- [ ] **Step 3: Verify both profiles link into the repo and the secret slot is intact**

```bash
echo "--- personal ---"
readlink -f "$HOME/.claude/settings.json"        # -> .../agents/settings.personal.json
test -L "$HOME/.claude/settings.local.json" && echo "WARN: personal local is a symlink" || echo "personal local: real file (gortex hooks) OK"
echo "--- work ---"
readlink -f "$HOME/.claude-work/settings.json"   # -> .../agents/settings.work.json
readlink -f "$HOME/.claude-work/hooks/global-memory-load.sh"  # -> repo agents/hooks/...
test -L "$HOME/.claude-work/settings.local.json" && echo "WARN: work local is a symlink" || echo "work local: real file OK"
jq -e '.env.PURE_SENTRY_TOKEN | length > 0' "$HOME/.claude-work/settings.local.json" && echo "work secret present"
```
Expected: personal `settings.json` → `agents/settings.personal.json`; work → `agents/settings.work.json`; work `hooks/global-memory-load.sh` → repo; both `settings.local.json` remain **real files** (not symlinks); `work secret present`.

- [ ] **Step 4: Verify the merged env reaches a work session (Sentry token)**

```bash
# Confirm Claude resolves the deep-merged token in the work profile.
# The pure-sentry connector reads $PURE_SENTRY_TOKEN from the session env.
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude -p 'print the length of the PURE_SENTRY_TOKEN environment variable, nothing else' 2>&1 | tail -5
```
Expected: reports a non-zero length (token present via `settings.json` + `settings.local.json` env deep-merge). If it reports empty/undefined, STOP — the merge assumption failed; do not proceed to Task 4.

---

### Task 4: Update `bootstrap.sh` for the new layout (portable/non-Nix machines)

**Files:**
- Modify: `agents/bootstrap.sh` (the shared/personal settings-linking block + comments)

**Interfaces:**
- Consumes: `agents/settings.personal.json`, `agents/settings.work.json` (Task 1).

- [ ] **Step 1: Replace the settings-linking block**

Find this block:

```bash
# Shared whole-file links (every profile).
for f in statusline-command.sh balance-refresh.py; do
  link "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
# Personal-only.
if [ "$IS_PERSONAL" -eq 1 ]; then
  link "$SRC_DIR/settings.json" "$CLAUDE_DIR/settings.json"
fi
```

Replace with:

```bash
# Shared whole-file links (every profile).
for f in statusline-command.sh balance-refresh.py; do
  link "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
# settings.json is committed per-profile: personal -> settings.personal.json,
# any secondary profile -> settings.work.json. The machine-local
# settings.local.json (personal: gortex hooks; work: PURE_SENTRY_TOKEN secret)
# is never linked — it stays local and is reunited at load via env deep-merge.
if [ "$IS_PERSONAL" -eq 1 ]; then
  link "$SRC_DIR/settings.personal.json" "$CLAUDE_DIR/settings.json"
else
  link "$SRC_DIR/settings.work.json" "$CLAUDE_DIR/settings.json"
fi
```

- [ ] **Step 2: Update the personal/secondary banner comment**

Find the comment above the `IS_PERSONAL` detection:

```bash
# Personal profile gets personal-only files (settings.json) + Codex; secondary
# profiles (e.g. ~/.claude-work via ccw) get the SHARED set only, so bootstrapping
# from ccw never clobbers the work profile's own settings.json.
```

Replace with:

```bash
# Both profiles get the SHARED set + a committed per-profile settings.json
# (personal -> settings.personal.json, secondary -> settings.work.json). Codex
# rides with the personal run only. The machine-local settings.local.json is
# never touched by either profile.
```

And update the secondary-profile notice line:

```bash
  printf 'Secondary profile — linking SHARED set only (settings.json + Codex skipped)\n\n'
```

to:

```bash
  printf 'Secondary profile — SHARED set + settings.work.json (Codex skipped, settings.local.json untouched)\n\n'
```

- [ ] **Step 3: Verify bootstrap is idempotent and links the right files on both profiles**

```bash
cd /home/me/gh/nix
echo "=== personal ===" && env -u CLAUDE_CONFIG_DIR bash agents/bootstrap.sh | tail -3
readlink -f "$HOME/.claude/settings.json"        # -> agents/settings.personal.json
echo "=== work ===" && CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh | tail -3
readlink -f "$HOME/.claude-work/settings.json"   # -> agents/settings.work.json
test -L "$HOME/.claude-work/settings.local.json" && echo "WARN local symlinked" || echo "work settings.local.json untouched OK"
```
Expected: both runs report `failed=0` (and skip the Nix-managed links via the `-ef` check); personal `settings.json` → `settings.personal.json`; work → `settings.work.json`; work `settings.local.json` still a real file.

- [ ] **Step 4: Commit**

```bash
cd /home/me/gh/nix
git add agents/bootstrap.sh
git commit -m "$(cat <<'EOF'
feat: bootstrap links committed per-profile settings.json

Personal -> settings.personal.json, secondary -> settings.work.json; never
touch the machine-local settings.local.json. Mirrors claude.nix's both-profile
model for non-Nix machines.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Update docs (`README.md`, `AGENTS.md`, `.gitignore`)

**Files:**
- Modify: `agents/README.md` (intro, tracked-files table, per-profile bootstrap section)
- Modify: `agents/AGENTS.md` (the "Persistent memory" tier paragraph)
- Modify: `agents/.gitignore` (clarifying comment only — `settings.local.json` is already ignored)

**Interfaces:** none (documentation).

- [ ] **Step 1: `README.md` — intro line**

Find:

```
The Claude Code user config — skills, agents, commands, statusline and
`settings.json` — lives here and is **symlinked into `~/.claude`** so the same
setup is reused on every machine (Windows 11 / Git Bash, macOS, Linux).
```

Replace with:

```
The Claude Code user config — skills, agents, commands, statusline and a
committed per-profile `settings.json` — lives here and is **symlinked into both
`~/.claude` (personal) and `~/.claude-work` (work)** so the same setup is reused
on every machine (Windows 11 / Git Bash, macOS, Linux).
```

- [ ] **Step 2: `README.md` — tracked-files table**

Replace the `settings.json` row:

```
| `settings.json` | `settings.json` | statusline path is portable (`$HOME`) |
```

with two rows:

```
| `settings.personal.json` | `~/.claude/settings.json` | personal profile config (committed) |
| `settings.work.json` | `~/.claude-work/settings.json` | work profile config (committed; Sentry secret lives in machine-local `settings.local.json`) |
```

- [ ] **Step 3: `README.md` — per-profile bootstrap section**

Find the `just agent-bootstrap-work` bullet:

```
- `just agent-bootstrap-work` — a **secondary** profile, e.g. `~/.claude-work`
  (invoked as `ccw`): links the SHARED set only (`AGENTS.md`→`CLAUDE.md`,
  `memory/`, `hosts/`→`host-memory.md`, `hooks/`, `skills/`, `subagents/`,
  `commands/`, `statusline-command.sh`, `balance-refresh.py`) and never touches
  that profile's own `settings.json` or its Codex config
  (`CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh`).
```

Replace with:

```
- `just agent-bootstrap-work` — a **secondary** profile, e.g. `~/.claude-work`
  (invoked as `ccw`): links the SHARED set (`AGENTS.md`→`CLAUDE.md`, `memory/`,
  `hosts/`→`host-memory.md`, `hooks/`, `skills/`, `subagents/`, `commands/`,
  `statusline-command.sh`, `balance-refresh.py`) **plus** the committed
  `settings.work.json` → `settings.json`. It never touches the machine-local
  `settings.local.json` (which holds the profile's Sentry secret) or its Codex
  config (`CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash agents/bootstrap.sh`).
  On NixOS this profile is also managed by `just switch` (see the nix section).
```

- [ ] **Step 4: `AGENTS.md` — update the persistent-memory tier paragraph**

Find (in the "Persistent memory" section):

```
`hooks/`, `skills/`, `subagents/`, `commands/`, `statusline-command.sh`, and
`balance-refresh.py` — so they're symlinked into **every** profile bootstrapped:
`~/.claude`, `~/.codex`, and secondary profiles like `~/.claude-work`. Only
`settings.json` is PERSONAL-ONLY, linked into `~/.claude` alone — a secondary
profile keeps its own.
```

Replace with:

```
`hooks/`, `skills/`, `subagents/`, `commands/`, `statusline-command.sh`, and
`balance-refresh.py` — so they're symlinked into **every** profile bootstrapped:
`~/.claude`, `~/.codex`, and secondary profiles like `~/.claude-work`.
`settings.json` is committed PER-PROFILE (`settings.personal.json` →
`~/.claude`, `settings.work.json` → `~/.claude-work`); each profile's
machine-local `settings.local.json` (personal: gortex hooks; work: the Sentry
secret) is owned by neither mechanism and never committed.
```

- [ ] **Step 5: `.gitignore` — clarify the settings.local.json entry**

Find:

```
settings.local.json
```

Replace with:

```
settings.local.json   # machine-local per profile (gortex hooks / Sentry secret) — never commit
```

- [ ] **Step 6: Verify docs reference the new filenames and no dangling `settings.json` claims remain**

```bash
cd /home/me/gh/nix
grep -n "settings.personal.json\|settings.work.json" agents/README.md agents/AGENTS.md
# The old "PERSONAL-ONLY ... settings.json ... linked into ~/.claude alone" claim must be gone:
grep -n "PERSONAL-ONLY" agents/AGENTS.md || echo "old PERSONAL-ONLY claim removed"
```
Expected: the new filenames appear in both docs; `old PERSONAL-ONLY claim removed`.

- [ ] **Step 7: Commit**

```bash
cd /home/me/gh/nix
git add agents/README.md agents/AGENTS.md agents/.gitignore
git commit -m "$(cat <<'EOF'
docs: describe committed per-profile settings + both-profile linking

README/AGENTS now document settings.personal.json / settings.work.json, the
machine-local settings.local.json tier, and that both profiles are linked by
claude.nix and bootstrap.sh.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Tier 1+2 committed per-profile `settings.json` → Task 1 (create) + Task 2/4 (link). ✓
- Tier 3 machine-local `settings.local.json` (gortex hooks / secret) → Task 1 (secret migration), left untouched in Tasks 2–4. ✓
- Nix owns both profiles → Task 2 + Task 3 (activate). ✓
- bootstrap.sh portable mirror → Task 4. ✓
- Rename to `settings.personal.json` → Task 1 Step 4. ✓
- Migration/backup of existing `~/.claude-work` files → Task 3 (backupFileExtension already set + stale-backup cleanup). ✓
- Verification (secret reaches env, additive merges, symlinks) → Task 3 Steps 3–4, Task 4 Step 3. ✓
- Docs → Task 5. ✓

**Placeholder scan:** No TBD/TODO; every code/JSON step shows exact commands or exact find/replace text. ✓

**Type/name consistency:** `settings.personal.json` and `settings.work.json` used identically across Tasks 1, 2, 4, 5; `profileFiles`/`linkEntries` helper names consistent within Task 2. ✓

## Notes / residual risk

- **`env` deep-merge is load-bearing** — Task 3 Step 4 empirically gates on it; if it fails, stop.
- **`extraKnownMarketplaces.pure-team.source.path`** in `settings.work.json` keeps the literal `/home/me/gh/pure/claude-plugins` (verbatim from the current file). It's committed and assumes home is `/home/me` on every work machine — true today; out of scope to parameterize.
- **gortex hooks** in `~/.claude/settings.local.json` are assumed machine-local and are never touched.
