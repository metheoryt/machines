---
name: gortex-align
description: Use when the user wants to align, onboard, or tune a repository for Gortex — improve its code-graph resolution quality, commit the gortex wiring (.gortex.yaml / .mcp.json), or set up type-information governance on a Python project (a type checker — ty / pyright / mypy — plus ruff annotation rules) so its type annotations feed gortex's native type-aware Python resolver. Configures per-repo wiring; does NOT install the gortex binary (that's a machine-level concern).
---

# Align a repo for Gortex

## Overview

Gortex indexes a repo into a code graph. Edge quality depends on how well the
code's type information resolves. For Python the resolver is gortex's **native,
type-aware `python-types`** provider — this build ships no `lsp-pyright`, so
pyright is *not* in gortex's resolution path. "Aligning a repo for gortex" means
two things:

1. **Wire it** — commit the gortex config so the integration is reproducible for
   teammates/CI, and confirm the daemon is tracking and has indexed it.
2. **Tune the type view** — make the code carry the type information the native
   provider keys off. That means *type information in the source* (annotations +
   installed stubs), not any one tool: a **type checker** (ty / pyright / mypy)
   measures whether names resolve, and **ruff** enforces annotation presence on
   leaf code. Use whichever checker the repo already has; default to **ty** when
   it has none. Bundled config blocks below.

**Scope boundary:** this skill *configures* per-repo wiring. It does **not**
install the `gortex` binary itself — that's machine provisioning (declarative on
NixOS). If the daemon/binary is absent, stop and tell the user it's a
machine-level install; don't try to provision it.

## Steps

### 1. Detect gortex (binary + daemon)

```bash
gortex daemon status
```

- Command not found / daemon not running → **stop**. Tell the user gortex isn't
  installed/running on this machine; that's a machine-level install (a nix
  module/package on NixOS), out of this skill's scope. Don't `curl | sh`.
- Running → continue. Note whether the **cwd is covered** by a tracked repo.

### 2. Wire the repo (reproducibility)

Check whether the gortex wiring is already present:

- A `gortex` server entry in `.mcp.json`? (the load-bearing artifact)
- A `.gortex/` dir? (recent gortex writes a **gitignored** `.gortex/` for local
  index state — *not* a committed `.gortex.yaml`; older builds wrote
  `.gortex.yaml`. Don't assume the file name.)

**Default to the core-only invocation — NOT a bare `gortex init`.** A bare init
sprays ~32 files across every detected adapter (Cursor, Antigravity, Zed, Codex,
Claude Code) — including ~20 auto-generated `.claude/skills/generated/gortex-*/SKILL.md`
community-routing files, per-repo hooks, and a permissions block. Those skills are
stale-prone navigation blurbs, noise in a shared repo, and irrelevant to gortex's
actual function (indexing + MCP query tools work without them). Instead:

```bash
gortex init --dry-run --yes --agents claude-code --no-skills --no-hooks   # preview first
gortex init          --yes --agents claude-code --no-skills --no-hooks   # writes .mcp.json + .claude/settings.json
```

This collapses to the 2 core files. Add adapters (`--agents claude-code,zed`)
only for tools the user actually uses here; add `--skills`/`--hooks` only on
request. Hooks are frequently already machine-wide (user-scope
`settings.local.json`), so per-repo hooks just duplicate them.

**Committing vs. local-only.** Only committed wiring carries to teammates/CI;
a daemon merely *tracking* the repo is local. But **stage, don't commit unless
asked** — and watch for two gotchas:
- Many repos use an allowlist-style `.gitignore` (`*` + un-ignore rules) that
  silently ignores `.mcp.json` / `.claude/` / `.gortex/`. Then `git status` is
  clean and nothing is staged — the wiring is local-only unless the user
  force-adds it. Surface this; don't assume "staged" means "will be committed".
- If the user says keep it out of git, that's fine — the local index still works;
  just tell them it won't be reproducible for teammates.

### 3. Verify tracking + index health

```bash
gortex daemon status        # is this repo tracked & is cwd covered?
```

`gortex init` does **not** auto-register the repo for persistent daemon
tracking — it indexes once in-process and appends the path to
`~/.gortex/config.yaml`. If `tracked repos` still shows `(none)`, run:

```bash
gortex daemon reload        # re-reads config, picks up the new repo
```

Then re-check `daemon status`: the repo should appear with a non-zero node/edge
count. Confirm the index is `ready` (not mid-warmup) before trusting graph
queries — use the `gortex://index-health` resource or `index_health` tool. Note
the gortex MCP tools only register in a Claude Code session whose cwd was covered
at session start — after first-time wiring, they appear on the next session reload.

### 4. Align the type view (Python) — detection-driven

Detect the language. **For Python**, align two halves — *resolution* (a type
checker) and *annotation presence* (a linter):

1. **Detect what's already there.** Scan `pyproject.toml` / config files for a
   type checker (`[tool.ty]`·`ty.toml`, `[tool.mypy]`·`mypy.ini`,
   `[tool.pyright]`·`pyrightconfig.json`) and a linter (`[tool.ruff]`·`ruff.toml`).
   Confirm a **deps-installed env** (`.venv` with dependencies) — no env and every
   checker degrades to unresolved-import noise.

2. **Type checker (resolution).**
   - One is **already configured** → use it; don't impose another.
   - **None** → set up **ty** by default (Astral-native, matches uv, fastest):
     add the `[tool.ty]` block from `type-governance-reference.md`, then
     `uvx ty check`. Note ty is **pre-1.0 (v0.0.x)** — surface still churns.
     Offer **pyright** (mature, best stubs) or **mypy** (loads the `django-stubs`
     plugin → resolves more Django magic) as alternatives.

3. **Ruff (annotation presence), always-on complement.**
   - ruff present → ensure `ANN` is in `select`.
   - a different linter present → add its annotation rules.
   - none → offer the full `[tool.ruff]` block from the reference (lint + format
     + `ANN` + isort).

4. **Act on the diagnostics.** Install the stubs the checker flags; add missing
   parameter/return annotations; kill `unknown`/`Any` at boundaries. Each fix
   gives the native type-aware provider more to resolve against.

5. **Ratchet** strictness once clean (ty: promote `[tool.ty.rules]` to `error`;
   pyright: `standard` → `strict`).

See `type-governance-reference.md` (next to this file) for the copy-paste
`pyproject.toml` blocks, the rationale, and the honest limits.

### 5. Re-index and report

After wiring/config changes, let the daemon re-warm, then sanity-check that
resolution improved (e.g. `find_usages` on a previously `text_matched` symbol).
Report what was committed-vs-staged and which stubs/annotations remain as
follow-ups.

## Honest limits

No static checker is the framework. ty and pyright do **not** load the
`django-stubs` *mypy plugin*, so plugin-driven Django magic (manager/queryset
return types, dynamic model attrs) stays partly unresolved even with stubs
installed — mypy + the plugin resolves the most. The "often missed" tier from the global
Gortex memory note still holds — signals (`@receiver`/`.connect`), Celery
`@shared_task`, admin auto-registration, settings string lists, template→`.html`.
**Never act on gortex's "0 usages / dead code" for any of those**; it's a false
positive on framework-invoked code regardless of how clean the checker is.

## Common mistakes

- **Trying to install the gortex binary** — out of scope; detect and defer to
  machine provisioning.
- **Running a bare `gortex init`** — it sprays ~32 files (multi-adapter configs +
  ~20 generated routing skills + hooks). Default to
  `--agents claude-code --no-skills --no-hooks`; widen only on request.
- **Committing `gortex init` output without asking** — stage it; commit only on
  request. And check the repo's `.gitignore` doesn't silently ignore the wiring
  (allowlist-style `*` gitignores do).
- **Assuming `init` tracks the repo** — it indexes once; run `gortex daemon reload`
  to pick it up for persistent tracking.
- **Pointing the checker at an env without deps installed** — resolution silently
  degrades to `text_matched`; no config helps if imports don't resolve.
- **Trusting graph queries mid-warmup** — confirm index health is `ready` first.
