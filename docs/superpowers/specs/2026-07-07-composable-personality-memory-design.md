# Composable personality memory — design

**Date:** 2026-07-07
**Status:** approved (design), pending implementation plan

## Problem

The synced global memory store (`agents/memory/global.md`) interleaves two
different kinds of content:

- **Facts** the agent has learned about *this* environment — repo layout,
  Docker/worktree gotchas, gortex resolution behavior, an empirical
  harness file-reading finding.
- **Personality** — how the agent should *behave*: outward-facing tone,
  workflow rituals (git-sync, reflect-between-chunks, ship-on-push), and a
  safety disposition (never destroy the last copy of a secret). Coding-craft
  opinions live in a sibling `agents/memory/practices.md`.

Behavioral directives are buried among fleet-specific facts, and the "who I am"
material is not a self-contained thing — it can't be lifted into a fresh profile
independently of this fleet's facts.

## Goal

Extract personality into its own **portable, modular** bundle, leaving `global.md`
as facts only.

- **Signal** — behavioral directives read as directives, not lost in facts.
- **Portability** — `personality/` is a complete, self-contained "who I am"
  bundle, droppable into a fresh profile independent of fleet facts.

**Explicit non-goal: token reduction.** Splitting two loaded files into five
(global + four facets) slightly *increases* load (extra per-file headers). The
honest wins are signal and portability. A real token cut would require
conditional loading (personality only in some sessions) — deliberately out of
scope; not worth the complexity.

## Structure

A `memory/personality/` subdirectory of four facets; `global.md` keeps facts.

```
agents/memory/
  personality/
    tone.md        ← outward-facing voice
    habits.md      ← rituals / workflows run without being told
    values.md      ← cross-cutting dispositions (non-code)
    practices.md   ← coding craft (moved intact from memory/practices.md)
  global.md        ← facts only
agents/hosts/<host>.md   ← per-host (unchanged)
```

## Extraction map

Every current entry gets a destination.

| Source (current) | Entry | Destination |
|---|---|---|
| `global.md` → Preferences | Communication — professional tone (outward-facing) | `personality/tone.md` |
| `global.md` → Preferences | Git-sync protocol | `personality/habits.md` |
| `global.md` → Preferences | Reflect between work chunks, file by scope | `personality/habits.md` |
| `global.md` → Shipping & deployment | Ship-on-push default | `personality/habits.md` |
| `global.md` → Preferences | Never destroy the last copy of a secret | `personality/values.md` |
| `memory/practices.md` (whole file) | Principles / Deltas / OOP / Gortex-tuned | `personality/practices.md` (moved intact) |
| `global.md` → Preferences | Verify Claude Code's file-reading | **stays `global.md`** — reclassified pref → fact (empirical harness finding, not a trait) |
| `global.md` | Repo layout (WSL boxes) | stays `global.md` |
| `global.md` | Worktree agents under docker-compose | stays `global.md` |
| `global.md` | Docker Desktop shares one engine | stays `global.md` |
| `global.md` | Gortex behavior | stays `global.md` |

Notes:

- **`values.md` is intentionally light** — just never-destroy-a-secret for now.
  It's a deliberate home for future cross-cutting dispositions, not padding.
- **Portability fix:** `tone.md`'s source cross-references `review-voice.md` and
  "the pure-dev review-voice card." For the bundle to be self-contained, **drop
  the pointer** and keep the tone rule standing on its own words (it already
  states the full rule; the ref was only provenance) — no dangling ref to
  fleet-specific plugin files carried into the portable personality.
- `global.md`'s `## Preferences & feedback` heading is emptied of the moved
  entries; keep the heading only if a non-moved preference remains, otherwise
  remove it.

## Wiring

Personality loads and syncs only if the four hardcoded sites know about it.
Collapse the per-file churn to a **directory link + glob**.

1. **Hook** — `agents/plugin/hooks/global-memory-load.sh`
   - Replace the single `emit .../memory/practices.md` call with a loop over
     `"$config_dir"/memory/personality/*.md`, emitting each (deterministic
     alphabetical order via the shell glob; guard the no-match case with
     `nullglob` or an existence test so an unexpanded `*.md` literal isn't
     `cat`-ed). `emit`'s empty/whitespace-only skip already tolerates a stub.
   - Keep the `global.md` and `host-memory.md` emits unchanged.
   - Order: `global.md`, then the `personality/*.md` group, then
     `host-memory.md`.

2. **NixOS** — `modules/home/claude.nix` and `modules/home/codex.nix`
   - Remove the `memory/practices.md` per-file link line.
   - Add one recursive link of the `memory/personality/` **subdirectory**
     (e.g. `"${profileDir}/memory/personality".source = link
     "${agents}/memory/personality"`). Leave the existing `global.md` per-file
     link untouched — do **not** convert the whole `memory/` dir to a single
     link, or it collides with the `global.md` link.

3. **Non-Nix fallback** — `agents/bootstrap.sh`
   - Replace the `memory/practices.md` link with a `memory/personality/`
     directory link (for both the `~/.claude` and `~/.codex` blocks). Ensure the
     `link` helper (or a directory-aware variant) symlinks the directory rather
     than erroring on a non-file.

4. **Docs**
   - `agents/AGENTS.md` "Persistent memory (synced & version-controlled)" —
     update the store list to name `memory/personality/` and its facets, and
     drop `memory/practices.md` from the top-level list.
   - `agents/AGENTS.md` "Recording a memory — pick the scope" — add guidance on
     which facet a new behavioral learning belongs to (tone / habit / value /
     practice) vs a fact (`global.md`).
   - `agents/README.md` — mirror the memory-section update if it enumerates the
     stores.

5. **Git tracking**
   - Confirm the new `agents/memory/personality/*.md` files are tracked (this is
     the `machines` repo, not the `~/.dotfiles` bare repo; check
     `agents/.gitignore` doesn't exclude the new subdir). Remove the now-moved
     `agents/memory/practices.md` from the tree (`git mv` its content into the
     facet) so no stale duplicate remains.

## Verification

- After `just switch` (NixOS) or `bootstrap.sh` (fallback): the profile's
  `memory/personality/` symlinks resolve, and `memory/practices.md` no longer
  exists at the profile root.
- A fresh session's injected context shows the four facets under their headers
  and no longer shows the moved entries inside `global.md`.
- `global.md` contains only facts; grep it for the moved headings to confirm
  they're gone.
- The old `practices.md` content appears exactly once (in
  `personality/practices.md`), not duplicated.
