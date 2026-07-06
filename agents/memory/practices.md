# Code practices

<!--
Always-loaded coding guidelines: brief universal principles + personal
(debatable) opinions + a gortex-tuned layer. Injected every session by the
global-memory-load.sh hook, synced across machines. Keep it concise and curated — edit/cut freely; the
Deltas are opinions, not laws. Don't restate what global.md / CLAUDE.md cover.
-->

## Principles (universal anchors)

- YAGNI — build what's needed now; delete speculative abstraction.
- Small, single-purpose units; a file that's growing is doing too much.
- Keep modules small and packages encapsulated (clear public surface, internals
  hidden); keep the file tree clean and legible.
- Match surrounding code (naming, comment density, idiom) over personal taste.
- Clarity over cleverness; obvious beats terse.

## Deltas (personal, debatable — curate freely)

- Prefer exceptions over sentinel returns — raise/propagate; don't return `None`
  to signal an error or absence. No silent `except: pass`.
- Think in concepts — model the domain in named concepts at the right altitude;
  design around ideas, not just mechanics.
- Prefer OOP over functional style — encapsulate behaviour with its data. Still
  avoid hidden global/mutable state.
- Declarative over imperative — express *what*, not step-by-step *how*, where the
  language allows.
- No premature *code* abstraction — don't extract incidental duplication until it
  repeats (~rule of three). Distinct from concept modeling above.
- Comments explain *why*, not *what*.

## OOP — keep in mind

- Composition over inheritance — inheritance only on a true *is-a*; default to
  composition/delegation. Keep hierarchies shallow (deep ones are fragile).
- Tell, don't ask — behaviour lives on the object that owns the data; avoid
  anemic classes (getters/setters with the logic elsewhere).
- Depend on abstractions — program to interfaces/protocols, inject dependencies;
  don't hard-wire concrete classes.
- Watch for god objects — a class that keeps accreting responsibilities is the
  top smell; split it. (gortex: `analyze hotspots` / high fan-in flags these;
  `get_class_hierarchy` shows deep trees.)
- Law of Demeter — talk to immediate collaborators, don't chain through
  internals (`a.b.c.do()`).

## Gortex-tuned

- **Code shape for the graph** — small explicit symbols, explicit calls over
  dynamic magic, type annotations. These resolve as solid edges; dynamic magic
  degrades to `text_matched`. (Aligns the repo to its static analyzer.)
- **Edit safety** — check blast radius before changing a signature; prefer a
  coordinated rename over manual find-replace. See `CLAUDE.md` tool-routing.
- **Trust by tier** — never act on gortex's "0 usages / dead code" for
  framework-invoked code; verify by confidence tier. Details in `global.md`.
- **Check freshness before trusting a query** — the graph lags the working
  tree. The daemon re-indexes on HEAD change (branch switch / commit / rebase)
  and after edits, with a warmup window where results are partial and the MCP
  connection can flap. Before relying on a query, confirm the index is current:
  `gortex repos` (FRESHNESS `fresh` + INDEXED == current HEAD) or `graph_stats` /
  `gortex daemon status` (state `ready`, not `warming up`). If `stale`/warming,
  wait for re-warm or fall back to `rg`/`ast-grep` rather than acting on a stale
  graph. Uncommitted working-tree edits and worktrees aren't in the base index —
  use `detect_changes` / an overlay for those.
