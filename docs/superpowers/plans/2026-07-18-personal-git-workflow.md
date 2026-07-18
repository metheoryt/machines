# Personal Git Workflow Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Claude one coherent, self-enforcing git workflow for the personal fleet-sync repos — commit-to-branch, auto-sync, and offer-FF-merge-back inside worktrees — instead of the scattered, contradictory notes it follows today.

**Architecture:** A single canonical doc (`agents/docs/git-workflow.md`) is the one source of truth. A SessionStart hook (`agents/plugin/hooks/worktree-workflow.sh`) fires only in a linked worktree whose `origin` is not blocklisted, prints live `main`↔branch divergence, and surfaces (cats) the doc's worktree-mode section — it never restates rules and never mutates git. The old scattered notes become pointers to the doc.

**Tech Stack:** Bash (hooks + tests), `git` worktree plumbing, `jq` (reads session JSON on stdin, already used by sibling hooks), Markdown. No new dependencies.

## Global Constraints

- **Hooks always `exit 0`.** Every path — detection failure, git error, missing doc — must exit 0 so a session never fails to start.
- **Single source of truth.** The workflow rules live ONLY in `agents/docs/git-workflow.md`. The hook and the memory notes surface or point to it; they never restate the rules.
- **Sync = merge, never rebase.** Worktree branches are Orca-tracked; rewriting them is unsafe.
- **Merge-back runs in the base checkout**, `git -C <base-checkout> merge --ff-only <branch>`, guarded by base-checkout-on-`main`-and-clean. Non-FF merge and the `main` push are always user-gated.
- **`main`↔`origin` is left to Orca** — the hook never pulls `main` and never compares `main` to `origin`.
- **Blocklist, not allowlist.** Fire by default in any linked worktree; skip only when `git remote get-url origin` matches a blocklist pattern. Initial blocklist entry: `thepureapp` (the Pure GitHub org, `github.com:thepureapp/*`).
- **Base branch defaults to the repo default branch** (`origin/HEAD`, else `main`).
- **Doc path is resolved physically from the hook's own location** (`cd -P` on `dirname "${BASH_SOURCE[0]}"`, then `../../docs/git-workflow.md`) so it works through the plugin symlink in every profile — do NOT rely on `CLAUDE_PLUGIN_ROOT`.
- **Worktree-mode section delimiters** in the doc are exactly `<!-- WORKTREE-MODE:START -->` and `<!-- WORKTREE-MODE:END -->`, each on its own line. The hook and the Task 1 test both depend on these literal strings.
- **Commit on this branch** (`git-worktree-orca-setup`), never on `main` — this plan practices the workflow it builds.

---

### Task 1: Canonical framework doc

**Files:**
- Create: `agents/docs/git-workflow.md`
- Test: `agents/plugin/hooks/tests/git-workflow-doc.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `agents/docs/git-workflow.md` containing a worktree-mode block delimited by `<!-- WORKTREE-MODE:START -->` / `<!-- WORKTREE-MODE:END -->`. Task 2's hook extracts that block with `sed -n '/START/,/END/p'`.

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/hooks/tests/git-workflow-doc.test.sh`:

```bash
#!/usr/bin/env bash
# The hook depends on being able to extract a non-empty worktree-mode section
# from the canonical doc. Assert that contract.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/../../../docs/git-workflow.md"

sec="$(sed -n '/<!-- WORKTREE-MODE:START -->/,/<!-- WORKTREE-MODE:END -->/p' "$DOC" 2>/dev/null)"

if [ -n "$sec" ] && printf '%s' "$sec" | grep -q 'merge --ff-only'; then
  echo "PASS worktree-mode section extractable and contains the merge-back command"
  exit 0
else
  echo "FAIL worktree-mode section missing/empty at $DOC"
  exit 1
fi
```

Note the path: test is at `agents/plugin/hooks/tests/`, doc at `agents/docs/` → `../../../docs/git-workflow.md`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/hooks/tests/git-workflow-doc.test.sh`
Expected: `FAIL worktree-mode section missing/empty …` (the doc does not exist yet).

- [ ] **Step 3: Create the doc**

Create `agents/docs/git-workflow.md`:

```markdown
# Personal git workflow

The one framework for git in the personal fleet-sync repos
(`github.com:metheoryt/*` — machines, vps, …). One model: **`main` is the shared
truth; you push to `main`, no review.** Two modes, picked by where you are.

Work repos (`github.com:thepureapp/*`) are NOT covered by this — they use the
pure-dev PR-for-approval flow.

## Main-checkout mode — on `main` in the canonical clone

- Commit on `main`.
- Ready / small change → commit + push `main`.
- Big or risky work → spawn a worktree and switch to worktree mode.

## Worktree mode — a feature branch in a linked worktree

<!-- WORKTREE-MODE:START -->
You are on a feature branch in a linked worktree. `main` lives in the base
checkout, not here.

- **Commit on the branch, never on `main`.** Do not push `main` from the worktree.
- **Stay current — auto-sync `main` → branch.** When the working tree is clean,
  the branch is behind `main`, and the merge is conflict-free, run `git merge main`
  in the worktree to catch up. On a dirty tree or a conflict, stop and ask. Always
  **merge, never rebase** (these branches are Orca-tracked). Keeping local `main`
  current with `origin` is Orca's job — don't pull `main` or worry about `main`
  vs `origin`.
- **Integrate — offer FF merge-back at checkpoints.** When the work is complete
  and tests pass, *offer* (never automatic) to merge the branch back into `main`.
  It must run in the **base checkout** (git refuses to update `main` from another
  worktree):

      git -C <base-checkout> merge --ff-only <branch>

  First check the base checkout is on `main` and clean; if not, report and defer.
  Because you kept syncing `main` in, this is a fast-forward. If `--ff-only` is
  refused (main diverged independently), stop and ask — do a real merge only with
  explicit OK.
- **Finish.** After a clean merge-back, offer to push `main` and to remove the
  worktree (`git worktree remove` + delete the branch). Both user-gated.
<!-- WORKTREE-MODE:END -->

---
*Enforcement: `agents/plugin/hooks/worktree-workflow.sh` surfaces the worktree
section above (plus live divergence) at session start in a non-blocklisted linked
worktree. This doc is the single source of truth — the hook and the memory notes
point here, they do not restate the rules.*
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/hooks/tests/git-workflow-doc.test.sh`
Expected: `PASS worktree-mode section extractable and contains the merge-back command`

- [ ] **Step 5: Add doc + tests dir to the allow-list and commit**

`agents/.gitignore` may be allow-only; ensure the new paths are tracked, then commit on the branch:

```bash
git add agents/docs/git-workflow.md agents/plugin/hooks/tests/git-workflow-doc.test.sh
git status --porcelain   # confirm both files are staged (not ignored)
git commit -m "docs(git-workflow): canonical personal git workflow doc"
```

If `git status` shows a file still untracked/ignored, add a `!`-allow line for it in `agents/.gitignore`, `git add agents/.gitignore`, and re-run the commit.

---

### Task 2: The worktree-workflow hook + test harness

**Files:**
- Create: `agents/plugin/hooks/worktree-workflow.sh`
- Test: `agents/plugin/hooks/tests/worktree-workflow.test.sh`

**Interfaces:**
- Consumes: `agents/docs/git-workflow.md` (Task 1) — cats the section between the `WORKTREE-MODE` delimiters.
- Produces: an executable SessionStart hook. On stdin it reads `{"cwd": "..."}` (session JSON, like the sibling hooks). On stdout: nothing when it should stay silent; otherwise a header, a live-state block, and the doc's worktree-mode section. Exit code always 0.

- [ ] **Step 1: Write the failing test harness**

Create `agents/plugin/hooks/tests/worktree-workflow.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior tests for worktree-workflow.sh — builds throwaway repos + worktrees,
# runs the hook with a fake session JSON on stdin, asserts on output.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../worktree-workflow.sh"
fail=0
tmp="$(mktemp -d)"
trap 'git worktree prune 2>/dev/null; rm -rf "$tmp"' EXIT

run_hook() { printf '{"cwd":"%s"}' "$1" | bash "$HOOK"; }

make_repo() { # $1 = dir, $2 = origin url (may be empty)
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
  [ -n "$2" ] && git -C "$1" remote add origin "$2"
  return 0
}

# Case 1: linked worktree, personal (non-blocklisted) remote -> fires
r1="$tmp/personal"; make_repo "$r1" "git@github.com:metheoryt/machines.git"
git -C "$r1" branch feat
git -C "$r1" worktree add -q "$tmp/personal-wt" feat
out="$(run_hook "$tmp/personal-wt")"
if printf '%s' "$out" | grep -q "worktree branch : feat" \
   && printf '%s' "$out" | grep -q "WORKTREE-MODE"; then
  echo "PASS case1 fires in personal worktree"
else
  echo "FAIL case1"; printf '%s\n' "$out"; fail=1
fi

# Case 2: base checkout of the same repo -> silent
out="$(run_hook "$r1")"
if [ -z "$out" ]; then echo "PASS case2 silent in base checkout"
else echo "FAIL case2 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

# Case 3: linked worktree, blocklisted remote -> silent
r3="$tmp/work"; make_repo "$r3" "git@github.com:thepureapp/backend-api.git"
git -C "$r3" branch feat
git -C "$r3" worktree add -q "$tmp/work-wt" feat
out="$(run_hook "$tmp/work-wt")"
if [ -z "$out" ]; then echo "PASS case3 silent for blocklisted remote"
else echo "FAIL case3 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

# Case 4: plain non-git dir -> silent
mkdir "$tmp/plain"
out="$(run_hook "$tmp/plain")"
if [ -z "$out" ]; then echo "PASS case4 silent outside git"
else echo "FAIL case4 (expected empty)"; printf '%s\n' "$out"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `bash agents/plugin/hooks/tests/worktree-workflow.test.sh`
Expected: FAIL (the hook file does not exist yet; case1 fails and the run exits non-zero — likely `case1` FAIL plus `bash: … worktree-workflow.sh: No such file or directory`).

- [ ] **Step 3: Implement the hook**

Create `agents/plugin/hooks/worktree-workflow.sh`:

```bash
#!/usr/bin/env bash
# Claude Code SessionStart hook — surface the personal git worktree-mode workflow.
#
# Fires ONLY when cwd is a LINKED git worktree whose `origin` remote is not on the
# blocklist. Prints live main<->branch divergence + the worktree-mode section of
# the canonical doc (agents/docs/git-workflow.md). Runs no git-mutating command.
# Always exits 0 so it can never block a session from starting.
set -u

# Remotes to stay silent for (work repos with their own PR flow).
BLOCKLIST=(thepureapp)

# Session JSON arrives on stdin; pull cwd, fall back to $PWD.
cwd="$(jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Must be inside a git repo.
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Must be a LINKED worktree: absolute git-dir differs from the common git-dir.
gd="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common="$(cd "$cwd" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)" || exit 0
[ -n "$common" ] || exit 0
[ "$gd" != "$common" ] || exit 0

# origin must not be blocklisted.
origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
for pat in "${BLOCKLIST[@]}"; do
  case "$origin" in *"$pat"*) exit 0 ;; esac
done

# --- live state ---
branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
base="$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
base="${base#origin/}"
[ -n "$base" ] || base="main"
base_checkout="$(dirname "$common")"

counts="$(git -C "$cwd" rev-list --left-right --count "$base...HEAD" 2>/dev/null)"
behind="$(printf '%s' "$counts" | awk '{print $1}')"
ahead="$(printf '%s' "$counts" | awk '{print $2}')"
[ -n "$behind" ] || behind="?"
[ -n "$ahead" ] || ahead="?"

if [ -z "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
  clean="clean"
else
  clean="DIRTY (uncommitted changes — do not auto-sync)"
fi

# --- canonical rules (single source of truth) ---
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
doc="$script_dir/../../docs/git-workflow.md"

printf 'You are in a git WORKTREE of a personal fleet-sync repo — worktree-mode git rules apply.\n\n'
printf 'Live state:\n'
printf '  worktree branch : %s\n' "$branch"
printf '  base branch     : %s (checked out at %s)\n' "$base" "$base_checkout"
printf '  divergence      : %s behind, %s ahead of local %s\n' "$behind" "$ahead" "$base"
printf '  working tree    : %s\n\n' "$clean"

if [ -f "$doc" ]; then
  sed -n '/<!-- WORKTREE-MODE:START -->/,/<!-- WORKTREE-MODE:END -->/p' "$doc"
else
  printf '(canonical rules doc not found at %s)\n' "$doc"
fi

exit 0
```

- [ ] **Step 4: Make the hook executable and run the harness to verify it passes**

Run:
```bash
chmod +x agents/plugin/hooks/worktree-workflow.sh
bash agents/plugin/hooks/tests/worktree-workflow.test.sh
```
Expected: four `PASS …` lines then `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/hooks/worktree-workflow.sh agents/plugin/hooks/tests/worktree-workflow.test.sh
git status --porcelain   # confirm both staged; if ignored, add !-allow lines to agents/.gitignore and re-add
git commit -m "feat(hooks): worktree-workflow SessionStart hook (blocklist-gated)"
```

---

### Task 3: Register the hook in `hooks.json` and verify live

**Files:**
- Modify: `agents/plugin/hooks/hooks.json`

**Interfaces:**
- Consumes: `agents/plugin/hooks/worktree-workflow.sh` (Task 2).
- Produces: the hook runs at every SessionStart, after the existing three.

- [ ] **Step 1: Add the registration**

Edit `agents/plugin/hooks/hooks.json` — add a fourth entry to the `SessionStart` `hooks` array, after `project-memory-check.sh`. The array becomes:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gortex-onboard-check.sh\""
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/global-memory-load.sh\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\""
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/project-memory-check.sh\""
          },
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/worktree-workflow.sh\""
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate the JSON**

Run: `jq -e '.hooks.SessionStart[0].hooks | length == 4' agents/plugin/hooks/hooks.json`
Expected: prints `true`, exit 0.

- [ ] **Step 3: Integration check — run the hook against this real worktree**

Run: `printf '{"cwd":"%s"}' "$PWD" | bash agents/plugin/hooks/worktree-workflow.sh`
Expected: the header + live state showing `worktree branch : git-worktree-orca-setup`, `base branch : main`, a `<N> behind, <M> ahead of local main` line, working-tree status, then the worktree-mode section from the doc.

- [ ] **Step 4: Integration check — confirm silence in the base checkout**

Run: `printf '{"cwd":"/home/me/machines"}' | bash agents/plugin/hooks/worktree-workflow.sh; echo "exit=$?"`
Expected: no output, `exit=0` (the base checkout is not a linked worktree).

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/hooks/hooks.json
git commit -m "feat(hooks): register worktree-workflow at SessionStart"
```

---

### Task 4: Reconcile the scattered notes → point at the doc

**Files:**
- Modify: `.claude/memory/project.md` (in this repo, machines' repo-local memory)
- Modify: `agents/memory/global.md`

**Interfaces:**
- Consumes: `agents/docs/git-workflow.md` (Task 1) as the pointer target.
- Produces: no code; removes the unqualified "push to main" instruction that misfired in worktrees, and adds a discoverable pointer.

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/hooks/tests/notes-reconciled.test.sh`:

```bash
#!/usr/bin/env bash
# The scattered "work directly on main / straight to main" instruction must be
# scoped to main-checkout mode, and both memory files must point at the doc.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"   # repo root (…/machines worktree)
fail=0

pm="$ROOT/.claude/memory/project.md"
gm="$ROOT/agents/memory/global.md"

grep -q 'git-workflow.md' "$pm" || { echo "FAIL project.md missing doc pointer"; fail=1; }
grep -q 'main-checkout' "$pm" || { echo "FAIL project.md not scoped to main-checkout mode"; fail=1; }
grep -q 'git-workflow.md' "$gm" || { echo "FAIL global.md missing doc pointer"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS notes reconciled" || true
exit $fail
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/hooks/tests/notes-reconciled.test.sh`
Expected: `FAIL project.md missing doc pointer` (and the global.md line), exit 1.

- [ ] **Step 3: Rewrite the project.md workflow bullet**

In `.claude/memory/project.md`, under `## Workflow`, replace the existing "Sync through git (2026-07-15)…" bullet with:

```markdown
- **Git workflow — one framework, see `agents/docs/git-workflow.md`.** `main` is
  the fleet-sync truth. **Main-checkout mode** (on `main` in `~/machines`): commit
  on `main`, push when ready; big/isolated work → spawn a worktree. **Worktree
  mode** (Orca worktrees): the `worktree-workflow` SessionStart hook injects the
  live rules — commit on the branch (never `main`), auto-sync `main`→branch, offer
  a fast-forward merge-back into `main` from the base checkout at checkpoints.
```

- [ ] **Step 4: Add the global.md pointer**

In `agents/memory/global.md`, add under a `## Git workflow` heading (create it if absent):

```markdown
## Git workflow

- **Personal fleet-sync repos use one framework:** `machines/agents/docs/git-workflow.md`
  (one model, two modes — main-checkout / worktree). In a non-blocklisted linked
  worktree the `worktree-workflow` hook surfaces the worktree-mode rules + live
  `main`↔branch divergence. Work repos (`github.com:thepureapp/*`) are excluded —
  they keep the pure-dev PR flow.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash agents/plugin/hooks/tests/notes-reconciled.test.sh`
Expected: `PASS notes reconciled`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add .claude/memory/project.md agents/memory/global.md agents/plugin/hooks/tests/notes-reconciled.test.sh
git status --porcelain   # confirm staged; if the test file is ignored, add a !-allow line to agents/.gitignore
git commit -m "docs(memory): point git-workflow notes at the canonical doc"
```

---

## Final verification (run after all tasks)

- [ ] Run all three test scripts; expect every one to exit 0:

```bash
for t in agents/plugin/hooks/tests/git-workflow-doc.test.sh \
         agents/plugin/hooks/tests/worktree-workflow.test.sh \
         agents/plugin/hooks/tests/notes-reconciled.test.sh; do
  echo "== $t =="; bash "$t"; echo "exit=$?"
done
```

- [ ] `bash scripts/quick-check.sh` (or `just quick`) still passes — no unrelated breakage.
- [ ] Confirm all commits landed on `git-worktree-orca-setup`, none on `main`: `git log --oneline main..HEAD`.
