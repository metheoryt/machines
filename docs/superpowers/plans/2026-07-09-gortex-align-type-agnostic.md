# gortex-align Tool-Agnostic Rework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the `gortex-align` skill from pyright-specific to tool-agnostic type-information governance (ty default, ruff complement, pyright/mypy fallbacks), then migrate skep as the validating first use.

**Architecture:** Three edited artifacts in the skill dir (`SKILL.md` reworked step 4 + trigger; `pyright-reference.md` renamed + rewritten to all-in-one pyproject blocks; `pyrightconfig.json` deleted), then a separate follow-up commit migrating skep's own `pyproject.toml`. No code — Markdown/TOML edits verified by grep assertions and live `uvx ty check` / `uvx ruff check` dry-runs.

**Tech Stack:** Markdown (skill files), TOML (`pyproject.toml` config blocks), `ty` 0.0.x, `ruff`, `pyright` (all via `uvx`), git.

## Global Constraints

- Skill dir: `/home/me/machines/agents/plugin/skills/gortex-align/` (repo `machines`, branch `gortex-align-type-agnostic` already checked out).
- Skep repo: `/home/me/my/skep/` (separate git repo; Task 3 commits there, not in `machines`).
- **Skill name stays `gortex-align`** — only the frontmatter `description` trigger changes.
- **Do not touch** SKILL.md steps 1–3 (binary detect / `.mcp.json` / tracking) — tool-independent, correct as-is.
- ty config surface verified live against **ty 0.0.57** on 2026-07-09: `[tool.ty.environment]` (`python-version`, `python`, `root`), `[tool.ty.src]` (`include`, `exclude`, `respect-ignore-files`), `[tool.ty.terminal]`, `[tool.ty.rules]` (kebab-case names, `error`/`warn`/`ignore`). Invoke: `uvx ty check`. At v0.0.x re-verify before trusting.
- Drop `reportAny` / `reportExplicitAny` from any pyright block (basedpyright-only; standard pyright rejects them).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: Rewrite the reference doc as all-in-one pyproject blocks; delete `pyrightconfig.json`

**Files:**
- Create: `agents/plugin/skills/gortex-align/type-governance-reference.md`
- Delete: `agents/plugin/skills/gortex-align/pyright-reference.md`
- Delete: `agents/plugin/skills/gortex-align/pyrightconfig.json`

**Interfaces:**
- Produces: a reference doc named `type-governance-reference.md` containing four labelled `pyproject.toml` blocks (`[tool.ty]`, `[tool.ruff]`, `[tool.pyright]`, `[tool.mypy]`). Task 2's `SKILL.md` step 4 links to this filename.

- [ ] **Step 1: Write the new reference doc**

Write `agents/plugin/skills/gortex-align/type-governance-reference.md` with exactly this content:

````markdown
# Type-information governance (for the `gortex-align` skill)

Gortex's Python resolver is the native, type-aware `python-types` provider — this
build ships no `lsp-pyright`, so **no** external type checker sits in gortex's
resolution path. What the provider keys off is **type information present in the
source**: annotations + installed stubs. A type checker is only a *governance
mechanism* — it surfaces where that info is thin and pressures you to add it. Any
checker works; the source-side result is what matters.

Two halves, two tools:

- **Resolution** — does each name / member / import resolve to a known type? Only
  a **type checker** (ty / pyright / mypy) measures this.
- **Annotation presence** — do functions carry param/return annotations at all? A
  **linter** (ruff `ANN`) enforces this cheaply on the leaf code a checker won't
  nag about.

Ruff alone can't measure resolution; a checker alone won't push you to annotate
everything. Use both.

## Choosing the checker

- **Already configured** (`[tool.ty]`, `[tool.mypy]`, `[tool.pyright]`) → use it,
  don't impose another.
- **None, on a uv / Astral repo** → **ty** (default): one toolchain with uv + ruff,
  fastest. Caveat: pre-1.0 (v0.0.x) — config keys and rule names still churn, and
  the stub story is thinner than pyright's. Eyes open.
- **Want maturity / best stubs** → **pyright**.
- **Django** → **mypy** + `django-stubs`: it loads the *mypy plugin* that resolves
  manager/queryset return types and dynamic model attributes — which ty and
  pyright cannot. For Django the checker choice materially changes what resolves.

## Config blocks (drop into `pyproject.toml`)

### ty (default) — verified against ty 0.0.57

```toml
[tool.ty.environment]
python-version = "3.13"   # the project's compat floor (requires-python)
python = "./.venv"        # env where deps are installed
root = ["./src"]          # first-party source roots

[tool.ty.src]
include = ["src", "tests"]
exclude = ["**/__pycache__", "build", "dist"]
respect-ignore-files = true

[tool.ty.terminal]
error-on-warning = false  # flip to true once clean, to gate CI

# [tool.ty.rules]  — kebab-case; promote to "error" as you pay gaps down, e.g.
# unresolved-import = "error"
# possibly-unresolved-reference = "warn"
```

Invoke: `uvx ty check` (or `ty check --python .venv`). Rule names and the config
surface are pre-1.0 — re-check `uvx ty check --help` and the docs if a key errors.

### ruff (always-on annotation-presence complement)

```toml
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "ANN"]   # ANN = flake8-annotations
ignore = ["ANN401"]                          # allow explicit Any where deliberate

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["ANN"]   # tests are leaf code — don't force annotations there

[tool.ruff.format]
```

Run: `uvx ruff check` / `uvx ruff format`. (Ruff already removed `ANN101`/`ANN102`
for self/cls — no need to ignore them.)

### pyright (mature fallback)

```toml
[tool.pyright]
pythonVersion = "3.13"
venvPath = "."
venv = ".venv"
include = ["src", "tests"]
exclude = ["**/__pycache__", "**/node_modules", ".venv", "build", "dist"]
useLibraryCodeForTypes = true
typeCheckingMode = "standard"   # ratchet to "strict" once clean

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
reportPrivateImportUsage = "warning"
reportWildcardImportFromLibrary = "warning"
reportImplicitOverride = "warning"
```

`reportAny` / `reportExplicitAny` are **basedpyright-only** — standard pyright
prints `Config contains unrecognized setting`. Add them back only if you run
basedpyright.

### mypy (Django)

```toml
[tool.mypy]
python_version = "3.13"
plugins = ["mypy_django_plugin.main"]   # the reason to pick mypy for Django

[tool.django-stubs]
django_settings_module = "myproject.settings"   # set to your settings module
```

## Adoption path

1. Pick the checker; point it at an env with **deps installed** — it can't
   resolve imports it can't see.
2. Install the stubs it flags (`django-stubs`, `djangorestframework-stubs`,
   `celery-types`, `types-requests`, …).
3. Work the missing-annotation / unknown-type diagnostics down — each fix gives
   the native type-aware provider more to resolve against.
4. Ratchet strictness once clean (ty: rules → `error`; pyright: `standard` →
   `strict`).

## Honest limits (true under any checker)

A static checker is not the framework. Even fully clean, plugin-driven and
runtime-registered magic stays partly unresolved — mypy + the `django-stubs`
plugin resolves the most, ty/pyright less. The "often missed" tier still holds:

- signals (`@receiver` / `.connect`), Celery `@shared_task`, admin
  auto-registration, settings string lists (`MIDDLEWARE` / `INSTALLED_APPS`),
  template-name → `.html`, `get_user_model()` / `apps.get_model()`.

**Never act on gortex's "0 usages / dead code" signal for any of those** — it's a
false positive on framework-invoked code regardless of how clean the checker is.
````

- [ ] **Step 2: Delete the old reference doc and standalone config**

Run:
```bash
cd /home/me/machines
git rm agents/plugin/skills/gortex-align/pyright-reference.md \
       agents/plugin/skills/gortex-align/pyrightconfig.json
```
Expected: both files staged for deletion.

- [ ] **Step 3: Verify the ty and ruff blocks actually parse and run**

Extract the ty + ruff blocks into a scratch `pyproject.toml` in a temp dir with a
tiny `src/` and dry-run them (proves the config surface is valid, not stale):
```bash
cd "$(mktemp -d)" && mkdir -p src tests && printf 'x: int = 1\n' > src/m.py
cat > pyproject.toml <<'TOML'
[project]
name = "probe"
version = "0"
requires-python = ">=3.13"
[tool.ty.environment]
python-version = "3.13"
[tool.ty.src]
include = ["src", "tests"]
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "ANN"]
ignore = ["ANN401"]
[tool.ruff.lint.per-file-ignores]
"tests/**" = ["ANN"]
[tool.ruff.format]
TOML
uvx ty check 2>&1 | tail -3
uvx ruff check 2>&1 | tail -3
```
Expected: `ty` runs and reports on `src/m.py` (no config-parse error); `ruff check`
runs (no "unknown setting"/parse error). If ty errors on a key name, fix the block
per current `uvx ty check --help` before continuing.

- [ ] **Step 4: Commit**

```bash
cd /home/me/machines
git add agents/plugin/skills/gortex-align/type-governance-reference.md
git commit -m "$(cat <<'EOF'
docs(gortex-align): all-in-one type-governance reference; drop pyright-only files

Replace pyright-reference.md + pyrightconfig.json with a single
type-governance-reference.md carrying [tool.ty] (default), [tool.ruff],
[tool.pyright] (fallback, minus basedpyright-only reportAny keys), and
[tool.mypy] pyproject blocks. ty block verified against ty 0.0.57.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Rework `SKILL.md` — detection-driven step 4 + broadened trigger

**Files:**
- Modify: `agents/plugin/skills/gortex-align/SKILL.md` (frontmatter line 3; Overview bullet 2; step 4 heading + body; the `cp pyrightconfig.json` common-mistake bullet; the honest-limits/reference link)

**Interfaces:**
- Consumes: `type-governance-reference.md` from Task 1 (the step-4 link target).
- Produces: a SKILL.md whose step 4 imposes no single checker and references no standalone config file.

- [ ] **Step 1: Broaden the frontmatter trigger (line 3)**

Replace the exact string:
```
set up pyright governance on a Python project so its type annotations feed gortex's native type-aware Python resolver.
```
with:
```
set up type-information governance on a Python project (a type checker — ty / pyright / mypy — plus ruff annotation rules) so its type annotations feed gortex's native type-aware Python resolver.
```

- [ ] **Step 2: Rewrite Overview bullet 2**

Replace the exact string:
```
2. **Tune the type view** — make the code carry the type information the native
   provider keys off. For Python this is pyright governance: pyright is a
   standalone type checker, and the annotations/stubs it forces you to add feed
   gortex's type-aware provider (plus pyright surfaces every unresolved spot as a
   diagnostic). Bundled config below.
```
with:
```
2. **Tune the type view** — make the code carry the type information the native
   provider keys off. That means *type information in the source* (annotations +
   installed stubs), not any one tool: a **type checker** (ty / pyright / mypy)
   measures whether names resolve, and **ruff** enforces annotation presence on
   leaf code. Use whichever checker the repo already has; default to **ty** when
   it has none. Bundled config blocks below.
```

- [ ] **Step 3: Replace the entire step-4 section**

Replace the whole `### 4. Align the stack (Python → pyright governance)` section
(from that heading through the end of its numbered list, up to but not including
`### 5. Re-index and report`) with:
```markdown
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
```

- [ ] **Step 4: Fix the `cp pyrightconfig.json` common-mistake bullet**

Replace the exact string:
```
- **Pointing pyright at an env without deps installed** — resolution silently
  degrades to `text_matched`; the config can't help if imports don't resolve.
```
with:
```
- **Pointing the checker at an env without deps installed** — resolution silently
  degrades to `text_matched`; no config helps if imports don't resolve.
```

- [ ] **Step 5: Update the honest-limits section reference to pyright**

In the `## Honest limits` section, replace the exact string:
```
Pyright does **not** load the `django-stubs` *mypy plugin*, so plugin-driven
Django magic (manager/queryset return types, dynamic model attrs) stays partly
unresolved even with stubs installed.
```
with:
```
No static checker is the framework. ty and pyright do **not** load the
`django-stubs` *mypy plugin*, so plugin-driven Django magic (manager/queryset
return types, dynamic model attrs) stays partly unresolved even with stubs
installed — mypy + the plugin resolves the most.
```

- [ ] **Step 6: Verify no stale pyright-only references remain**

Run:
```bash
cd /home/me/machines/agents/plugin/skills/gortex-align
grep -rn "pyrightconfig.json\|pyright-reference.md\|gortex-align/pyrightconfig" SKILL.md; echo "exit=$?"
```
Expected: no matches, `exit=1`. (A match means a dangling reference to a deleted
file — fix it.)

- [ ] **Step 7: Verify the reference link resolves**

Run:
```bash
cd /home/me/machines/agents/plugin/skills/gortex-align
grep -q "type-governance-reference.md" SKILL.md && test -f type-governance-reference.md && echo OK
```
Expected: `OK`.

- [ ] **Step 8: Commit**

```bash
cd /home/me/machines
git add agents/plugin/skills/gortex-align/SKILL.md
git commit -m "$(cat <<'EOF'
feat(gortex-align): detection-driven type-view step; drop pyright imposition

Rework SKILL.md step 4 from "pyright governance" to a two-half,
detection-driven flow: use the repo's existing type checker or default to ty
(pre-1.0, eyes open) with pyright/mypy fallbacks, plus ruff ANN as the
always-on annotation-presence complement. Broaden the frontmatter trigger and
point the reference link at type-governance-reference.md.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Migrate skep to ty + ruff (validates the reworked skill)

**Files:**
- Modify: `/home/me/my/skep/pyproject.toml` (add `[tool.ty]` + `[tool.ruff]` blocks)
- Delete: `/home/me/my/skep/pyrightconfig.json`

**Interfaces:**
- Consumes: the ty + ruff blocks authored in Task 1.
- Produces: skep aligned via ty (its own repo commit, on a skep branch — NOT in `machines`).

- [ ] **Step 1: Branch skep off main**

```bash
cd /home/me/my/skep
git checkout -b align-ty-ruff
```
Expected: switched to new branch (skep repo is separate from `machines`).

- [ ] **Step 2: Add the ty + ruff blocks to skep's `pyproject.toml`**

Append to `/home/me/my/skep/pyproject.toml`:
```toml
[tool.ty.environment]
python-version = "3.13"
python = "./.venv"
root = ["./src"]

[tool.ty.src]
include = ["src", "tests"]
exclude = ["**/__pycache__", "build", "dist"]
respect-ignore-files = true

[tool.ty.terminal]
error-on-warning = false

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "ANN"]
ignore = ["ANN401"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["ANN"]

[tool.ruff.format]
```

- [ ] **Step 3: Delete the standalone pyright config**

```bash
cd /home/me/my/skep
git rm pyrightconfig.json
```
Expected: staged for deletion.

- [ ] **Step 4: Run ty on src and confirm clean**

```bash
cd /home/me/my/skep
uvx ty check src 2>&1 | tail -8
```
Expected: no errors on `src/` (the `@override` + `formatting.py` annotation fixes
from this session already landed). If ty reports a genuine `src/` resolution
error, fix it with an annotation before committing. If ty errors on a *config
key*, reconcile the block against `uvx ty check --help` and update
`type-governance-reference.md` + this plan.

- [ ] **Step 5: Run ruff and auto-fix imports/format**

```bash
cd /home/me/my/skep
uvx ruff check src 2>&1 | tail -8
uvx ruff format src 2>&1 | tail -3
```
Expected: ruff runs; address any `ANN` findings on `src/` (annotate) or accept
format changes. Re-run `uvx ruff check src` until clean.

- [ ] **Step 6: Confirm gortex still resolves skep after the config swap**

```bash
gortex daemon reload && sleep 2 && gortex daemon status 2>&1 | grep -A2 "tracked repos" | grep skep
```
Expected: skep still listed with a non-zero node/edge count (resolution not
regressed by dropping pyrightconfig.json — expected, since gortex never read it).

- [ ] **Step 7: Commit (in the skep repo)**

```bash
cd /home/me/my/skep
git add pyproject.toml
git commit -m "$(cat <<'EOF'
chore: align type view via ty + ruff (drop pyrightconfig.json)

Migrate off the standalone pyright config to Astral-native ty + ruff in
pyproject.toml, per the reworked gortex-align skill. ty check clean on src/.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Reframe (premise fix) → Task 1 reference doc + Task 2 Overview/step-4. ✓
- Rename `pyright-reference.md` → `type-governance-reference.md` → Task 1. ✓
- Delete `pyrightconfig.json` → Task 1 step 2. ✓
- Detection-driven step 4 → Task 2 step 3. ✓
- ty default + pyright/mypy fallbacks → Task 1 "Choosing the checker" + Task 2 step 3. ✓
- Full ruff when absent + ANN-on otherwise → Task 1 ruff block + Task 2 step 3. ✓
- Drop basedpyright keys → Task 1 pyright block (keys omitted; note added). ✓
- pyproject-blocks-only, no loose files → Task 1 (delete json, no new standalone files). ✓
- Broadened trigger → Task 2 step 1. ✓
- Honest-limits retained + mypy-Django note → Task 1 honest-limits + Task 2 step 5. ✓
- Acceptance: ty block matches live surface → Task 1 step 3 + Task 3 step 4 dry-runs. ✓
- skep migration (follow-up) → Task 3. ✓

**Placeholder scan:** No "TBD"/"handle appropriately". The mypy block's
`myproject.settings` is intentional illustrative template text in a reference doc.
Verification steps carry exact commands + expected output. ✓

**Type/name consistency:** `type-governance-reference.md` used identically in Task
1 (create), Task 2 (link + grep), and the self-review. ty tables
(`[tool.ty.environment]` / `[tool.ty.src]` / `[tool.ty.rules]`) identical in Task 1
and Task 3. ruff `select`/`per-file-ignores` identical in Task 1 and Task 3. ✓
