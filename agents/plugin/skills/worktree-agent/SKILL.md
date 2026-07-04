---
name: worktree-agent
description: Use when spawning a review, code-edit, or test agent into an isolated git worktree (the Agent tool with isolation "worktree") in any repo — sets the per-tier conventions for gortex, Docker Compose, and gitignored local config so the spawned agent doesn't re-index the worktree, test the wrong code, or collide with the base stack on shared state. Model-invocable: the *launching* agent reads it while composing the subagent's prompt.
---

# Running agents in isolated worktrees

The Agent tool's `isolation: "worktree"` creates and cleans the worktree. Your job
as the launching agent is to compose the subagent's prompt so it follows the
conventions for its tier. A worktree is a second checkout of the same repo at an
untracked path — that untracked path is the root of all three failure modes below.
Classify the spawn first:

| Tier | What it does | Conventions |
|------|--------------|-------------|
| **Review** | reads code + diff, reasons | gortex: use the base index + `git diff <base>..HEAD`. Do NOT re-index the worktree. |
| **Edit** | writes code on a branch | gortex: `overlay_register {workspace_id: "<repo's gortex workspace slug>"}` then `overlay_push` edited buffers — graph queries then reflect your edits with no re-index. Never re-index the worktree path. |
| **Test** | runs the suite | Run the repo's `scripts/agent-worktree-setup.sh` first (if it ships one), then the command it prints. |

The **workspace slug** for the Edit tier is what gortex reports for this repo — it
appears in the gortex session orientation as `workspace: <slug>` (or run
`gortex daemon status`). It is the *base* checkout's slug; the worktree attaches to
that graph rather than getting its own.

## Always, as the spawned agent's first action

If the repo ships a worktree setup script, instruct the subagent to run it from its
worktree root before anything else:

    bash scripts/agent-worktree-setup.sh

Typically this symlinks the gitignored local config a fresh checkout lacks (e.g.
`.claude/settings.local.json`, `.env`) into the worktree and prints a ready-to-run,
collision-safe test command. If the repo has no such script, the spawned agent must
handle the three concerns below by hand — see "Running tests".

## Running tests

Use the command the setup script prints — do NOT hand-roll `docker compose`. Whether
scripted or hand-rolled, a test run from a worktree must bake in the three things
that go wrong otherwise:

- **Reuse the base stack** (`-p <project>`) — a bare `docker compose run` from a
  worktree starts a second stack that collides on the base stack's fixed
  `container_name`s. The project name must match the base checkout's real Compose
  project name exactly; do not sanitize or rename it.
- **Mount the worktree's own code** (`-v <worktree>/src:/app/src`) — otherwise the
  reused stack runs the base checkout's code, not the worktree's.
- **Namespace shared test state** (`-e …`) — per-agent test databases so parallel
  agents don't race on one shared DB. Which stores need this is repo-specific: an
  in-process fake (e.g. fakeredis) needs none; a real shared DB (postgres, mongo)
  needs a per-agent name via env.

## gortex "cwd not covered"

A worktree lives at an untracked path, so graph tools go dark there and the
enforcement hooks misfire. Review agents don't need graph tools (base + diff is
enough); edit agents attach to the base graph via `overlay_register` by workspace
slug. Do not run `index_repository` on the worktree — it wastes a full warmup and
hundreds of MB per worktree, and the overlay path gives edits back to the graph
without it.

<!-- Dual-homed: a copy of this skill also ships in the team-wide pure-dev plugin
(thepureapp/claude-plugins, skills/worktree-agent) for teammates. This personal
copy exists because pure-dev is work-profile-only; the SHARED nix skills tree
loads it in every profile. Keep the two in rough sync when the conventions change. -->
