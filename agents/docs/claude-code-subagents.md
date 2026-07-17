# Claude Code subagents — reference

Research capture on how Claude Code handles subagents, verified against the
official docs (docs.claude.com / code.claude.com) as of 2026-07. Grounds future
agent-config work in this repo. See also our own agents under
`agents/plugin/agents/` and the user-scope `~/.claude/agents/*.md`.

## What a subagent is

A **separate Claude instance with its own fresh context window**, spawned by the
main session through the `Agent` / `Task` tool.

- **Isolation.** The subagent inherits *only the prompt string* it is given —
  not the parent's conversation. Its file reads, greps, and exploration stay in
  *its* context; only its **final message** returns to the parent. This is the
  whole value: noisy exploration is kept out of the main context window.
- **Token accounting.** Subagent input/output tokens count separately; the
  parent context is not polluted by the subagent's work — only the summary lands
  back.

## Definition format (`.claude/agents/*.md`)

YAML frontmatter + Markdown system prompt. Fields (v2.1.x):

| Field | Purpose |
|---|---|
| `name` | Identifier |
| `description` | **The delegation trigger** — matched against the task to auto-route. Add `"use proactively"` to encourage auto-invocation |
| `tools` | Comma-separated allowlist (e.g. `Read, Grep, Bash`) |
| `model` | `opus` / `sonnet` / `haiku` |
| `isolation` | `worktree` → own git checkout (expensive; only for agents that write in parallel) |
| `permissionMode` | Permission mode |
| `mcpServers` | MCP servers available to the subagent |
| `skills` | Custom skills |
| `hooks` | Automations |
| `maxTurns` | Turn limit |
| `effort` | Reasoning effort |
| `disallowedTools` | Explicit blocklist |
| `background` | Force background execution |

Body after `---` is the system prompt (preferred over the legacy `prompt` field).
Subdirectories are allowed (`.claude/agents/review/`, etc.).

**Scope precedence** (high → low): CLI (`--agents`) > project (`.claude/agents/`)
> user (`~/.claude/agents/`) > plugin. **Plugin agents cannot use `hooks`,
`mcpServers`, or `permissionMode`** (security) — copy the agent into project/user
scope if you need them.

## Nesting depth & the fan-out footgun

- Nesting goes **up to 5 levels** (main → depth 1…5). A subagent at **depth 5
  does not receive the Agent tool** and cannot spawn further — hard stop.
- Practical sweet spot is **depth 2–3**; deeper is a smell.
- ⚠️ **The real risk is fan-out, not depth.** The 5-level cap stops infinite
  recursion but *not* explosive branching within it. Documented incidents:
  a few top-level Agent calls ballooned into 380–583 agent records, pinned CPUs
  at 100%, forced restarts (GitHub issues #68110, #68430, #77414). Recursive
  fan-out multiplies fast.

## Auto-invocation (same mechanism as skills)

- The `description` field **is** the router — Claude matches the task and
  delegates. `"use proactively"` encourages hand-off.
- **Auto-delegation is unreliable in practice** — Claude often does the task in
  the main session even when a subagent clearly matches. **Explicit invocation**
  ("use the X agent") is the only dependable trigger.
- **No hard "explicit-only" toggle.** The documented way to *discourage*
  auto-invocation is a vague/narrow description.

## Concurrency

- Ad-hoc subagents run **concurrently** (dispatch in one message → wall-clock =
  slowest, not sum). No documented hard cap, but wide fan-outs hit **API rate
  limits** and burn quota ~N× — **batch, don't one-shot a wide dispatch**.
- **Workflows** (scripted orchestration) *do* cap: ~16 concurrent, 1000 total
  per run.

## The three orchestration tiers (SOTA, early 2026)

| Tier | Use case | Cost | Coordination |
|---|---|---|---|
| **Subagents (1–3)** | Isolated research/review that shouldn't pollute main context | Low | Claude decides each spawn |
| **Agent teams (3–5 peers)** | Parallel investigation, competing hypotheses, cross-layer work | Higher | Shared task list + inter-agent messaging (`SendMessage`) |
| **Workflows (dozens+)** | Codebase-wide audits, big migrations, cross-verified research | Highest | A *script* holds the loop; results in variables, not Claude's context |

**Patterns:** research/implementation split (explore in a subagent, code in the
parent), fresh-context verification (a reviewer subagent beats implementer
self-review), domain specialists (security / perf / tests as different lenses).
Skills are reusable *instructions*; subagents are reusable *contexts*.

**Related SDKs:** Claude Code subagents (in-session) vs. **Claude Agent SDK**
(`claude-agent-sdk` / `@anthropic-ai/claude-agent-sdk`, self-hosted harness) vs.
**Managed Agents** (Claude API, Anthropic-hosted sandbox).

## How our fleet setup maps to this

- **`agents/subagents/`** is our own synced subagent home (per-file linked into
  every profile's `agents/` by `bootstrap.sh` / `claude.nix`). Ships
  `research-orchestrator` (Opus, `use proactively`, delegates + synthesises) and
  `web-research` (Sonnet leaf, `disallowedTools: Agent` so it can't spawn —
  enforces "no level 4" structurally). See the design/plan under
  `docs/superpowers/`.
- **gortex-provisioned agents:** `~/.claude/agents/gortex-search.md`,
  `gortex-impact.md` — NOT ours; `gortex install` renders them machine-wide into
  every detected assistant (drift-fenced by `gortex agents render`). The
  orchestrator delegates its code lane to `gortex-search` by name.
- **The `cyphy` plugin** (`agents/plugin/`) ships `quick-tasks` as its subagent
  (routine git/lint one-steppers; `Bash, Read, Glob, Grep`).
- **`agents/` is the git-tracked SHARED tier** symlinked into every profile
  (`~/.claude`, `~/.codex`, `~/.claude-*`). Shared agents added under
  `agents/plugin/agents/` propagate across the whole fleet on commit + pull;
  machine-local ones stay in `settings.local.json` territory.

**Next-step ideas:** extend the gortex-agent pattern (e.g. `gortex-review`,
`gortex-onboard`); add `"use proactively"` only where auto-routing is genuinely
wanted; reserve `isolation: worktree` for parallel-writing agents (already used
by `pure-dev-junior`); reach for a **Workflow** when a task wants dozens of
agents (fleet-wide config audit, mass migration) instead of hand-fanning.

## Sources

- https://code.claude.com/docs/en/sub-agents.md
- https://code.claude.com/docs/en/agents.md
- https://code.claude.com/docs/en/agent-teams.md
- https://code.claude.com/docs/en/workflows.md
- https://code.claude.com/docs/en/best-practices.md
- https://code.claude.com/docs/en/context-window.md
- https://code.claude.com/docs/en/agent-view.md
- https://code.claude.com/docs/en/plugins-reference
- GitHub issues: anthropics/claude-code #68110, #68430, #77414
