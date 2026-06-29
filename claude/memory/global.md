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

## Tooling — Gortex (code-intelligence MCP/daemon)

- Currently **local-only**: the `gortex` MCP entry (`.mcp.json`), index dir
  (`.gortex/`), and any config are gitignored and there's no `.gortex.yaml`, so
  the integration is per-developer — teammates and CI don't get it. Not yet
  shared/committed anywhere.
- **Trust it for static facts; verify anything dynamic.** Symbol search, typed
  `find_usages`/`get_callers`, impact analysis, and `analyze annotation_users`
  (decorator/task census) are reliable — on Python they're driven by the
  LSP-pyright provider (+ django-stubs when installed), at confidence 1.
- **Do NOT trust it on dynamic wiring.** Signals (`@receiver`), reverse-FK
  accessors (`obj.x_set`), template strings (`render(req,"x.html")`), URL routes
  (`analyze routes`), and model↔table maps (`analyze models`) produce no edges or
  confident garbage. Fall back to `search_text`/grep for these.
- **Its "dead code / 0 usages / safe to remove" signal is a false positive on
  framework-invoked code** (signal handlers, middleware `__call__`, dunders).
  Never act on it for decorated/framework-called code without a text-search
  cross-check.
- `graph_stats`' `semantic` block under-reports (the native `python-types` line
  can show ~0 edges); the real resolver is the `lsp-pyright` provider. Judge
  coverage from `find_usages` output, not that block.
