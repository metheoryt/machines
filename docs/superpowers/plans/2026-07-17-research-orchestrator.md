# Research Orchestrator Subagent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two fleet-synced Claude Code subagents — a `research-orchestrator` (delegates + synthesizes) and a `web-research` leaf worker — with the bootstrap/nix wiring to sync them across the fleet.

**Architecture:** The orchestrator (Opus, auto-invocable) plans a research question, delegates heavy lookups to leaf workers (code → the gortex-provisioned `gortex-search`; web → the new `web-research`), and returns one cited answer. Leaf workers inherit the full session tool surface but have the spawn tool stripped, so the delegation chain physically stops at depth 2. Agents live in `agents/subagents/*.md` and are symlinked per-file into every Claude profile's `agents/` dir.

**Tech Stack:** Claude Code subagents (`.md` + YAML frontmatter), bash (`agents/bootstrap.sh`), Nix/home-manager activation (`modules/home/claude.nix`).

## Global Constraints

- This repo ships **exactly two** agents: `research-orchestrator`, `web-research`. It does **not** ship, relocate, or edit `gortex-search`/`gortex-impact` — those are gortex-owned (provisioned by `gortex install`).
- Orchestrator: `model: opus`, `description` contains `use proactively`, **no `tools:` field** (inherits full session surface incl. the spawn tool).
- Leaf workers: **no `tools:` field** + `disallowedTools:` set to the spawn tool (name confirmed in Task 1 — `Task` unless the probe shows otherwise).
- Prompts describe **capabilities, not specific tool names** ("prefer a code-graph tool if available, else grep/read"). No hardcoded `mcp__gortex__*` call sequences.
- Bounded fan-out: orchestrator spawns **≤4 workers concurrently**, sequencing the rest.
- Agents research and synthesize only — never edit files or run mutating commands.
- No Codex mirror in this effort.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Repo is a normal git repo — plain `git`, work directly on the current branch (`Launching-subagents-call-stack`).

---

### Task 1: Probe — can a subagent delegate, and what is the spawn tool named?

The whole hybrid design assumes a Claude Code subagent can invoke the spawn tool to launch a sub-subagent. Verify this empirically before authoring the real agents (repo rule: verify harness behavior, don't assume).

**Files:**
- Create: `<scratchpad>/probe-notes.md` (findings only — not committed)

**Interfaces:**
- Produces: a documented decision — `DELEGATION_WORKS` (true/false) and `SPAWN_TOOL_NAME` (`Task` or `Agent`) — consumed by Tasks 2 and 3.

- [ ] **Step 1: Dispatch a nested-delegation probe**

Using the Agent tool, dispatch one subagent (subagent_type `general-purpose`) with this exact prompt:

```
You are a probe. Do exactly this and nothing else:
1. Report the exact names of any tool you have that can launch/spawn another agent or subagent (look for a tool named "Task" or "Agent").
2. If you have such a tool, use it to launch a sub-subagent whose entire job is to reply with the single word BANANA. Then tell me: (a) the spawn tool's exact name, (b) whether the nested agent ran, (c) the word it returned.
3. If you have NO such tool, say exactly: "NO_SPAWN_TOOL".
```

- [ ] **Step 2: Record the outcome**

Write `<scratchpad>/probe-notes.md` capturing:
- `DELEGATION_WORKS = true` if the probe returned `BANANA` from a nested agent; else `false`.
- `SPAWN_TOOL_NAME =` the exact tool name the probe reported (`Task` or `Agent`).

Expected (per docs): `DELEGATION_WORKS = true`, `SPAWN_TOOL_NAME = Task`. If `NO_SPAWN_TOOL` comes back, set `DELEGATION_WORKS = false` — Task 3 then uses its fallback (self-contained) variant.

- [ ] **Step 3: No commit**

This task produces only scratchpad notes. Nothing to commit.

---

### Task 2: `web-research` leaf worker

**Files:**
- Create: `agents/subagents/web-research.md`

**Interfaces:**
- Produces: a loadable subagent named `web-research` that the orchestrator (Task 3) delegates web lookups to. It must NOT be able to spawn subagents.

- [ ] **Step 1: Write the agent file**

Create `agents/subagents/web-research.md` (replace `Task` in `disallowedTools` with `SPAWN_TOOL_NAME` from Task 1 if it differed):

```markdown
---
name: web-research
description: "Use to research a topic on the web — search, fetch the most relevant sources, and return a concise summary WITH source URLs. A read-only leaf worker; it does not spawn other agents. Examples: \"Summarize the current best practice for X\", \"What does the RFC for Y actually say?\", \"Find upstream release notes for library Z\"."
model: sonnet
disallowedTools: Task
---

You are the web-research leaf worker. The parent agent delegated a web-research
task to you. You return a single summary message — the parent does not see your
tool calls, so earn the delegation by summarising well.

Use whatever web tools your session offers (search, then fetch). Do not assume a
specific tool name — use what is available:

1. Search for the topic and identify the most relevant, authoritative sources.
2. Fetch and read those sources (prefer primary sources over aggregators).
3. Return: the answer first, then the key evidence with a SOURCE URL for every
   claim, then caveats or gaps.

Do not dump raw page content. Do not edit files or run mutating commands — you
are read-only. You are a leaf: you never spawn other subagents.
```

- [ ] **Step 2: Verify it loads and runs**

Point a throwaway config dir at just this agent (isolates the test from the live profile; agents load from `$CLAUDE_CONFIG_DIR/agents/`), then invoke it headlessly:

```bash
PROBE="$(mktemp -d)/cfg"; mkdir -p "$PROBE/agents"
cp agents/subagents/web-research.md "$PROBE/agents/"
CLAUDE_CONFIG_DIR="$PROBE" claude -p "Use the web-research agent to answer: what is the latest stable Python 3.x minor release? Cite a source URL." \
  --allowedTools "Task WebSearch WebFetch Read" --output-format text
```
Expected: an answer naming a version with at least one `https://` source URL.

- [ ] **Step 3: Verify it CANNOT spawn (the leaf invariant)**

```bash
CLAUDE_CONFIG_DIR="$PROBE" claude -p "You are web-research. List the exact names of any tools you have that can launch another agent or subagent. If none, reply NO_SPAWN_TOOL." \
  --allowedTools "Task WebSearch WebFetch Read" --output-format text
```
Expected: `NO_SPAWN_TOOL` (the `disallowedTools: Task` line stripped the spawn tool). If a spawn tool IS still listed, the frontmatter name is wrong — try `disallowedTools: Agent`, re-run, and keep whichever yields `NO_SPAWN_TOOL`. Record the working name.

- [ ] **Step 4: Commit**

```bash
git add agents/subagents/web-research.md
git commit -m "$(cat <<'EOF'
feat(agents): web-research leaf worker

Read-only web research subagent (Sonnet): search + fetch + cited summary.
disallowedTools strips the spawn tool so it is a true leaf (no level 4).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `research-orchestrator`

Use the **primary** variant if Task 1 set `DELEGATION_WORKS = true`; otherwise use the **fallback** variant.

**Files:**
- Create: `agents/subagents/research-orchestrator.md`

**Interfaces:**
- Consumes: the `web-research` agent (Task 2) and the gortex-provisioned `gortex-search` agent (external).
- Produces: a loadable, auto-invocable subagent named `research-orchestrator`.

- [ ] **Step 1a (primary — delegation works): write the orchestrator**

Create `agents/subagents/research-orchestrator.md`:

```markdown
---
name: research-orchestrator
description: "Use proactively for open-ended research questions spanning code and/or external sources. Plans the question, delegates heavy lookups to worker subagents (code/architecture -> gortex-search; web/prose -> web-research), and returns ONE synthesised, cited answer. Examples: \"How does our auth flow work and does it match the OAuth spec?\", \"Research options for X and how this codebase would adopt them\", \"What changed upstream in library Y and what breaks here?\"."
model: opus
---

You are the research orchestrator. The parent delegated an open-ended research
question. You plan it, delegate the heavy lookups to worker subagents, and
return ONE synthesised, cited answer. The parent sees only your final message —
not your workers' tool calls — so earn the context isolation by summarising.

Use whatever tools your session offers. Delegate depth; do only quick triage
yourself.

Route work:
- CODE / architecture / call-tracing questions -> delegate to the `gortex-search`
  subagent (provisioned by gortex where present). If `gortex-search` is
  unavailable (no gortex on this session or directory), do that lookup yourself
  with text search + file reads.
- WEB / external / prose research -> delegate to the `web-research` subagent.
- Quick triage only (a single fetch, a small read) may be done yourself — never
  heavy exploration; that is what workers are for.

Plan and fan out:
1. Restate the question; split it into independent vs. dependent sub-questions.
2. Spawn workers for independent sub-questions IN PARALLEL, but in bounded
   batches — no more than 4 at once, because the session caps total parallel
   workers. Sequence dependent sub-questions (feed one worker's result into the
   next).
3. Never ask a worker to spawn its own workers; workers are leaves.

Synthesise:
- Lead with the answer / conclusion.
- Then the evidence: symbol IDs and file:line for code, source URLs for web.
- Then caveats and open questions.

You research and synthesise ONLY. Do not edit files or run mutating commands,
even though your inherited tool surface may allow it.
```

- [ ] **Step 1b (fallback — delegation blocked): write a self-contained orchestrator**

Only if Task 1 set `DELEGATION_WORKS = false`. Same file, but no delegation:

```markdown
---
name: research-orchestrator
description: "Use proactively for open-ended research questions spanning code and/or external sources. Researches directly (code via a graph tool if available else grep/read; web via search+fetch) and returns ONE synthesised, cited answer. Examples: \"How does our auth flow work and does it match the OAuth spec?\", \"Research options for X and how this codebase would adopt them\"."
model: opus
---

You are the research orchestrator. The parent delegated an open-ended research
question. You research it directly and return ONE synthesised, cited answer. The
parent sees only your final message — earn the context isolation by summarising.

Use whatever tools your session offers:
- CODE / architecture: prefer a code-graph tool if available (e.g. gortex
  `smart_context` / `get_callers`); otherwise text search + file reads.
- WEB / external: search, then fetch and read the most authoritative sources.

Work the question in order: restate it, gather the code evidence, gather the web
evidence, then synthesise. Lead with the conclusion, then the evidence (symbol
IDs / file:line for code, source URLs for web), then caveats.

You research and synthesise ONLY. Do not edit files or run mutating commands.
```

- [ ] **Step 2: Verify it loads and (primary) delegates end-to-end**

```bash
PROBE2="$(mktemp -d)/cfg"; mkdir -p "$PROBE2/agents"
cp agents/subagents/research-orchestrator.md agents/subagents/web-research.md "$PROBE2/agents/"
CLAUDE_CONFIG_DIR="$PROBE2" claude -p "Use the research-orchestrator to answer: what is the newest stable Node.js LTS version, and cite a source?" \
  --allowedTools "Task WebSearch WebFetch Read" --output-format stream-json --verbose | tee "$PROBE2/run.jsonl" >/dev/null
grep -c '"web-research"' "$PROBE2/run.jsonl" || true
```
Expected (primary): the run transcript references `web-research` (the orchestrator delegated), and the final text answers with a version + source URL. (Fallback: no `web-research` reference, but a correct cited answer.) `gortex-search` is not exercised here — this throwaway config has no gortex; the orchestrator's own fallback covers code lookups in that context.

- [ ] **Step 3: Commit**

```bash
git add agents/subagents/research-orchestrator.md
git commit -m "$(cat <<'EOF'
feat(agents): research-orchestrator subagent

Opus, use-proactively. Plans a research question, delegates heavy lookups to
leaf workers (gortex-search for code, web-research for web) in bounded batches,
and returns one cited synthesis. Inherits the full session surface + spawn tool.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Fleet-sync wiring (`bootstrap.sh` + `claude.nix`)

**Files:**
- Modify: `agents/bootstrap.sh` (after the cyphy plugin link, ~line 237)
- Modify: `modules/home/claude.nix` (inside the per-profile loop, after the plugin link, ~line 64)

**Interfaces:**
- Consumes: `agents/subagents/*.md` (Tasks 2–3).
- Produces: per-file symlinks `~/.claude*/agents/<name>.md -> <repo>/agents/subagents/<name>.md` on every profile, via both the portable (bash) and Nix paths.

- [ ] **Step 1: Add the bootstrap.sh link**

In `agents/bootstrap.sh`, immediately after the cyphy plugin block (the two lines ending with `link "$SRC_DIR/plugin" "$CLAUDE_DIR/skills/cyphy"`), insert:

```bash

# My own subagents: per-file links so machine-local agents AND the
# gortex-rendered gortex-*.md all coexist in ~/.claude/agents/.
link_entries_into "$SRC_DIR/subagents" "$CLAUDE_DIR/agents"
```

- [ ] **Step 2: Verify the bootstrap link (dry-run then real)**

```bash
DRY_RUN=1 bash agents/bootstrap.sh 2>&1 | grep -A1 "subagents\|agents/"
bash agents/bootstrap.sh 2>&1 | tail -20
ls -l ~/.claude/agents/research-orchestrator.md ~/.claude/agents/web-research.md
```
Expected: dry-run reports it *would* link the two agents; real run links them; `ls` shows both as symlinks pointing into `agents/subagents/`. The gortex `~/.claude/agents/gortex-*.md` files are untouched (still present).

- [ ] **Step 3: Add the claude.nix link**

In `modules/home/claude.nix`, inside the `for setsrc` loop, immediately after the line `$DRY_RUN_CMD ln -sfn "${agents}/plugin" "$prof/skills/cyphy"`, insert:

```nix
      # My own subagents — per-file links so the gortex-rendered agents and any
      # machine-local ones coexist in <profile>/agents/.
      $DRY_RUN_CMD mkdir -p "$prof/agents"
      for asrc in "${agents}"/subagents/*.md; do
        [ -e "$asrc" ] || continue
        $DRY_RUN_CMD ln -sfn "$asrc" "$prof/agents/$(basename "$asrc")"
      done
```

- [ ] **Step 4: Verify the nix syntax evaluates**

```bash
just quick
```
Expected: PASS (no eval error). Full activation happens on the next `just switch` on the NixOS hosts — note it; do not run `switch` as part of this task.

- [ ] **Step 5: Commit**

```bash
git add agents/bootstrap.sh modules/home/claude.nix
git commit -m "$(cat <<'EOF'
feat(agents): sync agents/subagents/ into every Claude profile

bootstrap.sh (portable) + claude.nix (NixOS) per-file symlink the new
research-orchestrator + web-research into <profile>/agents/, coexisting with
the gortex-rendered agents. Editing an agent is a live repo write; a new agent
needs one bootstrap/switch run to create its link.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Finalize — note the agents in the reference doc, then push

**Files:**
- Modify: `agents/docs/claude-code-subagents.md` (the "How our fleet setup maps to this" section)

**Interfaces:**
- Consumes: nothing. Produces: an updated reference + all work pushed.

- [ ] **Step 1: Add a line to the fleet-setup section**

In `agents/docs/claude-code-subagents.md`, under the fleet-setup bullets, add:

```markdown
- **`agents/subagents/`** is our own synced subagent home (per-file linked into
  every profile's `agents/` by bootstrap.sh / claude.nix). Ships
  `research-orchestrator` (Opus, delegates + synthesises) and `web-research`
  (Sonnet leaf). `gortex-search`/`gortex-impact` are NOT here — gortex
  provisions those machine-wide.
```

- [ ] **Step 2: Commit and push**

```bash
git add agents/docs/claude-code-subagents.md
git commit -m "$(cat <<'EOF'
docs(agents): note the research-orchestrator/web-research subagents

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
git push
```
Expected: push succeeds on branch `Launching-subagents-call-stack`.

- [ ] **Step 3: Manual end-to-end check (real profile)**

In a NEW Claude session in a gortex-tracked repo (so `gortex-search` exists), ask an open-ended question that spans code + web, and confirm the orchestrator is offered/used, workers run, and the answer is cited. (This needs a fresh session because agents load at session start.)

---

## Self-Review

**Spec coverage:**
- General research orchestrator (hybrid, delegates) → Task 3. ✔
- Reuse gortex-search + build 1 web worker → Task 2 (web-research) + Task 3 delegates to gortex-search. ✔
- Orchestrator Opus, web-worker Sonnet → frontmatter in Tasks 2/3. ✔
- Proactive invocation → `use proactively` in orchestrator description. ✔
- Inherit-all-minus-spawn on leaves → `disallowedTools` in Task 2. ✔
- Generalize prompts (no hardcoded gortex) → agent bodies use capability language. ✔
- No level 4 structural → `disallowedTools` verified in Task 2 Step 3. ✔
- Bounded fan-out ≤4 → orchestrator body. ✔
- Packaging `agents/subagents/` + bootstrap + claude.nix → Task 4. ✔
- Drop gortex-search/impact → Global Constraints + not created anywhere. ✔
- No Codex mirror → Global Constraints. ✔
- Verify-delegation-first + fallback → Task 1 + Task 3 Step 1b. ✔

**Placeholder scan:** No TBD/TODO; all agent bodies and edits are complete literals. The one runtime unknown (spawn-tool name) is resolved by Task 1 and threaded into Tasks 2–3 as an explicit substitution, not a placeholder.

**Type/name consistency:** agent names `research-orchestrator` / `web-research` and the delegated `gortex-search` are used identically across tasks; `SPAWN_TOOL_NAME` / `DELEGATION_WORKS` are defined in Task 1 and consumed in 2–3.
