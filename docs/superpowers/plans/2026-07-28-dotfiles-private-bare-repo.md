# Dotfiles: private bare repo, branch-per-machine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the private `metheoryt/dotfiles` bare repo the single engine for `$HOME` configuration across the fleet — branch per machine, a 10-minute sync timer, an explicit `promote` step — and retire chezmoi.

**Architecture:** `~/.dotfiles` is a bare git repo whose work-tree is `$HOME`. Each box checks out a branch named by its **logical fleet name**. A timer (`provision/dotfiles-sync.sh`, installed by the rewritten `dotfiles` provision role) commits tracked changes to that branch, pushes, and fast-forwards `origin/main` in — but only after a `git merge-tree --write-tree` preflight proves the merge is conflict-free, because the work-tree is live `$HOME`. Moving content the other way (branch → `main`) is a manual `/dotfiles-promote` skill that builds `main` in a throwaway linked worktree and never switches the `$HOME` work-tree.

**Tech Stack:** bash, PowerShell, git (bare-repo technique), systemd user units / launchd LaunchAgents / `schtasks`, Claude Code plugin hooks.

**Source spec:** `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

**Decisions carried verbatim from spec §3:**

| # | Decision |
|---|---|
| D1 | Single engine: private `metheoryt/dotfiles`, bare repo, work-tree `$HOME`. chezmoi retired. |
| D2 | Branch per machine, branched from `main`, named by **logical fleet name** (not OS hostname). |
| D3 | Tracked-or-not = the existing **allow-only `.gitignore`**. Unchanged in mechanism. |
| D4 | Shared-or-host = **derived from git**, not stored. On `main` ⇒ shared; absent ⇒ host-local. No routing manifest. |
| D5 | **Invariant: a path is shared XOR host-local.** Never both. No per-host overrides of a shared path. |
| D6 | Autocommit always targets the **machine branch**. No decision at commit time. |
| D7 | Sync is **timer-driven** (10 min), reusing the `fleet-selfpull` idiom. Not a filesystem watcher. |
| D8 | `promote` is **manual and explicit**. Never automatic. |
| D9 | Secrets: **rotatable credentials yes, private keys never.** The `.gitignore` ban block stays. |
| D10 | A `PostToolUse` hook **proactively offers** to track a homeless `$HOME` file. Declines are **session-scoped**, no persisted state. |
| D11 | The `promote` skill lives in the **dotfiles repo** (`~/.claude/skills/dotfiles-promote/`), tracked on `main`. The sync script stays in `machines`. |

**Hard safety properties — violating any of these is a plan failure:**

- **The sync script never leaves a conflict on disk.** The work-tree is `$HOME`; `<<<<<<<` markers in a live `~/.ssh/config` can lock the user out of their own fleet. Conflict detection happens in the object store (`merge-tree --write-tree`) *before* any working file changes.
- **`git merge-tree --write-tree` requires git ≥ 2.38.** Below that floor the sync script must **commit and push only, never merge**. A preflight that silently does not preflight is the exact failure the design exists to prevent.
- **The promote flow never switches the `$HOME` work-tree.** `checkout main` would delete every host-local file from `$HOME`. Promote uses a throwaway linked worktree.
- **`add -u` only.** Never `add -A` / `add .` anywhere in the sync path. New files are invisible to the timer by design.

**Naming — logical fleet names (spec §4.1), used as branch names:**

| logical | OS hostname | platform |
|---|---|---|
| `latitude` | `latitude5520` | nixos |
| `air` | `air` | darwin |
| `desktop` | `g614jv` | windows |
| `server` | `g513ie` | windows |
| `hub` | `27608` | debian |

**Scope note — self-declared WSL hosts.** They carry a gitignored `fleet.local.json` and never appear in `fleet.json`, so they have no logical/OS-hostname pair — their nickname *is* their identity. Spec §4.1 names them in the resolution chain, so Task 1 implements it and Task 6 wires the `linux.sh` workstation path. They are not in the enrollment list (Task 15); enrolling one is a later, separate act.

**Two tracks, do not interleave:**

- **Track A (Tasks 1–9)** — the `machines` repo. Testable in isolation, no effect on any remote.
- **Track B (Tasks 10–15)** — the `dotfiles` repo. Every Track B task must land **before any box is enrolled**, and `latitude` is enrolled **last** (Task 15) because it is the only box running an active deleter (`modules/home/ssh.nix`).

---

## File Structure

**Created in `machines`:**

| Path | Responsibility |
|---|---|
| `provision/dotfiles-sync.sh` | The timer body (posix). Lock → guard → commit → push → fetch → preflight → merge. |
| `provision/dotfiles-sync.ps1` | Windows twin of the above. |
| `provision/dotfiles-sync.test.sh` | Unit tests for the sync script against a scratch bare repo + temp `$HOME`. |
| `provision/tests/fleet-logical-name.test.sh` | Unit tests for `fleet_logical_name`. |
| `agents/plugin/hooks/dotfiles-offer.sh` | `PostToolUse` hook — offers to track a homeless `$HOME` file. |
| `agents/plugin/hooks/tests/dotfiles-offer.test.sh` | Table-driven tests over the hook's decision branches. |

**Modified in `machines`:**

| Path | Change |
|---|---|
| `provision/lib/fleet.sh` | Add `fleet_logical_name`. |
| `provision/roles/dotfiles.sh` | Rewrite: chezmoi → bare repo. Runs on **all** platforms including nixos. |
| `provision/roles/dotfiles.ps1` | Same rewrite, Windows side. |
| `provision/lib/tiers.sh` | Add `tier_dotfiles` (bootstrap) + `tier_dotfiles_sync` (timer). |
| `provision/linux.sh` | Add `dotfiles` to the `workstation` tier list (self-declared WSL path). |
| `provision/windows.ps1` | Register the `dotfiles-sync` scheduled task. |
| `provision/tests/roles.test.sh` | Invert the nixos `dotfiles` assertion; keep the `agents` one. |
| `agents/plugin/hooks/hooks.json` | Add the `PostToolUse` block (none exists today). |
| `.claude/memory/project.md` | Replace the chezmoi bullets. |
| `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md` | Mark superseded. |

**Deleted from `machines`:**

| Path | Why |
|---|---|
| `dotfiles/dot_gitconfig.tmpl` | chezmoi source; drifted hard from live `~/.gitconfig` (spec §9.4). Deleted in Task 9. |
| `dotfiles/pure/backend-api/dot_claude/memory/project.md` | Moves into the dotfiles repo. Deleted in **Task 11**, not Task 9 — it is the source Task 11 copies from, and the two tasks will not run in the same session. |
| `scripts/retire-dotfiles-husk.sh` | Deletes the very `~/.dotfiles` this plan reinstates. Loaded footgun. |
| `agents/tests/retire-dotfiles-husk.test.sh` | Its test. |

**Created / modified in the `dotfiles` repo (`main`):**

| Path | Change |
|---|---|
| `.gitignore` | D9 rewrite: rotatable credentials move ban → allow. Remove `.ssh/config`. |
| `.ssh/config` | **Deleted from `main`** — home-manager-owned on latitude, therefore host-local under D5. |
| `pure/backend-api/.claude/memory/project.md` | Moved from `machines`, provenance header rewritten. |
| `.claude/skills/dotfiles-promote/SKILL.md` | The promote skill (D11). |
| `README.md`, `CLAUDE.md` | Rewrite: logical-name branches, derived shared/host rule, sync timer, promote. |

---

# Track A — the `machines` repo

## Task 1: `fleet_logical_name`

The branch name resolver. Spec §4.1's chain: `fleet.local.json` `.self.nickname` if present, else `fleet_detect` (fleet.json lookup by OS hostname).

Must work **without jq** — `hub` ships python3 but no jq, and `fleet_profile_for_host` (`provision/lib/fleet.sh:60-80`) already carries a dual-path fallback for exactly this reason.

**Files:**
- Modify: `provision/lib/fleet.sh` (append after `fleet_profile_for_host`)
- Test: `provision/tests/fleet-logical-name.test.sh`

**Interfaces:**
- Consumes: `_fleet_lib_dir`, `fleet_detect` (both already in `provision/lib/fleet.sh`)
- Produces: `fleet_logical_name [repo]` — echoes the logical fleet name on stdout, returns 0. Returns 1 and echoes nothing when neither source resolves. `repo` defaults to the repo root inferred from `${BASH_SOURCE[0]}`.

- [ ] **Step 1: Write the failing test**

Create `provision/tests/fleet-logical-name.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for fleet_logical_name (provision/lib/fleet.sh).
#
# The branch name the dotfiles repo checks out comes from here, so a wrong
# answer puts a machine's commits on another machine's branch. Two sources,
# in priority order: a self-declared fleet.local.json nickname, then the
# fleet.json lookup by OS hostname.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision/lib/fleet.sh
source "$HERE/../lib/fleet.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$2" = "$3" ] && pass "$1" || die "$1: got '$2', want '$3'"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# A throwaway repo root carrying only the two manifests the resolver reads.
mkdir -p "$T/repo"
cat > "$T/repo/fleet.json" <<'JSON'
{"machines":{"air":{"platform":"darwin","roles":[],"detect":{"hostname":"air"}}}}
JSON

# 1. fleet.local.json nickname wins — it is the only identity a self-declared
#    WSL host has, and such a host has no fleet.json entry at all.
cat > "$T/repo/fleet.local.json" <<'JSON'
{"self":{"nickname":"wsl-g614jv","fleet":true,"platform":"linux"}}
JSON
eq "fleet.local.json nickname wins" "$(fleet_logical_name "$T/repo")" "wsl-g614jv"

# 2. No fleet.local.json => fall through to the fleet.json hostname lookup.
#    Asserted against fleet_detect's own answer rather than a hardcoded name, so
#    the test proves the FALL-THROUGH happened without depending on what this
#    box is actually called.
rm "$T/repo/fleet.local.json"
eq "falls back to fleet_detect" \
   "$(fleet_logical_name "$T/repo" 2>/dev/null || echo NONE)" \
   "$(fleet_detect 2>/dev/null || echo NONE)"

# 3. A fleet.local.json with no .self.nickname must NOT resolve to the empty
#    string — it must fall through, or the caller would check out branch "".
echo '{"other":1}' > "$T/repo/fleet.local.json"
out="$(fleet_logical_name "$T/repo" 2>/dev/null || true)"
[ "$out" != "" ] && pass "empty nickname falls through" || die "empty nickname returned empty (would check out branch '')"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

Test 2 uses a shell-function `hostname` override, which only works if `fleet_hostname` resolves `hostname` through the shell. It does — `fleet_hostname` calls `$(hostname)` unqualified. If the override proves not to take effect in your shell, replace test 2 with a direct call: `eq "falls back to fleet_detect" "$(fleet_logical_name "$T/repo" 2>/dev/null || echo NONE)" "$(cd "$T/repo" && fleet_detect 2>/dev/null || echo NONE)"` — it still proves the fall-through path is taken.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/fleet-logical-name.test.sh`
Expected: FAIL — `fleet_logical_name: command not found`

- [ ] **Step 3: Implement `fleet_logical_name`**

Append to `provision/lib/fleet.sh`:

```bash
# fleet_logical_name [repo]: this box's LOGICAL fleet name — the dotfiles branch
# it checks out (spec 2026-07-28 §4.1). Resolution chain, in order:
#   1. <repo>/fleet.local.json .self.nickname — self-declared WSL hosts, which
#      are first-class fleet members but never appear in fleet.json. The
#      nickname IS their identity (tailnet node name and branch name alike).
#   2. fleet_detect — the fleet.json lookup by OS hostname.
# Echoes nothing and returns 1 when neither resolves; callers must treat that as
# "do not check out a branch", never as an empty branch name.
#
# jq-optional, like fleet_profile_for_host: hub ships python3 but no jq. The sed
# fallback is last-resort and only has to survive the one-line shape this repo's
# own fleet-local.sh writes.
fleet_logical_name() {
    local repo="${1:-}" f n
    [ -n "$repo" ] || repo="$(_fleet_lib_dir)/../.."
    f="$repo/fleet.local.json"
    if [ -f "$f" ]; then
        if command -v jq >/dev/null 2>&1; then
            n="$(jq -r '.self.nickname // empty' "$f" 2>/dev/null)"
        elif command -v python3 >/dev/null 2>&1; then
            n="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("self", {}).get("nickname", ""))
except Exception:
    pass' "$f" 2>/dev/null)"
        else
            n="$(sed -n 's/.*"nickname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
        fi
        if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi
    fi
    fleet_detect
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/tests/fleet-logical-name.test.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Lint**

Run: `shellcheck provision/lib/fleet.sh provision/tests/fleet-logical-name.test.sh && bash -n provision/lib/fleet.sh`
Expected: clean (or only pre-existing warnings in `fleet.sh` unrelated to the new function)

- [ ] **Step 6: Commit**

```bash
git add provision/lib/fleet.sh provision/tests/fleet-logical-name.test.sh
git commit -m "feat(fleet): add fleet_logical_name — the dotfiles branch resolver"
```

---

## Task 2: `dotfiles-sync.sh` — lock, guard, commit, push

The first half of the timer body (spec §5.1 steps 0–3). Split from the merge half (Task 3) because a reviewer can meaningfully accept "it commits to the right branch and never to the wrong one" while still rejecting the merge safety story.

The guard reads the expected branch from a **state file** written once by the role (Task 6), not by resolving fleet identity at runtime. That keeps the timer independent of jq and of the `machines` repo being present at all.

**Files:**
- Create: `provision/dotfiles-sync.sh`
- Test: `provision/dotfiles-sync.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks. Task 6 will write `$DOTFILES_STATE_DIR/branch`.
- Produces, for Task 3 and Task 6:
  - Env contract: `DOTFILES_GIT_DIR` (default `$HOME/.dotfiles`), `DOTFILES_WORK_TREE` (default `$HOME`), `DOTFILES_STATE_DIR` (default `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync`).
  - `DOTFILES_SYNC_LIB_ONLY=1` sources the helpers without running a tick (mirrors `FLEET_SELFPULL_LIB_ONLY`).
  - `df <git-args…>` — git wrapper binding the git-dir/work-tree pair.
  - `git_has_mergetree` — returns 0 when git ≥ 2.38.
  - `sync_lock` — returns 0 if this process holds the lock, non-zero if another tick does.
  - `sync_guard` — echoes the expected branch, returns 0 ok / 1 hard stop / 3 silent skip.
  - `sync_commit <branch>` — returns 0 whether or not anything was committed.
  - `sync_push <branch>` — always returns 0; a push failure is non-fatal.
  - `sync_tick` — the whole tick. Exit status: 0 normal, 1 hard stop (wrong branch / merge in progress).

- [ ] **Step 1: Write the failing test**

Create `provision/dotfiles-sync.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for provision/dotfiles-sync.sh against a scratch bare "remote" and
# a temp $HOME. Nothing here touches the real ~/.dotfiles or the real remote.
#
# The property under test is not "does it sync" but "can it ever damage $HOME".
# The work-tree is a live home directory, so every case asserts on what is left
# ON DISK, not just on exit status.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dotfiles-sync.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$2" = "$3" ] && pass "$1" || die "$1: got '$2', want '$3'"; }

# setup: fresh remote + bare clone + machine branch 'air' + branch state file.
# Echoes the temp root. Every test gets its own.
setup() {
  local T S
  T="$(mktemp -d)"
  git init -q --bare "$T/remote.git"
  git init -q -b main "$T/seed"
  printf 'original\n' > "$T/seed/.tracked"
  printf '*\n!*/\n!.gitignore\n!.tracked\n' > "$T/seed/.gitignore"
  git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .tracked
  git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$T/seed" push -q "$T/remote.git" main

  mkdir -p "$T/home" "$T/state"
  git clone -q --bare "$T/remote.git" "$T/home/.dotfiles"
  local g=(git --git-dir="$T/home/.dotfiles" --work-tree="$T/home")
  "${g[@]}" config status.showUntrackedFiles no
  "${g[@]}" config user.email t@t
  "${g[@]}" config user.name t
  "${g[@]}" checkout -q -b air main
  "${g[@]}" push -q -u origin air
  echo air > "$T/state/branch"
  echo "$T"
}

# tick <root> [extra-env…]: run one sync tick against that root. Echoes exit code.
tick() {
  local T="$1"; shift
  DOTFILES_GIT_DIR="$T/home/.dotfiles" \
  DOTFILES_WORK_TREE="$T/home" \
  DOTFILES_STATE_DIR="$T/state" \
  HOME="$T/home" \
  "$@" bash "$SCRIPT" >"$T/out" 2>"$T/err"
  echo $?
}

dfx() { local T="$1"; shift; git --git-dir="$T/home/.dotfiles" --work-tree="$T/home" "$@"; }

# ── 1. Clean tick is a no-op ─────────────────────────────────────────────────
T="$(setup)"
before="$(dfx "$T" rev-parse air)"
rc="$(tick "$T")"
eq "clean tick: exit 0" "$rc" "0"
eq "clean tick: no new commit" "$(dfx "$T" rev-parse air)" "$before"
rm -rf "$T"

# ── 2. Dirty tick commits the change and pushes it ───────────────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
rc="$(tick "$T")"
eq "dirty tick: exit 0" "$rc" "0"
eq "dirty tick: committed" "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "dirty tick: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
rm -rf "$T"

# ── 3. Wrong branch: exit non-zero having committed NOTHING ──────────────────
# Guards against a stray `checkout main` turning the timer into a machine that
# force-feeds host-local content onto the shared branch.
T="$(setup)"
dfx "$T" checkout -q main
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse main)"
rc="$(tick "$T")"
[ "$rc" != "0" ] && pass "wrong branch: non-zero exit" || die "wrong branch: exited 0"
eq "wrong branch: nothing committed" "$(dfx "$T" rev-parse main)" "$before"
eq "wrong branch: work-tree untouched" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 4. No repo / no branch state: silent skip, exit 0 ────────────────────────
T="$(setup)"
rm -rf "$T/home/.dotfiles"
eq "missing repo: exit 0" "$(tick "$T")" "0"
rm -rf "$T"

T="$(setup)"
rm -f "$T/state/branch"
eq "missing branch state: exit 0" "$(tick "$T")" "0"
rm -rf "$T"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/dotfiles-sync.test.sh`
Expected: FAIL — `bash: .../dotfiles-sync.sh: No such file or directory`

- [ ] **Step 3: Implement the lock/guard/commit/push half**

Create `provision/dotfiles-sync.sh`:

```bash
#!/usr/bin/env bash
# provision/dotfiles-sync.sh — the dotfiles sync timer body.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.1
#
# ~/.dotfiles is a BARE repo whose work-tree is $HOME. Every 10 minutes this
# commits tracked changes to this machine's branch, pushes them, and merges
# origin/main in.
#
# THE GOVERNING SAFETY PROPERTY: the work-tree is a live home directory. A
# conflicted merge would write <<<<<<< markers into ~/.ssh/config, ~/.gitconfig,
# ~/.netrc — breaking ssh and git, possibly including the ability to fix it
# remotely. This script must never leave a conflict on disk and must never start
# a merge it cannot finish. That is what step 5 (merge-tree preflight) buys.
#
# EXIT STATUS: 0 for every normal outcome, INCLUDING a detected conflict and a
# failed push — both are expected states that recur each tick, and a non-zero
# there would just paint the timer permanently red. Non-zero means a hard stop
# that needs a human: HEAD on the wrong branch, or a merge/rebase left in
# progress.
#
# Testable: `DOTFILES_SYNC_LIB_ONLY=1 source` loads helpers without a tick.
set -u

: "${DOTFILES_GIT_DIR:=$HOME/.dotfiles}"
: "${DOTFILES_WORK_TREE:=$HOME}"
: "${DOTFILES_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync}"

# Never block on a credential/host prompt (mirrors fleet-selfpull.sh).
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=10}"
export GIT_SSH_COMMAND

# df <git-args…>: git bound to the bare-repo / $HOME work-tree pair.
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$DOTFILES_WORK_TREE" "$@"; }

# git_has_mergetree: `merge-tree --write-tree` landed in git 2.38. Below that
# floor there is NO way to detect a conflict without writing markers to disk
# first, so the merge step must be skipped entirely rather than attempted.
git_has_mergetree() {
    local v maj min rest
    v="$(git --version 2>/dev/null | awk '{print $3}')"
    maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
    case "$maj" in ''|*[!0-9]*) return 1 ;; esac
    case "$min" in ''|*[!0-9]*) return 1 ;; esac
    [ "$maj" -gt 2 ] && return 0
    [ "$maj" -eq 2 ] && [ "$min" -ge 38 ]
}

# sync_lock: 0 if we hold the lock, non-zero if another tick does. macOS ships
# no flock(1), so fall back to an atomic mkdir. A lock dir older than 30 minutes
# is stale by construction (the timer fires every 10 and its work takes seconds),
# so sweep it rather than wedging the timer forever after a kill -9.
sync_lock() {
    mkdir -p "$DOTFILES_STATE_DIR"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$DOTFILES_STATE_DIR/lock" || return 1
        flock -n 9
        return
    fi
    local d="$DOTFILES_STATE_DIR/lock.d"
    if [ -d "$d" ] && [ -z "$(find "$d" -maxdepth 0 -mmin -30 2>/dev/null)" ]; then
        rmdir "$d" 2>/dev/null || true
    fi
    mkdir "$d" 2>/dev/null || return 1
    # shellcheck disable=SC2064  # expand $d now: the trap must survive unset vars
    trap "rmdir '$d' 2>/dev/null || true" EXIT
}

# sync_guard: echo the expected branch. 0 = proceed, 1 = hard stop (loud),
# 3 = silent skip (this box is simply not enrolled yet).
sync_guard() {
    [ -d "$DOTFILES_GIT_DIR" ] || return 3
    local expected head
    expected="$(cat "$DOTFILES_STATE_DIR/branch" 2>/dev/null || true)"
    [ -n "$expected" ] || return 3

    if [ -e "$DOTFILES_GIT_DIR/MERGE_HEAD" ] \
       || [ -d "$DOTFILES_GIT_DIR/rebase-merge" ] \
       || [ -d "$DOTFILES_GIT_DIR/rebase-apply" ]; then
        echo "dotfiles-sync: a merge or rebase is in progress — resolve it by hand" >&2
        return 1
    fi

    head="$(df rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$head" != "$expected" ]; then
        echo "dotfiles-sync: HEAD is '$head', expected '$expected' — committing nothing" >&2
        return 1
    fi
    printf '%s\n' "$expected"
}

# sync_commit <branch>: stage tracked modifications and deletions ONLY.
# `add -u` is deliberate and load-bearing: it can never stage an untracked file,
# so tracking stays an explicit act (the offer-hook surfaces candidates instead).
# Returns 0 whether or not there was anything to commit.
sync_commit() {
    local branch="$1" paths n
    df add -u || return 1
    if df diff --cached --quiet; then return 0; fi
    n="$(df diff --cached --name-only | wc -l | tr -d ' ')"
    paths="$(df diff --cached --name-only | head -5 | tr '\n' ' ')"
    paths="${paths% }"
    [ "$n" -gt 5 ] && paths="$paths … (+$((n - 5)))"
    df commit -q -m "auto($branch): $paths" || return 1
}

# sync_push <branch>: ALWAYS returns 0. Offline, an expired token, a laptop on a
# captive portal — none of those are malfunctions. The commit is already safe
# locally and the next tick retries.
sync_push() {
    if ! df push -q origin "$1" 2>/dev/null; then
        echo "dotfiles-sync: push failed (offline or auth) — retrying next tick" >&2
    fi
    return 0
}

# sync_tick: one full pass. Task 3 extends this with fetch/preflight/merge.
sync_tick() {
    local branch rc
    branch="$(sync_guard)"; rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    sync_commit "$branch" || return 1
    sync_push "$branch"
    return 0
}

if [ -z "${DOTFILES_SYNC_LIB_ONLY:-}" ]; then
    sync_lock || exit 0     # another tick holds it; overlapping ticks are a no-op
    sync_tick
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/dotfiles-sync.test.sh`
Expected: `ALL PASS` (10 PASS lines)

- [ ] **Step 5: Lint**

Run: `chmod +x provision/dotfiles-sync.sh && shellcheck provision/dotfiles-sync.sh provision/dotfiles-sync.test.sh && bash -n provision/dotfiles-sync.sh`
Expected: clean

- [ ] **Step 6: Commit**

```bash
git add provision/dotfiles-sync.sh provision/dotfiles-sync.test.sh
git commit -m "feat(dotfiles): sync timer body — lock, branch guard, commit, push"
```

---

## Task 3: `dotfiles-sync.sh` — fetch, `merge-tree` preflight, merge

The safety half (spec §5.1 steps 4–6). `merge-tree --write-tree` computes the merge entirely in the object store and touches no working file, so a conflict is detected *before* anything on disk changes — strictly safer than merge-then-`--abort`, which writes markers first and only then rolls back.

**Files:**
- Modify: `provision/dotfiles-sync.sh` (add `sync_merge`, extend `sync_tick`)
- Modify: `provision/dotfiles-sync.test.sh` (add the conflict cases)

**Interfaces:**
- Consumes: `df`, `git_has_mergetree`, `sync_guard`, `sync_commit`, `sync_push`, `sync_tick` from Task 2.
- Produces: `sync_merge <branch>` — always returns 0. Side effects: drops or clears `$DOTFILES_STATE_DIR/conflict`.

- [ ] **Step 1: Write the failing tests**

Insert into `provision/dotfiles-sync.test.sh`, immediately before the final `[ "$fail" -eq 0 ]` line:

```bash
# ── 5. origin/main fast-forwards cleanly into the branch ─────────────────────
T="$(setup)"
printf 'shared\n' > "$T/seed/.shared"
printf '*\n!*/\n!.gitignore\n!.tracked\n!.shared\n' > "$T/seed/.gitignore"
git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .shared
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm "add shared"
git -C "$T/seed" push -q "$T/remote.git" main
eq "clean merge: exit 0" "$(tick "$T")" "0"
[ -f "$T/home/.shared" ] && pass "clean merge: shared file landed in \$HOME" \
                         || die "clean merge: .shared missing from \$HOME"
[ ! -f "$T/state/conflict" ] && pass "clean merge: no conflict marker" \
                             || die "clean merge: spurious conflict marker"
rm -rf "$T"

# ── 6. Conflicting origin/main: \$HOME byte-identical, marker dropped ────────
# THE test. If this regresses, a timer tick writes <<<<<<< into a live dotfile.
T="$(setup)"
printf 'theirs\n' > "$T/seed/.tracked"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qam "theirs"
git -C "$T/seed" push -q "$T/remote.git" main
printf 'ours\n' > "$T/home/.tracked"
rc="$(tick "$T")"
eq "conflict: exit 0" "$rc" "0"
eq "conflict: \$HOME byte-identical" "$(cat "$T/home/.tracked")" "ours"
case "$(cat "$T/home/.tracked")" in
  *'<<<<<<<'*) die "conflict: MARKERS WRITTEN TO LIVE \$HOME" ;;
  *) pass "conflict: no markers in \$HOME" ;;
esac
[ -f "$T/state/conflict" ] && pass "conflict: marker dropped" || die "conflict: no marker"
eq "conflict: local work still committed" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 7. Resolving the conflict clears the marker on the next tick ────────────
T="$(setup)"
printf 'theirs\n' > "$T/seed/.tracked"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qam "theirs"
git -C "$T/seed" push -q "$T/remote.git" main
printf 'ours\n' > "$T/home/.tracked"
tick "$T" >/dev/null
[ -f "$T/state/conflict" ] || die "setup for test 7: expected a marker"
# Resolve by taking origin/main's content, exactly as a human would.
dfx "$T" fetch -q origin main
dfx "$T" merge -q --no-edit -X theirs origin/main >/dev/null 2>&1
eq "resolved: exit 0" "$(tick "$T")" "0"
[ ! -f "$T/state/conflict" ] && pass "resolved: marker cleared" || die "resolved: marker still present"
rm -rf "$T"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash provision/dotfiles-sync.test.sh`
Expected: FAIL — test 5 fails with `.shared missing from $HOME` (no merge step exists yet)

- [ ] **Step 3: Implement `sync_merge` and wire it into `sync_tick`**

In `provision/dotfiles-sync.sh`, insert `sync_merge` after `sync_push`:

```bash
# sync_merge <branch>: fetch origin/main, preflight the merge in the object
# store, and only then touch $HOME. ALWAYS returns 0 — a conflict is a state to
# report, not a malfunction to alarm on.
sync_merge() {
    local branch="$1" marker="$DOTFILES_STATE_DIR/conflict"

    if ! df fetch -q origin main 2>/dev/null; then
        echo "dotfiles-sync: fetch failed (offline or auth) — retrying next tick" >&2
        return 0
    fi

    # BELOW THE FLOOR: commit and push only. Attempting the merge without a
    # preflight is the one thing this script must never do.
    if ! git_has_mergetree; then
        echo "dotfiles-sync: git $(git --version | awk '{print $3}') lacks 'merge-tree --write-tree' (needs 2.38+) — skipping merge; commit and push still ran" >&2
        return 0
    fi

    # merge-tree --write-tree writes ONLY to the object store. On conflict it
    # exits non-zero having changed nothing on disk. This is the whole reason
    # the design is safe to run unattended against a live $HOME.
    if ! df merge-tree --write-tree "$branch" origin/main >/dev/null 2>&1; then
        mkdir -p "$DOTFILES_STATE_DIR"
        {
            printf 'conflict merging origin/main into %s\n' "$branch"
            printf 'detected: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'resolve by hand, then the next tick clears this file:\n'
            printf '  git --git-dir=%s --work-tree=%s merge origin/main\n' \
                   "$DOTFILES_GIT_DIR" "$DOTFILES_WORK_TREE"
        } > "$marker"
        echo "dotfiles-sync: origin/main conflicts with $branch — \$HOME untouched; see $marker" >&2
        return 0
    fi

    rm -f "$marker"
    # Preflight was clean, so this cannot conflict. It can still refuse if a
    # tracked file changed in the seconds since sync_commit ran — harmless, the
    # next tick commits that change first and then merges.
    df merge -q --no-edit --ff origin/main >/dev/null 2>&1 || true
    return 0
}
```

Then replace `sync_tick` with:

```bash
# sync_tick: one full pass — spec §5.1 steps 1-6.
sync_tick() {
    local branch rc
    branch="$(sync_guard)"; rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    sync_commit "$branch" || return 1
    sync_push "$branch"
    sync_merge "$branch"
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash provision/dotfiles-sync.test.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Verify the git floor on the oldest box**

`merge-tree --write-tree` is the load-bearing primitive and `hub` is a Debian VPS. Check it before trusting the guard:

Run: `ssh hub 'git --version'`
Expected: `git version 2.39.x` or newer (Debian 12 ships 2.39.5). If it reports below 2.38, that box will commit and push but never merge — note it and continue; the guard already handles it, and `promote` surfaces the standing divergence.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck provision/dotfiles-sync.sh provision/dotfiles-sync.test.sh
git add provision/dotfiles-sync.sh provision/dotfiles-sync.test.sh
git commit -m "feat(dotfiles): merge-tree preflight — never write a conflict into live \$HOME"
```

---

## Task 4: `dotfiles-sync.ps1` — the Windows twin

Same six steps, PowerShell. `desktop` and `server` are Windows-native fleet members.

**Files:**
- Create: `provision/dotfiles-sync.ps1`

**Interfaces:**
- Consumes: the same env contract as Task 2 — `DOTFILES_GIT_DIR`, `DOTFILES_WORK_TREE`, `DOTFILES_STATE_DIR`.
- Produces: nothing consumed by later tasks except its path, referenced by Task 5's `windows.ps1` block and Task 7's role.

- [ ] **Step 1: Write the script**

Create `provision/dotfiles-sync.ps1`:

```powershell
<#
.SYNOPSIS
  Dotfiles sync tick for Windows. Mirror of provision/dotfiles-sync.sh.
.DESCRIPTION
  ~/.dotfiles is a bare repo whose work-tree is $HOME. Commits tracked changes
  to this machine's branch, pushes, then merges origin/main in -- but only after
  `git merge-tree --write-tree` proves the merge is conflict-free. The work-tree
  is a live home directory; a conflicted merge would write <<<<<<< markers into
  files the user needs to fix it. Registered as a ~10-min Scheduled Task by
  provision/windows.ps1.

  Exit 0 for every normal outcome including conflict and failed push. Exit 1
  only for a hard stop that needs a human (wrong branch, merge in progress).
#>
param(
    [string] $GitDir    = $(if ($env:DOTFILES_GIT_DIR)    { $env:DOTFILES_GIT_DIR }    else { Join-Path $HOME '.dotfiles' }),
    [string] $WorkTree  = $(if ($env:DOTFILES_WORK_TREE)  { $env:DOTFILES_WORK_TREE }  else { $HOME }),
    [string] $StateDir  = $(if ($env:DOTFILES_STATE_DIR)  { $env:DOTFILES_STATE_DIR }  else { Join-Path $HOME '.local\state\dotfiles-sync' })
)
$ErrorActionPreference = 'Continue'
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10' }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { exit 0 }                       # git absent: not enrolled, not an error
if (-not (Test-Path -LiteralPath $GitDir)) { exit 0 }

function Df { & $git --git-dir=$GitDir --work-tree=$WorkTree @args }

# 0. Lock. New-Item -ItemType Directory is atomic and fails if it exists, which
#    is the same primitive the posix side's mkdir fallback uses.
$lock = Join-Path $StateDir 'lock.d'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
if (Test-Path -LiteralPath $lock) {
    # A lock older than 30 minutes is stale: the timer fires every 10 and the
    # work takes seconds. Sweep rather than wedge forever after a hard kill.
    if ((Get-Item $lock).LastWriteTime -lt (Get-Date).AddMinutes(-30)) {
        Remove-Item -LiteralPath $lock -Force -Recurse -EA SilentlyContinue
    } else { exit 0 }
}
try { New-Item -ItemType Directory -Path $lock -EA Stop | Out-Null } catch { exit 0 }

try {
    # 1. Guard.
    $branchFile = Join-Path $StateDir 'branch'
    if (-not (Test-Path -LiteralPath $branchFile)) { exit 0 }
    $expected = (Get-Content -LiteralPath $branchFile -Raw).Trim()
    if (-not $expected) { exit 0 }

    foreach ($p in @('MERGE_HEAD','rebase-merge','rebase-apply')) {
        if (Test-Path -LiteralPath (Join-Path $GitDir $p)) {
            Write-Error "dotfiles-sync: a merge or rebase is in progress - resolve it by hand"; exit 1
        }
    }
    $head = (Df rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($head -ne $expected) {
        Write-Error "dotfiles-sync: HEAD is '$head', expected '$expected' - committing nothing"; exit 1
    }

    # 2. Commit tracked modifications and deletions ONLY. Never -A.
    Df add -u | Out-Null
    Df diff --cached --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $names = @(Df diff --cached --name-only)
        $shown = ($names | Select-Object -First 5) -join ' '
        if ($names.Count -gt 5) { $shown = "$shown ... (+$($names.Count - 5))" }
        Df commit -q -m "auto($expected): $shown" | Out-Null
    }

    # 3. Push. Offline / expired token is non-fatal; next tick retries.
    Df push -q origin $expected 2>$null | Out-Null

    # 4. Fetch.
    Df fetch -q origin main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 0 }

    # 5. Preflight. merge-tree --write-tree needs git 2.38+; below that floor,
    #    commit and push only -- never attempt an unpreflighted merge.
    $v = ((& $git --version) -split ' ')[2] -split '\.'
    $ok = ([int]$v[0] -gt 2) -or ([int]$v[0] -eq 2 -and [int]$v[1] -ge 38)
    if (-not $ok) {
        Write-Warning "dotfiles-sync: git $($v -join '.') lacks 'merge-tree --write-tree' (needs 2.38+) - skipping merge"
        exit 0
    }
    $marker = Join-Path $StateDir 'conflict'
    Df merge-tree --write-tree $expected origin/main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Set-Content -LiteralPath $marker -Value @(
            "conflict merging origin/main into $expected"
            "detected: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            "resolve by hand, then the next tick clears this file:"
            "  git --git-dir=$GitDir --work-tree=$WorkTree merge origin/main"
        )
        Write-Warning "dotfiles-sync: origin/main conflicts with $expected - `$HOME untouched; see $marker"
        exit 0
    }
    Remove-Item -LiteralPath $marker -Force -EA SilentlyContinue

    # 6. Merge. Preflight was clean, so this cannot conflict.
    Df merge -q --no-edit --ff origin/main 2>$null | Out-Null
    exit 0
}
finally { Remove-Item -LiteralPath $lock -Force -Recurse -EA SilentlyContinue }
```

- [ ] **Step 2: Verify it parses**

Run: `pwsh -NoProfile -Command '[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path provision/dotfiles-sync.ps1), [ref]$null, [ref]$e); if ($e) { $e; exit 1 } else { "parse OK" }'`
Expected: `parse OK`

If `pwsh` is not on this Mac, defer this check to `desktop` (Task 15) and note it — do not skip the parse check silently.

- [ ] **Step 3: Commit**

```bash
git add provision/dotfiles-sync.ps1
git commit -m "feat(dotfiles): Windows sync tick (dotfiles-sync.ps1)"
```

---

## Task 5: Timer installers — `tier_dotfiles_sync` + the Windows scheduled task

Spec §5.4: the timer is a **plain systemd user unit on Linux, not a Nix module** — installed by the role, same code path as every other POSIX box. It works on NixOS today and survives its retirement untouched.

Copy the `tier_selfpull` shape verbatim (`provision/lib/tiers.sh:781-855`): darwin `_launchd_periodic` → systemd-user → cron fallback.

**Files:**
- Modify: `provision/lib/tiers.sh` (append `tier_dotfiles_sync`)
- Modify: `provision/windows.ps1` (register the `dotfiles-sync` task alongside `fleet-selfpull`)

**Interfaces:**
- Consumes: `provision/dotfiles-sync.sh` (Task 2/3), `provision/dotfiles-sync.ps1` (Task 4). Existing helpers `_is_darwin`, `_launchd_periodic`, `info`, `ok`, `warn`, `have`, `$REPO`.
- Produces: `tier_dotfiles_sync` — no args, always returns 0 (best-effort tier, like `tier_selfpull`). Called by Task 6's `role_dotfiles`.

- [ ] **Step 1: Add `tier_dotfiles_sync`**

Append to `provision/lib/tiers.sh`, immediately after `tier_selfpull`:

```bash
# ── BEST-EFFORT: dotfiles sync timer — spec 2026-07-28 §5.4 ──────────────────
# ~10-min tick of provision/dotfiles-sync.sh: commit tracked $HOME changes to
# this machine's branch, push, merge origin/main in (preflighted). Deliberately
# a plain systemd USER unit rather than a Nix module even on NixOS, so the same
# code path serves every POSIX box and NixOS retirement removes a case, not a
# mechanism. Precedent: agents/bootstrap.sh already deploys outside the nix
# generation for the same reason. Idempotent.
#
# Cadence matches tier_selfpull / git-autofetch (10 min) — deliberately aligned.
tier_dotfiles_sync() {
  info "Installing dotfiles sync timer…"
  DFS="$REPO/provision/dotfiles-sync.sh"
  if [ ! -f "$DFS" ]; then
    warn "provision/dotfiles-sync.sh not found — skipping dotfiles sync timer"
  elif _is_darwin; then
    _launchd_periodic kz.cyphy.dotfiles-sync 600 /usr/bin/env bash "$DFS" \
      && ok "dotfiles-sync LaunchAgent installed" \
      || warn "could not load the dotfiles-sync LaunchAgent"
  elif systemctl --user show-environment >/dev/null 2>&1; then
    _ud3="$HOME/.config/systemd/user"; mkdir -p "$_ud3"
    {
      printf '[Unit]\nDescription=Sync $HOME dotfiles to this machine'\''s branch\n\n'
      printf '[Service]\nType=oneshot\nTimeoutStartSec=5min\n'
      printf 'ExecStart=/usr/bin/env bash %s\n' "$DFS"
    } > "$_ud3/dotfiles-sync.service"
    cat > "$_ud3/dotfiles-sync.timer" <<'UNIT'
[Unit]
Description=Periodic dotfiles sync

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    if systemctl --user daemon-reload >/dev/null 2>&1 \
       && systemctl --user enable --now dotfiles-sync.timer >/dev/null 2>&1; then
      ok "dotfiles-sync.timer (systemd-user) installed"
    else
      warn "could not enable dotfiles-sync.timer"
    fi
  elif have crontab; then
    if crontab -l 2>/dev/null | grep -qF "$DFS"; then
      ok "dotfiles-sync cron already present"
    elif { crontab -l 2>/dev/null; printf '*/10 * * * * sleep $((RANDOM %% 120)); /usr/bin/env bash %s >/dev/null 2>&1\n' "$DFS"; } \
           | crontab - >/dev/null 2>&1; then
      ok "dotfiles-sync cron installed"
    else
      warn "could not install dotfiles-sync cron"
    fi
  else
    warn "dotfiles-sync installed but not scheduled (no systemd user manager or cron)"
  fi
  return 0
}
```

Note the `OnBootSec=3min` (vs `fleet-selfpull`'s 2min): the sync merges `origin/main` in, and letting `fleet-selfpull` get its boot pass in first keeps the two off each other's first tick.

- [ ] **Step 2: Verify it parses and is reachable**

Run: `bash -n provision/lib/tiers.sh && TIERS_LIB_ONLY=1 bash -c 'source provision/lib/tiers.sh; declare -F tier_dotfiles_sync'`
Expected: `tier_dotfiles_sync`

- [ ] **Step 3: Register the Windows scheduled task**

In `provision/windows.ps1`, immediately after the `Register-ScheduledTask -TaskName 'fleet-selfpull'` try/catch block closes (around line 379), add:

```powershell
    # (3) dotfiles-sync - every 10 min, as the interactive user, jittered.
    # Same principal and settings shape as fleet-selfpull above: it touches
    # $HOME, so it must run as the human, not SYSTEM.
    $dfsPs1 = Join-Path $RepoDir 'provision\dotfiles-sync.ps1'
    $dfsAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$dfsPs1`""
    $dfsTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 10)
    $dfsTrigger.Repetition.Duration = ''      # empty = repeat indefinitely
    $dfsTrigger.RandomDelay = 'PT2M'
    $dfsSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $dfsPrincipal = New-ScheduledTaskPrincipal -UserId $pullUser -LogonType S4U -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName 'dotfiles-sync' -Action $dfsAction -Trigger $dfsTrigger `
            -Settings $dfsSettings -Principal $dfsPrincipal -Force | Out-Null
        Info "registered 'dotfiles-sync' (every 10 min, jittered) as $pullUser."
    } catch {
        Warn "dotfiles-sync registration failed for '$pullUser': $($_.Exception.Message) - leaving any existing task."
    }
```

This must go **inside** the same `else` branch that owns `$pullUser` — that branch is the "an interactive user exists" path. A headless SYSTEM run must not register a task that writes to a human's `$HOME`.

- [ ] **Step 4: Verify windows.ps1 still parses**

Run: `pwsh -NoProfile -Command '[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path provision/windows.ps1), [ref]$null, [ref]$e); if ($e) { $e; exit 1 } else { "parse OK" }'`
Expected: `parse OK` (defer to `desktop` if `pwsh` is absent here, same as Task 4)

- [ ] **Step 5: Commit**

```bash
git add provision/lib/tiers.sh provision/windows.ps1
git commit -m "feat(dotfiles): install the 10-min sync timer (launchd/systemd/cron/schtasks)"
```

---

## Task 6: Rewrite `role_dotfiles` (posix) and invert the nixos test

Spec §5.4. Role name and dispatcher registration survive; the engine swaps. Three jobs: clone the bare repo, check out this host's branch, install the timer. The role now runs on **all** platforms — the nixos no-op existed only because chezmoi collided with home-manager, and the bare-repo technique does not.

The role is also where `$DOTFILES_STATE_DIR/branch` gets written — the role knows the logical name, the timer does not.

**Files:**
- Modify: `provision/roles/dotfiles.sh` (full rewrite)
- Modify: `provision/tests/roles.test.sh:38-42`
- Modify: `provision/linux.sh:69` (workstation tier list)

**Interfaces:**
- Consumes: `fleet_logical_name` (Task 1, optional — falls back to the `$machine` argument), `tier_dotfiles_sync` (Task 5), `provision/dotfiles-sync.sh` (Tasks 2–3).
- Produces: `role_dotfiles <mode> <platform> <machine>` — `mode` is `dry-run|apply`. Writes `$HOME/.dotfiles` (bare clone) and `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync/branch`.

- [ ] **Step 1: Invert the failing assertion**

In `provision/tests/roles.test.sh`, replace the block at lines 38-42:

```bash
# nixos DOES deliberately skip agents — home-manager owns the profile there.
# That is a real arm, not the fallthrough, and must keep saying so.
case "$(role_agents dry-run nixos latitude 2>&1)" in
  *"owned by home-manager"*) pass "role_agents: nixos still defers to home-manager" ;;
  *) die "role_agents: nixos arm changed" ;;
esac

# dotfiles is the OPPOSITE as of spec 2026-07-28: the bare-repo engine has no
# collision with home-manager (a path is shared XOR host-local, so home-manager
# -owned paths simply never sit on main), so nixos reaches a REAL arm now. The
# old "owned by home-manager on nixos" skip would silently leave latitude with
# no sync timer and no branch checked out.
not_skipped "role_dotfiles(nixos)" "$(role_dotfiles dry-run nixos latitude 2>&1)"
case "$(role_dotfiles dry-run nixos latitude 2>&1)" in
  *"owned by home-manager"*) die "role_dotfiles: nixos still defers to home-manager — spec 2026-07-28 retires that skip" ;;
  *) pass "role_dotfiles: nixos no longer defers to home-manager" ;;
esac
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash provision/tests/roles.test.sh`
Expected: FAIL — `role_dotfiles: nixos still defers to home-manager`

- [ ] **Step 3: Rewrite the role**

Replace the entire contents of `provision/roles/dotfiles.sh`:

```bash
# provision/roles/dotfiles.sh — the `dotfiles` role executor (posix side).
# Sourced by provision.sh (do not execute). Defines role_dotfiles.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.4
#
# dotfiles = the private metheoryt/dotfiles repo, BARE-REPO technique: ~/.dotfiles
# is a bare git repo whose work-tree is $HOME, so tracked files already live at
# their real paths. No symlinks, no render step, no chezmoi.
#
# Runs on EVERY platform including nixos. The old nixos no-op existed because
# chezmoi collided with home-manager; the bare repo does not. Under the spec's
# shared-XOR-host invariant a home-manager-owned path is simply host-local —
# allow-listed on non-Nix branches, absent from main and from latitude's branch —
# so there is nothing for the two mechanisms to fight over.
# shellcheck shell=bash

DOTFILES_REMOTE="${DOTFILES_REMOTE:-git@github.com:metheoryt/dotfiles.git}"

# _dotfiles_branch <machine>: the logical fleet name to check out. Prefers the
# shared resolver (which honours a self-declared WSL host's fleet.local.json
# nickname); falls back to the machine the dispatcher already resolved, so this
# role stays sourceable and testable standalone.
_dotfiles_branch() {
    local b=""
    if command -v fleet_logical_name >/dev/null 2>&1 || declare -F fleet_logical_name >/dev/null 2>&1; then
        b="$(fleet_logical_name 2>/dev/null || true)"
    fi
    [ -n "$b" ] || b="$1"
    printf '%s' "$b"
}

# role_dotfiles <mode> <platform> <machine>
#   mode: dry-run | apply
role_dotfiles() {
    local mode="$1" platform="$2" machine="$3"
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local gitdir="$HOME/.dotfiles"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync"
    local branch; branch="$(_dotfiles_branch "$machine")"

    case "$platform" in
        nixos|wsl|debian|darwin) : ;;
        *)
            echo "  dotfiles: no posix executor for platform '$platform' (skipped)."
            return 0
            ;;
    esac

    if [ -z "$branch" ]; then
        echo "  dotfiles: could not resolve a logical fleet name — refusing to check out an empty branch." >&2
        return 1
    fi

    if [ "$mode" = dry-run ]; then
        echo "  ~ would clone $DOTFILES_REMOTE (bare) -> $gitdir"
        echo "  ~ would check out branch '$branch' (creating it from main if absent)"
        echo "  ~ would record the branch at $state/branch"
        echo "  ~ would install the 10-min dotfiles-sync timer"
        return 0
    fi

    # 1. Clone the bare repo if absent. `--bare` gives no work-tree of its own;
    #    every later call must pass --work-tree explicitly.
    if [ ! -d "$gitdir" ]; then
        echo "  dotfiles: cloning $DOTFILES_REMOTE -> $gitdir ..."
        git clone --quiet --bare "$DOTFILES_REMOTE" "$gitdir" || {
            echo "  dotfiles: clone failed — is this box's key registered for the private repo?" >&2
            return 1
        }
    fi
    local df=(git --git-dir="$gitdir" --work-tree="$HOME")
    # Never enumerate the rest of $HOME. Without this, `dotfiles status` lists
    # every untracked file in the home directory.
    "${df[@]}" config status.showUntrackedFiles no

    # 2. Check out this host's branch, creating it from main if it does not exist.
    #
    # THE CHECKOUT MUST BE GUARDED. git refuses it when an untracked file already
    # sits at a tracked path, and on a real box that is the NORMAL case, not an
    # edge case: air already has ~/.config/gh/config.yml, latitude has a
    # home-manager-generated ~/.ssh/config. Unguarded, the checkout is refused,
    # HEAD stays on the clone's default (main), the role writes the wrong branch
    # into the state file, and every sync tick from then on hits the wrong-branch
    # arm and exits 1 — a timer that looks installed and never works.
    "${df[@]}" fetch --quiet origin || true
    _dotfiles_checkout() {
        if "${df[@]}" "$@"; then return 0; fi
        echo "  dotfiles: checkout refused — untracked files in \$HOME already occupy tracked paths." >&2
        echo "  dotfiles: git named them above. Back each one up, delete it, and re-run:" >&2
        echo "    mv ~/<path> ~/<path>.pre-dotfiles" >&2
        echo "  dotfiles: NOT recording the branch or installing the timer — a timer" >&2
        echo "  dotfiles: on the wrong branch would refuse every tick silently." >&2
        return 1
    }
    if "${df[@]}" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        _dotfiles_checkout checkout --quiet "$branch" || return 1
    elif "${df[@]}" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        _dotfiles_checkout checkout --quiet -b "$branch" --track "origin/$branch" || return 1
    else
        echo "  dotfiles: branch '$branch' does not exist — creating it from origin/main."
        _dotfiles_checkout checkout --quiet -b "$branch" origin/main || return 1
        "${df[@]}" push --quiet -u origin "$branch" || \
            echo "  dotfiles: could not push the new branch — it stays local until the next sync tick." >&2
    fi

    # Belt-and-suspenders: never record a branch HEAD is not actually on.
    if [ "$("${df[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]; then
        echo "  dotfiles: HEAD is not on '$branch' after checkout — refusing to continue." >&2
        return 1
    fi

    # 3. Record the branch for the timer. The timer must NOT resolve fleet
    #    identity itself: that would couple it to jq and to this repo being
    #    present. It reads this file and refuses to run if HEAD disagrees.
    mkdir -p "$state"
    printf '%s\n' "$branch" > "$state/branch"

    echo "  dotfiles: $gitdir on branch '$branch'."

    # 4. Install the timer. tier_dotfiles_sync lives in provision/lib/tiers.sh,
    #    which linux.sh / macos.sh source but provision.sh does not — so source
    #    it here when it is not already in scope.
    if ! declare -F tier_dotfiles_sync >/dev/null 2>&1; then
        # tiers.sh expects these; define no-op-safe versions if absent.
        command -v info >/dev/null 2>&1 || info() { printf '  %s\n' "$*"; }
        command -v ok   >/dev/null 2>&1 || ok()   { printf '  ✓ %s\n' "$*"; }
        command -v warn >/dev/null 2>&1 || warn() { printf '  ! %s\n' "$*" >&2; }
        command -v have >/dev/null 2>&1 || have() { command -v "$1" >/dev/null 2>&1; }
        REPO="${REPO:-$repo}"
        # shellcheck source=provision/lib/tiers.sh
        TIERS_LIB_ONLY=1 source "$repo/provision/lib/tiers.sh"
    fi
    tier_dotfiles_sync
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash provision/tests/roles.test.sh`
Expected: `ALL PASS` — including `role_dotfiles: nixos no longer defers to home-manager`

- [ ] **Step 5: Wire the self-declared WSL path**

In `provision/linux.sh:69`, add `dotfiles` to the `workstation` tier list. That list is reached only by boxes that run `linux.sh` with the workstation profile — in practice exactly the self-declared WSL hosts, since every `fleet.json` Linux member reaches the role instead (`latitude` is nixos, `hub` uses the `hub` profile).

```bash
    TIERS=(apt_min apt_dev agents_config git_base gortex
           "agent_clis claude codex hermes" shell_init autofetch
           ssh_accounts selfpull ssh_trust dotfiles hermes_config hermes_dashboard) ;;
```

Then add `tier_dotfiles` to `provision/lib/tiers.sh`, immediately before `tier_dotfiles_sync`:

```bash
# ── BEST-EFFORT: dotfiles bootstrap for boxes that never reach the role ──────
# provision.sh's role dispatcher covers every fleet.json member. Self-declared
# WSL hosts run linux.sh directly and never see a role, so the tier list is
# their only path in. Same code, one call.
tier_dotfiles() {
  info "Bootstrapping dotfiles (bare repo)…"
  local name
  name="$(fleet_logical_name 2>/dev/null || true)"
  if [ -z "$name" ]; then
    warn "no logical fleet name (no fleet.local.json nickname, no fleet.json match) — skipping dotfiles"
    return 0
  fi
  # shellcheck source=provision/roles/dotfiles.sh
  source "$REPO/provision/roles/dotfiles.sh"
  role_dotfiles apply wsl "$name" || warn "dotfiles bootstrap reported an error"
  return 0
}
```

`linux.sh` already sources `provision/lib/fleet.sh` (line 54), so `fleet_logical_name` is in scope.

- [ ] **Step 6: Verify the tier list still resolves**

Only `dotfiles` goes in the list — `tier_dotfiles` calls `role_dotfiles`, which
installs the timer itself, so `dotfiles_sync` must NOT also be listed or the
timer install runs twice per provision.

Run: `MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE=workstation bash provision/linux.sh | grep -x tier_dotfiles`
Expected: `tier_dotfiles`

Run: `MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE=workstation bash provision/linux.sh | grep -x tier_dotfiles_sync && echo "REMOVE IT — double install" || echo "correct"`
Expected: `correct`

- [ ] **Step 7: Lint and commit**

```bash
shellcheck provision/roles/dotfiles.sh provision/lib/tiers.sh provision/tests/roles.test.sh
bash provision/tests/roles.test.sh
git add provision/roles/dotfiles.sh provision/tests/roles.test.sh provision/lib/tiers.sh provision/linux.sh
git commit -m "feat(dotfiles): rewrite the posix role — bare repo, all platforms incl. nixos"
```

---

## Task 7: Rewrite `Invoke-RoleDotfiles` (Windows)

Same three jobs, PowerShell. Reached by `desktop` and `server` through `provision.ps1`.

**Files:**
- Modify: `provision/roles/dotfiles.ps1` (full rewrite)

**Interfaces:**
- Consumes: `provision/dotfiles-sync.ps1` (Task 4). The scheduled task itself is registered by `windows.ps1` (Task 5), so this role only clones, branches, and records state.
- Produces: `Invoke-RoleDotfiles -Mode <dry-run|apply> -Platform <p> -Machine <m>`.

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `provision/roles/dotfiles.ps1`:

```powershell
# provision/roles/dotfiles.ps1 — the `dotfiles` role executor (Windows side).
# Dot-sourced by provision.ps1. Defines Invoke-RoleDotfiles.
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.4
#
# dotfiles = the private metheoryt/dotfiles repo, bare-repo technique: ~/.dotfiles
# is a bare git repo whose work-tree is $HOME. No chezmoi, no render step.
#
# The 10-min sync Scheduled Task is registered by provision/windows.ps1, not
# here -- it needs the interactive-user principal that windows.ps1 resolves.

function Invoke-RoleDotfiles {
    param(
        [Parameter(Mandatory)][ValidateSet('dry-run','apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $Machine
    )
    if ($Platform -ne 'windows') {
        Write-Host "  dotfiles: no Windows executor for platform '$Platform' (skipped)."
        return
    }

    $remote = if ($env:DOTFILES_REMOTE) { $env:DOTFILES_REMOTE } else { 'git@github.com:metheoryt/dotfiles.git' }
    $gitDir = Join-Path $HOME '.dotfiles'
    $state  = Join-Path $HOME '.local\state\dotfiles-sync'
    # $Machine IS the logical fleet name: provision.ps1 either takes it as an
    # argument or resolves it via Get-FleetDetected, which returns the
    # fleet.json KEY ($p.Name), not the OS hostname it matched on.
    # Verified against provision/lib/Fleet.psm1:16-23.
    $branch = $Machine

    if ($Mode -eq 'dry-run') {
        Write-Host "  ~ would clone $remote (bare) -> $gitDir"
        Write-Host "  ~ would check out branch '$branch' (creating it from main if absent)"
        Write-Host "  ~ would record the branch at $state\branch"
        return
    }

    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { throw "dotfiles: git not found on PATH" }

    # 1. Clone the bare repo if absent.
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Write-Host "  dotfiles: cloning $remote -> $gitDir ..."
        & $git clone --quiet --bare $remote $gitDir
        if ($LASTEXITCODE -ne 0) { throw "dotfiles: clone failed - is this box's key registered for the private repo?" }
    }
    function Df { & $git --git-dir=$gitDir --work-tree=$HOME @args }
    Df config status.showUntrackedFiles no | Out-Null

    # 2. Check out this host's branch, creating it from main if it does not exist.
    #
    # THE CHECKOUT MUST BE GUARDED, same as the posix side: git refuses it when
    # an untracked file already occupies a tracked path, which is the normal
    # case on a box that has been in use. Unguarded, HEAD stays on the clone's
    # default and the sync task then refuses every tick silently.
    Df fetch --quiet origin 2>$null | Out-Null
    Df rev-parse --verify --quiet "refs/heads/$branch" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Df checkout --quiet $branch | Out-Null
    } else {
        Df rev-parse --verify --quiet "refs/remotes/origin/$branch" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Df checkout --quiet -b $branch --track "origin/$branch" | Out-Null
        } else {
            Write-Host "  dotfiles: branch '$branch' does not exist - creating it from origin/main."
            Df checkout --quiet -b $branch origin/main | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Df push --quiet -u origin $branch | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  dotfiles: could not push the new branch - it stays local until the next sync tick."
                }
            }
        }
    }
    $head = (Df rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ($head -ne $branch) {
        throw ("dotfiles: HEAD is '$head', not '$branch'. The checkout was refused - untracked " +
               "files in `$HOME already occupy tracked paths (git named them above). Back each " +
               "one up, delete it, and re-run. Not recording the branch: a sync task on the " +
               "wrong branch refuses every tick silently.")
    }

    # 3. Record the branch for the sync task. The task must not resolve fleet
    #    identity itself; it reads this file and refuses if HEAD disagrees.
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $state 'branch') -Value $branch -NoNewline

    Write-Host "  dotfiles: $gitDir on branch '$branch'."
}
```

Note `-NoNewline` on `Set-Content`: the posix side trims, but the PowerShell reader uses `.Trim()` too, so either is safe — `-NoNewline` avoids a CRLF landing in the file.

- [ ] **Step 2: Verify it parses**

Run: `pwsh -NoProfile -Command '[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path provision/roles/dotfiles.ps1), [ref]$null, [ref]$e); if ($e) { $e; exit 1 } else { "parse OK" }'`
Expected: `parse OK` (defer to `desktop` if `pwsh` is absent here)

- [ ] **Step 3: Commit**

```bash
git add provision/roles/dotfiles.ps1
git commit -m "feat(dotfiles): rewrite the Windows role — bare repo, no chezmoi"
```

---

## Task 8: The proactive tracking-offer hook

Spec §5.3. A `PostToolUse` hook on `Edit`/`Write`/`NotebookEdit` that emits a non-blocking offer when an edited `$HOME` file has no home in any repo. Never a permission prompt.

**Spec clarification, decided here:** D10 says declines are session-scoped with no persisted state. A hook is a fresh process per invocation and cannot observe the user's answer at all — `PostToolUse` fires before any reply exists. So "declined this session" collapses to **"already offered this session"**, tracked in a scratch file keyed by the hook payload's `session_id` under the system temp dir. Nothing is synced, nothing survives a reboot, and a repeatedly-ignored path is re-offered in a later session — which is the self-limiting behavior the spec describes.

**Files:**
- Create: `agents/plugin/hooks/dotfiles-offer.sh`
- Create: `agents/plugin/hooks/tests/dotfiles-offer.test.sh`
- Modify: `agents/plugin/hooks/hooks.json`

**Interfaces:**
- Consumes: `~/.dotfiles` as created by Task 6. Degrades to silent when absent.
- Produces: a hook reading the `PostToolUse` JSON payload on stdin and writing either nothing or a `hookSpecificOutput.additionalContext` JSON object on stdout. Always exits 0 — a hook that fails must never block an edit.
- Test seam: `DOTFILES_GIT_DIR`, `DOTFILES_OFFER_STATE_DIR`.

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/hooks/tests/dotfiles-offer.test.sh`:

```bash
#!/usr/bin/env bash
# Table-driven tests for the dotfiles-offer PostToolUse hook.
#
# The hook decides, for a file the agent just edited, whether to offer to track
# it in the dotfiles repo. Six branches (spec §5.3); the two that matter most
# are the ban block (must NEVER offer to track a private key) and the
# gitignored-inside-a-repo case (the homeless file the whole hook exists for).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../dotfiles-offer.sh"

fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export DOTFILES_GIT_DIR="$T/home/.dotfiles"
export DOTFILES_OFFER_STATE_DIR="$T/offerstate"
mkdir -p "$HOME" "$DOTFILES_OFFER_STATE_DIR"

# A bare dotfiles repo tracking exactly one file, with the real allow-only
# .gitignore shape so check-ignore behaves like production.
git init -q --bare "$DOTFILES_GIT_DIR"
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$HOME" "$@"; }
df config status.showUntrackedFiles no
df config user.email t@t; df config user.name t
df checkout -q -b air 2>/dev/null || df symbolic-ref HEAD refs/heads/air
printf '*\n!*/\n!.gitignore\n!.tracked\n*.pem\nid_ed25519*\n.ssh/id_*\n.gnupg/\n' > "$HOME/.gitignore"
printf 'x\n' > "$HOME/.tracked"
df add "$HOME/.gitignore" "$HOME/.tracked"
df commit -q -m init

# A sibling git repo with an allowlist .gitignore — the homeless case.
mkdir -p "$HOME/pure/backend-api/.claude/memory"
git init -q "$HOME/pure/backend-api"
# Allowlist shape: `!/.claude/*.md` matches DIRECT children of .claude only, so
# .claude/memory/project.md stays ignored — that is the homeless case.
printf '*\n!*/\n!/.claude/*.md\n!*.py\n' > "$HOME/pure/backend-api/.gitignore"
printf 'note\n' > "$HOME/pure/backend-api/.claude/memory/project.md"
printf 'code\n' > "$HOME/pure/backend-api/main.py"

# run <session> <path>: feed one PostToolUse payload, echo stdout.
run() {
  printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" \
    | bash "$HOOK" 2>/dev/null
}
offers()     { case "$(run "$1" "$2")" in *dotfiles*) return 0 ;; *) return 1 ;; esac; }
assert_offer()  { offers "$1" "$2" && pass "$3" || die "$3 (expected an offer, got silence)"; }
assert_silent() { offers "$1" "$2" && die "$3 (expected silence, got an offer)" || pass "$3"; }

# 1. Outside $HOME -> silent.
printf 'x\n' > "$T/elsewhere.conf"
assert_silent s1 "$T/elsewhere.conf" "outside \$HOME is silent"

# 2. Ban block -> silent, ALWAYS. This one is a security property, not a
#    preference: an offer to track a private key is an offer to leak it.
mkdir -p "$HOME/.ssh"
printf 'KEY\n' > "$HOME/.ssh/id_ed25519"
assert_silent s2 "$HOME/.ssh/id_ed25519" "banned path (.ssh/id_*) is silent"
printf 'CERT\n' > "$HOME/server.pem"
assert_silent s2 "$HOME/server.pem" "banned path (*.pem) is silent"

# 3. Already tracked -> silent.
assert_silent s3 "$HOME/.tracked" "already-tracked path is silent"

# 4a. Inside another repo and trackable there -> silent, it belongs there.
assert_silent s4 "$HOME/pure/backend-api/main.py" "normal file in a repo is silent"

# 4b. Inside another repo but gitignored there -> OFFER. The homeless case.
assert_offer s4 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "gitignored-inside-a-repo file is offered"

# 5. Same path, same session -> silent the second time.
assert_silent s4 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "second offer in the same session is suppressed"

# 5b. Same path, NEW session -> offered again (declines are session-scoped).
assert_offer s5 "$HOME/pure/backend-api/.claude/memory/project.md" \
  "a new session re-offers the same path"

# 5c. Build noise inside a repo is gitignored there too, but must NOT be offered
#     — otherwise the hook fires on every artifact the agent touches.
mkdir -p "$HOME/pure/backend-api/.venv/lib"
printf 'x\n' > "$HOME/pure/backend-api/.venv/lib/thing.py"
assert_silent s5b "$HOME/pure/backend-api/.venv/lib/thing.py" "build noise (.venv) is silent"
printf 'x\n' > "$HOME/pure/backend-api/debug.log"
assert_silent s5b "$HOME/pure/backend-api/debug.log" "build noise (*.log) is silent"

# 6. Plain untracked $HOME file, no repo -> OFFER.
printf 'cfg\n' > "$HOME/.someconfig"
assert_offer s6 "$HOME/.someconfig" "plain untracked \$HOME file is offered"

# 7. No dotfiles repo at all -> silent everywhere. A box not yet enrolled must
#    never be nagged about files it has nowhere to put.
mv "$DOTFILES_GIT_DIR" "$T/moved"
assert_silent s7 "$HOME/.someconfig" "no dotfiles repo means silence"
mv "$T/moved" "$DOTFILES_GIT_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/hooks/tests/dotfiles-offer.test.sh`
Expected: FAIL — `dotfiles-offer.sh: No such file or directory`

- [ ] **Step 3: Implement the hook**

Create `agents/plugin/hooks/dotfiles-offer.sh`:

```bash
#!/usr/bin/env bash
# agents/plugin/hooks/dotfiles-offer.sh — PostToolUse (Edit|Write|NotebookEdit).
# Spec: docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md §5.3
#
# When the agent edits a file under $HOME that has no home in any repo, surface a
# non-blocking offer to track it in the dotfiles bare repo. NEVER a permission
# prompt, and never a blocker — this hook always exits 0, even on its own errors.
#
# The interesting branch is step 4: a file inside a git repo whose .gitignore is
# allowlist-style (`*` plus a few `!` lines) is ignored THERE, so writing it
# there produces machine-local state that never syncs. dotfiles is its only home.
# A normal source file in the same repo belongs to that repo and stays silent.
#
# Declines are session-scoped (D10). A hook process cannot observe the user's
# answer — PostToolUse fires before any reply exists — so "declined this session"
# is implemented as "already offered this session": one offer per (session,path),
# recorded in a scratch file that nothing syncs and a reboot discards.
set -u

: "${DOTFILES_GIT_DIR:=$HOME/.dotfiles}"
: "${DOTFILES_OFFER_STATE_DIR:=${TMPDIR:-/tmp}/dotfiles-offer}"

payload="$(cat)" || exit 0

# Field extraction without jq: this hook runs on every edit, so it must be cheap
# and must not hard-depend on a tool some fleet member lacks.
jget() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null
    else
        printf '%s' "$payload" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    fi
}
file="$(jget '.tool_input.file_path' 'file_path')"
session="$(jget '.session_id' 'session_id')"
[ -n "$file" ] || exit 0

# ── 1. Under $HOME? ──────────────────────────────────────────────────────────
case "$file" in
    "$HOME"/*) : ;;
    *) exit 0 ;;
esac
rel="${file#"$HOME"/}"

# No repo on this box: it is not enrolled, so there is nothing to offer.
[ -d "$DOTFILES_GIT_DIR" ] || exit 0
df() { git --git-dir="$DOTFILES_GIT_DIR" --work-tree="$HOME" "$@"; }

# ── 2. Ban block — silent, ALWAYS, before anything else. ─────────────────────
# Checked structurally rather than by asking git, because the whole point is
# that this must hold even if a future broad `!` rule un-ignores the path.
case "$rel" in
    .ssh/id_*|*.pem|*.key|*.gpg|id_rsa*|id_ed25519*|id_ecdsa*|.gnupg/*|.secrets/*)
        exit 0 ;;
esac
case "$(basename "$rel")" in
    id_rsa*|id_ed25519*|id_ecdsa*) exit 0 ;;
esac

# ── 3. Already tracked? ──────────────────────────────────────────────────────
df ls-files --error-unmatch "$rel" >/dev/null 2>&1 && exit 0

# ── 2b. Obvious non-config noise — silent. ───────────────────────────────────
# Step 4 below treats "gitignored inside a repo" as the homeless signal, which is
# spec-faithful but also matches every build artifact, virtualenv and cache the
# agent ever touches. Without this filter the hook fires constantly and the user
# turns it off, which costs more than the false negatives it prevents.
case "/$rel/" in
    */.venv/*|*/venv/*|*/node_modules/*|*/__pycache__/*|*/.pytest_cache/*|\
    */.mypy_cache/*|*/.ruff_cache/*|*/target/*|*/dist/*|*/build/*|*/.next/*|\
    */.direnv/*|*/.cache/*|*/coverage/*|*/.tox/*|*/site-packages/*)
        exit 0 ;;
esac
case "$rel" in
    *.pyc|*.pyo|*.o|*.so|*.class|*.log|*.lock|*.tmp|*.swp) exit 0 ;;
esac

# ── 4. Inside another git repo? ──────────────────────────────────────────────
# Walk up from the file's directory looking for a .git. If one is found, the
# question becomes: would THAT repo track this file? If yes, it belongs there —
# stay silent. If it is gitignored there, the file is homeless: offer.
dir="$(dirname "$file")"
owner=""
while [ "$dir" != "/" ] && [ "$dir" != "$HOME" ] && [ -n "$dir" ]; do
    if [ -e "$dir/.git" ]; then owner="$dir"; break; fi
    dir="$(dirname "$dir")"
done
if [ -n "$owner" ]; then
    if ! git -C "$owner" check-ignore -q "$file" 2>/dev/null; then
        exit 0      # trackable in its own repo — not our business
    fi
fi

# ── 5. Already offered this session? ─────────────────────────────────────────
mkdir -p "$DOTFILES_OFFER_STATE_DIR" 2>/dev/null || exit 0
# One flat file per session; the path is hashed so any filename is safe to key on.
if command -v shasum >/dev/null 2>&1; then
    key="$(printf '%s' "$rel" | shasum | cut -c1-16)"
elif command -v sha1sum >/dev/null 2>&1; then
    key="$(printf '%s' "$rel" | sha1sum | cut -c1-16)"
else
    key="$(printf '%s' "$rel" | tr -c 'a-zA-Z0-9' '_')"
fi
seen="$DOTFILES_OFFER_STATE_DIR/${session:-nosession}.$key"
[ -e "$seen" ] && exit 0
: > "$seen"

# ── 6. Offer. ────────────────────────────────────────────────────────────────
branch="$(df rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"dotfiles: \`~/$rel\` is not tracked anywhere — it is outside every repo that would keep it, so it is machine-local state today. Offer the user (do not act unprompted) to track it in the dotfiles repo on branch \`$branch\`. Accepting is two steps:\n  1. append \`!$rel\` to ~/.gitignore under the explicit-allow block\n  2. git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME add ~/.gitignore $rel\nIt lands on the machine branch; promoting it to main is a separate, manual /dotfiles-promote run. If the user declines, drop it — do not ask again this session."}}
JSON
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/hooks/tests/dotfiles-offer.test.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Register the hook**

`hooks.json` has only a `SessionStart` block today. Replace `agents/plugin/hooks/hooks.json` with:

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
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/dotfiles-offer.sh\""
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Verify the JSON and lint**

Run: `jq -e '.hooks.PostToolUse[0].matcher' agents/plugin/hooks/hooks.json && shellcheck agents/plugin/hooks/dotfiles-offer.sh agents/plugin/hooks/tests/dotfiles-offer.test.sh`
Expected: `"Edit|Write|NotebookEdit"` then clean shellcheck

- [ ] **Step 7: Commit**

```bash
chmod +x agents/plugin/hooks/dotfiles-offer.sh
git add agents/plugin/hooks/dotfiles-offer.sh agents/plugin/hooks/tests/dotfiles-offer.test.sh agents/plugin/hooks/hooks.json
git commit -m "feat(dotfiles): PostToolUse hook offering to track homeless \$HOME files"
```

---

## Task 9: Retire the chezmoi and husk artifacts

Two dead mechanisms to remove. `scripts/retire-dotfiles-husk.sh` deletes the very `~/.dotfiles` this plan reinstates — nothing wires it, and leaving it is a loaded footgun.

**Files:**
- Delete: `scripts/retire-dotfiles-husk.sh`, `agents/tests/retire-dotfiles-husk.test.sh`
- Delete: `dotfiles/dot_gitconfig.tmpl`
- Modify: `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md` (superseded marker)
- Modify: `.claude/memory/project.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `dotfiles/pure/backend-api/dot_claude/memory/project.md` is deliberately **left in place** for Task 11 to move. Deleting it here and stashing a copy in the session scratchpad would break the handoff — a 15-task plan will not run in one session, and the scratchpad does not survive. Task 11 deletes the directory once the content has a new home.

- [ ] **Step 1: Confirm nothing references the husk script**

Run: `grep -rn "retire-dotfiles-husk" --exclude-dir=.git . | grep -v 'docs/superpowers/plans/'`
Expected: only `agents/tests/retire-dotfiles-husk.test.sh` (its own test). If anything else appears — a justfile recipe, a tier, converge.sh — **stop** and resolve that reference first.

- [ ] **Step 2: Delete**

```bash
git rm -q scripts/retire-dotfiles-husk.sh agents/tests/retire-dotfiles-husk.test.sh
git rm -q dotfiles/dot_gitconfig.tmpl
```

`dot_gitconfig.tmpl` is **not** migrated (spec §9.4): it has drifted hard from
the live `~/.gitconfig` — applying it would drop `pager = delta`, the `[delta]`
block, the `gh auth git-credential` helper and `pull.rebase = true`, and rewrite
`user.name`. Track the live file instead, per box, during Task 15.

`dotfiles/pure/backend-api/` stays until Task 11 moves it.

- [ ] **Step 3: Mark the superseded spec**

In `docs/superpowers/specs/2026-07-08-fleet-provisioner-phase3-dotfiles-chezmoi-design.md`, insert immediately after the title line:

```markdown
> **SUPERSEDED 2026-07-28** by
> `2026-07-28-dotfiles-private-bare-repo-design.md`. That spec reverses §2's
> choice of chezmoi-sourced-from-`machines`: `machines` is public and dotfiles
> must carry rotatable credentials, so the engine is now the private
> `metheoryt/dotfiles` bare repo. Kept for the reasoning, not as guidance.
```

- [ ] **Step 4: Update project memory**

In `.claude/memory/project.md`, delete the two bullets added 2026-07-28 (the `dotfiles/`-hosts-foreign-repo-files convention and the blanket-`chezmoi apply` warning) and replace them with:

```markdown
- **`$HOME` config is the private `metheoryt/dotfiles` bare repo, not chezmoi**
  (spec `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md`).
  `~/.dotfiles` is a bare repo whose work-tree is `$HOME`; each box checks out a
  branch named by its **logical** fleet name (`latitude`, `air`, `desktop`,
  `server`, `hub`). `provision/dotfiles-sync.sh` commits + pushes tracked changes
  every 10 min and merges `origin/main` in behind a `merge-tree --write-tree`
  preflight. `machines/dotfiles/` and the chezmoi role were deleted 2026-07-28.
- **A path is shared XOR host-local.** On `main` ⇒ shared and byte-identical
  everywhere; absent from `main` ⇒ host-local. Never both. That is why
  home-manager-owned paths (`~/.ssh/config`, `~/.gitconfig`) are not on `main`:
  no exclusion mechanism is needed, they simply live on non-Nix host branches.
  Moving a path branch → `main` is the manual `/dotfiles-promote` skill.
- **Never `add -A` in the dotfiles repo**, and never `dotfiles checkout main` on
  a live box — the first can leak an unlisted file, the second deletes every
  host-local file from `$HOME` for the duration.
```

- [ ] **Step 5: Run the full posix test sweep**

Run: `for t in provision/tests/*.test.sh provision/*.test.sh agents/tests/*.test.sh agents/git-hooks/*.test.sh agents/plugin/hooks/tests/*.test.sh scripts/*.test.sh; do echo "== $t"; bash "$t" | tail -1; done`
Expected: `ALL PASS` from each. Any `FAILURES` line is a regression to fix before committing.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(dotfiles): retire chezmoi source and the husk-retirement script"
```

---

# Track B — the `dotfiles` repo

Everything in Track B lands **before any box is enrolled**. Work from a normal (non-bare) clone so the `$HOME` work-tree is never involved:

```bash
# NOT under $HOME: $HOME is the bare repo's work-tree, and main's allow-lines
# (!.gitignore, !README.md, !CLAUDE.md) carry no leading slash, so they match
# at any depth — a clone under $HOME becomes eligible for tracking.
git clone git@github.com:metheoryt/dotfiles.git /private/tmp/dotfiles-work
cd /private/tmp/dotfiles-work
```

All Track B paths below are relative to that clone.

## Task 10: `.gitignore` — D9 rewrite, and remove `.ssh/config` from `main`

Two changes, both on `main`, both prerequisites for enrollment.

**D9** says track rotatable credentials, never private keys — *"leak = rotate, not re-key the fleet."* The current ban block bans `.netrc`, `.npmrc`, `.pypirc`, and `.aws/credentials`; those move to the allow block. The key material stays banned.

**`.ssh/config` must leave `main`.** It is tracked on `main` today and home-manager **deletes** it on `latitude` (`modules/home/ssh.nix` runs `rm -f "$HOME/.ssh/config"` on activation). Under D5 that makes it host-local. Left on `main`, latitude would flap forever: merge `main` → file appears → `just switch` deletes it → `add -u` commits the deletion → push → next merge re-adds it. This is why latitude is enrolled last, and why this task cannot be deferred to spec §10.

`.gitconfig` is **not** on `main` today, so it needs no surgery — it stays an open question, answered per box during enrollment.

**Files:**
- Modify: `.gitignore`
- Delete: `.ssh/config`

- [ ] **Step 1: Rewrite the allow and ban blocks**

Replace sections 4 and 5 of `.gitignore` with:

```gitignore
# 4. Explicitly tracked files. Add one `!` line per file you want tracked.
#
#    SHARED vs HOST-LOCAL is NOT decided here — it is derived from git:
#      git --git-dir=$HOME/.dotfiles --work-tree=$HOME cat-file -e main:<path>
#    exit 0 => the path is on main => shared and byte-identical everywhere.
#    non-zero => host-local. A path is one or the other, never both.
#
#    THIS FILE IS THE ONE DELIBERATE EXCEPTION to shared-XOR-host (D5). It is on
#    main AND it necessarily differs per branch, because a host-local path's `!`
#    line can only live on that host's branch. Nothing else may be both.
#    Consequence: /dotfiles-promote must NEVER auto-apply .gitignore drift — it
#    would push one box's private allow-lines (`!.netrc`, `!.aws/credentials`,
#    `!.ssh/config`) onto main for every other box to inherit. The skill reports
#    it for manual review instead; see .claude/skills/dotfiles-promote/SKILL.md.
!.config/gh/config.yml
!.config/zed/settings.json

#    Rotatable credentials (spec 2026-07-28 D9). Deliberately tracked: this repo
#    is PRIVATE, and the recovery story for a leak here is "rotate the token",
#    not "re-key the fleet". Private keys are the opposite and stay banned below.
!.config/gh/hosts.yml
!.netrc
!.npmrc
!.pypirc
!.aws/credentials

# 5. Belt-and-suspenders. NEVER track key material, whatever a broad `!` rule
#    above might imply. These come LAST so they win, per gitignore
#    last-match-wins precedence. A leak here is unrecoverable by rotation: it is
#    the identity the whole fleet authenticates with.
.secrets
.secrets/
*.pem
*.key
id_rsa*
id_ed25519*
id_ecdsa*
.ssh/id_*
.gnupg/
*.gpg
```

Note `.ssh/config` is gone from the allow block — see step 2.

- [ ] **Step 2: Remove `.ssh/config` from `main`**

```bash
git rm -q --cached .ssh/config
rm -f .ssh/config
```

- [ ] **Step 3: Verify the ban block still wins**

```bash
mkdir -p .ssh && printf 'KEY\n' > .ssh/id_ed25519 && printf 'CERT\n' > server.pem
git check-ignore -v .ssh/id_ed25519 server.pem
git check-ignore -v .netrc 2>&1 || echo "netrc NOT ignored (correct — it is allow-listed)"
rm -f .ssh/id_ed25519 server.pem
```

Expected: both key paths report a match against a line in section 5; `.netrc` reports no match.

- [ ] **Step 4: Commit and push**

```bash
git add .gitignore
git commit -m "feat: track rotatable credentials, move .ssh/config to host branches

D9 (spec 2026-07-28): .netrc/.npmrc/.pypirc/.aws/credentials are rotatable, so
they move from the ban block to the allow block. Key material stays banned.

.ssh/config leaves main because home-manager owns and DELETES it on latitude
(modules/home/ssh.nix). Under the shared-XOR-host invariant it is therefore
host-local: allow-listed on each non-Nix branch, absent from main."
git push origin main
```

---

## Task 11: Move the backend-api project memory into the dotfiles repo

Spec §9.3. `~/pure/backend-api/.claude/memory/project.md` is the file the whole offer-hook exists for: it sits inside a git repo whose allowlist `.gitignore` (`*` plus `!/.claude/*.md`) ignores that path, so a copy written there is machine-local forever.

It lands **host-local first** — on the branch of whichever box works on backend-api — because only some boxes have that repo. Promote it later if that changes.

**Files:**
- Create: `pure/backend-api/.claude/memory/project.md` (on `main`; see the note below on why `main` and not a host branch)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `dotfiles/pure/backend-api/dot_claude/memory/project.md`, still present in the `machines` working tree (Task 9 deliberately left it). This task deletes it once the content has landed here.

**Placement note:** the *content* is shared (it describes a repo, not a machine), so it goes on `main` under D5 — a host that lacks `~/pure/backend-api` simply gets a directory it does not use, which is harmless. The alternative (host-local per box) would mean maintaining N copies of the same facts, which D5 exists to prevent.

- [ ] **Step 1: Copy the file and rewrite its provenance header**

```bash
mkdir -p pure/backend-api/.claude/memory
cp /Users/me/machines/dotfiles/pure/backend-api/dot_claude/memory/project.md \
   pure/backend-api/.claude/memory/project.md
```

If that source path is missing, recover it from git history in `machines`
(Task 9 leaves it in place, so this should not be needed):

```bash
git -C /Users/me/machines log --oneline --all -- dotfiles/pure/backend-api/dot_claude/memory/project.md
git -C /Users/me/machines show <that-ref>:dotfiles/pure/backend-api/dot_claude/memory/project.md
```

Then replace the HTML comment block at the top of `pure/backend-api/.claude/memory/project.md` (everything between `<!--` and `-->`, inclusive) with:

```markdown
<!--
Auto-loaded by the project-memory-check.sh SessionStart hook from
<repo>/.claude/memory/project.md.

NOT tracked in backend-api — its .gitignore is allowlist-style (`*` plus
`!/.claude/*.md`), so this path is ignored there and a file written there would
be machine-local and never sync. It is tracked in the private dotfiles repo
instead, whose work-tree is $HOME, so this file already lives at its real path:
no render step, no apply, no copy. Edit it HERE — this IS the tracked file.

It sits on `main`, so it is shared across every machine that checks out this
path. A host without ~/pure/backend-api just gets an unused directory.

Commit it like any other dotfile:
  git --git-dir=$HOME/.dotfiles --work-tree=$HOME add pure/backend-api/.claude/memory/project.md
The 10-min sync timer commits it to this machine's branch automatically once
tracked; getting it onto `main` is a manual /dotfiles-promote run.

One bullet per fact under a topical heading. Curate — edit or delete stale
entries rather than letting them pile up. No secrets.
-->
```

- [ ] **Step 2: Allow-list the path**

Add to `.gitignore`, in section 4 under the explicitly-tracked block:

```gitignore
!pure/backend-api/.claude/memory/project.md
```

- [ ] **Step 3: Verify it is actually trackable**

Run: `git check-ignore -v pure/backend-api/.claude/memory/project.md || echo "not ignored — trackable"`
Expected: `not ignored — trackable`

- [ ] **Step 4: Commit and push**

```bash
git add .gitignore pure/backend-api/.claude/memory/project.md
git commit -m "feat: track backend-api project memory (homeless in its own repo)

backend-api's .gitignore is allowlist-style and ignores .claude/memory/, so a
copy written there never syncs. dotfiles is its only home. Provenance header
rewritten — it previously documented the retired chezmoi mechanism."
git push origin main
```

- [ ] **Step 5: Delete the chezmoi source directory in `machines`**

The content now has a home, so the last chezmoi artifact can go. This is spec
§9.4's remaining half — Task 9 removed `dot_gitconfig.tmpl`, this removes the
directory.

**Do NOT push `machines` here.** `scripts/converge.sh`'s `touches_linux` gate
matches `provision/linux.sh`, `provision/lib/tiers.sh` and `provision/lib/fleet.sh`
— all three are in the Track A diff — and converge then runs
`provision/linux.sh` in APPLYING mode. Since Track A adds `dotfiles` to the
workstation tier list, the first `machines` push enrolls every linux-class box
unattended, before the branches exist (Task 14) and before checkout collisions
are cleared (Task 15 Step 2). Commit locally; Task 15 Step 1 owns the single push.

```bash
cd /Users/me/machines
git rm -qr dotfiles/
git commit -m "refactor(dotfiles): drop the chezmoi source dir — content moved to the dotfiles repo"
```

Verify: `test -d /Users/me/machines/dotfiles && echo "STILL THERE" || echo "gone"`
Expected: `gone`

Then return to the dotfiles clone for the remaining Track B tasks:

```bash
cd /private/tmp/dotfiles-work
```

---

## Task 12: The `/dotfiles-promote` skill

Spec §5.2 and D11. Tracked on `main` in the dotfiles repo so a clone+checkout delivers it. Doubles as a worked example of tracking a `$HOME` path that is not a classic dotfile.

`~/.claude/skills/` is a real directory; `cyphy` is a symlink *inside* it into `machines`, so a real tracked file sits beside it without conflict. This is a **user-scope** skill (`/dotfiles-promote`, not `/cyphy:dotfiles-promote`).

**Files:**
- Create: `.claude/skills/dotfiles-promote/SKILL.md`
- Modify: `.gitignore`

- [ ] **Step 1: Write the skill**

Create `.claude/skills/dotfiles-promote/SKILL.md`:

````markdown
---
name: dotfiles-promote
description: Use when the user wants to move dotfiles content from this machine's branch onto the shared `main` branch, or asks what on this box could be shared with the rest of the fleet. Reviews host-local tracked paths one at a time and pushes the chosen ones to `main`.
---

# Promote dotfiles from this machine's branch to `main`

## The one rule that matters

**Never run `dotfiles checkout main`.** The work-tree is `$HOME`. Host-local
files are tracked on this machine's branch and absent from `main`, so switching
the work-tree to `main` **deletes every one of them from `$HOME`** — including
`~/.ssh/config`. An interrupted run leaves a stripped home directory with no ssh
config and no obvious way back.

Build `main` in a throwaway **linked worktree** instead. `$HOME` is never touched.

## Setup

```bash
dotfiles() { git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" "$@"; }
branch="$(dotfiles rev-parse --abbrev-ref HEAD)"
# Explicit refspec: `git clone --bare` sets no remote.origin.fetch, so on a
# repo cloned by hand there is no refs/remotes/origin/* and every origin/main
# below fails to resolve. The provision role configures the refspec; this
# skill is what a human runs when something is already wrong, so it names it.
dotfiles fetch origin '+refs/heads/main:refs/remotes/origin/main'
```

If `$branch` is `main`, stop and tell the user: this box is misconfigured, the
sync timer will refuse to run, and promoting from `main` to `main` is a no-op.

## Step 1: report any standing sync conflict

```bash
cat "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync/conflict" 2>/dev/null
```

If that file exists, say so first. It means the sync timer has stopped merging
`origin/main` in — this box's view of `main` is stale, and promoting on top of a
stale view will produce a surprising diff. Offer to resolve it before continuing.

## Step 2: derive the two classes

Shared-vs-host is **derived from git**, never stored:

```bash
dotfiles ls-files | while read -r p; do
  [ "$p" = ".gitignore" ] && { echo "MANUAL $p"; continue; }
  if dotfiles cat-file -e "origin/main:$p" 2>/dev/null; then
    dotfiles diff --quiet "origin/main" -- "$p" || echo "DRIFT $p"
  else
    echo "HOSTONLY $p"
  fi
done
```

| class | meaning | how to handle |
|---|---|---|
| `DRIFT` | on `main` but this branch differs | **No question.** By the shared-XOR-host invariant it belongs on `main`. List it and include it. |
| `HOSTONLY` | tracked here, absent from `main` | **Ask per path**: promote to shared, or keep host-local? |
| `MANUAL` | `.gitignore` only | **Never auto-apply.** Show the diff, promote only the lines the user names. |

### Why `.gitignore` is special-cased

It is the single deliberate exception to shared-XOR-host: it lives on `main`
*and* differs per branch, because a host-local path's `!` line can only exist on
that host's branch. So it drifts on every box, permanently, by design.

Auto-applying that drift would push this box's private allow-lines — `!.netrc`,
`!.aws/credentials`, `!.ssh/config` — onto `main`, where every other branch
inherits them on the next sync tick. Show `dotfiles diff origin/main -- .gitignore`
and ask which lines are genuinely fleet-wide. Usually: none.

If you do promote `.gitignore` lines, expect the next sync tick on *other* boxes
to merge cleanly only if their own `.gitignore` did not move in the same region.
A conflict there is normal and safe — `$HOME` is untouched and the marker
explains it.

Present `HOSTONLY` paths one at a time with a one-line description of what each
file is. Do not batch them into a single yes/no.

**Warn — do not block — on these paths:** `.ssh/config`, `.gitconfig`. They are
home-manager-owned on `latitude` today, so putting them on `main` means every
branch inherits them and `latitude` fights them on each `just switch`. Say that
plainly and let the user decide. The warning becomes moot when NixOS retires.

## Step 3: promote in a throwaway worktree

With the selected paths in `$paths`:

```bash
wt="$(mktemp -d)/dotfiles-promote"
dotfiles worktree add "$wt" origin/main      # $HOME untouched
git -C "$wt" checkout "$branch" -- $paths
git -C "$wt" commit -m "promote from $branch: $paths"
git -C "$wt" push origin HEAD:main
dotfiles worktree remove --force "$wt"
```

Promote takes file **content**, not commits. That is deliberate: after the push
both sides hold byte-identical content at those paths, so step 4 cannot conflict.
Cherry-picking commits would drag along unrelated history and can conflict.

If the push is rejected because `main` moved, re-run from Step 1 — do not force.

## Step 4: bring `main` back down

```bash
dotfiles fetch origin '+refs/heads/main:refs/remotes/origin/main'
dotfiles merge --no-edit --ff origin/main
```

Clean by construction. If this conflicts, something changed `main` between step
3 and step 4 — stop and report it rather than resolving blind, because the
resolution writes into live `$HOME`.

## Step 5: tell the user what moved

Name every promoted path and say what is now shared fleet-wide. A path on `main`
is byte-identical on every machine from the next sync tick onward — that is a
fleet-wide change, and it should never be a surprise.
````

- [ ] **Step 2: Allow-list it**

Add to `.gitignore`, section 4:

```gitignore
!.claude/skills/dotfiles-promote/SKILL.md
```

- [ ] **Step 3: Verify it is trackable and the frontmatter parses**

```bash
git check-ignore -v .claude/skills/dotfiles-promote/SKILL.md || echo "trackable"
head -4 .claude/skills/dotfiles-promote/SKILL.md
```

Expected: `trackable`, then a `---` / `name:` / `description:` / `---` block.

- [ ] **Step 4: Rehearse the flow against a scratch repo**

Spec §8 requires asserting that promote leaves `$HOME` untouched and that a
host-local path absent from `main` still exists after a full run. The skill is
prose, not a script, so that assertion has to be executed by hand once. Do it:

```bash
R="$(mktemp -d)"
git init -q --bare "$R/remote.git"
git init -q -b main "$R/seed"
printf 'shared\n' > "$R/seed/.shared"
printf '*\n!*/\n!.gitignore\n!.shared\n!.hostonly\n' > "$R/seed/.gitignore"
git -C "$R/seed" -c user.email=t@t -c user.name=t add -A
git -C "$R/seed" -c user.email=t@t -c user.name=t commit -qm init
git -C "$R/seed" push -q "$R/remote.git" main

mkdir -p "$R/home"
git clone -q --bare "$R/remote.git" "$R/home/.dotfiles"
dotfiles() { git --git-dir="$R/home/.dotfiles" --work-tree="$R/home" "$@"; }
dotfiles config user.email t@t; dotfiles config user.name t
dotfiles config status.showUntrackedFiles no
dotfiles checkout -q -b air main
printf 'local-only\n' > "$R/home/.hostonly"
dotfiles add "$R/home/.hostonly"
dotfiles commit -qm "track hostonly"
dotfiles push -q -u origin air

# --- the promote flow from Step 3 of the skill ---
wt="$R/wt"
dotfiles worktree add -q "$wt" origin/main
git -C "$wt" checkout air -- .hostonly
git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "promote from air: .hostonly"
git -C "$wt" push -q origin HEAD:main
dotfiles worktree remove --force "$wt"
dotfiles fetch -q origin main
dotfiles merge -q --no-edit --ff origin/main

# --- the two assertions ---
[ "$(cat "$R/home/.hostonly")" = "local-only" ] \
  && echo "PASS host-local file survived the whole run" || echo "FAIL .hostonly damaged"
[ "$(dotfiles rev-parse --abbrev-ref HEAD)" = air ] \
  && echo "PASS work-tree never switched off the machine branch" || echo "FAIL HEAD moved"
git --git-dir="$R/remote.git" cat-file -e main:.hostonly \
  && echo "PASS content reached main" || echo "FAIL nothing promoted"
rm -rf "$R"; unset -f dotfiles
```

Expected: three `PASS` lines. If any fails, the skill's step 3 is wrong — fix
the SKILL.md before committing, not the rehearsal.

- [ ] **Step 5: Commit and push**

```bash
git add .gitignore .claude/skills/dotfiles-promote/SKILL.md
git commit -m "feat: add the /dotfiles-promote skill (D11 — lives here, not in machines)"
git push origin main
```

---

## Task 13: Rewrite `README.md` and `CLAUDE.md`

Both currently say *"one branch per **hostname** (e.g. `latitude5520`, matching `hostname`)"* — the exact thing D2 reverses. Both also present the `dotfiles` alias as fish-only, while the primary shell here is zsh.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `README.md`**

Replace the `## Branches` section with:

```markdown
## Branches

- **`main`** — content shared across every machine, byte-identical everywhere.
- **One branch per machine**, named by its **logical fleet name** — `latitude`,
  `air`, `desktop`, `server`, `hub`. Not the OS hostname: those churn
  (`methe-server` → `g513ie`, 2026-07-20) and a rename would orphan the branch.

Each machine checks out its own branch and **stays there**. Never
`dotfiles checkout main` on a live box — host-local files are absent from `main`,
so the checkout deletes them from `$HOME`.

### Shared or host-local — derived, never stored

A path is on `main` (**shared**) or on host branches only (**host-local**).
**Never both.** There is no routing manifest; the answer is a git query:

```console
$ dotfiles cat-file -e main:.config/zed/settings.json   # exit 0 => shared
```

If any machine needs different content at a path, that path leaves `main`
entirely and each branch carries its own copy. This is why `~/.ssh/config` and
`~/.gitconfig` are not on `main`: home-manager owns them on `latitude`.

### Sync and promote

A 10-minute timer (`machines/provision/dotfiles-sync.sh`, installed by the
`dotfiles` provision role) commits tracked changes to this machine's branch,
pushes them, and fast-forwards `origin/main` in — behind a
`git merge-tree --write-tree` preflight, so a conflicting `main` is detected in
the object store and **never written into live `$HOME`**. A conflict drops a
marker at `~/.local/state/dotfiles-sync/conflict` and stops merging until
resolved; commits and pushes keep running, so local work is never at risk.

Moving content the other way — branch → `main` — is manual and explicit: run
`/dotfiles-promote`.
```

Replace the `## Bootstrapping a new machine` section with:

```markdown
## Bootstrapping a new machine

Normally you do not: the `dotfiles` role in the `machines` repo clones the repo,
checks out this host's branch, and installs the sync timer.

```console
$ cd ~/machines && bash provision/provision.sh --apply
```

By hand, if you need to:

```console
$ git clone --bare git@github.com:metheoryt/dotfiles.git $HOME/.dotfiles
$ dotfiles() { git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" "$@"; }
$ dotfiles config status.showUntrackedFiles no
$ dotfiles config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
$ dotfiles fetch origin
$ dotfiles checkout <logical-fleet-name>    # latitude | air | desktop | server | hub
```

The `remote.origin.fetch` line is not optional. `git clone --bare` configures no
refspec, so without it the clone has no `refs/remotes/origin/*` at all and every
`origin/main` reference — including the sync timer's merge step — silently fails
to resolve.

If `checkout` complains that existing files in `$HOME` would be overwritten,
back them up (or delete them) and retry.
```

Update the `## The `dotfiles` command` section — replace the fish-alias block with:

```markdown
The repo is bare, so every git call needs both `--git-dir` and `--work-tree`.
A shell function wraps the pair. In zsh/bash (`~/.zshrc`):

```sh
dotfiles() { git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" "$@"; }
```

In fish (`~/.config/fish/config.fish`):

```fish
alias dotfiles 'git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
```

Where neither is loaded — a script, a hook, the Bash tool — spell it out:

```console
$ git --git-dir=$HOME/.dotfiles --work-tree=$HOME status
```
```

Update the `## What's tracked` table: drop the `.ssh/config` row, and add:

```markdown
| `pure/backend-api/.claude/memory/project.md` | Project memory for a repo whose own `.gitignore` ignores it |
| `.claude/skills/dotfiles-promote/SKILL.md` | The `/dotfiles-promote` skill |
```

Update the `## Secrets` section's deny-block list — `.netrc`, `.npmrc`,
`.pypirc`, and `.aws/credentials` are now **tracked**, not banned:

```markdown
## Secrets

This repo is **private**, which is what makes tracking credentials viable at all.
Two layers still apply:

1. **Allow-only by default.** A file is untracked unless explicitly unignored,
   so nothing leaks by accident.
2. **A deny block** at the end of `.gitignore` re-ignores key material —
   `*.pem`, `*.key`, `*.gpg`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`,
   `.ssh/id_*`, `.gnupg/`, `.secrets/`. These come **last**, so by gitignore's
   last-match-wins rule they override any broad `!` allow above them.

**Rotatable credentials are tracked on purpose** — `.netrc`, `.npmrc`,
`.pypirc`, `.aws/credentials`, `.config/gh/hosts.yml`. The recovery story for a
leak there is *rotate the token*. Private keys are the opposite: a leak means
re-keying the whole fleet, so they are never tracked, at any layer.

Before staging anything that looks sensitive, confirm it's still ignored:

```console
$ dotfiles check-ignore -v ~/.ssh/id_ed25519
```
```

- [ ] **Step 2: Update `CLAUDE.md`**

Replace the `## Branches` section with:

```markdown
## Branches

- **`main`** — content shared across every machine, byte-identical everywhere.
- **One branch per machine**, named by its **logical fleet name** — `latitude`,
  `air`, `desktop`, `server`, `hub` — not the OS hostname.

**Never run `dotfiles checkout main` on a live box.** Host-local files are
tracked on the machine branch and absent from `main`, so the checkout deletes
them from `$HOME` — including `~/.ssh/config`. If you need `main`'s content, use
a linked worktree: `dotfiles worktree add /tmp/x origin/main`.

Shared-vs-host is **derived from git**, never stored:

```console
git --git-dir=$HOME/.dotfiles --work-tree=$HOME cat-file -e main:<path>
```

Exit 0 means the path is on `main` and therefore shared. Non-zero means
host-local. **A path is one or the other, never both** — if a machine needs
different content at a path, that path leaves `main` entirely.

## The sync timer

A 10-minute timer (`machines/provision/dotfiles-sync.sh`) commits tracked
changes to this machine's branch, pushes, and merges `origin/main` in. Things it
will do that can surprise you:

- **It commits on its own.** A file you edit and leave half-written can land in a
  commit. Harmless — the next tick commits the finished version, and nothing
  reaches `main` without a manual promote.
- **It never stages a new file.** It runs `add -u`, which only touches already-
  tracked paths. A new file needs the explicit two-step below.
- **It refuses to run if HEAD is not on the expected branch**, recorded at
  `~/.local/state/dotfiles-sync/branch`. If you check out another branch here,
  sync stops until you check back.
- **A conflict stops merging, never writing.** `~/.local/state/dotfiles-sync/conflict`
  is the marker. `$HOME` is left untouched.

Moving content from this branch to `main` is the `/dotfiles-promote` skill.
Never automatic.
```

Update the `## Secrets` section to match README's — remove `.netrc`, `.npmrc`,
`.pypirc`, `.aws/credentials` from the deny list, and add the "rotatable
credentials are tracked on purpose" paragraph.

- [ ] **Step 3: Verify no stale hostname-branch language survives**

Run: `grep -n "latitude5520\|matching \`hostname\`\|per hostname" README.md CLAUDE.md || echo "clean"`
Expected: `clean`

- [ ] **Step 4: Commit and push**

```bash
git add README.md CLAUDE.md
git commit -m "docs: logical-name branches, derived shared/host rule, sync timer, promote"
git push origin main
```

---

## Task 14: Rename and create the branches

Spec §9.1 and §9.2. Every branch is created from the **finished** `main`, so Tasks 10–13 must be pushed first.

**Files:** none — remote git operations only.

- [ ] **Step 1: Confirm `main` is final**

```bash
git fetch origin
git log --oneline origin/main -6
git ls-tree -r --name-only origin/main
```

Expected: the tree contains `.gitignore`, `README.md`, `CLAUDE.md`, `.config/gh/config.yml`, `.config/zed/settings.json`, `.claude/skills/dotfiles-promote/SKILL.md`, `pure/backend-api/.claude/memory/project.md` — and **no** `.ssh/config`. If `.ssh/config` is still there, Task 10 Step 2 did not land; stop and fix it.

- [ ] **Step 2: Rename `latitude5520` → `latitude`**

```bash
git fetch origin latitude5520:refs/heads/latitude5520-local
git push origin refs/heads/latitude5520-local:refs/heads/latitude
git push origin --delete latitude5520
git branch -D latitude5520-local
```

Verify: `gh api repos/metheoryt/dotfiles/branches --jq '.[].name'`
Expected: `latitude`, `main` — no `latitude5520`.

Note this branch's `.ssh/config` history is preserved on `latitude`, which is
correct: the path is host-local now, and latitude is where home-manager will
delete it. Task 15's latitude step handles that.

- [ ] **Step 3: Create the four remaining branches from `main`**

```bash
for b in air desktop server hub; do
  git push origin "origin/main:refs/heads/$b"
done
```

Verify: `gh api repos/metheoryt/dotfiles/branches --jq '.[].name' | sort | tr '\n' ' '`
Expected: `air desktop hub latitude main server`

- [ ] **Step 4: Confirm `main` is not directly pushable by accident**

This is a convention, not a protection rule — the promote flow pushes to `main`
deliberately. Just confirm no machine branch is set as the default:

Run: `gh api repos/metheoryt/dotfiles --jq .default_branch`
Expected: `main`

---

## Task 15: Enrollment — `air`, `desktop`, `server`, `hub`, then `latitude`

> **Executed 2026-07-28.** Enrolled: `air`, `hub`, `desktop`, `latitude`, and
> the WSL host `desktop-ubuntu26` (branch auto-created from `main`).
> **`server` is still pending — it was offline.** Enroll it by hand when it is
> back: converge on a Windows box runs `windows.ps1` only and never the role.
> Deviations from the steps below are recorded in `.claude/memory/project.md`.

**Order is load-bearing.** `latitude` is last because it is the only box running an active deleter (`modules/home/ssh.nix`). Everything else is safe to enroll in any order.

This task is inherently interactive — it touches real machines. Run one box per step and verify before moving on.

**Files:** none in either repo. This is deployment.

**Interfaces:**
- Consumes: everything from Tasks 1–14. Requires the `machines` Track A commits to be pushed and pulled on each box first.

- [x] **Step 1: Push Track A and let the fleet pull**

```bash
cd /Users/me/machines
git push origin main
```

Wait for the 10-minute `fleet-selfpull` tick, or force it per box. Verify each box has the new files before provisioning it:

```bash
ssh <box> 'bash -lc "cd ~/machines && git log --oneline -1 && test -f provision/dotfiles-sync.sh && echo sync-script-present"'
```

- [x] **Step 2: Clear checkout collisions on every box first**

The bare checkout is refused when an untracked file already occupies a tracked
path, and on a box in daily use that is the **normal** case — `air` already has
`~/.config/gh/config.yml`, and `main` tracks it. The role now fails loudly rather
than half-enrolling (Task 6), but clearing the collisions up front turns each
enrollment into one clean pass.

**First, on each box, check `core.excludesFile`.** The dotfiles `.gitignore`
lands at `$HOME/.gitignore` on checkout and its first line is `*`. Git's default
excludes file is `~/.config/git/ignore`, but `~/.gitignore` is a common manual
setting — and on a box where it is set, enrolling makes `*` the global ignore
pattern for every repo on that machine.

```bash
git config --global core.excludesFile     # empty or ~/.config/git/ignore => safe
```

Anything resolving to `~/.gitignore` must be repointed before the checkout.

**Then check `gh`'s config before moving it aside.** Two GitHub accounts are live
simultaneously and account selection runs through config; a stale tracked
`config.yml` can silently change which account `gh` authenticates as. Diff first,
and do not proceed past a difference without reading it:

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME show main:.config/gh/config.yml \
  | diff - ~/.config/gh/config.yml && echo "identical — safe to replace"
```

Per box, before provisioning it:

```bash
for p in .config/gh/config.yml .config/zed/settings.json; do
  [ -e "$HOME/$p" ] && mv -v "$HOME/$p" "$HOME/$p.pre-dotfiles"
done
```

Also move any file listed in `main`'s tree that exists locally:

```bash
gh api "repos/metheoryt/dotfiles/git/trees/main?recursive=1" --jq '.tree[]|select(.type=="blob").path'
```

After enrollment, diff each `.pre-dotfiles` backup against the checked-out
version and merge anything worth keeping — then delete the backup. **`gh`'s
`config.yml` is the one to actually read**: a stale tracked copy can change
which account `gh` uses.

- [x] **Step 3: Enroll `air` (this MacBook)** — enrolled and verified. The
  closing question below (track `~/.gitconfig` / `~/.ssh/config` on air's
  branch?) was NOT decided and is still open; both remain untracked on every
  branch.

`air` has no `~/.dotfiles` today.

```bash
cd /Users/me/machines
bash provision/provision.sh --machine air          # dry-run first, review the plan
bash provision/provision.sh --machine air --apply
```

Verify:

```bash
git --git-dir=$HOME/.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD   # => air
cat ~/.local/state/dotfiles-sync/branch                                        # => air
launchctl print "gui/$(id -u)/kz.cyphy.dotfiles-sync" | head -5                # => the job exists
DOTFILES_SYNC_LIB_ONLY= bash provision/dotfiles-sync.sh; echo "exit=$?"        # => exit=0
git --git-dir=$HOME/.dotfiles --work-tree=$HOME log --oneline -3 air
```

Then decide the open question for this box: does `air` want `~/.gitconfig` and
`~/.ssh/config` tracked on its branch? If yes, that is the documented two-step
(`!path` line in `~/.gitignore`, then `dotfiles add`), and it lands host-local.

- [x] **Step 4: Enroll `hub`**

```bash
ssh hub 'bash -lc "cd ~/machines && git pull --ff-only && bash provision/provision.sh --machine hub --apply"'
```

Verify:

```bash
ssh hub 'bash -lc "git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME rev-parse --abbrev-ref HEAD; cat ~/.local/state/dotfiles-sync/branch; systemctl --user list-timers dotfiles-sync.timer --no-pager"'
```

Remember: remote commands go through `bash -lc` — hub's login shell may be fish,
which cannot parse bash loops or `$(...)` the same way.

If hub's git is below 2.38 (checked in Task 3 Step 5), confirm the guard fired
rather than a merge being attempted:

```bash
ssh hub 'bash -lc "bash ~/machines/provision/dotfiles-sync.sh 2>&1 | grep merge-tree || echo no-floor-warning"'
```

- [x] **Step 5: Enroll `desktop` and `server`**

Both are Windows-native. Run from a normal login on each box (not headless
SYSTEM — the scheduled task needs an interactive-user principal):

```powershell
cd $HOME\machines
git pull --ff-only
powershell -ExecutionPolicy Bypass -File provision\windows.ps1
powershell -ExecutionPolicy Bypass -File provision\provision.ps1 -Mode apply -Machine desktop   # or: server
```

Verify on each:

```powershell
git --git-dir=$HOME\.dotfiles --work-tree=$HOME rev-parse --abbrev-ref HEAD
Get-Content $HOME\.local\state\dotfiles-sync\branch
Get-ScheduledTask -TaskName dotfiles-sync | Select-Object TaskName, State
powershell -File $HOME\machines\provision\dotfiles-sync.ps1; $LASTEXITCODE
```

Expected: the logical name (`desktop` / `server`), the task in `Ready`, exit `0`.

This is also where Task 4, 5 and 7's deferred `pwsh` parse checks get resolved,
if they could not run on the Mac.

- [x] **Step 6: Enroll `latitude` — last, and with the `.ssh/config` check**

Before provisioning, confirm `main` no longer carries `.ssh/config` — if it does,
the flap described in Task 10 starts the moment the timer runs:

```bash
gh api "repos/metheoryt/dotfiles/git/trees/main?recursive=1" --jq '.tree[].path' \
  | grep -qx '.ssh/config' && echo "STOP — .ssh/config still on main" || echo "safe to enroll latitude"
```

Only proceed on `safe to enroll latitude`.

`latitude`'s branch still tracks `.ssh/config` from before the rename. Home-manager
will delete the file on the next `just switch`, and the timer will commit that
deletion to the `latitude` branch — which is correct and expected: the path is
host-local, and on this host its local content is "absent." Nothing propagates to
`main`, because promote is manual.

```bash
ssh latitude 'bash -lc "cd ~/machines && git pull --ff-only && bash provision/provision.sh --machine latitude --apply"'
```

Verify:

```bash
ssh latitude 'bash -lc "git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME rev-parse --abbrev-ref HEAD; cat ~/.local/state/dotfiles-sync/branch; systemctl --user list-timers dotfiles-sync.timer --no-pager; ls ~/.local/state/dotfiles-sync/"'
```

Expected: branch `latitude`, timer active, **no** `conflict` file.

- [x] **Step 7: Let one full cycle run, then check every box for a conflict marker**

Wait ~15 minutes, then:

```bash
ls ~/.local/state/dotfiles-sync/ 2>/dev/null
for h in hub latitude; do echo "== $h"; ssh "$h" 'bash -lc "ls ~/.local/state/dotfiles-sync/ 2>/dev/null"'; done
```

Expected: `branch` and possibly `lock`/`lock.d` on each — **no** `conflict`. A
conflict marker anywhere means Track B left `main` and some branch genuinely
divergent; read the marker, resolve by hand on that box, and confirm the next
tick clears it.

- [x] **Step 8: Record the outcome**

Append to `machines/.claude/memory/project.md` under the dotfiles heading:

```markdown
- **Enrollment completed 2026-07-28** — branches `latitude` (renamed from
  `latitude5520`), `air`, `desktop`, `server`, `hub`, all from `main`.
  `.ssh/config` was removed from `main` during migration because home-manager
  deletes it on latitude; it is host-local on every branch that wants it.
```

Then commit in `machines`:

```bash
git add .claude/memory/project.md
git commit -m "docs(memory): record dotfiles enrollment across the fleet"
git push origin main
```

---

## Deliberately not in this plan

- **NixOS retirement** and **Claude profile retirement** — spec §1 scopes both out; each needs its own brainstorm. Spec §7 explains why nothing here needs rework when NixOS goes.
- **age-encrypted secrets** — a private repo is the answer for now (spec §1).
- **The `enabledPlugins` project-scope probe** (spec §10) — gates profile retirement, gates nothing here.
- **Enrolling self-declared WSL hosts** — the mechanism is wired (Task 1's resolver, Task 6's `tier_dotfiles`), but no WSL box is in the enrollment list. Enrolling one is a later, separate act: run `bash ~/machines/provision/linux.sh` on it after its `fleet.local.json` exists.
- **`.gitconfig` on any branch** — spec §10's second open question. It is not on `main`, so it needs no migration; answer it per box during Task 15, where each step already prompts for it.
