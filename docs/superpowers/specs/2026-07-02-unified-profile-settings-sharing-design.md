# Unified profile config sharing — three-tier settings split

**Date:** 2026-07-02
**Status:** approved — forks resolved (rename to settings.personal.json; Nix owns both profiles)
**Scope:** how `~/.claude` (personal) and `~/.claude-work` (work) share agent config;
where each `settings.json` field lives; who links the work profile.

## Problem

Today the personal/work split hinges on one hardcoded rule in `bootstrap.sh`
(`IS_PERSONAL`): `settings.json` is linked into `~/.claude` only, and the work
profile keeps its own machine-local `settings.json`. `just switch` (Nix,
`modules/home/claude.nix`) manages `~/.claude` only — it never touches
`~/.claude-work`, which is why `switch` doesn't set up the work profile.

We want a clearer, gitignore-driven tier model: machine-specific files are
gitignored; everything else is shared into **both** profiles and overwrites on
apply; and `just switch` sets up both profiles on NixOS.

## Key finding — settings.json diverges more than "secret + work plugins"

Empirical diff of the two live `settings.json` files:

| Key | personal (`~/.claude`) | work (`~/.claude-work`) |
|---|---|---|
| `env` | empty | `PURE_SENTRY_TOKEN` (the only real secret) |
| `enabledPlugins` | warp, superpowers, claude-md-mgmt, commit-commands | superpowers, code-review, pure-connectors, pure-dev, sentry |
| `extraKnownMarketplaces` | claude-code-warp | pure-team |
| `hooks.SessionStart` | gortex-onboard, global-memory-load, project-memory | session-naming echo, global-memory-load |
| `model` | opus-4-8 | (absent) |
| `theme` | (absent) | auto |
| `skipWorkflowUsageWarning` | (absent) | true |
| `voice.mode` | hold | tap |
| `statusLine.command` | `bash "$HOME/.claude/statusline-command.sh"` | `bash /home/me/.claude-work/statusline-command.sh` |
| common | `agentPushNotifEnabled`, `voiceEnabled`, `tui=fullscreen`, `voice.enabled` | same |

Most of this divergence is **profile-specific but machine-invariant** (the work
plugin set is identical on every machine; the personal model is opus
everywhere). That is a *third* bucket beyond the two the original request
implied (shared-committed vs machine-gitignored): it must be **committed** (so it
syncs across machines) yet **per-profile** (so work ≠ personal).

## The two-slot constraint

Claude Code reads exactly **two** files at a user config dir:
`settings.json` + `settings.local.json`. Merge semantics (verified against docs +
the live setup):

- `env` — **deep merge** (keys combine; higher precedence wins per key).
- `hooks.*` — **array merge, additive** (higher precedence *adds* hooks; cannot
  remove a lower-precedence hook).
- `enabledPlugins` — object, **deep merge** (union).
- scalars (`model`, `theme`, …) — higher precedence **overrides**.

Both profiles already spend their `settings.local.json` slot on a **machine-local
layer**:

- **personal** `~/.claude/settings.local.json` → gortex hooks
  (`/run/current-system/sw/bin/gortex …`, PreCompact/PreToolUse/SessionStart/
  Stop/UserPromptSubmit) — a NixOS-specific path, machine-local, likely
  auto-managed by the gortex integration.
- **work** `~/.claude-work/settings.local.json` → will hold the
  `PURE_SENTRY_TOKEN` secret.

With the machine-local layer occupying `settings.local.json` in both profiles,
there is **no third user-scope slot for a separate shared-base file**. (Managed
settings are highest-precedence and would override profiles — wrong direction.)
So the shared base must be **inlined into each profile's committed
`settings.json`**, not kept as its own file.

## Design — three tiers

### Tier 1 + 2: committed per-profile `settings.json`

Two committed files, each a **complete** profile config (common base inlined):

- `agents/settings.personal.json` → symlinked to `~/.claude/settings.json`
  (this is today's `agents/settings.json`, essentially unchanged — it already
  omits the gortex hooks and carries no secret).
- `agents/settings.work.json` → symlinked to `~/.claude-work/settings.json`
  (today's live work `settings.json` **minus** `env.PURE_SENTRY_TOKEN`).

Duplicated between them: `agentPushNotifEnabled`, `voiceEnabled`,
`voice.enabled`, `tui`, `enabledPlugins.superpowers`, and the
`global-memory-load` SessionStart hook. This is ~4–6 keys and low-drift; and
several nominally-"common" fields (the `global-memory-load` path, `statusLine`)
already differ by profile dir, so a shared base file would not have unified them
anyway.

**Naming (decided):** rename `agents/settings.json` →
`agents/settings.personal.json` for symmetry with `settings.work.json` and a
clear three-tier mental model.

### Tier 3: machine-local `settings.local.json` (gitignored, not repo-linked)

Left exactly as today's mechanism — a real machine-local file at each config
dir, **never** symlinked from the repo, **not** managed by Nix or bootstrap:

- `~/.claude/settings.local.json` → gortex hooks (unchanged; untouched by this
  work).
- `~/.claude-work/settings.local.json` → `{ "env": { "PURE_SENTRY_TOKEN": "…" } }`
  (moved out of the committed work `settings.json`; `env` deep-merge reunites it
  at load time).

`.gitignore` already ignores `settings.local.json` — keep it. The new
`settings.personal.json` / `settings.work.json` are **not** matched by any ignore
pattern, so they commit normally.

### Who links each profile

`just switch` manages **both** profiles on NixOS; `bootstrap.sh` is the portable
equivalent for non-Nix machines. `settings.local.json` is owned by neither.

**`modules/home/claude.nix`** — extract the per-profile link set into a helper
and call it twice:

- `~/.claude`: `settings.json`→`settings.personal.json`; shared whole-file links
  (statusline, balance-refresh, CLAUDE.md, memory/*, host-memory); entry dirs
  (hooks, skills, agents←subagents, commands).
- `~/.claude-work`: `settings.json`→`settings.work.json`; the **same** shared
  whole-file links and entry dirs.
- Neither profile links `settings.local.json`.
- Codex (`~/.codex`) unchanged.

**`bootstrap.sh`** — replace the `IS_PERSONAL` settings carve-out:

- personal run → link `settings.personal.json`→`~/.claude/settings.json`.
- secondary run (`~/.claude-work`) → link
  `settings.work.json`→`~/.claude-work/settings.json`.
- never touch `settings.local.json` in either.
- Codex block stays personal-only.

## Migration (one-time)

1. `agents/settings.work.json` ← current `~/.claude-work/settings.json` **minus**
   `env.PURE_SENTRY_TOKEN`. Commit.
2. `~/.claude-work/settings.local.json` ← `{"env":{"PURE_SENTRY_TOKEN":"<current>"}}`.
   Machine-local; **do not commit**.
3. (If renaming) `git mv agents/settings.json agents/settings.personal.json`;
   update `claude.nix`, `bootstrap.sh`, README refs.
4. Before first `switch`, the existing **real** files under `~/.claude-work`
   (`settings.json`, `statusline-command.sh`, `hooks/`, …) will block
   home-manager (it refuses to overwrite unmanaged files). Clear them first —
   run `just agent-bootstrap-work` (backs up to `.bootstrap-bak/`) or move them
   aside — then `just switch`.
5. Personal `~/.claude/settings.local.json` (gortex hooks) is untouched.

## Verification

- After moving the token: launch a work session (`ccw`) and confirm the sentry
  connector still authenticates (token reaches `env` via deep-merge).
- Confirm work `enabledPlugins` = base ∪ work overlay and `hooks.SessionStart`
  contains both `global-memory-load` and the session-naming echo (additive
  merge).
- Confirm personal gortex hooks still fire (settings.local.json untouched).
- `just switch` links both profiles; `find ~/.claude-work -maxdepth 2 -type l`
  shows repo-pointed symlinks; work `settings.local.json` remains a real file.
- Re-run `bootstrap.sh` for both profiles → `failed=0`, idempotent.

## Out of scope / non-goals

- No change to which non-settings files are shared (skills/hooks/memory/etc. are
  already shared into both profiles).
- No secret moves to shell env vars (rejected: unnecessary once the machine-local
  `settings.local.json` slot holds it).
- No shared-base *file* (rejected: no third user-scope slot; base is inlined).

## Decisions

1. **Rename** `agents/settings.json` → `agents/settings.personal.json` (approved).
2. **Nix owns both profiles** (approved) — `just switch` links `~/.claude` and
   `~/.claude-work`; `bootstrap.sh` is the portable fallback. Requires the
   one-time cleanup of existing real `~/.claude-work` files before first switch
   (see Migration §4).

## Open question (non-blocking)

- Are the gortex hooks in `~/.claude/settings.local.json` user-authored or
  auto-generated by the gortex onboard hook? Default assumption: leave
  machine-local, untouched by this work.

## Correction (2026-07-02, post-implementation)

The load-bearing assumption in "The two-slot constraint" — that a config-dir-root
`settings.local.json`'s `env` block is deep-merged into the session — is **FALSE**.
A real `ccw` work session showed `PURE_SENTRY_TOKEN` unset in the Bash-tool env
despite living in `~/.claude-work/settings.local.json`. Empirically confirmed:
Claude Code reads **only `settings.json`** at a config-dir root; `settings.local.json`
is a *project-scope* file (`<project>/.claude/settings.local.json`). So the
config-dir-root `settings.local.json` is never read and its `env` does nothing.
(This also means the earlier "user-scope `settings.local.json` is honored" belief,
inferred from the personal gortex hooks, was wrong for the `env` path.)

**Kept:** the committed `settings.personal.json` / `settings.work.json` split and
both-profile linking (Tasks 1–2, 4–5) — all correct and unaffected.

**Fixed (final decision): per-project secret storage.** `PURE_SENTRY_TOKEN` lives
in each work repo's PROJECT-scope `.claude/settings.local.json` (gitignored per
repo). This is the *one* place Claude reads `settings.local.json`, and its `env`
reaches the session and its Bash-tool subprocesses — both verified empirically:

| Where the token sits | Read by Claude? | Reaches Bash tool? |
|---|---|---|
| config-dir-root `~/.claude-work/settings.local.json` `env` | **no** | no |
| config-dir-root `~/.claude-work/.env` | **no** | no |
| launching process environment (e.g. a wrapper `export`) | n/a | **yes** |
| PROJECT-scope `<repo>/.claude/settings.local.json` `env` | **yes** | **yes** |

An intermediate fix that exported the token via a `ccw` launcher function
(commit `de94731`) worked but was reverted in favour of the simpler per-project
model, which needs no wrapper — `ccw` stays a plain alias. Trade-off: the token
is present only when Claude is launched inside a work repo that carries it, and
must be replicated into each such repo (each gitignoring `.claude/settings.local.json`).
The earlier "no secret to shell env vars" non-goal therefore stands after all.
