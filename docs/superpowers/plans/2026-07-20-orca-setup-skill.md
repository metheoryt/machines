# /orca-setup Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a cyphy-plugin skill `/orca-setup` that, run once per repo, scaffolds the repo's committed `.orca/worktree-setup.sh` custom-rules delegate and prints the Orca setup-script one-liner for the user to paste into Orca's UI — never writing `orca-data.json`, never closing the IDE.

**Architecture:** Three artifacts under `agents/plugin/skills/orca-setup/`. `SKILL.md` is the orchestration procedure (guard → scaffold → print). `orca-status.sh` is a deterministic, **read-only** helper that reports how the repo's Orca setup field is currently wired (`WIRED`/`UNWIRED`/`ABSENT`/`CONFLICT`). `worktree-setup.template.sh` is the non-fatal scaffold copied to `$base/.orca/worktree-setup.sh`. Two standalone bash test scripts mock the inputs.

**Tech Stack:** Bash, `jq`, git. Same mock-the-tools test style as the sibling `agents/plugin/skills/ship/tests/fleet-pull.test.sh`.

## Global Constraints

- **Read-only toward Orca config.** `orca-status.sh` MUST NOT write, truncate, or re-serialize `orca-data.json`. The skill never mutates Orca config and never asks the user to close Orca. The only write the skill performs is scaffolding `$base/.orca/worktree-setup.sh` (a repo file the user commits).
- **Scaffold is non-fatal.** The generated `.orca/worktree-setup.sh` and the template it comes from MUST NOT use `set -e` and MUST end with `exit 0`. A failing step logs a `WARN:` to stderr and continues.
- **Identity by projectId, path as fallback.** Match Orca entries on the normalized origin → `projectId` (`github:owner/repo`) against `.projectHostSetups[]`; fall back to `.repos[]` matched by base checkout path (`.repos[]` carries no `projectId`). Never treat path as the primary key.
- **Base checkout resolution.** Resolve the base checkout as the parent of `git rev-parse --git-common-dir` (works from a worktree or a main checkout), exactly as `scripts/orca-worktree-setup.sh` does.
- **Refuse work/Pure repos.** If `git remote get-url origin` matches `thepureapp/`, STOP — those keep the pure-dev PR flow.
- **The dispatcher one-liner is exactly** `bash "$HOME/machines/scripts/orca-worktree-setup.sh"` (stored verbatim, including the double quotes, in `orca-data.json`).
- **Absolute, profile-independent script paths in SKILL.md:** reference helpers as `~/machines/agents/plugin/skills/orca-setup/<script>` (the `cyphy` plugin is symlinked into every profile; the repo path is stable).
- **Gortex readiness is opt-in** via the `ORCA_GORTEX=1` env var and degrades silently when `gortex` is absent.
- **Tests are standalone.** Each test file runs via `bash <file>`, prints `PASS`/`FAIL` lines, and exits nonzero if any assertion failed (mirror `fleet-pull.test.sh`).
- **Helpers use `set -u`;** the scaffold/template does NOT (non-fatal contract).

---

### Task 1: `orca-status.sh` — read-only wiring status

**Files:**
- Create: `agents/plugin/skills/orca-setup/orca-status.sh`
- Test: `agents/plugin/skills/orca-setup/tests/orca-status.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a CLI contract used by `SKILL.md` (Task 3):
  `orca-status.sh <orca-data.json-path> <origin-url> <expected-setup> <base-path>`
  prints exactly ONE line to stdout, one of:
  - `WIRED` — the matched entry's setup equals `<expected-setup>`
  - `UNWIRED` — the matched entry exists but its setup is empty/unset
  - `ABSENT` — no entry matches (repo not opened in Orca yet)
  - `CONFLICT\t<current-value>` — a different non-empty setup is configured (tab-separated)
  Always exits 0. Never modifies `<orca-data.json-path>`.

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/skills/orca-setup/tests/orca-status.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior tests for orca-status.sh — builds a fixture orca-data.json, runs the
# helper for each matrix branch, and asserts the emitted token. Also asserts the
# fixture is byte-identical afterwards (read-only contract).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../orca-status.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

DISPATCH='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'

DATA="$tmp/orca-data.json"
cat > "$DATA" <<JSON
{
  "repos": [
    { "path": "/base/machines", "hookSettings": { "scripts": { "setup": "$DISPATCH" } } },
    { "path": "/base/reposonly", "hookSettings": { "scripts": { "setup": "$DISPATCH" } } }
  ],
  "projectHostSetups": [
    { "projectId": "github:metheoryt/machines", "path": "/base/machines",
      "hookSettings": { "scripts": { "setup": "$DISPATCH" } } },
    { "projectId": "github:metheoryt/empty", "path": "/base/empty",
      "hookSettings": { "scripts": { "setup": "" } } },
    { "projectId": "github:metheoryt/foreign", "path": "/base/foreign",
      "hookSettings": { "scripts": { "setup": "bash /some/other-setup.sh" } } }
  ]
}
JSON

# WIRED — all origin URL forms of the same repo canonicalize to the same projectId
for u in \
  "git@github.com:metheoryt/machines.git" \
  "git@github.com:metheoryt/machines" \
  "https://github.com/metheoryt/machines.git" \
  "ssh://git@github.com/metheoryt/machines.git" ; do
  got="$(bash "$SCRIPT" "$DATA" "$u" "$DISPATCH" "/base/machines")"
  [ "$got" = "WIRED" ] && pass "WIRED $u" || die "WIRED $u -> '$got'"
done

# UNWIRED — entry present, setup empty
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/empty.git" "$DISPATCH" "/base/empty")"
[ "$got" = "UNWIRED" ] && pass "UNWIRED" || die "UNWIRED -> '$got'"

# CONFLICT — different non-empty setup, value reported after a tab
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/foreign.git" "$DISPATCH" "/base/foreign")"
[ "$got" = "$(printf 'CONFLICT\tbash /some/other-setup.sh')" ] \
  && pass "CONFLICT" || die "CONFLICT -> '$got'"

# ABSENT — no matching projectId and no matching path
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/nope.git" "$DISPATCH" "/base/nope")"
[ "$got" = "ABSENT" ] && pass "ABSENT" || die "ABSENT -> '$got'"

# Fallback — repo only in .repos[] (by path), not in projectHostSetups -> WIRED
got="$(bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/reposonly.git" "$DISPATCH" "/base/reposonly")"
[ "$got" = "WIRED" ] && pass "repos-fallback WIRED" || die "repos-fallback -> '$got'"

# Missing data file -> ABSENT, never an error
got="$(bash "$SCRIPT" "$tmp/nofile.json" "git@github.com:metheoryt/machines.git" "$DISPATCH" "/base/machines")"
[ "$got" = "ABSENT" ] && pass "missing-file ABSENT" || die "missing-file -> '$got'"

# READ-ONLY — fixture is byte-identical after all runs
before="$(cksum "$DATA")"
bash "$SCRIPT" "$DATA" "git@github.com:metheoryt/machines.git" "$DISPATCH" "/base/machines" >/dev/null
after="$(cksum "$DATA")"
[ "$before" = "$after" ] && pass "read-only (fixture unchanged)" || die "fixture mutated!"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/skills/orca-setup/tests/orca-status.test.sh`
Expected: fails immediately — `orca-status.sh` does not exist yet, so every `bash "$SCRIPT" …` errors and the assertions go RED (or the script aborts). Ends with `SOME FAILED`, nonzero exit.

- [ ] **Step 3: Write `orca-status.sh`**

Create `agents/plugin/skills/orca-setup/orca-status.sh`:

```bash
#!/usr/bin/env bash
# orca-status.sh — READ-ONLY report of how a repo's Orca worktree setup-script
# field is currently wired. Never writes orca-data.json; safe with Orca open.
#
# Usage: orca-status.sh <orca-data.json> <origin-url> <expected-setup> <base-path>
# Prints ONE line: WIRED | UNWIRED | ABSENT | CONFLICT<TAB><current-value>. Exit 0.
#
# Note: this derives Orca's `github:owner/repo` projectId, a DIFFERENT string
# shape from fleet-pull.sh's `host/owner/repo` normalize_url — the two serve
# different stores, so the small overlap in URL-stripping is intentional, not a
# missed DRY.
set -u

DATA="${1:-}"; ORIGIN="${2:-}"; EXPECT="${3:-}"; BASE="${4:-}"

[ -n "$DATA" ] && [ -f "$DATA" ] || { echo "ABSENT"; exit 0; }

# Derive Orca's projectId (e.g. github:owner/repo) from a git origin URL.
project_id() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"     # strip any user@
  u="${u/://}"                    # scp-form host:owner -> host/owner (first :)
  u="${u/:/\/}"                   # port-less colon safeguard
  local host="${u%%/*}" rest="${u#*/}"
  local provider
  case "$host" in
    github.com)    provider=github ;;
    gitlab.com)    provider=gitlab ;;
    bitbucket.org) provider=bitbucket ;;
    *)             provider="$host" ;;
  esac
  printf '%s:%s' "$provider" "$rest"
}

pid="$(project_id "$ORIGIN")"

# Read current setup: prefer .projectHostSetups[] matched by projectId; fall back
# to .repos[] matched by base path (.repos[] has no projectId). "" means the key
# is present but unset; sentinel __ABSENT__ means no entry in either array.
current="$(jq -r --arg pid "$pid" --arg base "$BASE" '
  ( [ .projectHostSetups[]? | select(.projectId == $pid) ] ) as $phs
  | ( [ .repos[]? | select(.path == $base) ] ) as $rp
  | if   ($phs | length) > 0 then ($phs[0].hookSettings.scripts.setup // "")
    elif ($rp  | length) > 0 then ($rp[0].hookSettings.scripts.setup  // "")
    else "__ABSENT__" end
' "$DATA" 2>/dev/null)" || current="__ABSENT__"

case "$current" in
  __ABSENT__) printf 'ABSENT\n' ;;
  "")         printf 'UNWIRED\n' ;;
  "$EXPECT")  printf 'WIRED\n' ;;
  *)          printf 'CONFLICT\t%s\n' "$current" ;;
esac
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash agents/plugin/skills/orca-setup/tests/orca-status.test.sh`
Expected: every line `PASS …`, final line `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x agents/plugin/skills/orca-setup/orca-status.sh
git add agents/plugin/skills/orca-setup/orca-status.sh \
        agents/plugin/skills/orca-setup/tests/orca-status.test.sh
git commit -m "feat(orca-setup): read-only orca-data.json wiring status"
```

---

### Task 2: `worktree-setup.template.sh` — the committed `.orca` scaffold

**Files:**
- Create: `agents/plugin/skills/orca-setup/worktree-setup.template.sh`
- Test: `agents/plugin/skills/orca-setup/tests/template.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the exact byte content that `SKILL.md` (Task 3) copies verbatim to `$base/.orca/worktree-setup.sh`. It carries two marker-delimited managed blocks that re-runs may update:
  - `orca-setup:managed:repo-steps`
  - `orca-setup:managed:gortex-readiness`
  The template is a complete, runnable, non-fatal bash script (no substitution at scaffold time — the gortex block resolves everything at worktree-creation runtime).

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/skills/orca-setup/tests/template.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior tests for worktree-setup.template.sh — the scaffold copied into a
# repo's .orca/. Asserts the non-fatal contract (always exit 0) and the opt-in
# gortex-readiness behavior, with `gortex` mocked on PATH.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../worktree-setup.template.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# The template must be a valid bash script that never uses `set -e` and ends at exit 0.
grep -q 'set -e' "$TEMPLATE" && die "template must not use set -e" || pass "no set -e"
grep -q 'exit 0' "$TEMPLATE" && pass "has exit 0" || die "template missing exit 0"
grep -q 'orca-setup:managed:repo-steps' "$TEMPLATE" && pass "repo-steps marker" || die "no repo-steps marker"
grep -q 'orca-setup:managed:gortex-readiness' "$TEMPLATE" && pass "gortex marker" || die "no gortex marker"

# Default (ORCA_GORTEX unset): runs clean, exit 0, no gortex invoked.
out="$(cd "$tmp" && bash "$TEMPLATE" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "default exit 0" || die "default rc=$rc"

# gortex absent from PATH but ORCA_GORTEX=1: must still exit 0 (command -v guard).
out="$(cd "$tmp" && PATH="/usr/bin:/bin" ORCA_GORTEX=1 bash "$TEMPLATE" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "gortex-absent exit 0" || die "gortex-absent rc=$rc"

# Mock gortex on PATH: daemon DOWN (status !=0) -> template starts it, exit 0.
mkbin="$tmp/bin"; mkdir -p "$mkbin"
cat > "$mkbin/gortex" <<'MOCK'
#!/usr/bin/env bash
# args: "daemon status" -> exit 1 (down); "daemon start --detach" -> exit 0
if [ "$1" = "daemon" ] && [ "$2" = "status" ]; then exit 1; fi
if [ "$1" = "daemon" ] && [ "$2" = "start" ]; then echo "started" ; exit 0; fi
exit 0
MOCK
chmod +x "$mkbin/gortex"
err="$(cd "$tmp" && PATH="$mkbin:$PATH" ORCA_GORTEX=1 bash "$TEMPLATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && pass "gortex-down exit 0" || die "gortex-down rc=$rc"
printf '%s' "$err" | grep -q 'started gortex daemon' \
  && pass "gortex-down started daemon" || die "gortex-down did not start: $err"

# Mock gortex: daemon UP (status ==0) -> template does NOT start it, exit 0.
cat > "$mkbin/gortex" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "daemon" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "daemon" ] && [ "$2" = "start" ]; then echo "SHOULD-NOT-RUN"; exit 0; fi
exit 0
MOCK
chmod +x "$mkbin/gortex"
err="$(cd "$tmp" && PATH="$mkbin:$PATH" ORCA_GORTEX=1 bash "$TEMPLATE" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$err" | grep -q 'SHOULD-NOT-RUN'; } \
  && pass "gortex-up no restart" || die "gortex-up misbehaved: rc=$rc err=$err"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/plugin/skills/orca-setup/tests/template.test.sh`
Expected: fails — `worktree-setup.template.sh` does not exist, so `grep`/`bash` on it error. Ends with `SOME FAILED`, nonzero exit.

- [ ] **Step 3: Write `worktree-setup.template.sh`**

Create `agents/plugin/skills/orca-setup/worktree-setup.template.sh`:

```bash
#!/usr/bin/env bash
# .orca/worktree-setup.sh — repo-specific Orca worktree delegate.
#
# Scaffolded by /orca-setup. The machines dispatcher
# (~/machines/scripts/orca-worktree-setup.sh) runs this from inside a fresh
# worktree AFTER linking the generic gitignored config set. Put this repo's own
# worktree setup here.
#
# INVARIANT: never block Orca. Every path is non-fatal; always exit 0.
# Do NOT `set -e`.

log() { echo ".orca/worktree-setup: $*" >&2; }

# >>> orca-setup:managed:repo-steps >>>
# Repo-specific steps go here. Examples:
#   - link an extra gitignored file the generic set misses
#   - copy a seed DB / .superpowers ledger the app needs
#   - print a ready-to-run command for the developer
# Keep every step non-fatal (guard with `|| log "WARN: ..."`).
# <<< orca-setup:managed:repo-steps <<<

# >>> orca-setup:managed:gortex-readiness >>>
# Gortex readiness (opt-in via ORCA_GORTEX=1): ensure the daemon is running so
# graph tools work from this worktree and the working agent's own
# `overlay_register {workspace_id: <slug>}` (see cyphy:worktree-agent) doesn't
# hit "cwd not covered". Does NOT register an overlay here — a fresh worktree has
# no uncommitted edits to overlay, and the agent reads its slug from its own
# session orientation.
if [ "${ORCA_GORTEX:-0}" = "1" ] && command -v gortex >/dev/null 2>&1; then
  if gortex daemon status >/dev/null 2>&1; then
    log "gortex daemon already running"
  else
    gortex daemon start --detach >/dev/null 2>&1 \
      && log "started gortex daemon" \
      || log "WARN: could not start gortex daemon"
  fi
fi
# <<< orca-setup:managed:gortex-readiness <<<

exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash agents/plugin/skills/orca-setup/tests/template.test.sh`
Expected: every `PASS …`, final `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/orca-setup/worktree-setup.template.sh \
        agents/plugin/skills/orca-setup/tests/template.test.sh
git commit -m "feat(orca-setup): non-fatal .orca worktree-setup scaffold template"
```

---

### Task 3: `SKILL.md` — orchestration (guard → scaffold → print)

**Files:**
- Create: `agents/plugin/skills/orca-setup/SKILL.md`

**Interfaces:**
- Consumes:
  - `orca-status.sh <orca-data.json> <origin-url> <expected-setup> <base-path>` → one of `WIRED` / `UNWIRED` / `ABSENT` / `CONFLICT\t<value>` (Task 1).
  - `worktree-setup.template.sh` — copied verbatim to `$base/.orca/worktree-setup.sh` (Task 2).
- Produces: the `/orca-setup` skill (discovered automatically by the `cyphy` skills-directory plugin — no manifest edit needed, exactly like the sibling `ship` skill).

- [ ] **Step 1: Write `SKILL.md`**

Create `agents/plugin/skills/orca-setup/SKILL.md`:

````markdown
---
name: orca-setup
description: "Use when the user wants to set up (or re-check) a repo for Orca-managed worktrees — one-time per repo. Scaffolds the repo's committed .orca/worktree-setup.sh custom-rules delegate and PRINTS the Orca setup-script one-liner for the user to paste into Orca's per-repo settings. Never writes Orca config, never closes the IDE. Fleet-sync personal repos only; refuses work/Pure repos. Invoked as /orca-setup."
---

# /orca-setup — wire a repo for Orca-managed worktrees

Runs in your session. It does the parts worth automating — the guard, the
committed `.orca/worktree-setup.sh` scaffold, and a **read-only** check of the
current Orca wiring — then hands YOU the exact setup-script command to paste into
Orca's UI. It never edits `orca-data.json` and never asks you to close Orca.

Background: `scripts/orca-worktree-setup.sh` is the shared dispatcher Orca runs on
each fresh worktree; it links generic gitignored config, then delegates to this
repo's `.orca/worktree-setup.sh`. Overlay conventions for the working agent live
in `cyphy:worktree-agent`.

## Step 1 — Guard & identity

1. `git remote get-url origin` — if it matches `thepureapp/`, STOP: work repos
   use the pure-dev PR flow, not /orca-setup.
2. Resolve the base checkout (Orca keys its entry to it, not to a worktree path):

   ```bash
   common=$(git rev-parse --git-common-dir)
   case "$common" in /*|[A-Za-z]:*) : ;; *) common=$(cd "$(git rev-parse --show-toplevel)" && cd "$common" && pwd) ;; esac
   BASE=$(dirname "$common")
   ORIGIN=$(git -C "$BASE" remote get-url origin)
   ```

## Step 2 — Scaffold `$BASE/.orca/worktree-setup.sh` (committed → synced)

Copy the template verbatim if the repo has no delegate yet; if it exists, DO NOT
clobber — show a diff and only offer to refresh the marker-delimited managed
blocks.

```bash
TEMPLATE=~/machines/agents/plugin/skills/orca-setup/worktree-setup.template.sh
DEST="$BASE/.orca/worktree-setup.sh"
if [ -e "$DEST" ]; then
  diff -u "$DEST" "$TEMPLATE" || true   # show what a refresh would change; ask the user
else
  mkdir -p "$BASE/.orca" && cp "$TEMPLATE" "$DEST" && chmod +x "$DEST"
fi
```

Tell the user this file is committed and syncs across the fleet, and that
repo-specific steps go in the `orca-setup:managed:repo-steps` block. Gortex
readiness is opt-in — it runs only when the worktree is created with
`ORCA_GORTEX=1` in the environment. Offer to `git add "$DEST"`.

## Step 3 — Print the setup command (read-only status; no writes)

Check how the repo is currently wired, then print guidance. This reads
`orca-data.json` read-only — safe with Orca open.

```bash
DATA="$HOME/.config/orca/profiles/local-default/orca-data.json"
DISPATCH='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'
STATUS=$(~/machines/agents/plugin/skills/orca-setup/orca-status.sh "$DATA" "$ORIGIN" "$DISPATCH" "$BASE")
echo "$STATUS"
```

Turn the token into guidance:

- **`WIRED`** → "Already pointed at the dispatcher — nothing to paste."
- **`UNWIRED`** or **`ABSENT`** → print the one-liner and where it goes:

  > Paste this into Orca → the repo's settings → **Setup script** field:
  >
  >     bash "$HOME/machines/scripts/orca-worktree-setup.sh"
  >
  > (If `ABSENT`: the repo isn't listed in Orca yet — open it once so it appears,
  > then paste. Orca applies it on the next worktree it creates.)

- **`CONFLICT\t<value>`** → "A different setup script is configured (`<value>`).
  Replace it with the dispatcher one-liner only if you mean to; otherwise leave
  it." Never presume — the user decides.

## Notes

- Orca's registry is per-runtime/per-host and `orca-data.json` is not synced, so
  the paste is per machine. The committed `.orca/worktree-setup.sh` DOES sync, so
  the custom rules travel; only the paste repeats.
- This skill performs no Orca-config writes and no destructive git ops.
````

- [ ] **Step 2: Verify the skill is well-formed and the wiring works end-to-end (read-only)**

Frontmatter check:

```bash
head -3 agents/plugin/skills/orca-setup/SKILL.md
```
Expected: a `---` fence, `name: orca-setup`, and a `description:` line.

End-to-end smoke on THIS repo (read-only; scaffolds into a throwaway dir, does NOT touch machines' own `.orca/` and does NOT paste anything):

```bash
DATA="$HOME/.config/orca/profiles/local-default/orca-data.json"
DISPATCH='bash "$HOME/machines/scripts/orca-worktree-setup.sh"'
BASE=/home/me/machines
ORIGIN=$(git -C "$BASE" remote get-url origin)
~/machines/agents/plugin/skills/orca-setup/orca-status.sh "$DATA" "$ORIGIN" "$DISPATCH" "$BASE"
# scaffold into a temp dir to prove the copy works without mutating the repo
t=$(mktemp -d); cp ~/machines/agents/plugin/skills/orca-setup/worktree-setup.template.sh "$t/ws.sh"
bash "$t/ws.sh"; echo "scaffold rc=$?"; rm -rf "$t"
```
Expected: the status line prints `WIRED` (machines is already pointed at the dispatcher — confirms projectId/path matching against the real file), and `scaffold rc=0`. If `orca-data.json` is absent on the box, `ABSENT` is the correct, non-erroring result.

- [ ] **Step 3: Commit**

```bash
git add agents/plugin/skills/orca-setup/SKILL.md
git commit -m "feat(orca-setup): SKILL.md orchestration — guard, scaffold, print"
```

---

## Notes for the executor

- No plugin manifest to edit: the `cyphy` plugin auto-discovers skills under `agents/plugin/skills/` (the sibling `ship` skill needed no registration).
- Do NOT run `/orca-setup` against the machines repo in a way that writes `.orca/worktree-setup.sh` or pastes into Orca during implementation — that is a user-facing action for after the skill ships. Verification uses temp dirs and read-only reads only.
- After all tasks: a final whole-branch review, then `superpowers:finishing-a-development-branch` (offer FF merge-back into `main`, then `/ship`).
