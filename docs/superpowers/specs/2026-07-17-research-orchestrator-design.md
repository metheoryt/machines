# Research orchestrator subagent — design

**Date:** 2026-07-17
**Status:** approved (brainstorming), pending implementation-plan
**Repo:** `machines` (branch `Launching-subagents-call-stack`)

## Goal

Build a fleet-synced **general research orchestrator** subagent as a learning
effort — a subagent that plans a research question, delegates the heavy work to
leaf worker subagents (in parallel or sequentially), and synthesizes a single
cited answer. It is the first agent in this repo that itself *delegates*,
deliberately exercising the delegation topology the fleet is moving toward:

- The main session orchestrates and delegates heavily.
- Custom subagents live in the git-synced profile and propagate across machines.
- Subagents may delegate too, but *less* than the main session, and **never past
  depth 2** ("no level 4").
- A session-wide cap limits parallel workers, so fan-out is planned in bounded
  batches.

Background reference on Claude Code subagent mechanics:
`agents/docs/claude-code-subagents.md`.

## Topology

```
main session              (depth 0 — orchestrates the whole task)
  └─ research-orchestrator (depth 1, Opus, "use proactively")
       ├─ gortex-search    (depth 2, leaf — code lane, reused)
       └─ web-research     (depth 2, leaf, Sonnet — external lane, new)
```

Main → orchestrator → worker is depth 2 — well inside Claude Code's 5-level cap.

`gortex-search` is **not owned by this repo** — it is provisioned machine-wide by
`gortex install` (which renders artifacts into every detected AI assistant, e.g.
`~/.claude/agents/` and `~/.openclaude/agents/`, and drift-fences them via
`gortex agents render`). The orchestrator delegates to it *by name* when present;
we neither ship nor relocate it, to avoid duplicating and drifting against
gortex-managed content.

### Invariants enforced structurally (not by prompt alone)

- **No level 4.** Leaf workers omit `tools:` (so they inherit the full session
  surface) but set `disallowedTools: Task` — the spawn tool is physically
  removed, so the delegation chain cannot extend past them. (Enforcing harness
  behavior structurally rather than by instruction follows the repo's standing
  "verify/enforce, don't hope" rule.)
- **Only the orchestrator delegates.** Leaves have no spawn tool; the main
  session and the orchestrator are the only delegating layers.
- **Bounded fan-out.** The orchestrator's prompt instructs it to spawn workers in
  batches (≤4 concurrent) and sequence the rest, so a broad question does not
  exceed the session-wide parallel-worker cap.

## Components

### research-orchestrator (new)

- **Model:** Opus (synthesis/planning is the hard part).
- **Invocation:** `use proactively` — the main session may auto-delegate
  open-ended research.
- **Tools:** `tools:` omitted → inherits the full session surface (gortex when
  present, web, file read) **plus** the Task/Agent spawn tool needed to delegate.
- **Behavior (prompt):**
  1. Restate the question and decompose it into independent vs. dependent
     sub-questions.
  2. Do only *quick* triage itself (a single fetch, a small read) — never heavy
     exploration.
  3. Delegate depth to leaf workers: code/architecture → `gortex-search`;
     external/prose → `web-research`. Fan out independent sub-questions in
     bounded batches (≤4 at once); sequence dependent ones.
  4. Synthesize worker summaries into one answer: conclusion first, then
     evidence (symbol IDs / file:line / source URLs), then caveats.
  5. Research and synthesize only — do not edit files or run mutating commands,
     even though the inherited surface technically allows it.

### web-research (new)

- **Model:** Sonnet (mechanical fetch + summarize).
- **Tools:** `tools:` omitted; `disallowedTools: Task` (leaf — cannot delegate).
  Effective surface: `WebSearch`, `WebFetch`, file read. Prompt keeps it
  read-only (no edits/commands).
- **Behavior (prompt):** search → fetch the most relevant sources → read →
  return a concise summary with source URLs. Generalized, capability-level
  guidance — no hardcoded tool-call sequences.

### gortex-search (external dependency — not shipped here)

The orchestrator's code lane. **Owned by gortex, not this repo:** `gortex
install` renders it machine-wide into every detected assistant, so it is present
on every fleet machine (where gortex is installed) without us shipping it. The
orchestrator delegates to it by name and degrades gracefully (own grep/read)
when it — or gortex — is absent (e.g. a directory the daemon doesn't cover).

Consequence: we do **not** relocate `gortex-search` / `gortex-impact` into this
repo. Copying them would duplicate gortex-generated files and fight its
`gortex agents render` drift fence.

## Prompt philosophy — generalize, don't hardcode

New agents describe *capabilities*, not specific tool names:

> "Locate and read code using the best tools your session offers. If a
> code-graph tool is available (e.g. gortex `smart_context` / `get_callers`),
> prefer it. Otherwise fall back to text search and file reads."

This keeps agents portable: they adapt to whatever a given machine or directory
exposes (a directory not covered by the gortex daemon has no graph tools — the
agent must still work there). "Use everything available in the session" is
realized mechanically by **omitting `tools:`**; a leaf's one deliberate
subtraction is the spawn tool via `disallowedTools`.

## Packaging & sync

New repo home: **`agents/subagents/*.md`** (already git-tracked — `machines` is a
normal repo, no allow-only ignore; nothing to "unignore").

| File | Change |
|---|---|
| `agents/subagents/research-orchestrator.md` | new |
| `agents/subagents/web-research.md` | new |
| `agents/bootstrap.sh` | add `link_entries_into "$SRC_DIR/subagents" "$CLAUDE_DIR/agents"` in the shared (all-profile) section |
| `modules/home/claude.nix` | matching per-file symlink declaration for the NixOS hosts |

Only two agents are shipped by this repo; `gortex-search` / `gortex-impact` are
left to gortex (see above).

`link_entries_into` (bootstrap.sh:160) already exists and is used for Codex
agents (bootstrap.sh:257) — it symlinks each entry of a source dir into a dest
dir individually. Because it links **per file**, our two synced agents coexist
in `~/.claude/agents/` alongside the gortex-rendered `gortex-*.md` files without
collision (distinct names) — neither clobbers the other.

**Sync semantics:** editing an agent is a plain repo write — effective
immediately, no rebuild. A *new* agent file needs one `bootstrap.sh` (or
`just switch` on NixOS) run to create its link. Propagating to another machine is
`git pull` there.

### Out of scope (YAGNI)

- **Codex mirror.** These agents lean on the Claude Agent/Task tool +
  `WebSearch`/`WebFetch`; Codex's subagent format and tools differ. Claude-only
  first; mirror later if useful.
- **Anything about gortex-search / gortex-impact.** They are gortex-owned,
  provisioned machine-wide by `gortex install`; this repo neither ships,
  relocates, nor edits them.

## Load-bearing risk & verification

The hybrid design assumes **a Claude Code subagent can invoke the spawn tool to
delegate to sub-subagents.** Documentation says nesting works up to 5 levels,
but the repo's standing rule is to verify harness behavior empirically before
designing around it.

**Verification is step 0 of implementation, not an afterthought:**

1. **Probe delegation.** A throwaway minimal orchestrator tries to spawn one
   worker. Confirms: (a) a subagent can use the spawn tool at all; (b) an omitted
   `tools:` surfaces session MCP (gortex) inside a subagent; (c) the spawn-tool
   name for `disallowedTools` (`Task` vs `Agent`).
2. **Fallback.** If subagent→subagent delegation is blocked, collapse the
   orchestrator to a **self-contained** research agent (uses everything itself,
   no fan-out). Every other decision in this design survives unchanged.
3. **End-to-end.** One real code question + one real web question through the
   orchestrator. Confirm workers run, context stays isolated (parent sees only
   summaries), and the answer is cited.

## Success criteria

- `research-orchestrator` and `web-research` exist in `agents/subagents/` and
  load as subagents after linking.
- Delegation verified empirically (or the documented fallback applied).
- A real research question returns a cited, synthesized answer with heavy
  exploration kept in worker contexts.
- Agents are portable: they function on a session/directory without gortex by
  falling back to text search + file reads.
- The two new agents are fleet-synced via `bootstrap.sh` + `claude.nix`, and
  coexist with the gortex-rendered agents in `~/.claude/agents/` without
  collision.
