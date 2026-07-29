---
name: agent-system-design
description: "Design multi-agent systems and plan autonomous agent fleets."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [multi-agent, fleet, orchestration, architecture, roadmap, planning]
    related_skills: [plan, orchestration, autonomous-ai-agents]
---

# Agent System Design

Use this skill when the user wants to design, plan, or roadmap a multi-agent
system — especially autonomous agent fleets, orchestration platforms, or
community features for agent-driven products.

## User's workflow split

**Hermes = creative planning and architecture. Claude Code (Opus) = implementation.**

- Design discussions, roadmapping, feature brainstorming, and architecture
  decisions happen HERE.
- When a plan is ready, it gets handed off to Claude Code for coding.
- Never try to implement code during a design session — stay in planning mode.
- Write plans to disk so Claude can pick them up.

## Design process

### 1. Understand the system

- Read `ARCHITECTURE.md` if it exists. Never read build plans or dated specs
  to understand how the system works — architecture docs are the source of truth.
- Map the process topology: what runs where, who talks to whom.
- Identify the seams: transport layer, wire protocol, persistence, auth boundaries.
- Understand the vocabulary (projects often have dual metaphors — beehive +
  corporate, etc.).

### 2. Assess current state

- What's shipped vs on a branch vs design-only?
- What's the capability ladder (L0, L1, L2, ...)?
- What are the known sharp edges and gotchas?
- What's the MVP bar?

### 3. Roadmap planning

- Define MVP: what's the minimal set to "touch it"?
- Order by dependency: what blocks what?
- Identify quick wins vs architectural heavy lifts.
- Flag design-only features that need more specification.

### 4. Feature design (e.g., community mesh, delegation, managers)

- Start with the user's vision, then ask clarifying questions:
  - Ownership model (single-user fleet vs multi-user community)?
  - Relationship to existing features (replaces, augments, sits beside)?
  - Navigation/routing model?
  - Addressing model (how do agents find each other)?
  - Permission model (what can agents do where)?
- Capture decisions in a design doc. Prefer concrete examples over abstract
  descriptions.
- When the user says "let's discuss" — explore, don't jump to solutions.
  When they say "let's decide" — converge and write it down.

### 5. Handoff to implementation

- Save the plan or design doc to the project repo.
- The user will feed it to Claude Code (Opus) for coding.
- Keep plans concrete: exact file paths, module names, architectural
  boundaries. Claude needs enough context to implement without guessing.

## Pitfalls

- **Don't code during design sessions** — the user explicitly uses Hermes for
  planning and Claude for implementation. Writing code here wastes tokens and
  the user's money.
- **Don't read dated build plans** — `docs/plans/` is execution history, not
  current architecture. The architecture doc is the truth.
- **Don't confuse the two vocabularies** when a project uses dual metaphors
  (beehive + corporate, etc.). Name the processes by their technical role;
  name the agents by their org role. Clarify which is which.
- **Don't abstract prematurely** — a feature like "community mesh" should be
  explored with concrete examples before being turned into abstractions.
