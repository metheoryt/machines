---
name: gortex-align
description: Use when the user wants to align, onboard, or tune a repository for Gortex — improve its code-graph resolution quality, commit the gortex wiring (.gortex.yaml / .mcp.json), or set up pyright governance on a Python project so its type annotations feed gortex's native type-aware Python resolver. Configures per-repo wiring; does NOT install the gortex binary (that's a machine-level concern).
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
   provider keys off. For Python this is pyright governance: pyright is a
   standalone type checker, and the annotations/stubs it forces you to add feed
   gortex's type-aware provider (plus pyright surfaces every unresolved spot as a
   diagnostic). Bundled config below.

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

Check whether the gortex wiring is committed:

- `.gortex.yaml` present and tracked?
- A `gortex` server entry in `.mcp.json` present and tracked?

If either is missing, run `gortex init` from the repo root, review the generated
files, and **stage them** (don't commit unless the user asked). A daemon merely
*tracking* a repo works locally but carries nothing to teammates/CI — only the
committed `.gortex.yaml` + `.mcp.json` make it reproducible.

### 3. Verify tracking + index health

```bash
gortex daemon status        # is this repo tracked & is cwd covered?
```

If untracked, register/track it per the daemon's CLI. Confirm the index is
`ready` (not mid-warmup) before trusting graph queries — use the
`gortex://index-health` resource or `index_health` tool.

### 4. Align the stack (Python → pyright governance)

Detect the language. **For Python:**

1. Copy the bundled reference config into the repo root as `pyrightconfig.json`
   (or fold its keys into `[tool.pyright]` in `pyproject.toml`):
   ```bash
   cp ~/.claude/skills/gortex-align/pyrightconfig.json ./pyrightconfig.json
   ```
2. Adapt it to the repo: fix `include` to the real source roots, point
   `venv`/`venvPath` (or `pythonPath`) at the env where deps are **installed**,
   set `pythonVersion`. Pyright can't resolve imports it can't see, so without a
   deps-installed env its diagnostics are useless.
3. Run pyright (or read the diagnostics) and act on them:
   - `reportMissingTypeStubs` → install the stubs (`django-stubs`,
     `djangorestframework-stubs`, `celery-types`, `types-requests`, …).
   - `reportMissing*Type` / `reportUnknown*` → add annotations. Each fix gives
     the native type-aware provider more type information to resolve against.
4. Once clean, suggest ratcheting `typeCheckingMode` from `standard` to
   `strict`.

See `pyright-reference.md` (next to this file) for the rationale, the
`[tool.pyright]` variant, and the honest limits.

### 5. Re-index and report

After wiring/config changes, let the daemon re-warm, then sanity-check that
resolution improved (e.g. `find_usages` on a previously `text_matched` symbol).
Report what was committed-vs-staged and which stubs/annotations remain as
follow-ups.

## Honest limits

Pyright does **not** load the `django-stubs` *mypy plugin*, so plugin-driven
Django magic (manager/queryset return types, dynamic model attrs) stays partly
unresolved even with stubs installed. The "often missed" tier from the global
Gortex memory note still holds — signals (`@receiver`/`.connect`), Celery
`@shared_task`, admin auto-registration, settings string lists, template→`.html`.
**Never act on gortex's "0 usages / dead code" for any of those**; it's a false
positive on framework-invoked code regardless of how clean pyright is.

## Common mistakes

- **Trying to install the gortex binary** — out of scope; detect and defer to
  machine provisioning.
- **Committing `gortex init` output without asking** — stage it; commit only on
  request.
- **Pointing pyright at an env without deps installed** — resolution silently
  degrades to `text_matched`; the config can't help if imports don't resolve.
- **Trusting graph queries mid-warmup** — confirm index health is `ready` first.
