<!-- gortex:rules:start -->
## MANDATORY: Use Gortex MCP tools instead of Read/Grep/Glob

A Gortex daemon is configured machine-wide via the `gortex` MCP server. Whenever you are operating on indexed source code (any repo registered with the daemon — check `gortex daemon status`), you MUST prefer graph queries over file reads. PreToolUse hooks deny `Read` / `Grep` / `Glob` against indexed source — the deny message names the right tool.

### Optional: delegate research to a local agent

When `llm.provider` is configured (one of `local` / `anthropic` / `openai` / `azure` / `ollama` / `claudecli` / `codex` / `copilot` / `cursor` / `opencode` / `gemini` / `bedrock` / `deepseek` — pick one in `.gortex.yaml` or `~/.gortex/config.yaml`, or via `GORTEX_LLM_PROVIDER` / `GORTEX_LLM_MODEL`), the `ask` MCP tool is registered. It runs a grammar-constrained agent that uses gortex tools to research one question and returns a synthesized answer — useful when you'd otherwise issue many `search_symbols` / `get_callers` / `contracts` calls. Only the `local` provider requires a `-tags llama` build; the others are pure-Go HTTP / subprocess adapters available in every binary.

| When you'd otherwise...               | Consider...                              |
|---------------------------------------|------------------------------------------|
| Run many calls to answer one open-ended question | `ask` (one call, ~5-30s, ~200-400 token answer) |
| Trace a request across repos (consumer → contract → handler → downstream) | `ask` with `chain: true` |
| Look up a single known fact | Skip `ask` — direct tools are faster |

If `ask` isn't in `tools/list`, no provider could construct (missing model / API key, `local` without `-tags llama`, `claudecli` without `claude` on `$PATH`, `bedrock` without AWS credentials). Fall through to direct tools.

### Search and Navigation

| Instead of...                         | You MUST use...                          |
|---------------------------------------|------------------------------------------|
| `Grep` / `grep` / `rg` for a symbol      | `search_symbols` (BM25 + camelCase-aware)|
| `Grep` for references                 | `find_usages` (zero false positives)     |
| `Grep` to find callers                | `get_callers` / `get_call_chain`         |
| `Glob` over source files (`**/*.go`)  | `get_repo_outline` / `search_symbols`    |
| Multiple `Read` calls to explore      | `smart_context` (one call)               |

### Reading Source

| Instead of...                         | You MUST use...                          |
|---------------------------------------|------------------------------------------|
| `Read` whole file for one function    | `get_symbol_source` (80% fewer tokens; add `compress_bodies: true` when you only need the surface signature) |
| `Read` to understand a file           | `get_file_summary` / `get_editing_context` (the latter emits `source_compressed` when `compress_bodies: true`) |
| `Read` to check a signature           | `get_symbol` (signature in `meta.signature`) |
| `Read` to trace calls                 | `get_call_chain` / `get_callers`         |
| `Read` on a non-indexed / raw file    | `read_file` (atomic, honours editor-buffer overlays; `compress_bodies: true` elides function bodies for ~30-40% of original tokens) |

### Editing and Refactoring

| Instead of...                         | You MUST use...                          |
|---------------------------------------|------------------------------------------|
| `Edit` whole file by string match    | `edit_file` (Gortex MCP — no pre-Read required, atomic write, auto-reindex; pass `dry_run` to preview) |
| `Write` a new file or full rewrite   | `write_file` (no pre-Read required; creates parent dirs; pass `dry_run` to preview) |
| Read→Edit roundtrip for one symbol    | `edit_symbol` (edit by ID)               |
| Manual find-and-replace for renames   | `rename_symbol` (cross-file refs)        |
| Sequencing multi-file edits yourself  | `batch_edit` (dependency-ordered)        |

### Dataflow (CPG-lite)

The `flow_between` and `taint_paths` MCP tools answer **"where does this value flow?"** by walking the new dataflow edges (`value_flow` intra-procedural; `arg_of` caller-arg→callee-param; `returns_to` callee→assignment).

| Instead of...                         | You MUST use...                          |
|---------------------------------------|------------------------------------------|
| Tracing a value through helpers by hand | `flow_between(source_id, sink_id, max_depth=8)` — ranked dataflow paths between two symbols |
| Grepping for sources / sinks         | `taint_paths(source_pattern, sink_pattern)` — pattern-driven sweep. Patterns: bare token = name substring; `exact:Foo`; `path:dir/`; `kind:method`. Sinks auto-expand functions to their params. |
| Asking "can A reach B?" over the call graph | `trace_path(source_id, sink_id)` — shortest A→B call path (bidirectional BFS); on no-path returns a why-unreachable diagnosis naming the dynamic-dispatch / external boundary where the chain breaks. CLI: `gortex trace <from> <to>`. |

### Structural Code Search

`search_ast` answers "find every code site whose AST matches this shape" — the missing primitive between `search_symbols` (name-based) and `find_usages` (target-required). Cross-language; every match enriched with the enclosing function's `symbol_id`.

| Instead of...                            | You MUST use...                          |
|------------------------------------------|------------------------------------------|
| Grep for an anti-pattern across the repo | `search_ast` with a bundled `detector` (`error-not-wrapped`, `sql-string-concat`, `weak-crypto`, `panic-in-library`, `goroutine-without-recover`, `http-client-no-timeout`, `hardcoded-secret`, `empty-catch`, `java-string-equality`, `python-mutable-default-arg`). |
| Grep for a code shape (e.g. `.Get(_, nil)`) | `search_ast` with `pattern: "..."` (raw tree-sitter S-expression) + `language`. Capture nodes with `@name`, anchor with `@match`, predicates `(#eq? @x "…")` / `(#match? @x "…")`. |
| Scoping the audit to load-bearing code   | Pass `min_fan_in_of_enclosing_func: <N>` — drops matches in functions with fewer than N callers. |

### Clone Detection

`find_clones` surfaces near-duplicate function/method clusters from the `similar_to` graph layer — a MinHash + LSH pass over normalised tokens that catches copy-paste and renamed-variable (Type-1/Type-2) clones.

| Instead of...                            | You MUST use...                          |
|------------------------------------------|------------------------------------------|
| Eyeballing the repo for copy-paste       | `find_clones` — near-duplicate clusters; filter with `min_similarity` / `path_prefix` / `repo`. |
| Hunting safe-to-delete duplicates        | `find_clones` with `dead_only: true` — clusters containing a dead symbol: "dead duplicates of live code". |

### Code Quality and Analysis

The `analyze` MCP tool is a unified dispatcher. Pass `kind: "<name>"` for one of:

- Structural: `dead_code`, `hotspots`, `cycles`, `would_create_cycle`
- Comments / churn: `todos`, `stale_code`, `ownership`
- Coverage / releases: `coverage`, `coverage_gaps`, `coverage_summary`, `releases`, `blame`
- Schema: `orphan_tables`, `unreferenced_tables`
- Flags / interop: `stale_flags`, `cgo_users`, `wasm_users`
- Edge-driven: `channel_ops`, `goroutine_spawns`, `field_writers`, `annotation_users`, `config_readers`, `event_emitters`, `error_surface`, `external_calls`
- Framework layer: `routes` (handler ↔ HTTP/gRPC/WS/GraphQL/topic), `models` (ORM class ↔ DB table), `components` (parent → child JSX)
- Infrastructure: `k8s_resources` (KindResource fan-out by kind/namespace), `images` (KindImage with consumer count), `kustomize` (KindKustomization overlay tree)
- Data transformation: `dbt_models` (dbt / SQLMesh models, seeds, snapshots, sources with column counts + lineage fan-in/out)
- Multi-repo: `cross_repo` (repo-boundary-crossing calls / implements / extends grouped by source → target repo)

The `gortex enrich blame|coverage|releases|all` CLI hydrates the graph with the metadata that the `stale_*`, `coverage*`, `ownership`, and `releases` analyzers need.

### PR / Change Review

Review a diff through the graph instead of hand-walking each gate. `analyze` with `kind: "review"` runs the idiomatic / correctness rulepack (NPE, thread-safety check-then-act, N+1, logic-error; Go + Python) with a graph-grounded false-positive-reduction pass. The `review` / `review_pack` MCP tools (or `gortex review [--diff|--base <ref>] [--audience agent|human]`) return one fused packet — verdict + `file:line` findings + cost. For a queue of open PRs, `list_prs` / `triage_prs` / `pr_risk` / `get_pr_impact` / `suggest_reviewers` (or `gortex prs --triage`) rank by graph-derived blast radius and route reviewers.

### Token Economy

For list-shaped responses (`search_symbols`, `find_usages`, `analyze`, `batch_symbols`, `get_callers`, `get_call_chain`, `get_dependencies`, `get_dependents`, `find_implementations`, `get_file_summary`, `get_editing_context`, `smart_context`, `contracts`), pick a wire format. Order of preference: **gcx > toon > json**.

- `format: "gcx"` — GCX1 compact wire format. Round-trippable, ~27% fewer tokens. Decode with `@gortex/wire` (npm) or `github.com/gortexhq/gcx-go` (Go). **Default for known clients (claude-code, cursor, vscode, zed, aider, kilocode, opencode, openclaw, codex, omp-coding-agent)** when the request omits `format`.
- `format: "toon"` — TOON tabular text. Lossy but compact; useful for clients without a GCX decoder.
- `format: "json"` — verbose legacy default. Falls back automatically for unknown clients.

Explicit `format` arg always overrides the session default in either direction.

### Token Economy (content compression)

`compress_bodies: true` is an orthogonal axis: GCX1 shrinks the response *shape*; `compress_bodies` shrinks the response *content*. **Compose them** for stacked savings.

The flag replaces every function/method body in the returned source with a `{ /* N lines elided */ }` stub (Python: `...  # N lines elided`, Ruby: `# N lines elided`, Elixir: `do\n  # N lines elided\nend`). Signatures, doc-comments, imports, top-level constants/types, and structure stay intact. A 200-line file lands at ≤ 60 lines (~30-40% of original tokens). Wired in 16 languages: go, typescript, tsx, javascript, python, rust, java, c, cpp, csharp, kotlin, scala, php, ruby, bash, elixir.

| Instead of...                                          | You MUST use...                          |
|--------------------------------------------------------|------------------------------------------|
| Reading a whole 2k-line file to learn the surface      | `read_file` with `compress_bodies: true` |
| Pulling a class's full source to see its method shapes | `get_symbol_source` with `compress_bodies: true` |
| Calling `get_editing_context` then fetching every neighbour's source for signatures | `get_editing_context` with `compress_bodies: true` — emits `source_compressed` alongside the structural sections |

When the language has no grammar binding or tree-sitter can't parse the input, the flag is a no-op — raw source comes back and the response's `bodies_elided` flag stays absent. Safe to set unconditionally.

### Pagination, sparse fieldsets, and graceful degradation

Every list-shaped tool runs through a per-response budget by default — the agent harness's spill-to-disk fallback is a true edge case, not the routine outcome on real-world payloads. When a response would exceed the budget, the server runs a priority-aware cascade:

1. **Strip verbose meta** (`doc`, raw `meta` blobs) — cheapest cut, never drops rows.
2. **Drop tier-3 rows** — params, closures, generic params, `param_of` / `typed_as` / `value_flow` edges, low-confidence (`text_matched`) edges. High-noise rows agents almost never need on the first response.
3. **Drop tier-2 rows** — fields, constants, variables, references, instantiates, etc.
4. **Last-resort tail-trim** of the longest remaining tier-1 list.

Each escape adds metadata: `_meta_stripped`, `_dropped_tier_<N>_<list>`, `_truncated_by_budget`, `_max_returned_<list>`, `_original_count_<list>`. Use them to decide whether to narrow the filter, raise `max_bytes`, or paginate.

Knobs you can pull when you need something different:

- **Pagination** — `search_symbols`, `winnow_symbols`, `prefetch_context`, and `contracts` (action=list) accept `cursor` (opaque token from a previous `next_cursor`). Don't parse the cursor; round-trip what the server gave you.
- **Explicit budget** — pass `max_bytes: <N>` to override the project default. Pass `max_bytes: 0` to opt OUT of budgeting entirely — full result inline, transport spills if oversized. Use the opt-out only when you genuinely need every row (security audits, exhaustive enumeration).
- **Sparse fieldsets** — pass `fields: "id,line"` (comma-separated) to drop columns at the row level. Pure size win, no priority drops.
- **Limit defaults** — most tools default to 20–50 rows; raise `limit` only when a single page is too small. Pagination is preferred over a giant `limit`.

### MCP Resources

Bootstrap-state tools (`graph_stats` / `index_health` / `workspace_info` / `list_repos` / `get_active_project`) are also exposed as MCP resources at `gortex://stats` / `gortex://index-health` / `gortex://workspace` / `gortex://repos` / `gortex://active-project`. Subscribe via `resources/subscribe` to receive `notifications/resources/updated` after each graph re-warm — no polling. Tools stay registered for clients that don't speak resources.

Analyzer rollups (read-only summaries of the current indexed state): `gortex://report` (orientation), `gortex://god-nodes` (top hotspots), `gortex://surprises` (cycles + dead code + hubs), `gortex://audit` (CLAUDE.md drift), `gortex://questions` (TODOs).

### Session Memory (save_note / query_notes / distill_session)

Gortex remembers code; this triplet remembers **why you made a call**. Notes persist per-repo across daemon restarts and context compactions, scoped to the session's workspace, auto-linked to symbols mentioned in the body.

| Trigger                                                  | You MUST call                                                                 |
|----------------------------------------------------------|-------------------------------------------------------------------------------|
| Session start in a touched repo (after a compaction or on a fresh run) | `distill_session` — top symbols, pinned notes, decisions, recent excerpts. Seed your mental model before reading any file. |
| Making a decision, rejecting an alternative, hitting a non-obvious constraint, committing to an invariant | `save_note tags:"decision" body:"<what+why>"` — mention symbol IDs in the body for auto-linking; pin (`pinned:true`) anything load-bearing. |
| Before editing a symbol you've touched before            | `query_notes symbol_id:"<id>"` — prior decisions and warnings ride on each symbol. |

**Save:** decisions, non-obvious constraints, follow-ups, bug reproductions, surprising graph findings, partial-progress hand-offs. **Skip:** play-by-play (the diff says it), patterns derivable from the graph, anything already in CLAUDE.md. Canonical tags: `decision`, `bug`, `follow-up`, `gotcha`, `invariant` — `decision` gets its own section in `distill_session`.

### Development Memories (store_memory / query_memories / surface_memories)

`save_note` is a **per-session scratchpad**; `store_memory` is the **workspace-wide durable knowledge base**. Memories outlive sessions, agents, and teammates — every future agent in the workspace inherits them.

| Trigger                                                  | You MUST call                                                                 |
|----------------------------------------------------------|-------------------------------------------------------------------------------|
| Immediately after `smart_context` (every new task)            | `surface_memories task:"<task>" symbol_ids:"<top hits>"` — ranked memories anchored to your working set. Each hit carries `match_reasons` so you know *why* it surfaced. |
| You discover a durable invariant / gotcha / decision worth teaching the team | `store_memory kind:"<invariant|gotcha|convention|decision|constraint|incident>" body:"<what+why>" symbol_ids:"<id>" importance:5` — pin load-bearing memories. |
| You discover a memory is no longer true                  | `store_memory body:"<corrected>" supersedes:"<old-id>"` — preserves audit trail; the old memory is hidden from `surface_memories` by default. |

**Store:** invariants (violating them breaks the system), conventions (this package never X), incident learnings, API contracts not enforced by types, debugging traps, cross-cutting decisions. **Skip:** anything derivable from code, session-local play-by-play (use `save_note` instead), CLAUDE.md content. Canonical kinds: `invariant`, `constraint`, `convention`, `gotcha`, `decision`, `incident`, `reference`.

### Session Start

The SessionStart hook injects daemon status (tracked repos, cwd coverage, ready/warmup state). If you see "daemon is not running" — run `gortex daemon start --detach` and re-run the task. If you see "cwd is not covered by any tracked repo" — graph tools won't be available for that directory.

Once the daemon is up, **call** `distill_session` next — surfaces decisions / pinned notes / recent excerpts saved in prior sessions in this workspace so a context compaction or a fresh process doesn't erase what was already learned.

<!-- gortex:rules:end -->

# Persistent memory (synced & version-controlled)

The two files imported below are git-tracked in this repo (`claude/`) and
symlinked into `~/.claude`, so anything recorded in them survives sessions and
syncs across machines on commit + pull. They are loaded into EVERY session — be
concise, and never put secrets in them.

## Recording a memory — pick the scope

When you learn a durable fact (who the user is, a confirmed preference or piece
of feedback, long-running project context, a learned constraint), APPEND it to
the scoped file below instead of the default per-project memory dir:

- **Global** — true on every machine and project → `~/.claude/memory/global.md`
- **Per-host** — specific to THIS machine (installed tooling, local paths,
  hardware quirks) → `~/.claude/host-memory.md`
- **Per-project** — specific to one repo → that repo's own `CLAUDE.md`, or
  `<repo>/.claude/memory/project.md` to keep it out of the repo's root
  `CLAUDE.md`. The `project-memory-check.sh` SessionStart hook auto-loads
  `project.md` in every repo (merged with global + per-host memory) and offers
  to start tracking it where it doesn't exist yet — so it's git-tracked and
  synced like the other scopes, with no per-repo `@import` wiring. For repos you
  can't commit into, `CLAUDE.local.md` (add to its .gitignore).

One bullet per fact under a topical `##` heading. Keep it curated — edit or
delete stale entries rather than letting them pile up.

### Wiring — no per-project action needed

- **Global + per-host** load in EVERY project automatically: `modules/home/claude.nix`
  symlinks `CLAUDE.md`, `memory/global.md`, and `hosts/<hostname>.md` (as
  `host-memory.md`) into `~/.claude` via `mkOutOfStoreSymlink`. Nothing to set up
  per repo — commit here, pull on the other machine to propagate.
- **Per-project** memory lives *inside the target repo* (its `CLAUDE.md` /
  `.claude/memory/project.md` / `CLAUDE.local.md`) and Claude auto-discovers it
  from the working directory. It is NOT wired through this flake — each repo
  carries its own.
- **Not synced:** the harness auto-memory at `~/.claude/projects/<slug>/memory/`
  is path-keyed and machine-local — deliberately not symlinked here. Leave it
  local; don't expect it to follow you across machines.

@memory/global.md
@memory/practices.md
@host-memory.md
