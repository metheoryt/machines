# Global memory

<!--
Claude-written persistent memory, loaded into every session on every machine
(injected by the global-memory-load.sh hook). Append durable, CROSS-PROJECT facts here: who the
user is, preferences that hold everywhere, confirmed feedback, long-running
context. One bullet per fact under a topical heading. Keep it curated — edit or
remove stale entries. Tracked in git: committed from this repo and pulled
elsewhere to sync. Do NOT put secrets here.
-->

## User

## Preferences & feedback

- **Git-sync protocol — keep work synced across machines, agents do it
  themselves.** Applies to every branch in every repo:
  - **Before acting on code:** a background timer fetches every repo every ~10
    min (NixOS: `services.gitAutoFetch`; Windows: the `git-autofetch` Scheduled
    Task), so `git status` / the prompt already show "behind by N" without you
    fetching. Check that, and if behind, pull+rebase before working (`git pull
    --rebase`). Start from an up-to-date base — never commit on a stale branch.
    The timer is fetch-only (refs); it never pulls, so the actual pull is yours.
  - **After making changes:** commit and push the work yourself, without waiting
    to be told. Don't leave work uncommitted between turns.
  - **Cooldown ~10 min:** throttle these sync operations — don't pull or
    commit+push more than about once every 10 minutes. Batch changes within a
    cooldown window into a single commit rather than thrashing git on every
    micro-edit. If &lt;10 min since the last sync and nothing is mid-break, keep
    working and let the next window catch it up.
  - Scope commits to coherent units; don't sweep unrelated in-progress work into
    one commit. If the tree mixes concerns, surface it rather than lumping.

- **Never destroy the last copy of a secret.** Don't delete a backup/stash of a
  credential on the reasoning that it's "reconstructable" from other files —
  those other files can change or vanish too. Keep at least one intact copy
  until the secret is verified in its new home. (Learned the hard way: deleted
  a `settings.json.backup` holding a Sentry token, then the sibling
  `settings.local.json` copy also disappeared → token lost, user had to
  regenerate.)

- **Verify Claude Code's file-reading before designing around it.** Empirically
  confirmed for a user config dir (`CLAUDE_CONFIG_DIR`): only `settings.json` is
  read at the config-dir ROOT — a config-root `settings.local.json` **and** a
  config-root `.env` are NOT read. Reliable ways to get env into a session (and
  its Bash-tool subprocesses): (a) a var in the launching process env, or
  (b) a PROJECT-scope `<repo>/.claude/settings.local.json` `env` (this is the
  one place `settings.local.json` is honored). Test with a throwaway
  `CLAUDE_CONFIG_DIR` + `printenv` probe rather than assuming.

## Context

## Communication — professional tone (outward-facing)

- **Applies to everything a human other than me reads** — PR titles/bodies,
  commit messages, Jira/Confluence comments, Slack, email, review comments.
  NOT in-session chat replies to me. This generalizes the pure-dev
  review-voice card + the PR "why, not what" rule into one tone for all such
  output; the plugin's `review-voice.md` stays the detailed, review-specific
  version.
- **Lean.** As few sentences as carry the point; cut preamble, restatement,
  and ceremony. Say *why*, not *what* — the diff / thread / artifact already
  shows the what.
- **No hype, no padding.** Don't inflate praise; no marketing gloss,
  superlatives, or filler adjectives. Plain over clever; obvious beats terse.
- **Honest and humble.** When I might be missing context, say so — it invites
  correction. Don't overstate confidence or paper over unknowns.
- **Opinion, not orders — but direct when it's clear.** For judgment calls,
  convey a view and let the reader decide. When something is plainly right or
  broken, say it directly. Directness tracks stakes: soft/optional on
  low-stakes, unambiguous on important. Courteous throughout.

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
