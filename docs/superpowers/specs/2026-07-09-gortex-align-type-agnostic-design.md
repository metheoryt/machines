# Rework `gortex-align`: type-information governance (tool-agnostic)

**Date:** 2026-07-09
**Skill:** `agents/plugin/skills/gortex-align/` (plugin `cyphy`, repo `machines`)
**Status:** design approved, pending spec review

## Problem

The skill currently frames Python alignment as *"align for gortex == resolve
cleanly under **pyright**."* That is a category error the skill's own overview
half-admits: gortex ships no `lsp-pyright`; its resolver is the native,
type-aware `python-types` provider, which keys off **type information present in
the source** — annotations + installed stubs — **not pyright**. Pyright is only
one interchangeable *governance mechanism* for surfacing and pressuring that info
in.

Two concrete symptoms of the over-fit:

- The bundled `pyrightconfig.json` carries `reportAny` / `reportExplicitAny`,
  which **standard pyright rejects as unrecognized** (they are *basedpyright*
  keys). Verified live: `uvx pyright` prints
  `Config contains unrecognized setting "reportAny"`.
- The skill imposes pyright even on repos already standardized on the Astral
  toolchain (uv + ruff), where **ty** is the coherent single-vendor fit.

## Goal

Decouple the skill's method from any one tool:

> **Goal:** the source carries *resolvable* type information.
> **Method:** a **type checker** measures *resolution* (ty / pyright / mypy); a
> **linter** enforces *annotation presence* (ruff `ANN`). These are two halves,
> not substitutes — ruff alone cannot measure resolution; a type checker alone
> won't nag you to annotate leaf code.

## Non-goals

- **No skill rename.** `gortex-align` is already tool-agnostic; only the trigger
  wording drops "pyright."
- **Wiring steps 1–3 untouched** (binary detect, `.mcp.json`, tracking) — they
  are language- and tool-independent and already correct.
- **No standalone config files.** All templates become copy-paste
  `pyproject.toml` blocks (modern uv repos centralize there).
- Not a general linting/formatting crusade — ruff is set up only as the
  annotation-presence complement.

## Design

### Decisions (locked)

| Fork | Decision |
|------|----------|
| Default checker for a repo with none | **ty**, with the pre-1.0 caveat documented; pyright (mature) / mypy (Django-plugin edge) as fallbacks. |
| Linter role | **Full ruff setup when absent** (lint + format + `ANN`); if a linter exists, just ensure annotation rules are on. Always-on complement, never a substitute for the checker. |
| Bundled config | **pyproject snippets, all-in-one** in the reference doc. No loose `*.json`/`*.toml` files. |
| basedpyright keys | **Dropped** from the pyright block; noted as "re-add under basedpyright." |

### File changes

- `SKILL.md` — rework step 4 (below); broaden the frontmatter `description`
  trigger off "pyright" to "type checker / ty / ruff / annotations."
- `pyright-reference.md` → **rename** `type-governance-reference.md` — becomes the
  all-in-one pyproject reference (content below).
- `pyrightconfig.json` — **delete**; folded into the reference as a
  `[tool.pyright]` block (minus the basedpyright keys).

### New `SKILL.md` step 4 — "Align the type view (Python)", detection-driven

1. **Detect** existing tooling by scanning `pyproject.toml` / config files for
   `[tool.ty]`·`ty.toml`, `[tool.mypy]`·`mypy.ini`, `[tool.pyright]`·`pyrightconfig.json`,
   `[tool.ruff]`·`ruff.toml`; and confirm a **deps-installed env** (no env → any
   checker degrades to unresolved-import noise).
2. **Type checker (resolution half):**
   - A checker is **already configured** → *use it*, don't impose another.
   - **None** → set up **ty** by default (`uvx ty check`), noting it is pre-1.0
     (v0.0.x). Offer **pyright** (mature, best stubs) or **mypy** (loads the
     `django-stubs` mypy plugin → resolves more Django magic) as alternatives.
3. **Ruff (annotation-presence half), always-on complement:**
   - ruff present → ensure `ANN` is in `select`.
   - a different linter present → add its equivalent annotation rules.
   - none → offer the **full ruff** block (lint + format + `ANN` + isort).
4. **Act on diagnostics:** install stubs the checker flags; add missing
   parameter/return annotations; kill `unknown`/`Any` at boundaries. Each fix
   gives the native provider more to resolve against.
5. **Ratchet** strictness once clean (ty: promote key `[tool.ty.rules]` to
   `error`; pyright: `standard` → `strict`).

Keep the **honest-limits** section, now noting *tool choice matters there*: for
Django, mypy + `django-stubs` plugin resolves manager/queryset/dynamic-attr
magic that ty and pyright cannot. The framework-invoked false-positive tier
(`@receiver`/`.connect`, `@shared_task`, admin auto-registration, settings
string lists, template→`.html`) still holds regardless of checker — never act on
gortex "0 usages / dead code" for those.

### Bundled `type-governance-reference.md` — verified pyproject blocks

Config surface verified live against ty **0.0.57** and pyright on 2026-07-09.

**ty (default):**

```toml
[tool.ty.environment]
python-version = "3.13"   # match the project's compat floor (requires-python)
python = "./.venv"        # env where deps are installed
root = ["./src"]          # first-party source roots

[tool.ty.src]
include = ["src", "tests"]
exclude = ["**/__pycache__", "build", "dist"]
respect-ignore-files = true

[tool.ty.terminal]
error-on-warning = false  # true once clean, to gate CI

# [tool.ty.rules]  — kebab-case; promote to "error" as you pay gaps down, e.g.
# unresolved-import = "error"
# possibly-unresolved-reference = "warn"
```

Invoke: `uvx ty check` (or `ty check --python .venv`).

**ruff (always-on complement):**

```toml
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "ANN"]   # ANN = flake8-annotations
ignore = ["ANN401"]                          # allow explicit Any where needed

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["ANN"]   # don't force annotations on test leaf code

[tool.ruff.format]
```

Note: ruff already dropped `ANN101`/`ANN102` (self/cls) — no need to ignore them.

**pyright (mature fallback):** the current bundled config **minus** `reportAny`
/ `reportExplicitAny` (basedpyright-only — re-add those two only if you run
basedpyright). Everything else — `useLibraryCodeForTypes`, the `venv` pin,
`reportMissing*`/`reportUnknown*` gap diagnostics — carries over unchanged.

**mypy (Django edge):**

```toml
[tool.mypy]
python_version = "3.13"
plugins = ["mypy_django_plugin.main"]   # the reason to pick mypy for Django

[tool.django-stubs]
django_settings_module = "myproject.settings"
```

### skep migration (follow-up, validates the rework)

After the skill lands, migrate **skep** itself as the first real test:

- Replace `pyrightconfig.json` with `[tool.ty]` + `[tool.ruff]` blocks in
  `pyproject.toml`.
- `uvx ty check` clean on `src/` (already 0 pyright errors; the 3 `@override` +
  `formatting.py` list annotation already landed this session).
- Confirm the 546 tests-tree pyright *errors* become a non-issue under ty's
  defaults + `per-file-ignores` for tests (they were `reportMissingParameterType`
  noise from the pyright config, not real resolution failures).
- Re-index gortex and spot-check resolution is at least as good.

This is a separate change from the skill rework, gated on it.

## Acceptance criteria

- `SKILL.md` step 4 is detection-driven; no step imposes pyright unconditionally.
- Reference doc renamed, holds ty/ruff/pyright/mypy pyproject blocks; the two
  basedpyright keys are gone from the pyright block.
- `pyrightconfig.json` deleted from the skill dir; no skill step references a
  standalone config file.
- ty config block matches the live 0.0.x surface (`[tool.ty.environment]` /
  `[tool.ty.src]` / `[tool.ty.rules]`, `uvx ty check`).
- Honest-limits section retained, with the mypy-for-Django note added.
- skep migrated and `uvx ty check` clean on `src/` (follow-up).

## Verification

- Grep the skill dir: no remaining `pyrightconfig.json` reference, no
  unconditional "use pyright" phrasing.
- Dry-run the ty and ruff blocks against skep (`uvx ty check`,
  `uvx ruff check`) — both parse and run.
