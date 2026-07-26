# Hermes Agent Fleet Integration Plan

> **For Hermes:** Execute task-by-task with careful testing at each step.

**Goal:** Persist Hermes Agent config, skills, and memory in the `machines` repo so
every fleet host (WSL distros, NixOS latitude, hub) can bootstrap a consistent,
version-controlled Hermes setup with a single command — mirroring the existing
Claude Code / Codex pattern.

**Architecture:** A new `hermes/` directory in the repo root holds version-controlled
config (`config.yaml`, skills, memory, profiles). A `hermes/bootstrap.sh` links these
into `~/.hermes/` (copy_managed for config.yaml since Hermes self-writes it;
symlinks for skills/memory entries). The provisioning tier system (`linux.sh` →
`tiers.sh`) gains a `tier_agent_clis hermes` install step and a
`tier_hermes_config` bootstrap step. A `just hermes-bootstrap` recipe wraps it
for manual use.

**Tech Stack:** Bash provisioning scripts, the official Hermes install.sh, symlink
management (copy_managed + link patterns from `agents/bootstrap.sh`).

---

## Current State

- Hermes Agent v0.19.0 is installed on this WSL distro at `~/.hermes/hermes-agent/`
  (git install method).
- Active config at `~/.hermes/config.yaml` (876 bytes) — Nous provider,
  deepseek-v4-pro, web/browser via gateway, OpenAI TTS/STT.
- Custom skills at `~/.hermes/skills/` (8.5M, 14 category dirs).
- Memory at `~/.hermes/memories/` (4K).
- No existing Hermes references anywhere in the repo.
- The repo already manages Claude Code (`agents/`) and Codex (`agents/codex/`)
  with the same pattern this plan follows.

## What Gets Persisted vs What Stays Local

| Persisted in repo | Stays local (volatile/secrets) |
|---|---|
| `hermes/config.yaml` | `~/.hermes/.env` (secrets) |
| `hermes/skills/` (each skill dir) | `~/.hermes/state.db` (sessions) |
| `hermes/memories/` | `~/.hermes/auth.json` (OAuth) |
| `hermes/SOUL.md` (if user-authored) | `~/.hermes/sessions/` (transcripts) |
| `hermes/profiles/<name>/` (if any) | `~/.hermes/hermes-agent/` (install) |
| | `~/.hermes/cache/`, `audio_cache/`, `image_cache/` |

---

## Task 1: Create `hermes/` directory structure in repo

**Objective:** Seed the version-controlled Hermes config directory.

**Files:**
- Create: `hermes/config.yaml`
- Create: `hermes/.gitkeep` (in empty subdirs)
- Create: `hermes/memories/.gitkeep`
- Create: `hermes/profile/.gitkeep`

**Step 1: Create dirs and seed config from the live install**

Copy `~/.hermes/config.yaml` into `hermes/config.yaml` as the baseline.
Create empty `hermes/skills/`, `hermes/memories/`, `hermes/profile/` dirs
with `.gitkeep` placeholders.

**Step 2: Seed a .gitignore**

Create `hermes/.gitignore`:
```
# Secrets — never commit
.env
auth.json
auth.lock

# Runtime state — volatile per host
state.db
state.db-*
sessions/
cache/
audio_cache/
image_cache/
gateway*
channel_directory.json
context_length_cache.yaml
.update_check
.skills_prompt_snapshot.json
.hermes_history
hooks/
image_cache/
kanban/
kanban.db*
log/
logs/
```

**Step 3: Commit baseline**

```bash
git add hermes/
git commit -m "feat(hermes): seed version-controlled Hermes config directory"
```

---

## Task 2: Write `hermes/bootstrap.sh`

**Objective:** Symlink repo-tracked Hermes config into `~/.hermes/`, mirroring
the pattern from `agents/bootstrap.sh`.

**Files:**
- Create: `hermes/bootstrap.sh`

**Design decisions:**

- `config.yaml` → `copy_managed` (NOT symlink). Hermes itself writes to
  config.yaml (`hermes config set …`), so a symlink would dirty the tracked
  repo file. Same rationale as `agents/settings.json`.
- `skills/` entries → `link_entries_into` each skill directory as individual
  symlinks, so machine-local skills coexist with tracked ones.
- `memories/` → `link_entries_into` each memory entry.
- `SOUL.md` → `link` if present in repo, skip otherwise.
- `profile/` → if the repo has `hermes/profile/<name>/`, a
  `PROFILE=<name> hermes/bootstrap.sh` invocation creates
  `~/.hermes/profiles/<name>/` with symlinked config.yaml + skills + memory.

The script sources its helper functions (`link`, `copy_managed`, `hash_file`,
`link_entries_into`) from `agents/bootstrap.sh` via `BOOTSTRAP_LIB_ONLY=1` to
stay DRY.

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
# hermes/bootstrap.sh — symlink version-controlled Hermes config from
# <repo>/hermes/ into ~/.hermes/. Mirrors agents/bootstrap.sh pattern.
#
# Usage:
#   bash hermes/bootstrap.sh              # personal ~/.hermes
#   PROFILE=work bash hermes/bootstrap.sh # profile ~/.hermes/profiles/work/
set -u

# Source shared link/copy_managed helpers from agents/bootstrap.sh
BOOTSTRAP_LIB_ONLY=1 . "$(dirname "${BASH_SOURCE[0]}")/../agents/bootstrap.sh"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PROFILE="${PROFILE:-}"

if [ -n "$PROFILE" ]; then
  HERMES_HOME="$HOME/.hermes/profiles/$PROFILE"
  mkdir -p "$HERMES_HOME"
fi
BAK_ROOT="$HERMES_HOME/.bootstrap-bak"

printf 'Bootstrapping Hermes config\n  repo:  %s\n  live:  %s\n\n' "$SRC_DIR" "$HERMES_HOME"

linked=0 skipped=0 backed=0 failed=0

# config.yaml — copy_managed, not symlink (Hermes self-writes it)
if [ -f "$SRC_DIR/config.yaml" ]; then
  copy_managed "$SRC_DIR/config.yaml" "$HERMES_HOME/config.yaml"
else
  printf '  ! no hermes/config.yaml in repo — skipping\n'
fi

# SOUL.md — link if present
link "$SRC_DIR/SOUL.md" "$HERMES_HOME/SOUL.md" 2>/dev/null || true

# Skills — symlink each tracked skill into ~/.hermes/skills/
link_entries_into "$SRC_DIR/skills" "$HERMES_HOME/skills"

# Memory — symlink each tracked memory file
link_entries_into "$SRC_DIR/memories" "$HERMES_HOME/memories"

# Prune empty backup dirs
[ -d "$BAK_ROOT" ] && find "$BAK_ROOT" -type d -empty -delete 2>/dev/null

printf '\nDone. linked=%d  skipped=%d  backed-up=%d  failed=%d\n' \
  "$linked" "$skipped" "$backed" "$failed"
[ -d "$BAK_ROOT" ] && printf 'Previous real files saved under %s\n' "$BAK_ROOT"
[ "$failed" -gt 0 ] && exit 1
```

**Step 2: Make executable and test dry-run**

```bash
chmod +x hermes/bootstrap.sh
DRY_RUN=1 bash hermes/bootstrap.sh
```

Expected: reports what it would link/copy without touching `~/.hermes/`.

---

## Task 3: Add `tier_agent_clis hermes` in provisioning

**Objective:** Install the Hermes CLI via its native installer during
`provision/linux.sh`, matching how Claude and Codex are installed.

**Files:**
- Modify: `provision/lib/tiers.sh`

**Step 1: Add `hermes` case to `tier_agent_clis()`**

In `tier_agent_clis()`, add a `hermes` case after `codex`:

```bash
      hermes)
        if have hermes; then
          ok "hermes already installed"
        else
          info "Installing Hermes Agent…"
          curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash >/dev/null 2>&1 \
            && ok "hermes installed" \
            || warn "hermes install failed — retry: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
        fi ;;
```

**Step 2: Add `tier_hermes_config` in tiers.sh**

A new tier that calls `hermes/bootstrap.sh`:

```bash
tier_hermes_config() {
  info "Linking synced Hermes config…"
  bash "$REPO/hermes/bootstrap.sh" || die "hermes/bootstrap.sh failed"
  ok "Hermes config linked"
}
```

**Step 3: Add to workstation profile tier list**

In `linux.sh`, add `hermes` to the agent CLIs list and `hermes_config` to the
tier list:

```bash
  workstation)
    TIERS=(apt_min apt_dev agents_config git_base gortex
           "agent_clis claude codex hermes" shell_init autofetch
           ssh_accounts selfpull ssh_trust hermes_config) ;;
```

**Step 4: Add `hermes_config` to hub profile if desired**

Hub profile likely doesn't need Hermes (it's a lean server). Skip unless the
user asks.

---

## Task 4: Add `just hermes-bootstrap` recipe

**Objective:** Manual bootstrap command, mirroring `just agent-bootstrap`.

**Files:**
- Modify: `justfile`

Add after the `agent-bootstrap-profile` recipe:

```make
# Bootstrap Hermes Agent config (~/.hermes)
hermes-bootstrap:
    @echo "🔗 Bootstrapping Hermes Agent config..."
    @bash hermes/bootstrap.sh
```

---

## Task 5: Wire `tier_hermes_config` into `tiers.sh`

**Objective:** Actually write the `tier_hermes_config` function and register it.

**Files:**
- Modify: `provision/lib/tiers.sh` (add function + case entry)
- Modify: `provision/linux.sh` (add to workstation TIERS)

This is the implementation of the design from Task 3. Do it as a separate
commit.

---

## Task 6: Update documentation

**Objective:** Document Hermes as a fleet agent in the repo docs.

**Files:**
- Modify: `AGENTS.md` (→ `CLAUDE.md`)

**Changes:**
1. In the "Common Commands" section, add a Hermes subsection or note.
2. In the module/provisioning overview, mention `hermes/` as the config dir.
3. Add a line in `agents/README.md` about Hermes config management.

---

## Task 7: Seed existing skills into the repo

**Objective:** Copy the current Hermes skills from this WSL distro into
`hermes/skills/` so they're tracked and synced.

**Files:**
- Create: `hermes/skills/<category>/<skill-name>/` (many)

**Step 1: Copy skills**

```bash
cp -r ~/.hermes/skills/* hermes/skills/
```

**Step 2: Commit**

```bash
git add hermes/skills/
git commit -m "feat(hermes): seed current skill set into repo"
```

---

## Task 8: Test the full provisioning chain on a fresh WSL distro

**Objective:** Verify a newly provisioned WSL host gets Hermes + config.

**Steps:**
1. Export a fresh WSL distro or use a test dir.
2. Run `just provision-wsl test-hermes` (or the individual scripts).
3. Verify `hermes --version` works.
4. Verify `~/.hermes/config.yaml` is a managed copy of the repo baseline.
5. Verify `~/.hermes/skills/` has symlinks to repo skills.
6. Verify `~/.hermes/memories/` has symlinks to repo memories.
7. Run `hermes` interactively — confirm skills load from the symlinked dir.

---

## Risks

- **Installer output:** The Hermes install.sh may prompt or be chatty.
  The `>/dev/null 2>&1` redirect should handle this, but verify it's truly
  non-interactive. If not, wrap with `HERMES_NON_INTERACTIVE=1` or similar.
- **config.yaml drift:** Hermes writes to its config.yaml (`hermes config set …`).
  `copy_managed` with the srchash stamp handles this — re-seeds only when the
  committed baseline changes. Local edits (from `hermes config set`) survive
  between re-seeds.
- **Skills compatibility:** If skills change format between Hermes versions, a
  newer skill on an older Hermes install might break. Follow Hermes release
  notes for breaking changes to the skill format.
- **Profiles:** The profile mechanism in `hermes/bootstrap.sh` is designed but
  untested — verify if `PROFILE=…` is needed before implementing.

## Out of Scope (YAGNI)

- NixOS Home Manager module for Hermes (declarative config). The bootstrap.sh
  script covers both NixOS and non-NixOS hosts; a Nix module can come later.
- Hermes pet mascots, desktop plugins, TUI widgets — not in the core config
  surface.
- Hermes gateway / cron / webhooks — those are per-machine runtime concerns,
  not fleet-wide config.
- Migration of the `~/.hermes/hermes-agent/` install directory into Nix — the
  curl installer is fine for WSL; NixOS can use the same or a flake input later.
- Other profiles beyond the default — only add profile support when a second
  profile exists.
