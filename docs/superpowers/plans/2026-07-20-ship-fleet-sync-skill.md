# `/ship` Fleet-Sync Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a cyphy-plugin skill `/ship` that commits, merges-back, pushes `main`, then FF-pulls the change on every other fleet member — with a deterministic, unit-tested `fleet-pull.sh` doing the risky cross-shell fleet half.

**Architecture:** Hybrid. `SKILL.md` is the procedure the agent follows for the gated local mutations (commit → worktree FF merge-back → push). `fleet-pull.sh` is a standalone, non-interactive bash script that discovers each member's checkout by normalized `origin` URL and runs `git pull --ff-only origin main`, skipping any box that is unreachable, absent, dirty, or diverged. Nothing destructive ever runs on a remote box.

**Tech Stack:** Bash, `jq`, `git`, `ssh` (fleet aliases), `tailscale`. Tests are standalone bash scripts that build throwaway git repos and mock `ssh`/`tailscale` on `PATH`, mirroring `agents/plugin/hooks/tests/worktree-workflow.test.sh`.

## Global Constraints

- **Zero destructive remote ops.** `fleet-pull.sh` may only read state and run `git pull --ff-only`. Never force, merge (non-FF), reset, stash, or checkout on a remote box.
- **`fleet-pull.sh` always exits 0.** Per-box failures are `SKIP` rows in the summary, never a nonzero exit — the skill always gets the full table.
- **Self-exclusion keys off the tailnet IP**, matched against `fleet.json` `.machines.<alias>.tailnet.ip`. Never the OS hostname (`detect.hostname`) or the tailnet node display name.
- **Discovery keys off the normalized `origin` URL**, never a path convention (this fleet already breaks `~/my/<repo>`: `machines` lives at `~/machines`).
- **Every remote command runs as `ssh <alias> bash -s [args] < script`** so it dispatches to WSL bash on the Windows boxes and plain bash on `latitude`/`hub`.
- **Member list + tailnet IPs come from `fleet.json`** at `$SCRIPT_DIR/../../../../fleet.json`; the member key IS the SSH alias.
- **Skill frontmatter `name: ship`**; skills auto-discover by directory (no plugin.json edit).
- **Commit all work on the `orca-worktrees` branch** (worktree mode), not `main`.
- **Test override env vars** `fleet-pull.sh` MUST honor: `FLEET_JSON`, `LOCAL_TAILNET_IP`, `SSH`. Defaults resolve to the real values.

---

### Task 1: `fleet-pull.sh` — pure helpers (URL normalization + self-detection)

**Files:**
- Create: `agents/plugin/skills/ship/fleet-pull.sh`
- Test: `agents/plugin/skills/ship/tests/fleet-pull.test.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `normalize_url <url>` → prints canonical `host/owner/repo` (lowercase host, no scheme/user/`.git`).
  - `local_tailnet_ip` → prints the box's `100.64.0.0/10` address (honors `LOCAL_TAILNET_IP` override).
  - `self_alias` → prints the `fleet.json` member key whose `.tailnet.ip` equals `local_tailnet_ip` (empty if none).
  - Env vars: `FLEET_JSON` (default `$SCRIPT_DIR/../../../../fleet.json`), `LOCAL_TAILNET_IP`, `SSH` (default `ssh`).
  - Sourcing guard: when sourced (not executed) the file defines functions but does NOT run `main`, so tests can call helpers directly.

- [ ] **Step 1: Write the failing test**

Create `agents/plugin/skills/ship/tests/fleet-pull.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior tests for fleet-pull.sh — builds throwaway repos + a fake fleet.json,
# mocks ssh/tailscale on PATH, asserts on the summary output.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../fleet-pull.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# --- fake fleet.json (alias -> tailnet ip) ---
FLEET="$tmp/fleet.json"
cat > "$FLEET" <<'JSON'
{ "machines": {
  "latitude": { "tailnet": { "ip": "100.64.0.2" } },
  "desktop":  { "tailnet": { "ip": "100.64.0.4" } },
  "server":   { "tailnet": { "ip": "100.64.0.3" } },
  "hub":      { "tailnet": { "ip": "100.64.0.1" } }
} }
JSON

# Source the script so we can call helpers directly.
FLEET_JSON="$FLEET" LOCAL_TAILNET_IP="100.64.0.2" source "$SCRIPT"

# normalize_url: all forms of the same repo canonicalize equal.
want="github.com/metheoryt/machines"
for u in \
  "git@github.com:metheoryt/machines.git" \
  "git@github.com:metheoryt/machines" \
  "https://github.com/metheoryt/machines.git" \
  "ssh://git@github.com/metheoryt/machines.git" ; do
  got="$(normalize_url "$u")"
  [ "$got" = "$want" ] && pass "normalize $u" || die "normalize $u -> '$got' (want '$want')"
done

# self_alias: LOCAL_TAILNET_IP 100.64.0.2 -> latitude
got="$(self_alias)"
[ "$got" = "latitude" ] && pass "self_alias=latitude" || die "self_alias -> '$got' (want latitude)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `fleet-pull.sh` does not exist yet (source error / functions undefined).

- [ ] **Step 3: Write minimal implementation**

Create `agents/plugin/skills/ship/fleet-pull.sh`:

```bash
#!/usr/bin/env bash
# fleet-pull.sh — FF-only, skip-if-unsafe pull of `main` on every OTHER fleet
# member that has this repo checked out. Zero destructive remote ops. Always
# exits 0 (per-box failures are SKIP rows).
#
# Usage: fleet-pull.sh <origin-url>
# Test overrides: FLEET_JSON, LOCAL_TAILNET_IP, SSH
set -u

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_JSON="${FLEET_JSON:-$SCRIPT_DIR/../../../../fleet.json}"
SSH="${SSH:-ssh}"

# Canonicalize a git remote URL to host/owner/repo (lowercase host, no
# scheme/user/.git) so scp-form and https forms of the same repo compare equal.
normalize_url() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"     # strip any user@
  u="${u/://}"                    # scp-form host:owner -> host/owner (first :)
  u="${u/:/\/}"                   # any leading ssh:// port-less colon safeguard
  printf '%s' "$u" | awk -F/ '{ $1=tolower($1) }1' OFS=/
}

# The box's own tailnet (100.64.0.0/10) address.
local_tailnet_ip() {
  if [ -n "${LOCAL_TAILNET_IP:-}" ]; then printf '%s\n' "$LOCAL_TAILNET_IP"; return; fi
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$ip" ] && { printf '%s\n' "$ip"; return; }
  ip -4 -o addr show 2>/dev/null \
    | grep -oE '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+' | head -1
}

# The fleet.json member key whose tailnet.ip == this box (empty if none).
self_alias() {
  local ip; ip="$(local_tailnet_ip)"
  [ -n "$ip" ] || return 0
  jq -r --arg ip "$ip" \
    '.machines | to_entries[] | select(.value.tailnet.ip == $ip) | .key' \
    "$FLEET_JSON" 2>/dev/null | head -1
}

# main() is added in Task 3. Only run it when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  :  # main "$@"  (wired in Task 3)
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: PASS lines for all `normalize *` cases and `self_alias=latitude`, then `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "feat(ship): fleet-pull.sh helpers — url normalization + tailnet self-detection"
```

---

### Task 2: `fleet-pull.sh` — per-member remote probe + FF-pull decision

**Files:**
- Modify: `agents/plugin/skills/ship/fleet-pull.sh`
- Test: `agents/plugin/skills/ship/tests/fleet-pull.test.sh`

**Interfaces:**
- Consumes: `normalize_url` (Task 1), `SSH` env.
- Produces:
  - `REMOTE_SCRIPT` — a bash string, piped to each box, that finds a checkout matching the target URL under the box's `$HOME` roots and prints exactly one token: `OK <short>..<short>`, `OK up-to-date`, `SKIP absent`, `SKIP dirty`, or `SKIP diverged`.
  - `run_member <alias> <normalized-target>` → runs the reachability probe then `REMOTE_SCRIPT` over `$SSH`, printing the resulting token (or `SKIP unreachable`).

- [ ] **Step 1: Write the failing test**

Append to `agents/plugin/skills/ship/tests/fleet-pull.test.sh`, before the final `ALL PASS` block:

```bash
# --- mock ssh: each alias has its own fake $HOME under $tmp/home/<alias>. ---
# `ssh [-o ..] <alias> true`      -> reachability (fail if alias in UNREACHABLE)
# `ssh <alias> bash -s <target>`  -> run stdin script locally with HOME=that box
UNREACHABLE="$tmp/unreachable"; : > "$UNREACHABLE"
mkdir -p "$tmp/home"
mock_ssh() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  if [ "${1:-}" = "true" ]; then
    grep -qx "$alias" "$UNREACHABLE" && return 1 || return 0
  fi
  # $@ is now: bash -s <target> ; run it locally with this box's HOME on stdin.
  HOME="$tmp/home/$alias" bash "${@:2}"
}
export -f mock_ssh 2>/dev/null || true
SSH="mock_ssh"

mkrepo() { # $1 = dir ; makes a repo with origin = machines, one commit
  git init -q "$1"; git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" remote add origin git@github.com:metheoryt/machines.git
}

target="$(normalize_url git@github.com:metheoryt/machines.git)"

# server: clean checkout, behind origin -> OK (a real FF). Build an "origin" the
# checkout can pull from, one commit ahead.
mkdir -p "$tmp/home/server/my"
up="$tmp/upstream.git"; git init -q --bare "$up"
mkrepo "$tmp/home/server/my/machines"
git -C "$tmp/home/server/my/machines" remote set-url origin "$up"
git -C "$tmp/home/server/my/machines" push -q origin main
git -C "$tmp/home/server/my/machines" commit -q --allow-empty -m ahead
git -C "$tmp/home/server/my/machines" push -q origin main
git -C "$tmp/home/server/my/machines" reset -q --hard HEAD~1   # now 1 behind
# The remote probe matches on the ORIGIN url; point target at the bare upstream.
tgt_server="$(normalize_url "$up")"
got="$(run_member server "$tgt_server")"
case "$got" in OK\ *..*) pass "server OK (ff)";; *) die "server -> '$got' (want OK ff)";; esac

# desktop: no matching checkout -> SKIP absent
mkdir -p "$tmp/home/desktop"
got="$(run_member desktop "$target")"
[ "$got" = "SKIP absent" ] && pass "desktop absent" || die "desktop -> '$got' (want SKIP absent)"

# latitude: dirty checkout -> SKIP dirty
mkrepo "$tmp/home/latitude/machines"
echo x > "$tmp/home/latitude/machines/dirty"
tgt_lat="$(normalize_url git@github.com:metheoryt/machines.git)"
got="$(run_member latitude "$tgt_lat")"
[ "$got" = "SKIP dirty" ] && pass "latitude dirty" || die "latitude -> '$got' (want SKIP dirty)"

# hub: unreachable -> SKIP unreachable
echo hub >> "$UNREACHABLE"
got="$(run_member hub "$target")"
[ "$got" = "SKIP unreachable" ] && pass "hub unreachable" || die "hub -> '$got' (want SKIP unreachable)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `run_member`/`REMOTE_SCRIPT` undefined.

- [ ] **Step 3: Write minimal implementation**

In `agents/plugin/skills/ship/fleet-pull.sh`, insert BEFORE the `if [ "${BASH_SOURCE[0]}" = "$0" ]` guard:

```bash
# Script piped to each member. $1 = normalized target url. Prints ONE token.
REMOTE_SCRIPT='set -u
target="$1"
roots="$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly"
norm() {
  local u="$1"
  u="${u%.git}"; u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"; u="${u/://}"
  printf "%s" "$u" | awk -F/ "{ \$1=tolower(\$1) }1" OFS=/
}
found=""
for root in $roots; do
  for d in "$root" "$root"/*; do
    { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || continue
    o="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    if [ "$(norm "$o")" = "$target" ]; then found="$d"; break 2; fi
  done
done
[ -n "$found" ] || { echo "SKIP absent"; exit 0; }
[ -z "$(git -C "$found" status --porcelain 2>/dev/null)" ] || { echo "SKIP dirty"; exit 0; }
before="$(git -C "$found" rev-parse --short HEAD 2>/dev/null)"
if git -C "$found" pull --ff-only origin main >/dev/null 2>&1; then
  after="$(git -C "$found" rev-parse --short HEAD 2>/dev/null)"
  if [ "$before" = "$after" ]; then echo "OK up-to-date"; else echo "OK $before..$after"; fi
else
  echo "SKIP diverged"
fi'

# Reachability probe + remote run for one member. Prints one status token.
run_member() {
  local alias="$1" target="$2"
  if ! $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" true 2>/dev/null; then
    printf 'SKIP unreachable\n'; return 0
  fi
  local res
  res="$(printf '%s' "$REMOTE_SCRIPT" | $SSH "$alias" bash -s "$target" 2>/dev/null)"
  printf '%s\n' "${res:-SKIP no-output}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: PASS for `server OK (ff)`, `desktop absent`, `latitude dirty`, `hub unreachable`, then `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "feat(ship): per-member remote probe + FF-only pull decision"
```

---

### Task 3: `fleet-pull.sh` — orchestration loop, self-exclusion, summary table

**Files:**
- Modify: `agents/plugin/skills/ship/fleet-pull.sh`
- Test: `agents/plugin/skills/ship/tests/fleet-pull.test.sh`

**Interfaces:**
- Consumes: `normalize_url`, `self_alias` (Task 1), `run_member` (Task 2), `FLEET_JSON`.
- Produces: `main <origin-url>` — iterates `fleet.json` members, skips self, prints a header line and one `MEMBER  RESULT` row per other member. Always exits 0. Wired to run on direct execution.

- [ ] **Step 1: Write the failing test**

Append to the test file, before the final `ALL PASS` block:

```bash
# --- full run via main(): self (latitude, LOCAL_TAILNET_IP=100.64.0.2) excluded ---
# Reset boxes: server behind (OK ff), desktop absent, hub unreachable (already),
# latitude is SELF so must NOT appear.
out="$(FLEET_JSON="$FLEET" LOCAL_TAILNET_IP="100.64.0.2" SSH="mock_ssh" \
       main "$up" 2>/dev/null)"
printf '%s' "$out" | grep -qE '^latitude' && die "self latitude should be excluded" || pass "self excluded"
printf '%s' "$out" | grep -qE '^server .*OK'      && pass "table server OK"      || die "table missing server OK: $out"
printf '%s' "$out" | grep -qE '^desktop .*SKIP'   && pass "table desktop SKIP"   || die "table missing desktop SKIP: $out"
printf '%s' "$out" | grep -qE '^hub .*unreachable'&& pass "table hub unreachable"|| die "table missing hub: $out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `main` is still the `:` placeholder, so no table is printed.

- [ ] **Step 3: Write minimal implementation**

In `agents/plugin/skills/ship/fleet-pull.sh`, add the `main` function BEFORE the execution guard, then wire the guard:

```bash
main() {
  local raw="${1:-}"
  [ -n "$raw" ] || { echo "usage: fleet-pull.sh <origin-url>" >&2; return 0; }
  local target self
  target="$(normalize_url "$raw")"
  self="$(self_alias)"
  printf 'Fleet pull of %s  (self: %s)\n' "$target" "${self:-unknown}"
  printf '%-10s %s\n' 'MEMBER' 'RESULT'
  local m
  while read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "$self" ] && continue
    printf '%-10s %s\n' "$m" "$(run_member "$m" "$target")"
  done < <(jq -r '.machines | keys[]' "$FLEET_JSON" 2>/dev/null)
  return 0
}
```

Change the execution guard at the end of the file from:

```bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  :  # main "$@"  (wired in Task 3)
fi
```

to:

```bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: PASS for `self excluded`, `table server OK`, `table desktop SKIP`, `table hub unreachable`, then `ALL PASS`.

- [ ] **Step 5: Make the script executable and commit**

```bash
chmod +x agents/plugin/skills/ship/fleet-pull.sh
git add agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git update-index --chmod=+x agents/plugin/skills/ship/fleet-pull.sh
git commit -m "feat(ship): orchestration loop with self-exclusion + summary table"
```

---

### Task 4: `SKILL.md` — the `/ship` procedure + fleet-git reference, then finalize

**Files:**
- Create: `agents/plugin/skills/ship/SKILL.md`

**Interfaces:**
- Consumes: `fleet-pull.sh` (Tasks 1–3) via `"$SCRIPT_DIR/fleet-pull.sh" "<origin-url>"`.
- Produces: an auto-discovered skill invocable as `/ship`.

- [ ] **Step 1: Write `SKILL.md`**

Create `agents/plugin/skills/ship/SKILL.md`:

```markdown
---
name: ship
description: "Use when the user wants to ship a change across the personal fleet — commit, fast-forward merge-back into main, push origin, then FF-pull the change on every other fleet member. Fleet-sync personal repos only (machines and siblings); refuses work/Pure repos, which keep the pure-dev PR flow. Invoked as /ship."
---

# /ship — land a change on the whole fleet

Runs in your session so every mutation stays gated by you and the safety
classifier. The local half is done here step-by-step; the fleet half is the
deterministic `fleet-pull.sh` next to this file.

Conventions this flow assumes live in `agents/docs/git-workflow.md` (worktree vs
main-checkout modes) and global memory (fleet SSH shell-dispatch, Windows
HTTPS-push, gh-vs-git auth). Read those if anything below is unclear.

## Guard (stop early if any fail)

1. `git remote get-url origin` — if it matches `thepureapp/`, STOP: work repos
   use the pure-dev PR flow, not /ship.
2. Confirm this is a fleet-sync repo (personal, cloned on multiple boxes). If
   unsure, ask.
3. Detect mode: linked worktree (git-dir != common-dir) → **worktree mode**;
   else **main-checkout mode**.

## Local half (you gate each mutation)

1. **Commit (if dirty).** Show `git status` + a diff summary, propose a commit
   message, get the user's OK, then commit — on the **branch** in worktree mode,
   on **main** in main-checkout mode. Never commit on `main` from a worktree.
2. **Merge-back (worktree mode only).** Verify the base checkout (`dirname` of
   the common git-dir) is on `main` and clean, then:
   `git -C <base> merge --ff-only <branch>`. If it is not a fast-forward, STOP
   and ask — never a real merge without explicit OK.
3. **Push.** `git -C <base> push origin main` (main-checkout: push from cwd). If
   the safety classifier denies it, report and give the user the exact command.

## Fleet half

Run the deterministic pull and show its table verbatim:

    "$SCRIPT_DIR/fleet-pull.sh" "$(git remote get-url origin)"

It FF-pulls `main` on every other member, skipping any that are unreachable,
absent, dirty, or diverged. It never runs a destructive op. Report the table;
for any `SKIP(dirty)` / `SKIP(diverged)` row, tell the user that box needs a
manual look.

## Finish (optional)

Offer to delete the branch. Offer `git worktree remove` too — UNLESS the session
is Orca-managed (`TERM_PROGRAM=Orca`), in which case offer branch deletion only
(Orca owns the worktree lifecycle). All user-gated.
```

- [ ] **Step 2: Verify the skill is discovered**

Run: `test -f agents/plugin/skills/ship/SKILL.md && head -3 agents/plugin/skills/ship/SKILL.md`
Expected: prints the frontmatter opening with `name: ship`. (Auto-discovery needs no manifest edit; a running Claude Code session picks it up on next launch.)

- [ ] **Step 3: Run the full test suite one more time**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 4: Commit**

```bash
git add agents/plugin/skills/ship/SKILL.md
git commit -m "feat(ship): SKILL.md — /ship procedure + fleet-git reference"
```

---

## Self-Review

**Spec coverage:**
- Form = cyphy-plugin skill `/ship`, not a subagent → Task 4 (SKILL.md), Global Constraints. ✓
- Hybrid architecture (SKILL.md + tested fleet-pull.sh) → Tasks 1–4. ✓
- Local half: guard → commit → worktree FF merge-back → push → fleet-pull → finish → SKILL.md. ✓
- Fleet-pull FF-only, skip-if-unsafe (unreachable/absent/dirty/diverged), zero destructive ops → Tasks 2–3 + Global Constraints. ✓
- Scope: any fleet-sync repo, discovery by normalized origin URL, refuse work/Pure → Task 2 (`REMOTE_SCRIPT` match), Task 4 (guard). ✓
- Self-detection by tailnet IP → Task 1 (`self_alias`), Task 3 (exclusion). ✓
- Shell split via `ssh <alias> bash -s` → Task 2 (`run_member`). ✓
- Testing (URL normalization, self-exclusion, OK/SKIP matrix, stable summary) → Tasks 1–3 tests. ✓
- Lands on `orca-worktrees` branch → commit steps + Global Constraints. ✓

**Placeholder scan:** No TBD/TODO; the only intentional interim stub is the `:` in the Task-1 execution guard, explicitly replaced with `main "$@"` in Task 3. ✓

**Type consistency:** `normalize_url`, `local_tailnet_ip`, `self_alias`, `REMOTE_SCRIPT`, `run_member`, `main` are named identically wherever referenced across tasks; token strings (`OK …`, `SKIP absent|dirty|diverged|unreachable`) match between `REMOTE_SCRIPT`, `run_member`, and the tests. ✓
```
