# Pyright config rationale (for the `gortex-align` skill)

Gortex's Python resolver is the **native, type-aware `python-types`** provider —
this build ships no `lsp-pyright`, so pyright is *not* in gortex's resolution
path. Pyright earns its place anyway: it's a standalone type checker whose
demanded annotations and stubs feed the type-aware native provider, and its
diagnostics surface every spot that would otherwise resolve weakly. The fastest
way to make a Python repo gortex-friendly is still to make it resolve cleanly
under a strict-ish pyright.

`pyrightconfig.json` next to this file is the drop-in. The skill's step 4 copies
it into the target repo; this doc explains *why* each part is there.

## How to read the config

- **(A) Resolution knobs** — settings that *actually change what pyright can
  resolve* — and therefore the type information it can feed the native provider:
  - `useLibraryCodeForTypes: true` — infer types from a dependency's source when
    it ships no stubs. The most common single cause of un-stubbed libraries
    resolving to `Any`.
  - `venv` / `venvPath` (or `pythonPath`) pointing at an env with deps
    **installed** — pyright can't resolve imports it can't see.
  - `pythonVersion` — match the interpreter the project runs.
- **(B) Gap diagnostics** — these don't change resolution; they *surface* every
  spot with thin type info (missing annotations, inferred `Any`, unresolved
  imports, missing stubs) — the same spots the native provider can't key off
  either. Fixing each one — annotate, or install the stub — improves what the
  provider resolves.

## `[tool.pyright]` (pyproject.toml) variant

```toml
[tool.pyright]
pythonVersion = "3.13"
venvPath = "."
venv = ".venv"
include = ["src", "app"]
exclude = ["**/__pycache__", "**/node_modules", ".venv", "build", "dist", "**/migrations"]
useLibraryCodeForTypes = true
typeCheckingMode = "standard"

reportMissingImports = "error"
reportMissingModuleSource = "warning"
reportMissingTypeStubs = "warning"
reportAttributeAccessIssue = "error"
reportMissingParameterType = "error"
reportUntypedBaseClass = "error"
reportUntypedNamedTuple = "error"
reportUntypedFunctionDecorator = "warning"
reportUntypedClassDecorator = "warning"
reportUnknownParameterType = "warning"
reportUnknownArgumentType = "warning"
reportUnknownVariableType = "warning"
reportUnknownMemberType = "warning"
reportUnknownLambdaType = "warning"
reportAny = "warning"
reportExplicitAny = "warning"
reportPrivateImportUsage = "warning"
reportWildcardImportFromLibrary = "warning"
reportImplicitOverride = "warning"
```

## Adoption path

1. Drop the config in, fix `include` / `venv`, install deps into the venv.
2. Install framework stubs the project needs: `django-stubs`,
   `djangorestframework-stubs`, `celery-types`, `types-requests`, etc.
   `reportMissingTypeStubs` warnings tell you which.
3. Work the `reportMissing*Type` / `reportUnknown*` warnings down — each fix
   gives the native type-aware provider more to resolve against.
4. Once clean, ratchet `typeCheckingMode` to `"strict"`.

## Honest limits (what pyright still won't resolve)

Pyright is a static type checker, not the framework. It does **not** load the
`django-stubs` *mypy plugin*, so plugin-driven Django magic — manager/queryset
return types, dynamic model attributes — stays partly unresolved even with the
stubs installed. So this config tightens the static-OO core and the
third-party-call surface, but the "often missed" tier from the global Gortex
memory note still applies:

- signals (`@receiver` / `.connect`), Celery `@shared_task`, admin
  auto-registration, settings string lists (`MIDDLEWARE` / `INSTALLED_APPS`),
  template-name → `.html`, `get_user_model()` / `apps.get_model()`.

**Never act on gortex's "0 usages / dead code" signal for any of those** — it's
a false positive on framework-invoked code regardless of how clean pyright is.
