# Composable Personality Memory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the agent's behavioral "personality" (tone, habits, values, coding practices) out of `agents/memory/global.md` into a portable `agents/memory/personality/` directory of four facets, leaving `global.md` as facts only, and rewire the loader + symlink mechanisms to load and sync the new layout.

**Architecture:** Content migration + wiring. Move designated sections from `global.md` and the whole `practices.md` into four new files under `agents/memory/personality/`. Then update the four hardcoded sites that reference the old layout — the `global-memory-load.sh` SessionStart hook (glob the new dir), and three symlink mechanisms (`claude.nix`, `codex.nix`, `bootstrap.sh`) — collapsing per-file wiring to a single directory link.

**Tech Stack:** Markdown memory stores, Bash (SessionStart hook + bootstrap), Nix (home-manager `mkOutOfStoreSymlink`).

**Spec:** `docs/superpowers/specs/2026-07-07-composable-personality-memory-design.md`

## Global Constraints

- This is the `machines` repo (a normal git repo), NOT the `~/.dotfiles` bare repo. Use plain `git` from repo root `/home/me/machines`.
- **Do not sweep the pre-existing unstaged change to `agents/settings.personal.json` into any commit.** Stage only the files each task names.
- New personality files live at `agents/memory/personality/*.md` — verified trackable (not gitignored).
- The three symlink mechanisms must stay in lockstep: `claude.nix`, `codex.nix`, and `bootstrap.sh` produce identical links. A change to one is a change to all three.
- **Do not run `just switch` or re-run `bootstrap.sh` until Task 3 is committed** — the loader/symlink sites reference `memory/practices.md` until then, so an intermediate apply would drop `practices.md` from the loaded set. After Task 3, apply normally.
- Personality facet load order is alphabetical by filename (`habits`, `practices`, `tone`, `values`); content is self-labeled by headers, so order among facets does not matter.
- `values.md` is intentionally light (one entry for now). That is by design, not an omission.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `agents/memory/personality/tone.md` | Outward-facing communication voice | create |
| `agents/memory/personality/habits.md` | Rituals/workflows run without being told | create |
| `agents/memory/personality/values.md` | Cross-cutting non-code dispositions | create |
| `agents/memory/personality/practices.md` | Coding craft (moved from `memory/practices.md`) | create (move) |
| `agents/memory/global.md` | Facts only | trim |
| `agents/memory/practices.md` | — | delete (content moved) |
| `agents/plugin/hooks/global-memory-load.sh` | Inject stores into every session | rewire loader |
| `modules/home/claude.nix` | NixOS symlinks for `~/.claude` + `~/.claude-work` | rewire |
| `modules/home/codex.nix` | NixOS symlinks for `~/.codex` | rewire |
| `agents/bootstrap.sh` | Non-Nix symlink fallback | rewire |
| `agents/AGENTS.md` | Canonical instructions (memory scoping guidance) | doc update |
| `agents/README.md` | Repo overview (memory section) | doc update |

---

## Task 1: Extract personality facets, trim global.md

Create the four facet files and remove the moved content from `global.md` and `practices.md`. Sections are bounded by `##` headings, so boundaries are unambiguous — **move the full section verbatim**, do not paraphrase.

**Files:**
- Create: `agents/memory/personality/tone.md`
- Create: `agents/memory/personality/habits.md`
- Create: `agents/memory/personality/values.md`
- Create: `agents/memory/personality/practices.md`
- Modify: `agents/memory/global.md`
- Delete: `agents/memory/practices.md`

- [ ] **Step 1: Create `personality/tone.md`**

Write this header, then append (cut from `global.md`) the entire `## Communication — professional tone (outward-facing)` section — its heading line through its last bullet. **Portability edit:** in the moved text, drop the clause referencing `review-voice.md` / "the pure-dev review-voice card" (the first bullet's parenthetical provenance); the rule stands on its own words. Keep everything else verbatim.

```markdown
# Personality — tone

<!--
Outward-facing communication voice. One facet of the portable personality
bundle (memory/personality/), loaded every session by the global-memory-load.sh
hook and synced across machines. Applies to everything a human OTHER than me
reads; NOT in-session chat replies to me. Keep curated. No secrets.
-->
```

- [ ] **Step 2: Create `personality/habits.md`**

Write this header, then append (cut from `global.md`, verbatim) three sections in this order: the `## Preferences & feedback` **Git-sync protocol** bullet, the **Reflect between work chunks** bullet, and the entire `## Shipping & deployment defaults` section. Convert the two moved `Preferences & feedback` bullets into their own `##` subsections (`## Git-sync protocol` and `## Reflect between work chunks, then file by scope`) so each stands alone.

```markdown
# Personality — habits

<!--
Rituals and workflows I run without being told (sync cadence, reflection,
shipping defaults). One facet of the portable personality bundle
(memory/personality/), loaded every session and synced across machines.
Keep curated. No secrets.
-->
```

- [ ] **Step 3: Create `personality/values.md`**

Write this header, then append (cut from `global.md`, verbatim) the **Never destroy the last copy of a secret** bullet from `## Preferences & feedback`, as a `## Never destroy the last copy of a secret` subsection.

```markdown
# Personality — values

<!--
Cross-cutting dispositions (non-code). Intentionally light for now — a home for
future character/values entries. One facet of the portable personality bundle
(memory/personality/), loaded every session and synced across machines.
Keep curated. No secrets.
-->
```

- [ ] **Step 4: Create `personality/practices.md` from the old file**

Move the whole `agents/memory/practices.md` into `agents/memory/personality/practices.md`:

```bash
cd /home/me/machines
git mv agents/memory/practices.md agents/memory/personality/practices.md
```

Then edit the moved file's top HTML comment: change the sentence "Injected every session by the global-memory-load.sh hook" to note it is one facet of `memory/personality/`. Leave all the practice bullets (Principles / Deltas / OOP / Gortex-tuned) verbatim.

- [ ] **Step 5: Reclassify the harness-fact bullet and clean up `global.md` headings**

In `global.md`, the `## Preferences & feedback` section now has only the **Verify Claude Code's file-reading before designing around it** bullet left (the other three moved out). That bullet is an empirical harness fact, not a preference. Rename the heading `## Preferences & feedback` to `## Harness behavior (empirical)` (it now holds just that one bullet). Confirm no other `Preferences & feedback` content remains.

- [ ] **Step 6: Verify the content moved cleanly**

Run:

```bash
cd /home/me/machines
echo "--- global.md must NOT contain moved headings ---"
grep -nE '## (Communication — professional tone|Shipping & deployment|Preferences & feedback)' agents/memory/global.md && echo "FAIL: stale heading in global.md" || echo "OK: global.md trimmed"
echo "--- moved bullets gone from global.md ---"
grep -nE 'Git-sync protocol|Reflect between work chunks|Never destroy the last copy' agents/memory/global.md && echo "FAIL: moved bullet still in global.md" || echo "OK"
echo "--- old practices.md gone ---"
test ! -e agents/memory/practices.md && echo "OK: practices.md removed" || echo "FAIL: practices.md still present"
echo "--- four facets exist and are non-empty ---"
for f in tone habits values practices; do test -s "agents/memory/personality/$f.md" && echo "OK: $f.md" || echo "FAIL: $f.md missing/empty"; done
echo "--- practices content lives only in the facet ---"
grep -l 'Composition over inheritance' agents/memory/personality/practices.md agents/memory/global.md 2>/dev/null
```

Expected: every line prints `OK`; the last `grep -l` prints only `agents/memory/personality/practices.md`.

- [ ] **Step 7: Commit**

```bash
cd /home/me/machines
git add agents/memory/personality/ agents/memory/global.md
git add -u agents/memory/practices.md   # stage the deletion (git mv already staged the add)
git commit -m "memory: extract personality facets from global.md

Move tone / habits / values / coding-practices into memory/personality/;
global.md keeps facts only. Wiring updated in follow-up commits.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rewire the loader hook to glob personality/

Replace the single `practices.md` emit with a loop over `memory/personality/*.md`.

**Files:**
- Modify: `agents/plugin/hooks/global-memory-load.sh`

**Interfaces:**
- Consumes: the `emit()` function already in the hook (`emit <path> <header>`; skips missing/empty/whitespace-only files).
- Produces: session-injected output containing one block per personality facet, headed `Personality — <facet> ...`, plus the unchanged `global.md` and `host-memory.md` blocks.

- [ ] **Step 1: Replace the practices emit with a personality loop**

In `agents/plugin/hooks/global-memory-load.sh`, replace this block:

```bash
emit "$config_dir/memory/practices.md" \
  "Code practices (synced, git-tracked, loaded every session):"
```

with:

```bash
# Personality facets (tone / habits / values / practices) — one file each,
# loaded in deterministic (alphabetical) order. nullglob so an empty or missing
# personality/ dir expands to nothing instead of a literal '*.md' path.
shopt -s nullglob
for facet in "$config_dir"/memory/personality/*.md; do
  emit "$facet" \
    "Personality — $(basename "$facet" .md) (synced, git-tracked, loaded every session):"
done
shopt -u nullglob
```

Leave the `global.md` emit (above it) and the `host-memory.md` emit (below it) unchanged, so final order is: global → personality facets → host.

- [ ] **Step 2: Test the hook against a fixture config dir**

Run:

```bash
cd /home/me/machines
tmp="$(mktemp -d)"
mkdir -p "$tmp/memory/personality"
printf '# Global\n\nfact one\n'            > "$tmp/memory/global.md"
printf '# Personality — tone\n\nbe lean\n' > "$tmp/memory/personality/tone.md"
printf '# Personality — habits\n\nsync\n'  > "$tmp/memory/personality/habits.md"
printf '# Host\n\nnote\n'                  > "$tmp/host-memory.md"
bash agents/plugin/hooks/global-memory-load.sh "$tmp"
echo "=== exit: $? ==="
rm -rf "$tmp"
```

Expected output contains, in order: the Global block, `Personality — habits` block (alphabetical, before tone), `Personality — tone` block, then the Per-host block. No literal `*.md` appears. Exit 0.

- [ ] **Step 3: Test the empty/missing personality dir case**

Run:

```bash
cd /home/me/machines
tmp="$(mktemp -d)"
mkdir -p "$tmp/memory"                                  # no personality/ dir under it
printf '# Global\n\nfact\n' > "$tmp/memory/global.md"
bash agents/plugin/hooks/global-memory-load.sh "$tmp"; echo "=== exit: $? ==="
rm -rf "$tmp"
```

Expected: only the Global block prints, no `Personality —` header, no literal `*.md`, exit 0 (nullglob handled it).

- [ ] **Step 4: Commit**

```bash
cd /home/me/machines
git add agents/plugin/hooks/global-memory-load.sh
git commit -m "hook: load memory/personality/ facets by glob

Replaces the single practices.md emit; deterministic alphabetical order,
nullglob-guarded for an empty/missing dir.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Rewire the three symlink mechanisms

Swap each `practices.md` per-file link for a single `memory/personality/` directory link.

**Files:**
- Modify: `modules/home/claude.nix:53`
- Modify: `modules/home/codex.nix:38`
- Modify: `agents/bootstrap.sh:172` and `agents/bootstrap.sh:210`

- [ ] **Step 1: `claude.nix` — directory link**

In `modules/home/claude.nix`, replace line 53:

```nix
    "${profileDir}/memory/practices.md".source = link "${agents}/memory/practices.md";
```

with:

```nix
    "${profileDir}/memory/personality".source = link "${agents}/memory/personality";
```

(`link` is `mkOutOfStoreSymlink`; pointing it at a directory creates one live symlink to that dir. The sibling `global.md` per-file link on line 52 stays as-is — do not convert the whole `memory/` dir to one link.)

- [ ] **Step 2: `codex.nix` — directory link**

In `modules/home/codex.nix`, replace line 38:

```nix
      ".codex/memory/practices.md".source = link "${agents}/memory/practices.md";
```

with:

```nix
      ".codex/memory/personality".source = link "${agents}/memory/personality";
```

- [ ] **Step 3: `bootstrap.sh` — directory link (both profiles)**

In `agents/bootstrap.sh`, replace line 172:

```bash
link "$SRC_DIR/memory/practices.md" "$CLAUDE_DIR/memory/practices.md"
```

with:

```bash
link "$SRC_DIR/memory/personality" "$CLAUDE_DIR/memory/personality"
```

and replace line 210:

```bash
  link "$SRC_DIR/memory/practices.md" "$CODEX_DIR/memory/practices.md"
```

with:

```bash
  link "$SRC_DIR/memory/personality" "$CODEX_DIR/memory/personality"
```

(`link` uses `ln -s`, which symlinks a directory fine; its `-ef`/`-L` idempotency checks work on dir symlinks too.)

- [ ] **Step 4: Verify Nix evaluates**

Run:

```bash
cd /home/me/machines
just quick   # fast syntax check (bash scripts/quick-check.sh)
```

Expected: passes with no eval error mentioning `claude.nix` / `codex.nix`.

- [ ] **Step 5: Verify bootstrap produces the directory symlink**

Run against a throwaway config dir (does not touch the real `~/.claude`):

```bash
cd /home/me/machines
tmp="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$tmp" bash agents/bootstrap.sh >/dev/null 2>&1
echo "--- personality symlink resolves to repo dir ---"
readlink "$tmp/memory/personality"
test "$(readlink -f "$tmp/memory/personality")" = "$(readlink -f agents/memory/personality)" && echo "OK: points at repo personality/" || echo "FAIL"
echo "--- no stray practices.md link created ---"
test ! -e "$tmp/memory/practices.md" && echo "OK: no practices.md" || echo "FAIL"
echo "--- facets visible through the link ---"
ls "$tmp/memory/personality/"
rm -rf "$tmp"
```

Expected: the symlink resolves to `agents/memory/personality`, no `practices.md`, and `ls` shows the four facet files. (`CLAUDE_CONFIG_DIR != ~/.claude` runs the secondary-profile path, which skips Codex — that is fine; the `~/.claude` personality link is what we assert.)

- [ ] **Step 6: Commit**

```bash
cd /home/me/machines
git add modules/home/claude.nix modules/home/codex.nix agents/bootstrap.sh
git commit -m "wire: symlink memory/personality/ dir, drop practices.md per-file link

claude.nix / codex.nix / bootstrap.sh now link the whole personality/
directory (one live symlink) instead of the retired practices.md file.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Update the docs

Point the memory documentation at the new layout.

**Files:**
- Modify: `agents/AGENTS.md`
- Modify: `agents/README.md`

- [ ] **Step 1: `AGENTS.md` — store list + scoping guidance**

In `agents/AGENTS.md`:

- In the "Persistent memory (synced & version-controlled)" section, change the opening enumeration "The memory stores (`memory/global.md`, `memory/practices.md`, and the per-host `host-memory.md`)" to list `memory/global.md`, the `memory/personality/` facets (`tone.md`, `habits.md`, `values.md`, `practices.md`), and the per-host `host-memory.md`.
- In "Recording a memory — pick the scope", add a bullet distinguishing a **fact** (→ `memory/global.md`) from a **behavioral trait** (→ the matching `memory/personality/` facet: outward voice → `tone.md`; a ritual/workflow → `habits.md`; a cross-cutting disposition → `values.md`; a coding-craft opinion → `practices.md`).

- [ ] **Step 2: `README.md` — memory section**

In `agents/README.md`, find the "Memory & knowledge base" section and update any enumeration of the stores to name `memory/personality/` and its four facets instead of a top-level `memory/practices.md`.

- [ ] **Step 3: Verify docs no longer point at the retired path**

Run:

```bash
cd /home/me/machines
echo "--- no doc references a top-level memory/practices.md ---"
grep -nE 'memory/practices\.md' agents/AGENTS.md agents/README.md && echo "FAIL: stale ref" || echo "OK"
echo "--- docs mention personality ---"
grep -nl 'memory/personality' agents/AGENTS.md agents/README.md
```

Expected: `OK` (no stale `memory/practices.md` doc ref), and both docs listed as mentioning `memory/personality`.

- [ ] **Step 4: Commit**

```bash
cd /home/me/machines
git add agents/AGENTS.md agents/README.md
git commit -m "docs: describe memory/personality/ facet layout

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Apply and verify end-to-end

Now that all wiring is committed, apply it and confirm a real session loads the new layout.

**Files:** none (apply + verify).

- [ ] **Step 1: Apply the config**

On this NixOS host, re-link via home-manager:

```bash
cd /home/me/machines
just switch
```

Expected: switch succeeds; `~/.claude/memory/personality` now exists as a symlink and `~/.claude/memory/practices.md` no longer exists (home-manager GCs the removed entry).

- [ ] **Step 2: Verify the live links**

```bash
readlink -f ~/.claude/memory/personality
test ! -e ~/.claude/memory/practices.md && echo "OK: practices.md gone from profile" || echo "FAIL"
ls ~/.claude/memory/personality/
```

Expected: resolves to `~/machines/agents/memory/personality`, no profile `practices.md`, four facet files listed.

- [ ] **Step 3: Verify a session injects the facets**

Simulate the SessionStart hook exactly as the harness calls it:

```bash
bash ~/.claude/skills/cyphy/hooks/global-memory-load.sh "$HOME/.claude" | grep -E '^Personality — |^Global memory|^Per-host'
```

Expected: `Global memory ...`, then `Personality — habits ...`, `Personality — practices ...`, `Personality — tone ...`, `Personality — values ...`, then `Per-host ...` — and no line mentioning a standalone "Code practices" block.

- [ ] **Step 4: Push**

```bash
cd /home/me/machines
git push
```

(Then `git pull` + `just switch` on the other NixOS hosts, or re-run `bootstrap.sh` on non-Nix machines, to propagate — per the repo's sync protocol.)

---

## Notes for the executor

- **No unit-test framework here** — the "tests" are the grep/symlink assertions shown inline. Each is deterministic; treat a `FAIL` print as a red test and fix before committing.
- **Verbatim moves:** when a step says "move a section verbatim," copy the exact existing lines from `global.md`; do not reword. The only edits to moved content are the two called out explicitly (drop the `review-voice.md` provenance clause in `tone.md`; retouch the top comment in `practices.md`).
- **Secondary profile (`~/.claude-work`):** `claude.nix` links both `.claude` and `.claude-work` via `profileFiles`, so the personality dir lands in both automatically — no extra step.
