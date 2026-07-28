# Agent config handover to dotfiles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the agent config that is `$HOME` content *by nature* out of `machines` and into the private dotfiles bare repo, leaving `machines` with only the deployers, the tests, and the fleet-coupled tooling.

**Architecture:** The criterion is a property of the bare-repo design, not a convenience test: dotfiles' work-tree **is** `$HOME`, so a tracked path must be a path that legitimately exists in a home directory. `~/.claude/memory/global.md` is such a path; `agents/tests/bootstrap.test.sh` is not. Content moves to its real path and dotfiles tracks it there; `agents/bootstrap.sh` stops deploying that path and instead fans the *other* profiles (`~/.codex`, `~/.claude-<postfix>`) out at the dotfiles-owned primary. One deployer per path is preserved throughout — dotfiles owns `~/.claude/…`, bootstrap owns everything else.

**Tech stack:** POSIX `sh` (`agents/bootstrap.sh` is `sh`-compatible, not bash), bash test harnesses under `agents/tests/`, git bare-repo invocation, `fleet-selfpull` / `dotfiles-sync` timers.

## Decision this plan enacts

**It reverses `d9b1be4` (committed 2026-07-28, the same day).** That commit recorded `$HOME/CLAUDE.md` as *the* dotfiles agent-memory slot, on the premise that `~/.claude/CLAUDE.md` and `~/.claude/memory/` were unavailable because `bootstrap.sh`'s `link()` does `rm -f "$dest"` on a wrong-target symlink — two deployers on one path. This plan removes bootstrap from those paths entirely, so the premise no longer holds. `$HOME/CLAUDE.md` **stays** what it is today (decision rules that must be ambient in every session under `$HOME`, including work repos); `~/.claude/memory/` becomes the store for everything that should load only in agent sessions. Task 8 records the reversal.

## Global constraints

- **Every dotfiles git command passes both flags:** `git --git-dir=$HOME/.dotfiles --work-tree=$HOME <cmd>`. The `dotfiles` shell wrapper is not loaded in the Bash tool.
- **Never `dotfiles checkout main`** on a live box — host-local files are absent from `main` and the checkout deletes them from `$HOME`, `~/.ssh/config` included. Use a throwaway linked worktree.
- **Never `dotfiles add -A`** — `.gitignore` is allow-only and `add -A` can stage an unlisted file.
- **`cd ~` before any `ls-files` / `status`** — run from a subdirectory of `$HOME` those commands derive a pathspec prefix and list nothing, which looks exactly like an empty checkout.
- **A path is shared XOR host-local** (D5). On `main` ⇒ shared and byte-identical everywhere; absent from `main` ⇒ host-local. Never both. `.gitignore` is the single deliberate exception.
- **Host-local allow-lines carry a leading slash** (`!/.gitconfig`); shared allow-lines do not. Unanchored patterns match at any depth.
- **`git check-ignore -v` exits 0 on a NEGATED match too.** To test trackability use `git --git-dir=$HOME/.dotfiles --work-tree=$HOME add --dry-run <path>` — a refusal means ignored.
- **Never touch the trailing deny block** in `~/.gitignore` (`*.pem`, `*.key`, `id_ed25519*`, `.ssh/id_*`, `.gnupg/`, `.secrets/`). It is last so it wins under last-match-wins.
- **`agents/bootstrap.sh` is `sh`, not bash.** No arrays, no `[[ ]]`, no `local -n`. Follow the existing style; `shellcheck` runs over it in `just quick`.
- **Run `bash agents/tests/bootstrap.test.sh` after every bootstrap edit.** It drives `DRY_RUN=1`, which reads live dirs and writes nothing.
- **`nix` gates cannot run on this box** (air, macOS, no Nix). `modules/home/claude.nix` is touched in Task 8 for comments only; any Nix evaluation is deferred to `latitude` per repo convention.

## Out of scope, with reasons

| Not moved | Why |
|---|---|
| `agents/settings*.json` | Deployed by `copy_managed`, not `link` — already a real file at `~/.claude/settings.json`, deliberately so, because Orca injects an agent-hooks block and Claude itself writes it (`/plugin`, `/config`). The stamp logic re-seeds only when the tracked baseline changes. Handing the path to dotfiles would put the 10-minute sync timer in the middle of that write dance. Separate decision, separate plan. |
| `agents/plugin/**` (incl. all hooks) | Deployed as ONE whole-directory symlink to `~/.claude/skills/cyphy`, and every hook has a test under `agents/plugin/hooks/tests/`. Splitting content from tests across two repos is the cost the criterion refuses to pay here. |
| `ship`, `kb-refresh`, `skills/lib`, `orca-setup`, `orca-repair` | All five have `tests/` dirs and read `fleet.json` or machines paths. Tested fleet tooling. Stays. |
| `agents/subagents/`, `agents/codex/subagents/` | Rides inside the plugin/Codex link topology; no independent value in moving. |
| `modules/home/*.nix`, `provision/lib/tiers.sh` generators | The generator collapse — see `2026-07-28-home-config-generator-collapse.md`. Gated on the latitude wipe, because `modules/home/*` loses its only consumer then. |

## File structure

**Modified in `machines`:**

| Path | Responsibility after this plan |
|---|---|
| `agents/bootstrap.sh` | Deployer for `~/.codex` and `~/.claude-<postfix>` only. Adds `retire_link()`; stops linking the moved paths into the primary profile; sources cross-profile links from the dotfiles-owned primary. |
| `agents/tests/bootstrap.test.sh` | Gains `retire_link` cases and negative assertions that the moved paths are no longer linked into the primary. |
| `agents/AGENTS.md` | Deleted from `machines` (Task 5) — content lands at `~/.claude/CLAUDE.md`. |
| `agents/memory/`, `agents/hosts/` | Deleted from `machines` (Tasks 3, 4). |
| `agents/statusline-command.sh`, `agents/balance-refresh.py` | Deleted from `machines` (Task 7). |
| `agents/plugin/skills/{gortex-align,update-balance,worktree-agent}/` | Deleted from `machines` (Task 6). |
| `agents/README.md`, `.claude/memory/project.md`, `modules/home/claude.nix` | Documentation reconciled to the new ownership split (Task 8). |

**Created in dotfiles (real paths under `$HOME`):**

| Path | Branch | Note |
|---|---|---|
| `.claude/host-memory.md` | machine branch | Host-local by nature — dotfiles is already branch-per-machine. |
| `.claude/memory/global.md` | `main` | |
| `.claude/memory/personality/{tone,habits,values,practices}.md` | `main` | |
| `.claude/CLAUDE.md` | `main` | Agent-session instructions. Distinct from `$HOME/CLAUDE.md`. |
| `.claude/skills/{gortex-align,update-balance,worktree-agent}/SKILL.md` | `main` | Beside the existing real `.claude/skills/dotfiles-promote/SKILL.md`. |
| `.claude/statusline-command.sh`, `.claude/balance-refresh.py` | `main` | |
| `pure/backend-api/.claude/memory/project.md` | `main` | Already tracked; Task 1 merges the orphan into it. |

## The migration hazard, and the ordering it forces

Two failure modes govern every content task:

1. **Checkout collision.** If dotfiles `main` gains `.claude/memory/global.md` while a box still has *anything* untracked at that path (a bootstrap symlink counts), the merge aborts with *"untracked working tree files would be overwritten by merge"* and that box stops syncing. This is exactly what `~/.config/gh/config.yml` did during enrollment — it collided on two of four boxes.
2. **Divergence in the window.** Between "bootstrap stops deploying" and "dotfiles tracks it", each box holds an independent real copy that agents keep writing to. Promote the wrong one and the others' content is silently lost — the documented 11-vs-3 disjoint-bullet merge.

Therefore every content task follows the same five-beat order, and **never** promotes before the fleet has converged:

1. Land the `bootstrap.sh` change in `machines` (symlink → real copy via `copy_managed`, so no memory outage), push.
2. Let `fleet-selfpull` converge, or force it per box. Verify with `ls -l` that the path is a **real file, not a symlink**, on every enrolled box.
3. Gather each box's copy, diff them, merge disjoint content into one authoritative file.
4. On the authoritative box: allow-list, `dotfiles add`, commit, `/dotfiles-promote` to `main`.
5. On every other box: diff its local copy against `main`'s (must be empty after beat 3), then `rm` it so the incoming merge has a clear path.

`server` is **not enrolled** in dotfiles and converge on a Windows box runs `windows.ps1` only, never the dotfiles role. Treat `server` as out of the fleet for beats 2–5 and enroll it separately; do not block on it.

---

### Task 1: Merge the orphaned kan-kan project memory, then delete it

Independent of every other task — no bootstrap change, no fleet ordering. Do it first.

`agents/memory/projects/backend-api.md` is loaded by nothing: `bootstrap.sh` links only `memory/global.md` and `memory/personality`, and no hook reads `memory/projects/`. Its header says `# Project memory — kan-kan`, and `kan-kan` **is** `backend-api` (`~/pure/backend-api/docker/kankan.env`). The dotfiles repo already tracks the live memory for that repo at `pure/backend-api/.claude/memory/project.md`. The two files share **zero** bullets: 71 lines of Qurly / Jira-CFT / Centrifugo facts in `machines`, 72 lines of purchase-crediting / Apple-retention facts in dotfiles.

**Files:**
- Delete: `machines/agents/memory/projects/backend-api.md`
- Modify: `$HOME/pure/backend-api/.claude/memory/project.md` (append three sections)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing later tasks depend on. Task 4 assumes `agents/memory/` contains only `global.md` and `personality/` when it deletes the tree.

- [ ] **Step 1: Confirm the orphan is still orphaned and still disjoint**

```bash
cd /Users/me/machines
grep -rn "memory/projects" agents/bootstrap.sh agents/plugin/hooks/*.sh modules/home/claude.nix
# Expected: no output. Any hit means something loads it — stop and re-plan.

cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME show \
  main:pure/backend-api/.claude/memory/project.md > /tmp/dotfiles-ba.md
diff /tmp/dotfiles-ba.md /Users/me/machines/agents/memory/projects/backend-api.md
# Expected: a full-file diff with no shared bullets (verified 2026-07-28).
```

- [ ] **Step 2: Append the three orphaned sections to the tracked file**

Open `$HOME/pure/backend-api/.claude/memory/project.md` and append the `## Tooling`, `## Product / domain`, `## Jira (CFT project)`, and `## Realtime / Centrifugo` sections **verbatim** from `machines/agents/memory/projects/backend-api.md`, below its existing sections. Keep the tracked file's own header and HTML comment — the orphan's header (`# Project memory — kan-kan`) and comment block are discarded, because the tracked file's comment documents the dotfiles tracking story and the orphan's does not.

Do not paraphrase, reorder, or "improve" the bullets. This is a merge, not an edit.

- [ ] **Step 3: Verify nothing was lost in the merge**

```bash
# Every `- **` bullet from the orphan must now appear in the tracked file.
cd /Users/me/machines
grep -c '^- \*\*' agents/memory/projects/backend-api.md   # note the number, N
grep -c '^- \*\*' $HOME/pure/backend-api/.claude/memory/project.md
# Expected: the second count equals (original tracked count) + N.
```

- [ ] **Step 4: Commit the merge in dotfiles**

Already tracked and already allow-listed (`!pure/backend-api/.claude/memory/project.md`), so this is a one-liner. The 10-minute timer would commit it on its own; committing explicitly keeps the message meaningful.

```bash
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME add pure/backend-api/.claude/memory/project.md
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory(backend-api): merge in the disjoint kan-kan facts orphaned in machines"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push origin air
```

- [ ] **Step 5: Promote to `main` so every box gets it**

The path is already on `main`, so this is a content update, not a new path. Run the `/dotfiles-promote` skill and select `pure/backend-api/.claude/memory/project.md`. Do **not** hand-edit `main` — the skill builds it in a throwaway linked worktree, which is the only safe way (a `checkout main` in `$HOME` would delete every host-local file).

- [ ] **Step 6: Delete the orphan from `machines` and commit**

```bash
cd /Users/me/machines
git rm agents/memory/projects/backend-api.md
rmdir agents/memory/projects   # expected to succeed; if not, something else is in there
git commit -m "refactor(agents): drop the orphaned kan-kan memory — merged into the dotfiles copy

Loaded by nothing (bootstrap links only memory/global.md and
memory/personality). Its content was disjoint from the dotfiles-tracked
pure/backend-api/.claude/memory/project.md and has been merged there."
```

---

### Task 2: `retire_link()` — the transition helper, test-first

Every content task needs to remove a symlink that `bootstrap.sh` used to own. `link()` cannot do it (it only *replaces* a wrong-target link) and `copy_managed()` converts a symlink into a real copy, which is the right first beat but leaves bootstrap still owning the path. `retire_link()` is the final beat: drop a symlink that points into the repo, and leave anything else strictly alone.

Safety property that matters: **it must never delete a real file.** After the handover, the real file at that path is dotfiles-tracked content — deleting it would destroy memory and then get committed by the sync timer.

**Files:**
- Modify: `agents/bootstrap.sh` (add helper beside `copy_managed`)
- Test: `agents/tests/bootstrap.test.sh` (append Case 4)

**Interfaces:**
- Consumes: `$SRC_DIR` (absolute path to `machines/agents`), `_resolve()`, `$DRY_RUN`, the `linked` counter — all already defined in `bootstrap.sh`.
- Produces: `retire_link <abs-dest>` — removes `<abs-dest>` if and only if it is a symlink whose resolved target is inside `$SRC_DIR`. No-op on a real file, on a dangling link, on a symlink pointing elsewhere, and on a missing path. Used by Tasks 3–7.

- [ ] **Step 1: Write the failing test**

Append to `agents/tests/bootstrap.test.sh`:

```bash
# Case 4: retire_link — drops a symlink INTO the repo, never anything else.
# Reuses the lib-only sourcing from Case 3 ($tmp and helpers are already live).
SRC_DIR="$tmp/src"; mkdir -p "$SRC_DIR"
printf 'REPO-CONTENT\n' > "$SRC_DIR/thing.md"

# (a) a symlink into $SRC_DIR is removed.
r_link="$tmp/retire-me.md"; ln -s "$SRC_DIR/thing.md" "$r_link"
retire_link "$r_link" >/dev/null
check "retire_link removes a symlink into the repo" '[ ! -e "$r_link" ] && [ ! -L "$r_link" ]'

# (b) a REAL file is never touched — this is the memory-loss guard.
r_real="$tmp/keep-me.md"; printf 'DOTFILES-OWNED\n' > "$r_real"
retire_link "$r_real" >/dev/null
check "retire_link leaves a real file alone"    '[ -f "$r_real" ]'
check "retire_link preserves real file content" '[ "$(cat "$r_real")" = "DOTFILES-OWNED" ]'

# (c) a symlink pointing OUTSIDE the repo is not ours — leave it.
r_other="$tmp/other-target.md"; printf 'SOMEONE-ELSE\n' > "$r_other"
r_foreign="$tmp/foreign-link.md"; ln -s "$r_other" "$r_foreign"
retire_link "$r_foreign" >/dev/null
check "retire_link leaves a foreign symlink alone" '[ -L "$r_foreign" ]'

# (d) missing path is a silent no-op, not an error.
retire_link "$tmp/does-not-exist.md" >/dev/null
check "retire_link is a no-op on a missing path" '[ $? -eq 0 ]'

# (e) DRY_RUN removes nothing.
r_dry="$tmp/dry-link.md"; ln -s "$SRC_DIR/thing.md" "$r_dry"
DRY_RUN=1 retire_link "$r_dry" >/dev/null
check "retire_link removes nothing under DRY_RUN" '[ -L "$r_dry" ]'
```

- [ ] **Step 2: Run the test and watch Case 4 fail**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

Expected: Cases 1–3 `ok`, every Case 4 line `FAIL` (`retire_link: command not found`), non-zero exit.

- [ ] **Step 3: Implement `retire_link()`**

Add to `agents/bootstrap.sh` immediately after the `copy_managed()` function, before the `BOOTSTRAP_LIB_ONLY` early return (so the tests can source it):

```sh
# retire_link <abs-dest>: remove dest IF AND ONLY IF it is a symlink pointing
# into $SRC_DIR — i.e. a link this script used to own and no longer does. Used
# during the handover of a path from bootstrap to the dotfiles repo: the content
# is already a real file on converged boxes (copy_managed did that), and this
# clears the stale symlink on a box that lagged, so the incoming dotfiles merge
# is not blocked by an untracked path.
#
# NEVER deletes a real file. After the handover the real file at dest IS the
# dotfiles-tracked content; removing it would destroy memory and the 10-minute
# sync timer would then commit the deletion.
retire_link() {
  dest="$1"
  [ -L "$dest" ] || return 0                     # real file, or nothing there
  tgt="$(_resolve "$dest")"
  case "$tgt" in
    "$SRC_DIR"/*) ;;                             # ours — fall through and drop it
    *) return 0 ;;                               # someone else's link
  esac
  if [ -n "${DRY_RUN:-}" ]; then
    printf '  ~ would retire stale link: %s\n' "$dest"
    return 0
  fi
  rm -f "$dest"
  printf '  - retired stale link: %s\n' "$dest"
}
```

- [ ] **Step 4: Run the tests and verify all cases pass**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

Expected: every line `ok`, exit 0. If (c) fails, `_resolve` is following the link before the `case` — confirm `_resolve` is applied to `$dest` and compared against `$SRC_DIR`, and that `$SRC_DIR` in the test has no trailing slash.

- [ ] **Step 5: Lint and commit**

```bash
cd /Users/me/machines
shellcheck agents/bootstrap.sh agents/tests/bootstrap.test.sh
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "feat(agents): add retire_link for handing a path from bootstrap to dotfiles

Drops a symlink pointing into agents/ and nothing else. Explicitly refuses
to delete a real file, because after a handover the real file at that path
is dotfiles-tracked content."
```

---

### Task 3: Hand `~/.claude/host-memory.md` to dotfiles

Per-host memory first: it is the cleanest fit in the whole plan (dotfiles is already branch-per-machine, so host-local is its native mode), it never touches `main`, and it needs no promote — which makes it the safe rehearsal for Tasks 4–7.

It also retires a naming problem. `agents/hosts/` holds **7 files for 5 machines**: `air.md`, `27608.md`, `latitude5520.md`, `g513ie.md`, `g614jv.md`, plus `ME-G614JV.md` (the same physical box as `g614jv` under its native Windows hostname) and `methe-server.md` (stale since the `g513ie` rename). The `$HOST_ID.md` scheme keys on OS-hostname *identity*, not machine; dotfiles' branch-per-machine collapses that to one file per box with no naming convention at all.

**Files:**
- Modify: `agents/bootstrap.sh` (host-memory block, ~line 288-320)
- Modify: `agents/tests/bootstrap.test.sh` (Case 1 assertions invert)
- Delete: `agents/hosts/` (entire directory, after content lands)
- Create in dotfiles: `.claude/host-memory.md` on each machine branch
- Modify in dotfiles: `~/.gitignore` (host-local allow-line, leading slash)

**Interfaces:**
- Consumes: `retire_link` and `copy_managed` from Task 2 / existing bootstrap.
- Produces: `~/.claude/host-memory.md` as a real, dotfiles-tracked file on every enrolled box. `global-memory-load.sh` needs no change — it already reads `$config_dir/host-memory.md`, config-dir-relative.

- [ ] **Step 1: Write the failing test**

Replace Case 1 in `agents/tests/bootstrap.test.sh` with its inverse — bootstrap must no longer seed or link a per-host file into the primary profile, and must no longer consult `MACHINES_HOST_ID` for one:

```bash
# Case 1: per-host memory is dotfiles-owned. bootstrap neither seeds
# agents/hosts/<id>.md nor links anything at ~/.claude/host-memory.md; it only
# retires a stale link there. MACHINES_HOST_ID is no longer consulted.
out1="$(MACHINES_HOST_ID=testhost DRY_RUN=1 CLAUDE_CONFIG_DIR=/tmp/does-not-exist-claude bash "$boot" 2>&1)"
check "no per-host file is seeded in the repo" \
  '! printf "%s" "$out1" | grep -q "hosts/testhost.md"'
check "nothing is linked at host-memory.md" \
  '! printf "%s" "$out1" | grep -qE "would (link|back up \+ link): .*/host-memory.md"'
```

Both assertions are negative, and that is the whole behavioral contract for the primary profile: bootstrap must produce *no* output for this path. The positive half — that a stale link actually gets retired — is Task 2's Case 4(a), which tests `retire_link` directly rather than through a bootstrap run whose output depends on whatever happens to be at the live path.

- [ ] **Step 2: Run the test and watch Case 1 fail**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

Expected: `FAIL - no per-host file is seeded in the repo` and `FAIL - nothing is linked at host-memory.md`, because today's bootstrap does both.

- [ ] **Step 3: Convert the live file to a real copy on every box, before changing bootstrap**

This beat protects content. Run on each enrolled box (`air`, `hub`, `desktop`, `latitude`, and the WSL host `desktop-ubuntu26`):

```bash
# The symlink target is the repo file; copy its content to the real path.
cp -L ~/.claude/host-memory.md /tmp/host-memory.real
rm ~/.claude/host-memory.md
mv /tmp/host-memory.real ~/.claude/host-memory.md
ls -l ~/.claude/host-memory.md   # expect a real file: no `->` in the output
```

Do this per box over SSH (`ssh <logical-name>`), or through `agents/plugin/skills/lib/fleet-dispatch.sh` if you prefer the dispatch primitive. Skip `server` — not enrolled.

- [ ] **Step 4: Track it on each machine's branch**

Per box, still individually (the content differs per box — that is the point):

```bash
cd ~
# 1. allow-list it, host-local, LEADING SLASH (an unanchored line would make a
#    stray .claude/host-memory.md inside any project checkout eligible).
#    Add under the "4b. HOST-LOCAL to this branch" block in ~/.gitignore:
#      !/.claude/host-memory.md
# 2. verify it is now trackable (check-ignore lies on negated matches):
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add --dry-run .claude/host-memory.md
# Expected: the path echoed back, no "ignored by" refusal.
# 3. stage the allow-list change together with the file, per the two-step rule:
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add .gitignore .claude/host-memory.md
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory: track this box's agent host memory (host-local)"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push origin "$(git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD)"
```

**Never promote this path to `main`.** It is host-local by definition, and `main` gaining it would hand every box one machine's memory and then flap.

- [ ] **Step 5: Strip the host-memory block out of bootstrap**

In `agents/bootstrap.sh`, delete the entire per-host block (the `HOST_ID=` assignment, the stub-seeding `if`, the `DRY_RUN` branch, and the `link "$host_src" "$CLAUDE_DIR/host-memory.md"` call) and replace it with:

```sh
# Per-host memory is dotfiles-owned: a real file at ~/.claude/host-memory.md,
# tracked on this machine's dotfiles branch (host-local — it must never reach
# main). bootstrap only clears a stale link from the era when agents/hosts/<id>.md
# was the source, so an unconverged box does not block the dotfiles merge.
retire_link "$CLAUDE_DIR/host-memory.md"
```

Then handle the fan-out. In the Codex block, replace `link "$host_src" "$CODEX_DIR/host-memory.md"` with a link at the dotfiles-owned primary:

```sh
link "$PRIMARY_DIR/host-memory.md" "$CODEX_DIR/host-memory.md"
```

and define `PRIMARY_DIR` once, immediately after `CLAUDE_DIR`:

```sh
# The PRIMARY profile's live dir — always ~/.claude, independent of which profile
# this run is bootstrapping. Dotfiles owns the content inside it; secondary
# profiles and ~/.codex are linked AT it, not at the repo.
#
# It must NOT be derived from CLAUDE_CONFIG_DIR: that variable is how a secondary
# profile run is driven (CLAUDE_CONFIG_DIR=~/.claude-pure), so deriving from it
# would make PRIMARY_DIR equal CLAUDE_DIR on every run and the fan-out guard
# below would never fire. MACHINES_PRIMARY_DIR exists only so the tests can point
# it at a throwaway dir.
PRIMARY_DIR="${MACHINES_PRIMARY_DIR:-$HOME/.claude}"
```

Sanity-check the guard before moving on — a secondary profile must produce a link, the primary must not:

```bash
cd /Users/me/machines
DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude-probe" bash agents/bootstrap.sh | grep host-memory
# Expect: "would link: ~/.claude-probe/host-memory.md -> /Users/me/.claude/host-memory.md"
DRY_RUN=1 bash agents/bootstrap.sh | grep -c "would link.*host-memory"
# Expect: 0
```

For a secondary profile (`POSTFIX` != `default`), add the same link, guarded so the primary never links to itself:

```sh
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link "$PRIMARY_DIR/host-memory.md" "$CLAUDE_DIR/host-memory.md"
fi
```

Note `host_id()` may now be unused. Leave the function in place — `provision/` and `modules/home/claude.nix` also reason about host identity; removing it is a separate cleanup. Confirm with `grep -rn 'host_id\|MACHINES_HOST_ID' agents/ modules/ provision/` and only delete if there is exactly one definition and no other caller.

- [ ] **Step 6: Run the tests, then a real dry run**

```bash
cd /Users/me/machines
bash agents/tests/bootstrap.test.sh          # expect all ok
shellcheck agents/bootstrap.sh
DRY_RUN=1 bash agents/bootstrap.sh | grep -i host
# Expect: no "would link" for host-memory.md. On this box the real file already
# exists, so no retire line either.
```

- [ ] **Step 7: Delete `agents/hosts/` and commit**

```bash
cd /Users/me/machines
git rm -r agents/hosts
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "refactor(agents): hand per-host memory to dotfiles

~/.claude/host-memory.md is now a real file tracked on each machine's
dotfiles branch — host-local by nature, which is dotfiles' native mode.
bootstrap only retires the stale link and points ~/.codex at the primary.
Retires the \$HOST_ID.md naming scheme: agents/hosts/ held 7 files for 5
machines (ME-G614JV/g614jv were one box under two OS hostnames,
methe-server predated the g513ie rename)."
git push
```

- [ ] **Step 8: Converge the fleet and verify**

```bash
# Per box: pull machines, run bootstrap, confirm the real file survived.
ssh <box> 'cd ~/machines && git pull --ff-only && bash agents/bootstrap.sh >/dev/null && ls -l ~/.claude/host-memory.md'
# Expected on every box: a real file (no `->`), content intact.
```

If any box shows a symlink, `retire_link` did not fire — check that its `~/machines` actually pulled and that `_resolve` returns an absolute path there.

---

### Task 4: Hand `~/.claude/memory/global.md` and the personality facets to dotfiles

The highest-churn content in `machines` (48 commits on `global.md`) and the one with the real divergence risk, because agents write to it at runtime on five boxes.

**Files:**
- Modify: `agents/bootstrap.sh` (memory block, ~line 284-287, plus the Codex block)
- Modify: `agents/tests/bootstrap.test.sh` (add Case 5)
- Delete: `agents/memory/` (entire directory, after content lands)
- Create in dotfiles on `main`: `.claude/memory/global.md`, `.claude/memory/personality/{tone,habits,values,practices}.md`
- Modify in dotfiles: `~/.gitignore` (shared allow-lines, no leading slash)

**Interfaces:**
- Consumes: `retire_link`, `PRIMARY_DIR` (both from Tasks 2–3).
- Produces: real dotfiles-tracked files at `~/.claude/memory/global.md` and `~/.claude/memory/personality/*.md`, with `~/.codex/memory/*` and any secondary profile symlinked at them. `global-memory-load.sh` is unchanged — it globs `$config_dir/memory/personality/*.md`, which resolves identically through a real dir.

- [ ] **Step 1: Write the failing test**

Append Case 5 to `agents/tests/bootstrap.test.sh`:

```bash
# Case 5: the shared memory store is dotfiles-owned. bootstrap links nothing
# from agents/memory into the primary profile, and points Codex at the primary.
out5="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "nothing links agents/memory into the primary profile" \
  '! printf "%s" "$out5" | grep -qE "\.claude/memory/(global\.md|personality)"'
check "codex memory is sourced from the primary profile, not the repo" \
  '! printf "%s" "$out5" | grep -E "\.codex/memory" | grep -q "machines/agents/memory"'
```

- [ ] **Step 2: Run the test and watch Case 5 fail**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

Expected: both Case 5 lines `FAIL` — today bootstrap links `memory/global.md` and `memory/personality` into `~/.claude/memory/`, and links Codex straight at `$SRC_DIR`.

- [ ] **Step 3: Convert to real copies on every box**

```bash
cd ~/.claude/memory
cp -L global.md /tmp/global.real && rm global.md && mv /tmp/global.real global.md
# personality is a DIRECTORY symlink — replace it with a real dir of real files.
cp -rL personality /tmp/personality.real && rm personality && mv /tmp/personality.real personality
ls -l ~/.claude/memory ~/.claude/memory/personality   # expect no `->` anywhere
```

Run on every enrolled box. Skip `server`.

- [ ] **Step 4: Reconcile the five copies into one authoritative file**

This is the beat that prevents silent memory loss. Collect each box's copy and diff:

```bash
mkdir -p /tmp/global-gather
for box in air hub desktop latitude desktop-ubuntu26; do
  scp "$box":~/.claude/memory/global.md "/tmp/global-gather/$box.md" 2>/dev/null \
    || echo "SKIP $box (unreachable)"
done
cd /tmp/global-gather && for f in *.md; do echo "=== $f"; diff air.md "$f" | head -40; done
```

Any box-specific bullet that is *not* on `air` must be merged into the authoritative copy before the promote. This is the same procedure that recovered 11 and 3 disjoint bullets during enrollment — do not skip it because the files "look the same". If a bullet is genuinely host-specific, it belongs in that box's `~/.claude/host-memory.md` (Task 3), not in the shared file.

- [ ] **Step 5: Track and promote to `main`**

```bash
cd ~
# Allow-list under the shared block in ~/.gitignore — NO leading slash, matching
# the other shared allow-lines:
#   !.claude/memory/global.md
#   !.claude/memory/personality/tone.md
#   !.claude/memory/personality/habits.md
#   !.claude/memory/personality/values.md
#   !.claude/memory/personality/practices.md
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add --dry-run .claude/memory/global.md
# Expected: echoed back, not refused.
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add .gitignore .claude/memory
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "memory: track the shared agent memory store at its real path"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push origin air
```

Then run `/dotfiles-promote` and select all five paths. The skill will also report the `.gitignore` drift — promote **only** the five `!.claude/memory/…` lines it names, never the whole file (`~/.gitignore` is the one deliberate shared-XOR-host exception and carries `air`'s private host-local lines).

- [ ] **Step 6: Clear the path on every other box**

Per non-authoritative box, after the promote:

```bash
diff <(ssh <box> 'cat ~/.claude/memory/global.md') /tmp/global-gather/air.md
# Expected: empty, because Step 4 merged everything. If NOT empty, stop —
# go back to Step 4; the incoming merge would overwrite unmerged content.
ssh <box> 'rm -rf ~/.claude/memory/global.md ~/.claude/memory/personality'
```

The next `dotfiles-sync` tick (≤10 min) merges `main` in and materializes them. Verify:

```bash
ssh <box> 'ls -l ~/.claude/memory ~/.claude/memory/personality && head -3 ~/.claude/memory/global.md'
```

- [ ] **Step 7: Strip the memory block out of bootstrap**

Replace the three lines in `agents/bootstrap.sh`:

```sh
_mkdir "$CLAUDE_DIR/memory"
link "$SRC_DIR/memory/global.md" "$CLAUDE_DIR/memory/global.md"
link "$SRC_DIR/memory/personality" "$CLAUDE_DIR/memory/personality"
```

with:

```sh
# The shared memory store is dotfiles-owned: real files at
# ~/.claude/memory/{global.md,personality/*.md}, tracked on the dotfiles repo's
# main branch. bootstrap only clears links from the era when agents/memory/ was
# the source. Secondary profiles and ~/.codex are linked AT the primary below.
_mkdir "$CLAUDE_DIR/memory"
retire_link "$CLAUDE_DIR/memory/global.md"
retire_link "$CLAUDE_DIR/memory/personality"
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link "$PRIMARY_DIR/memory/global.md"  "$CLAUDE_DIR/memory/global.md"
  link "$PRIMARY_DIR/memory/personality" "$CLAUDE_DIR/memory/personality"
fi
```

And in the Codex block, repoint both links from the repo to the primary:

```sh
_mkdir "$CODEX_DIR/memory"
link "$PRIMARY_DIR/memory/global.md"  "$CODEX_DIR/memory/global.md"
link "$PRIMARY_DIR/memory/personality" "$CODEX_DIR/memory/personality"
```

- [ ] **Step 8: Test, verify Codex still resolves, delete the tree, commit**

```bash
cd /Users/me/machines
bash agents/tests/bootstrap.test.sh          # expect all ok
shellcheck agents/bootstrap.sh
bash agents/bootstrap.sh >/dev/null
# The end-to-end property: Codex reads the dotfiles-owned file through the link.
readlink ~/.codex/memory/global.md           # expect /Users/me/.claude/memory/global.md
head -3 ~/.codex/memory/global.md            # expect the real content
git rm -r agents/memory
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "refactor(agents): hand the shared memory store to dotfiles

~/.claude/memory/{global.md,personality/} are now real files tracked on the
dotfiles repo's main branch. bootstrap retires its links and points ~/.codex
and any secondary profile at the primary profile instead of at the repo, so
exactly one deployer owns each path and runtime memory writes land in one file
rather than diverging across N copies."
git push
```

- [ ] **Step 9: Converge the fleet and verify no box lost memory**

```bash
for box in air hub desktop latitude desktop-ubuntu26; do
  echo "=== $box"
  ssh "$box" 'cd ~/machines && git pull --ff-only >/dev/null && bash agents/bootstrap.sh >/dev/null;
              ls -l ~/.claude/memory/global.md; wc -l ~/.claude/memory/global.md;
              ls -l ~/.codex/memory/global.md 2>/dev/null'
done
```

Expected per box: `~/.claude/memory/global.md` a real file with the full line count; `~/.codex/memory/global.md` a symlink to it.

---

### Task 5: Hand `~/.claude/CLAUDE.md` (from `agents/AGENTS.md`) to dotfiles

`agents/AGENTS.md` is the canonical agent instruction file, linked to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. It is `$HOME` content by nature, on the same footing as the memory store.

**Keep the two `CLAUDE.md` files straight.** `$HOME/CLAUDE.md` (already on dotfiles `main`) is ambient in **every** session under `$HOME`, work repos included, so it holds only decision rules. `~/.claude/CLAUDE.md` loads in agent sessions regardless of cwd. They are different slots with different costs; this task fills the second one and leaves the first alone.

**Files:**
- Modify: `agents/bootstrap.sh` (the `link "$SRC_DIR/AGENTS.md"` calls, two of them)
- Modify: `agents/tests/bootstrap.test.sh` (add Case 6)
- Delete: `agents/AGENTS.md`
- Create in dotfiles on `main`: `.claude/CLAUDE.md`

**Interfaces:**
- Consumes: `retire_link`, `PRIMARY_DIR`.
- Produces: `~/.claude/CLAUDE.md` as a real dotfiles-tracked file; `~/.codex/AGENTS.md` symlinked at it.

- [ ] **Step 1: Write the failing test**

Append Case 6:

```bash
# Case 6: agent instructions are dotfiles-owned; Codex reads the primary's copy.
out6="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "no link from agents/AGENTS.md into the primary profile" \
  '! printf "%s" "$out6" | grep -q "agents/AGENTS.md"'
```

- [ ] **Step 2: Run the test and watch Case 6 fail**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

Expected: `FAIL - no link from agents/AGENTS.md into the primary profile`.

- [ ] **Step 3: Convert to a real file, reconcile, track, promote**

```bash
# Per box, as in Task 4 Step 3:
cp -L ~/.claude/CLAUDE.md /tmp/claude-md.real && rm ~/.claude/CLAUDE.md && mv /tmp/claude-md.real ~/.claude/CLAUDE.md
```

The file is repo-sourced and identical on every box (it is not agent-written at runtime like `global.md`), so a single `diff` across two boxes is sufficient reconciliation:

```bash
diff <(ssh latitude 'cat ~/.claude/CLAUDE.md') ~/.claude/CLAUDE.md   # expect empty
```

Then track on `air` with a shared (unanchored) allow-line `!.claude/CLAUDE.md`, commit, and `/dotfiles-promote` it to `main` — same mechanics as Task 4 Step 5.

- [ ] **Step 4: Repoint bootstrap**

Replace:

```sh
link "$SRC_DIR/AGENTS.md" "$CLAUDE_DIR/CLAUDE.md"
```

with:

```sh
# Agent instructions are dotfiles-owned (~/.claude/CLAUDE.md, tracked on main).
# Distinct from $HOME/CLAUDE.md, which is ambient in every session under $HOME.
retire_link "$CLAUDE_DIR/CLAUDE.md"
if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
  link "$PRIMARY_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
fi
```

and in the Codex block replace `link "$SRC_DIR/AGENTS.md" "$CODEX_DIR/AGENTS.md"` with:

```sh
link "$PRIMARY_DIR/CLAUDE.md" "$CODEX_DIR/AGENTS.md"
```

- [ ] **Step 5: Clear the path on the other boxes, then delete and commit**

Per box: `ssh <box> 'rm -f ~/.claude/CLAUDE.md'` (its content is now on `main` and byte-identical), then wait for the sync tick and confirm the file reappears as tracked content.

```bash
cd /Users/me/machines
bash agents/tests/bootstrap.test.sh && shellcheck agents/bootstrap.sh
bash agents/bootstrap.sh >/dev/null
readlink ~/.codex/AGENTS.md          # expect /Users/me/.claude/CLAUDE.md
git rm agents/AGENTS.md
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "refactor(agents): hand agent instructions to dotfiles

~/.claude/CLAUDE.md is now a real file on the dotfiles repo's main branch;
~/.codex/AGENTS.md links at it. Distinct slot from \$HOME/CLAUDE.md, which
stays ambient-everywhere decision rules."
git push
```

Note: `machines/AGENTS.md` at the repo root is a **different file** (the repo's own agent instructions, symlinked to `machines/CLAUDE.md`). Do not touch it.

---

### Task 6: Move the three untested skills to dotfiles

Skills split cleanly on a testable line: **has `tests/` ⇒ tested fleet tooling ⇒ stays in `machines`; no `tests/` ⇒ content-only ⇒ dotfiles.** Verified: `kb-refresh`, `lib`, `orca-repair`, `orca-setup`, and `ship` have `tests/`; `gortex-align`, `update-balance`, and `worktree-agent` do not. The rule also happens to keep every `fleet.json` reader in `machines`, so no skill is separated from either its tests or its fleet coupling.

Precedent for the destination: `.claude/skills/dotfiles-promote/SKILL.md` is already a real dotfiles-tracked file sitting beside the `cyphy` plugin symlink inside `~/.claude/skills/`, so a real directory there does not collide with the plugin.

Invocation names change: `/cyphy:gortex-align` becomes `/gortex-align` (user-scope, not plugin-scope). That is a user-visible change worth confirming before executing this task.

**Files:**
- Delete: `agents/plugin/skills/gortex-align/`, `update-balance/`, `worktree-agent/`
- Create in dotfiles on `main`: `.claude/skills/{gortex-align,update-balance,worktree-agent}/` (full directory contents, not just `SKILL.md`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: three user-scope skills. Nothing else references them by plugin-qualified name — verify in Step 1.

- [ ] **Step 1: Verify no cross-reference and no hidden test**

```bash
cd /Users/me/machines
for s in gortex-align update-balance worktree-agent; do
  echo "=== $s"
  find "agents/plugin/skills/$s" -type f          # note every file, not just SKILL.md
  grep -rn "cyphy:$s" --include='*.md' --include='*.sh' --include='*.json' . | grep -v "skills/$s/"
done
```

Expected: no `tests/` dir under any of the three, and no `cyphy:<name>` reference outside the skill's own directory. Any hit means something invokes the plugin-qualified name and must be updated in the same commit.

- [ ] **Step 2: Copy each skill to its real `$HOME` path**

```bash
for s in gortex-align update-balance worktree-agent; do
  mkdir -p "$HOME/.claude/skills/$s"
  cp -r "/Users/me/machines/agents/plugin/skills/$s/." "$HOME/.claude/skills/$s/"
done
find $HOME/.claude/skills/gortex-align $HOME/.claude/skills/update-balance $HOME/.claude/skills/worktree-agent -type f
```

- [ ] **Step 3: Verify the skills load from the new location before deleting the old**

```bash
claude -p 'List the skills available to you whose names start with gortex-align, update-balance, or worktree-agent. Answer with names only.'
```

Expected: all three named, unqualified. The plugin copy is still present at this point, so a duplicate-name warning is acceptable — what matters is that the user-scope copy is discovered.

- [ ] **Step 4: Track and promote**

Add one unanchored allow-line per file to `~/.gitignore` under the shared block (one line per file, as the allow-list requires — `!.claude/skills/gortex-align/SKILL.md` and so on for every file found in Step 1), then:

```bash
cd ~
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add --dry-run .claude/skills/gortex-align/SKILL.md
git --git-dir=$HOME/.dotfiles --work-tree=$HOME add .gitignore .claude/skills
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "skills: track the three untested user-scope skills at their real paths"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push origin air
```

Then `/dotfiles-promote` the skill files and only the `!.claude/skills/…` allow-lines.

- [ ] **Step 5: Delete from `machines` and commit**

```bash
cd /Users/me/machines
git rm -r agents/plugin/skills/gortex-align agents/plugin/skills/update-balance agents/plugin/skills/worktree-agent
git commit -m "refactor(agents): move the three untested skills to dotfiles

Split on a testable line: a skill with tests/ is fleet tooling and stays here
(ship, kb-refresh, lib, orca-setup, orca-repair — all of which also read
fleet.json); a skill without tests is $HOME content and belongs in dotfiles.
Invocation changes from /cyphy:<name> to /<name> (user scope)."
git push
```

- [ ] **Step 6: Confirm on a second box after its sync tick**

```bash
ssh latitude 'ls ~/.claude/skills/ && head -4 ~/.claude/skills/gortex-align/SKILL.md'
```

---

### Task 7: Move `statusline-command.sh` and `balance-refresh.py` to dotfiles

Both are plain `link()`ed whole files with no tests, referenced from `settings.json` by `$HOME`-relative path (`"command": "bash \"$HOME/.claude/statusline-command.sh\""`), so the reference keeps working with no settings change.

**Files:**
- Modify: `agents/bootstrap.sh` (the shared whole-file `for` loop, ~line 255-257)
- Modify: `agents/tests/bootstrap.test.sh` (add Case 7)
- Delete: `agents/statusline-command.sh`, `agents/balance-refresh.py`
- Create in dotfiles on `main`: `.claude/statusline-command.sh`, `.claude/balance-refresh.py`

**Interfaces:**
- Consumes: `retire_link`, `PRIMARY_DIR`.
- Produces: both files as real dotfiles-tracked executables at `~/.claude/`.

- [ ] **Step 1: Write the failing test**

```bash
# Case 7: statusline + balance refresh are dotfiles-owned.
out7="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "statusline is not linked from the repo" \
  '! printf "%s" "$out7" | grep -q "agents/statusline-command.sh"'
check "balance-refresh is not linked from the repo" \
  '! printf "%s" "$out7" | grep -q "agents/balance-refresh.py"'
```

- [ ] **Step 2: Run the test and watch Case 7 fail**

```bash
cd /Users/me/machines && bash agents/tests/bootstrap.test.sh
```

- [ ] **Step 3: Convert to real files and confirm the executable bit**

```bash
cd ~/.claude
for f in statusline-command.sh balance-refresh.py; do
  cp -L "$f" "/tmp/$f.real" && rm "$f" && mv "/tmp/$f.real" "$f" && chmod +x "$f"
done
ls -l statusline-command.sh balance-refresh.py   # expect real files, mode with x
```

git records the executable bit as `100755`, so it survives the checkout on other boxes.

- [ ] **Step 4: Verify the statusline still renders**

```bash
bash "$HOME/.claude/statusline-command.sh" </dev/null
```

Expected: the usual status line (or its no-input fallback), not `No such file or directory`.

- [ ] **Step 5: Track, promote, repoint bootstrap**

Track on `air` with unanchored allow-lines `!.claude/statusline-command.sh` and `!.claude/balance-refresh.py`, commit, `/dotfiles-promote` both.

Then replace the loop in `agents/bootstrap.sh`:

```sh
for f in statusline-command.sh balance-refresh.py; do
  link "$SRC_DIR/$f" "$CLAUDE_DIR/$f"
done
```

with:

```sh
# statusline + balance refresh are dotfiles-owned real files at ~/.claude/.
# settings.json references them as "$HOME/.claude/statusline-command.sh", so the
# reference is unchanged. Secondary profiles link at the primary.
for f in statusline-command.sh balance-refresh.py; do
  retire_link "$CLAUDE_DIR/$f"
  if [ "$CLAUDE_DIR" != "$PRIMARY_DIR" ]; then
    link "$PRIMARY_DIR/$f" "$CLAUDE_DIR/$f"
  fi
done
```

- [ ] **Step 6: Clear other boxes, delete, commit**

```bash
# Per box: content is identical and now on main, so just clear the path.
ssh <box> 'rm -f ~/.claude/statusline-command.sh ~/.claude/balance-refresh.py'

cd /Users/me/machines
bash agents/tests/bootstrap.test.sh && shellcheck agents/bootstrap.sh
git rm agents/statusline-command.sh agents/balance-refresh.py
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "refactor(agents): hand statusline + balance refresh to dotfiles

Real files at ~/.claude/, tracked on main. settings.json already referenced
them via \$HOME, so no settings change is needed."
git push
```

- [ ] **Step 7: Verify on a second box after its sync tick**

```bash
ssh latitude 'ls -l ~/.claude/statusline-command.sh && bash ~/.claude/statusline-command.sh </dev/null | head -2'
```

---

### Task 8: Reconcile the documentation and record the reversal

The ownership split now differs from what four documents describe. Every one of them is load-bearing: three are injected into live sessions.

**Files:**
- Modify: `agents/README.md` — the "Memory & knowledge base" section and the SHARED-set list
- Modify: `machines/CLAUDE.md` — the `agents/` module table row and the memory-store description
- Modify: `machines/.claude/memory/project.md` — the dotfiles bullets
- Modify: `modules/home/claude.nix` — header comment (comments only; no Nix evaluation on this box)
- Modify: `$HOME/CLAUDE.md` (dotfiles `main`) — the memory-scope routing table
- Modify: `~/.claude/memory/global.md` (dotfiles `main`) — the "Recording a memory — pick the scope" wiring section

**Interfaces:**
- Consumes: the final state of Tasks 1–7.
- Produces: documentation that matches reality. No code depends on it.

- [ ] **Step 1: Establish the ground truth to document**

```bash
cd /Users/me/machines
grep -n "retire_link\|^link \|link \"\$PRIMARY_DIR\|copy_managed \|link_entries_into " agents/bootstrap.sh
```

Write the resulting list down — it is the authoritative "what bootstrap still deploys" inventory, and every doc edit below must agree with it.

- [ ] **Step 2: Rewrite the ownership story in `agents/README.md`**

State the criterion and the split explicitly, so the next agent does not re-derive it:

> **Who owns what.** Dotfiles' work-tree is `$HOME`, so any file whose rightful home is a path under `$HOME` is tracked there, at that path: `~/.claude/CLAUDE.md`, `~/.claude/memory/{global.md,personality/}`, `~/.claude/host-memory.md`, `~/.claude/skills/{gortex-align,update-balance,worktree-agent}/`, `~/.claude/statusline-command.sh`, `~/.claude/balance-refresh.py`. `machines` keeps what has no `$HOME` path: this bootstrap script, the tests, and the fleet-coupled plugin (`ship`, `kb-refresh`, `lib`, `orca-setup`, `orca-repair` — all tested, all reading `fleet.json`).
>
> **One deployer per path.** Dotfiles owns everything inside `~/.claude`. `bootstrap.sh` owns `~/.codex` and each `~/.claude-<postfix>`, and it links those **at the primary profile**, never at this repo. `retire_link()` clears a link left over from the old arrangement and refuses to delete a real file.
>
> Exception: `settings.json` stays `copy_managed` from this repo, because Orca and Claude both write the live file and the stamp logic keeps that machine-local.

Also correct the SHARED-set list — it currently names the moved files.

- [ ] **Step 3: Correct `machines/CLAUDE.md`**

The repo-overview file describes `hermes/` as carrying `memories/` and implies `agents/` carries the memory stores. Update the `agents/` description to the deployer-and-tests role, and note that `hermes/memories/` is empty (Task 8 does not fill it; flag it as an unfilled slot or delete it in a follow-up).

- [ ] **Step 4: Rewrite the dotfiles bullets in `.claude/memory/project.md` and record the reversal**

Replace the bullet that says `~/.claude/CLAUDE.md` and `~/.claude/memory/` are unavailable-because-two-deployers, and add:

```markdown
- **Agent config content lives in dotfiles, not `machines` (2026-07-28).** The
  criterion is a property of the bare repo: its work-tree IS `$HOME`, so a
  tracked path must be a path that legitimately exists in a home directory.
  `~/.claude/{CLAUDE.md,memory/global.md,memory/personality/,host-memory.md,
  statusline-command.sh,balance-refresh.py}` and the three untested skills are
  dotfiles-tracked at those paths; `machines` keeps `bootstrap.sh`, the tests,
  and the fleet-coupled plugin. **This REVERSES `d9b1be4`**, which had recorded
  `$HOME/CLAUDE.md` as the only available agent-memory slot on the premise that
  bootstrap's `link()` would fight dotfiles for `~/.claude/…`. bootstrap no
  longer touches those paths — it only `retire_link()`s stale links and fans
  `~/.codex` / `~/.claude-<postfix>` out AT the primary profile. `$HOME/CLAUDE.md`
  keeps its own distinct job: decision rules that must be ambient in every
  session under `$HOME`, work repos included.
- **A skill with `tests/` stays in `machines`; a skill without moves to dotfiles.**
  The line coincides exactly with fleet coupling — every `fleet.json` reader is
  tested — so no skill is separated from its tests or its manifest.
- **`agents/hosts/` is gone.** Per-host memory is `~/.claude/host-memory.md`,
  host-local on each dotfiles branch. The old `$HOST_ID.md` scheme keyed on
  OS-hostname identity and had drifted to 7 files for 5 machines.
```

- [ ] **Step 5: Update the two dotfiles-tracked memory documents**

In `$HOME/CLAUDE.md` and `~/.claude/memory/global.md`, the "Recording a memory — pick the scope" section still routes global memory to `~/.claude/memory/global.md` *as a symlink into `machines`* and says an edit "is a plain write to the git-tracked repo file". Both statements are now wrong in their mechanism and right in their conclusion: the file is still directly writable and still needs no `just switch`, but it is tracked in **dotfiles**, and propagation is `git pull` in dotfiles (or just waiting for the 10-minute timer), not in `machines`. Correct the mechanism, keep the conclusion.

These are dotfiles-tracked files on `main` — edit them in place and promote, do not edit them in `machines`.

- [ ] **Step 6: Commit both repos**

```bash
cd /Users/me/machines
git add agents/README.md CLAUDE.md .claude/memory/project.md modules/home/claude.nix
git commit -m "docs: record the agent-config handover to dotfiles

Documents the criterion (dotfiles' work-tree is \$HOME, so a tracked path
must be a real home-directory path), the one-deployer-per-path split, the
tested-skill line, and the reversal of d9b1be4."
git push

cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME add CLAUDE.md .claude/memory/global.md
git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "docs: correct the memory-scope wiring after the handover"
git --git-dir=$HOME/.dotfiles --work-tree=$HOME push origin air
```

Then `/dotfiles-promote` both paths (`CLAUDE.md` is already on `main`; `.claude/memory/global.md` landed there in Task 4).

- [ ] **Step 7: Final fleet verification**

```bash
for box in air hub desktop latitude desktop-ubuntu26; do
  echo "=== $box"
  ssh "$box" 'ls -l ~/.claude/CLAUDE.md ~/.claude/host-memory.md ~/.claude/memory/global.md \
                     ~/.claude/statusline-command.sh 2>&1 | sed "s|/Users/me|~|;s|/home/me|~|"
              cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME status --short
              cat ~/.local/state/dotfiles-sync/conflict 2>/dev/null && echo "CONFLICT MARKER PRESENT"'
done
```

Expected per box: four real files (no `->`), a clean dotfiles status, no conflict marker. A conflict marker means a box still had an untracked path when `main` arrived — clear the path and let the next tick retry.

---

## Follow-ups deliberately not in this plan

- **`server` is not enrolled in dotfiles.** It needs a manual enrollment before it can receive any of this; converge on a Windows box runs `windows.ps1` only, never the dotfiles role.
- **`hermes/`** (`config.yaml`, `SOUL.md`, `skills/`, `profile`) is the same shape as `agents/` with its own `bootstrap.sh` and an **empty** `memories/`. Same decision, deferred so this plan stays one subsystem.
- **`agents/settings*.json`** — the `copy_managed` question. Needs its own decision about who owns a file that Orca, Claude, and a git timer all write.
- **The generator collapse** — `modules/home/*.nix` (me.nix 41 commits, ssh.nix 13, claude.nix 20, zed-bin 11, codex.nix 9) and `tier_git_base` / `tier_ssh_accounts` / `tier_shell_init` exist to *render* `$HOME` content (`~/.gitconfig`, `~/.ssh/config`, `~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`, ghostty, starship, zed). Under this plan's criterion the artifact is dotfiles and the renderer collapses to "install the tool, mint the keys" — key generation (`~/.ssh/id_<user>`, `~/.ssh/id_fleet`) is irreducible because keys are never tracked. Gated on the latitude wipe, which removes `modules/home/*`'s only consumer. See `2026-07-28-home-config-generator-collapse.md`.
