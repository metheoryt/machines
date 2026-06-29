# Global memory

<!--
Claude-written persistent memory, loaded into every session on every machine
(imported by claude/CLAUDE.md). Append durable, CROSS-PROJECT facts here: who the
user is, preferences that hold everywhere, confirmed feedback, long-running
context. One bullet per fact under a topical heading. Keep it curated — edit or
remove stale entries. Tracked in git: committed from this repo and pulled
elsewhere to sync. Do NOT put secrets here.
-->

## User

## Preferences & feedback

- Before doing any work on a local branch, pull and rebase it onto its remote
  first (`git pull --rebase`, or `git fetch && git rebase origin/<branch>`).
  Applies to every branch in every repo — start from an up-to-date base, never
  commit on top of a stale branch.

## Context

## Gortex

- Gortex's Python resolution is near-compiler-grade for the STATIC OO layer
  (classes, methods, inheritance/MRO, imports, explicit calls, direct ORM calls
  like `Model.objects.filter`). It degrades on framework "magic" — true for
  Django/DRF especially — so trust it BY TIER, not blindly:
  - **Trust:** views/models/serializers/forms/admin classes & their methods, CBV
    mixin MRO, statically-typed manager calls.
  - **Verify (best-effort framework analyzers):** URLconf routing, DRF
    `router.register`, model↔table — check coverage with
    `analyze routes|route_frameworks|models` and spot-check against the source.
  - **Often missed or only `text_matched`:** signals (`@receiver`/`.connect`),
    reverse-FK accessors (`x.y_set`), settings string lists (MIDDLEWARE/
    INSTALLED_APPS), template-name→`.html`, `get_user_model()`/`apps.get_model()`,
    dynamic queryset methods, Celery `@shared_task`, admin auto-registration.
  - Every edge carries a confidence tier (`lsp_resolved` … `text_matched`), so
    speculative links are labelled — that's gortex's edge over grep here.
- Its **"dead code / 0 usages / safe to remove" signal is a false positive on
  framework-invoked code** (signal handlers, middleware `__call__`, dunders).
  Never act on it for decorated/framework-called code without a text-search
  cross-check.
- `graph_stats`' `semantic` block under-reports (the native `python-types` line
  can show ~0 edges); the real resolver is the `lsp-pyright` provider — judge
  coverage from `find_usages` output, not that block.
- **Build caveat (verified vasya, gortex v0.56.0, 2026-06-30):** that "real
  resolver is lsp-pyright" claim is BUILD-DEPENDENT and was false for this
  daemon. v0.56.0 ships only NATIVE semantic providers (`python-types`, etc.) —
  no `lsp-*` in `graph_stats.semantic.providers`, and the daemon log shows no
  pyright langserver spawn. Here `python-types` WAS the resolver and reported
  100% coverage (1535/1535 symbols, edges as `ast_resolved`), not ~0. So:
  installing pyright + a `pyrightconfig.json` does NOT add a gortex resolution
  tier on this build — it buys a standalone type-checker whose demanded
  annotations still help the native type-aware provider, plus gap-diagnostics.
  Before assuming lsp-pyright is live, check `semantic.providers` for an `lsp-*`
  entry and grep the daemon log for a langserver spawn.
- Integration is reproducible ONLY if `.gortex.yaml` + a gortex server entry in
  `.mcp.json` are committed. A local daemon merely *tracking* a repo works for you
  but carries nothing to teammates/CI — run `gortex init` to commit the wiring.
- **General principle — align a repo to its static analyzer.** Gortex's
  resolution quality is bounded by what the language's underlying analyzer can
  resolve (Python → `lsp-pyright`). The highest-leverage way to make a
  gortex-backed repo align better is therefore to tighten that analyzer's view:
  type hints, installed/typed deps, framework stubs. When working in a
  gortex-backed repo, treat weak resolution as fixable — proactively offer the
  alignment wins that fit its stack rather than accepting `text_matched` edges.
- **`/gortex-align` skill does the alignment.** When a gortex-backed repo could
  be tuned — wiring not committed, or a Python project resolving to
  `text_matched` — offer the `gortex-align` skill. It detects the daemon (won't
  install the binary — that's machine provisioning), commits the
  `.gortex.yaml`/`.mcp.json` wiring, verifies index health, and for Python sets
  up pyright governance from a bundled resolution-focused `pyrightconfig.json`
  (resolution knobs like `useLibraryCodeForTypes`/venv vs gap diagnostics that
  surface every `text_matched`-bound spot; adopt at `standard`, ratchet to
  `strict`). Pyright won't load the django-stubs mypy plugin, so the "often
  missed" tier above still stands.
