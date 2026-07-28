# Dotfiles sync commit debounce + manual trigger — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dotfiles sync timer commit once per *editing burst* instead of
once per 10-minute tick, and add a `/dotfiles-sync` skill that commits now.

**Architecture:** The timer's tick cadence does not change — only the commit
decision does. A new `sync_should_commit` gate compares a hash of the tracked
diff against the previous tick's: an unchanged diff means editing has settled and
the tick commits; a changed diff means the human is mid-edit and the tick defers.
A max-age valve commits anyway once the tree has been dirty for 2 hours, so a
continuously-touched file still reaches `origin`. `DOTFILES_SYNC_FORCE=1` bypasses
the gate — and *only* the gate — which is what the skill sets.

**Tech Stack:** POSIX `sh`-compatible bash (`provision/dotfiles-sync.sh`),
PowerShell 5.1 (`provision/dotfiles-sync.ps1`), the existing
`provision/dotfiles-sync.test.sh` harness, a `SKILL.md` in the dotfiles repo.

## Why this is a prerequisite, not a cleanup

**No `auto(<branch>):` commit exists yet.** The dotfiles history is 14
hand-written commits; the tracked set is 7 rarely-touched files, so the timer has
never had anything to commit. The churn arrives with **Task 4 of
`2026-07-28-agent-config-to-dotfiles.md`**, which hands `memory/global.md`, the
four personality facets, and `host-memory.md` to dotfiles — files that get an
appended bullet per agent session.

**Land this plan before that task.** Afterwards is still correct but noisier.

## Why debounce and not a literal daily commit

`sync_tick` commits **before** it merges, and `merge-tree --write-tree`
preflights *committed trees* — it cannot see the dirty work-tree. So with a long
commit gate, a locally-dirty tracked path that `origin/main` also touches gives:

1. preflight compares the unchanged branch tip against `origin/main` → **clean**
2. `sync_merge` therefore does `rm -f "$marker"` — the conflict marker is removed
3. the real `df merge -q --no-edit --ff origin/main` refuses with *"Your local
   changes to the following files would be overwritten by merge"*
4. `provision/dotfiles-sync.sh:161` swallows it: `|| true`

No marker, no log line, no commit, no propagation — for the whole gate window.
And the overlapping paths are exactly the memory files, which are both locally
dirty and promoted to `main` from other boxes.

Debouncing bounds that window to **one tick**. A 24h gate would extend it to 24h,
and the only way to close it would be to stash around the merge — writing to a
live `$HOME`, which breaks the script's governing safety property.

The user chose debounce-per-burst over literal-daily on 2026-07-28 with this
tradeoff on the table.

## Global Constraints

- **The work-tree is a live `$HOME`.** The script must never leave a conflict on
  disk and must never start a merge it cannot finish. Every test asserts on what
  is left **on disk**, not just on exit status.
- **Exit status contract is unchanged.** 0 for every normal outcome *including* a
  detected conflict, a failed push, and a deferred commit. Non-zero only for a
  hard stop needing a human: HEAD on the wrong branch, or a merge/rebase in
  progress.
- **`add -u` stays.** It can never stage an untracked file, so tracking remains a
  deliberate act. Do not introduce `add -A` or a pathspec.
- **`DOTFILES_SYNC_FORCE` bypasses the debounce gate ONLY.** It must never
  bypass `sync_guard`. A manual trigger that can be talked into committing
  host-local content while HEAD is on `main` is a worse bug than the one this
  plan fixes. Task 1 pins this with a test.
- **Never store the diff content.** Tracked files include `.netrc`,
  `.npmrc`, `.pypirc`, `.aws/credentials`, and `.config/gh/hosts.yml`. Hash the
  diff; `$DOTFILES_STATE_DIR` must not become a second plaintext copy of a
  credential.
- **No new state under a tracked path.** `$DOTFILES_STATE_DIR` is
  `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync`, ignored by the
  allow-only `~/.gitignore`. No `.gitignore` change in this plan.
- **Rollout is script-only.** Every scheduler points at the absolute script path
  (`tier_dotfiles_sync`'s `_launchd_periodic … "$DFS"` / the systemd unit's
  `ExecStart` / the cron line / `windows.ps1`'s `Register-ScheduledTask` on
  `provision\dotfiles-sync.ps1`). A `git pull` in `~/machines` updates the body
  in place and the next tick picks it up: **no timer reload, no re-provision, no
  `tier_dotfiles_sync` edit.**

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `provision/dotfiles-sync.sh` | Modify | Add `sync_hash` + `sync_should_commit`; gate the commit in `sync_tick`; update the header comment |
| `provision/dotfiles-sync.test.sh` | Modify | Rewrite cases 2, 6, 7, 8 for the new cadence; add cases 9–16 |
| `provision/dotfiles-sync.ps1` | Modify | Mirror the gate in the Windows twin |
| `provision/lib/tiers.sh:884` | Modify | Comment only — tick cadence vs commit cadence |
| `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md` | Modify | §5.1 step 2 + the accepted-behaviors bullet |
| `~/.claude/skills/dotfiles-sync/SKILL.md` | Create (**dotfiles repo, `main`**) | The manual trigger |
| `~/CLAUDE.md` | Modify (**dotfiles repo, `main`**) | The "It commits on its own" bullet |

Tasks 1–2 are `~/machines` commits. Task 3 is two dotfiles commits on a machine
branch plus one `/dotfiles-promote` run.

---

## Task 1: Commit debounce in `provision/dotfiles-sync.sh`

**Files:**
- Modify: `provision/dotfiles-sync.sh` (header comment lines 5–7; new helpers
  after `sync_commit` at line 105; `sync_tick` at lines 166–175)
- Test: `provision/dotfiles-sync.test.sh` (cases 2, 6, 7, 8 rewritten; 9–16 new)

**Interfaces:**
- Consumes: `df()`, `sync_guard`, `sync_commit`, `sync_push`, `sync_merge`,
  `$DOTFILES_STATE_DIR` — all already present.
- Produces: `sync_hash` (hashes stdin, echoes one hex/CRC token),
  `sync_should_commit` (exit 0 = commit this tick, 1 = defer),
  `DOTFILES_SYNC_MAX_AGE` (seconds, default 7200),
  `DOTFILES_SYNC_FORCE` (non-empty = bypass the gate),
  state files `$DOTFILES_STATE_DIR/pending.hash` and `pending.since`.

- [ ] **Step 1: Rewrite the four existing cases that assume commit-on-first-tick**

Four current cases assert a commit after a single tick and will fail under the
new cadence. This is expected — they encode the *old* cadence. Rewrite them
first, before touching the script, so the suite's baseline failure is only the
new behavior.

In `provision/dotfiles-sync.test.sh`, replace case 2 (lines 68–75) with:

```bash
# ── 2. Dirty tick defers; the next tick commits the settled change and pushes ─
# COMMIT CADENCE: a tick commits only once the tracked diff has stopped moving.
# See sync_should_commit — one editing burst yields one commit, not one per tick.
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse air)"
rc="$(tick "$T")"
eq "dirty tick: exit 0" "$rc" "0"
eq "dirty tick: defers the first time" "$(dfx "$T" rev-parse air)" "$before"
rc="$(tick "$T")"
eq "settled tick: exit 0" "$rc" "0"
eq "settled tick: committed" "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "settled tick: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
eq "settled tick: work-tree unchanged" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"
```

Replace case 6 (lines 121–138) with the version below. **This is the case that
encodes the design decision**: it asserts the merge stall is bounded to a single
tick, which is precisely what a daily gate would extend to 24h.

```bash
# ── 6. Conflicting origin/main: $HOME byte-identical, marker dropped ─────────
# THE test. If this regresses, a timer tick writes <<<<<<< into a live dotfile.
#
# Tick 1 documents the ONE-TICK STALL that the debounce accepts: the commit is
# deferred, so merge-tree compares the UNCHANGED branch tip against origin/main
# and finds no conflict, and the real merge then refuses because .tracked is
# dirty. Nothing is written and nothing is claimed. Tick 2 commits and the
# conflict is detected properly. Bounding this to one tick is why the gate is a
# debounce and not a 24h timer.
T="$(setup)"
printf 'theirs\n' > "$T/seed/.tracked"
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qam "theirs"
git -C "$T/seed" push -q "$T/remote.git" main
printf 'ours\n' > "$T/home/.tracked"

rc="$(tick "$T")"
eq "conflict tick 1: exit 0" "$rc" "0"
eq "conflict tick 1: \$HOME byte-identical" "$(cat "$T/home/.tracked")" "ours"

rc="$(tick "$T")"
eq "conflict: exit 0" "$rc" "0"
eq "conflict: \$HOME byte-identical" "$(cat "$T/home/.tracked")" "ours"
case "$(cat "$T/home/.tracked")" in
  *'<<<<<<<'*) die "conflict: MARKERS WRITTEN TO LIVE \$HOME" ;;
  *) pass "conflict: no markers in \$HOME" ;;
esac
if [ -f "$T/state/conflict" ]; then pass "conflict: marker dropped"; else die "conflict: no marker"; fi
eq "conflict: local work still committed" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"
```

In case 7 (lines 140–157), replace the single setup tick

```bash
tick "$T" >/dev/null
[ -f "$T/state/conflict" ] || die "setup for test 7: expected a marker"
```

with two, since the marker now appears on the second tick:

```bash
tick "$T" >/dev/null
tick "$T" >/dev/null
[ -f "$T/state/conflict" ] || die "setup for test 7: expected a marker"
```

In case 8 (lines 165–176), replace the single tick

```bash
rc="$(cd "$T/home/sub" && tick "$T")"
eq "cwd inside work-tree: exit 0" "$rc" "0"
```

with two, both from the subdirectory — the second is the one that commits:

```bash
rc="$(cd "$T/home/sub" && tick "$T")"
eq "cwd inside work-tree: exit 0" "$rc" "0"
rc="$(cd "$T/home/sub" && tick "$T")"
eq "cwd inside work-tree: second tick exit 0" "$rc" "0"
```

- [ ] **Step 2: Write the new failing cases**

Append these before the final tally line (`[ "$fail" -eq 0 ] && …`) in
`provision/dotfiles-sync.test.sh`.

`tick`'s existing `[extra-env…]` contract is what carries the new variables: its
`"$@"` expands inside the `VAR=val … bash "$SCRIPT"` assignment prefix, so
`tick "$T" DOTFILES_SYNC_FORCE=1` is valid as-is.

```bash
# ── 9. Debounce: state is cleared once the commit lands ──────────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
tick "$T" >/dev/null
if [ -f "$T/state/pending.hash" ]; then
  pass "debounce: pending.hash recorded on the deferring tick"
else
  die "debounce: no pending.hash after a dirty tick"
fi
tick "$T" >/dev/null
if [ ! -f "$T/state/pending.hash" ] && [ ! -f "$T/state/pending.since" ]; then
  pass "debounce: state cleared after the commit"
else
  die "debounce: stale pending state survived the commit"
fi
# A clean tree must also clear it, so a reverted edit does not arm a later commit.
tick "$T" >/dev/null
if [ ! -f "$T/state/pending.hash" ]; then pass "debounce: clean tick leaves no state"; else die "debounce: clean tick left state"; fi
rm -rf "$T"

# ── 10. A diff that keeps moving keeps deferring ─────────────────────────────
T="$(setup)"
before="$(dfx "$T" rev-parse air)"
printf 'one\n' > "$T/home/.tracked"
tick "$T" >/dev/null
printf 'two\n' > "$T/home/.tracked"
tick "$T" >/dev/null
eq "moving diff: still nothing committed" "$(dfx "$T" rev-parse air)" "$before"
tick "$T" >/dev/null
eq "moving diff: commits once settled" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "moving diff: committed the LATEST content" \
   "$(dfx "$T" show air:.tracked)" "two"
rm -rf "$T"

# ── 11. DOTFILES_SYNC_FORCE commits on the first dirty tick ──────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
eq "force: exit 0" "$(tick "$T" DOTFILES_SYNC_FORCE=1)" "0"
eq "force: committed immediately" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
eq "force: pushed" "$(git -C "$T/remote.git" rev-parse air)" "$(dfx "$T" rev-parse air)"
rm -rf "$T"

# ── 12. FORCE bypasses the debounce ONLY — never the branch guard ─────────────
# The manual-trigger skill sets FORCE. If it could also override sync_guard, a
# /dotfiles-sync run on a stray `checkout main` would force host-local content
# onto the shared branch — worse than the churn the debounce exists to prevent.
T="$(setup)"
dfx "$T" checkout -q main
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse main)"
rc="$(tick "$T" DOTFILES_SYNC_FORCE=1)"
if [ "$rc" != "0" ]; then pass "force+wrong branch: non-zero exit"; else die "force+wrong branch: exited 0"; fi
eq "force+wrong branch: nothing committed" "$(dfx "$T" rev-parse main)" "$before"
eq "force+wrong branch: work-tree untouched" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 13. The max-age valve commits a tree that will not settle ────────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
eq "valve: exit 0" "$(tick "$T" DOTFILES_SYNC_MAX_AGE=0)" "0"
eq "valve: committed on the first dirty tick" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 14. Hand-staged content is explicit intent, never debounced ──────────────
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
dfx "$T" add "$T/home/.tracked"
eq "staged: exit 0" "$(tick "$T")" "0"
eq "staged: committed on the first tick" \
   "$(dfx "$T" show -s --format=%s air | cut -d' ' -f1)" "auto(air):"
rm -rf "$T"

# ── 15. A deferred commit does not block propagation from origin/main ────────
# The whole point of gating the COMMIT rather than the tick: incoming shared
# content must still land in $HOME on the very tick that defers.
T="$(setup)"
printf 'edited\n' > "$T/home/.tracked"
printf 'shared\n' > "$T/seed/.shared"
printf '*\n!*/\n!.gitignore\n!.tracked\n!.shared\n' > "$T/seed/.gitignore"
git -C "$T/seed" -c user.email=t@t -c user.name=t add .gitignore .shared
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -qm "add shared"
git -C "$T/seed" push -q "$T/remote.git" main
eq "deferred+merge: exit 0" "$(tick "$T")" "0"
if [ -f "$T/home/.shared" ]; then
  pass "deferred+merge: shared file landed despite the deferred commit"
else
  die "deferred+merge: .shared missing — the debounce blocked propagation"
fi
eq "deferred+merge: local edit preserved" "$(cat "$T/home/.tracked")" "edited"
rm -rf "$T"

# ── 16. The debounce hash reads the whole tree, not the cwd subtree ──────────
# Regression twin of case 8: git computes a pathspec prefix from the cwd, which
# once made `add -u` a silent no-op. Explicit --git-dir + --work-tree suppresses
# that, but the hash must be proven prefix-safe the same way `add -u` was — the
# real invocation is `bash ~/machines/provision/dotfiles-sync.sh` from anywhere.
T="$(setup)"
mkdir -p "$T/home/sub"
printf 'edited\n' > "$T/home/.tracked"
before="$(dfx "$T" rev-parse air)"
( cd "$T/home/sub" && tick "$T" >/dev/null )
if [ -s "$T/state/pending.hash" ]; then
  pass "subdir hash: drift outside the cwd was seen"
else
  die "subdir hash: EMPTY — the hash saw only the cwd subtree"
fi
( cd "$T/home/sub" && tick "$T" >/dev/null )
if [ "$(dfx "$T" rev-parse air)" != "$before" ]; then
  pass "subdir hash: settled drift outside the cwd committed"
else
  die "subdir hash: nothing committed from a subdirectory"
fi
rm -rf "$T"
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `bash provision/dotfiles-sync.test.sh`

Expected: `FAILURES`. Specifically the cases that require deferral fail because
the script still commits on the first tick — e.g.
`FAIL dirty tick: defers the first time`,
`FAIL moving diff: still nothing committed`,
`FAIL debounce: no pending.hash after a dirty tick`. Cases 11, 13, and 14 may
already pass, since committing on the first tick is what they assert.

- [ ] **Step 4: Add the tunable and the two helpers**

In `provision/dotfiles-sync.sh`, after the `DOTFILES_STATE_DIR` default (line
26), add:

```sh
# COMMIT DEBOUNCE: a tick commits only when the tracked diff is unchanged from
# the previous tick — i.e. editing has settled — so one editing burst yields one
# commit instead of one per tick. MAX_AGE is the valve: a tree dirty this long
# commits as-is, so a file being touched forever still reaches origin.
: "${DOTFILES_SYNC_MAX_AGE:=7200}"
```

Then insert both helpers after `sync_commit` (i.e. after line 105, before the
`sync_push` comment block):

```sh
# sync_hash: hash stdin. Used ONLY to compare this tick's dirty diff with the
# previous tick's, so the weak cksum fallback is acceptable — a collision commits
# one tick early, which is the pre-debounce behavior, not a fault. Hashing rather
# than storing the diff is deliberate: tracked files include .netrc, .npmrc and
# .aws/credentials, and the state dir must not become a second plaintext copy of
# a credential.
sync_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        cksum | awk '{print $1 "-" $2}'
    fi
}

# sync_should_commit: 0 = commit on this tick, 1 = defer to a later one.
#
# WHY A DEBOUNCE AND NOT A DAILY GATE: sync_tick commits BEFORE it merges, and
# `merge-tree --write-tree` preflights COMMITTED trees — it cannot see the dirty
# work-tree. So for a locally-dirty tracked path that origin/main also touches,
# a long gate gives: preflight clean -> the conflict marker is REMOVED -> the
# real `df merge` refuses ("Your local changes ... would be overwritten") -> the
# `|| true` at the end of sync_merge swallows it. Silent, for the whole window.
# Debouncing bounds that window to a single tick.
sync_should_commit() {
    local pend="$DOTFILES_STATE_DIR/pending.hash"
    local since="$DOTFILES_STATE_DIR/pending.since"
    local cur prev now t0

    [ -n "${DOTFILES_SYNC_FORCE:-}" ] && return 0

    # Anything already staged is an explicit human act (`dotfiles add <path>`).
    # Never debounce intent.
    df diff --cached --quiet || return 0

    if df diff --quiet; then
        rm -f "$pend" "$since"      # clean tree: nothing armed for a later tick
        return 1
    fi

    mkdir -p "$DOTFILES_STATE_DIR"
    cur="$(df diff | sync_hash)"
    now="$(date +%s)"

    # `since` is written only on the clean -> dirty transition, so it survives a
    # diff that keeps changing. That is what makes the valve fire on a tree being
    # edited continuously rather than resetting with every keystroke.
    [ -f "$since" ] || printf '%s\n' "$now" > "$since"
    t0="$(cat "$since" 2>/dev/null || printf '%s' "$now")"
    case "$t0" in ''|*[!0-9]*) t0="$now" ;; esac
    [ "$((now - t0))" -ge "$DOTFILES_SYNC_MAX_AGE" ] && return 0

    prev="$(cat "$pend" 2>/dev/null || true)"
    printf '%s\n' "$cur" > "$pend"
    [ -n "$prev" ] && [ "$cur" = "$prev" ]
}
```

- [ ] **Step 5: Gate the commit in `sync_tick`**

Replace the body of `sync_tick` (lines 166–175) with:

```sh
sync_tick() {
    local branch rc
    branch="$(sync_guard)"; rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    if sync_should_commit; then
        sync_commit "$branch" || return 1
        rm -f "$DOTFILES_STATE_DIR/pending.hash" "$DOTFILES_STATE_DIR/pending.since"
    fi
    # Push and merge run on EVERY tick, deferred commit or not: a commit stranded
    # by an earlier offline tick still needs pushing, and shared content from
    # origin/main must not wait on this box's editing settling down.
    sync_push "$branch"
    sync_merge "$branch"
    return 0
}
```

- [ ] **Step 6: Update the file header**

Replace lines 5–7 of `provision/dotfiles-sync.sh`:

```sh
# ~/.dotfiles is a BARE repo whose work-tree is $HOME. Every 10 minutes this
# commits tracked changes to this machine's branch, pushes them, and merges
# origin/main in.
```

with:

```sh
# ~/.dotfiles is a BARE repo whose work-tree is $HOME. Every 10 minutes this
# pushes and merges origin/main in; it commits tracked changes to this machine's
# branch once they have SETTLED (see sync_should_commit) so that one editing
# burst produces one commit rather than one per tick.
```

- [ ] **Step 7: Run the suite to verify it passes**

Run: `bash provision/dotfiles-sync.test.sh`

Expected: `ALL PASS`, 16 cases.

- [ ] **Step 8: Commit**

```bash
git add provision/dotfiles-sync.sh provision/dotfiles-sync.test.sh
git commit -m "feat(dotfiles-sync): commit once per editing burst, not per tick"
```

---

## Task 2: Mirror the gate in the Windows twin, and reconcile the docs

**Files:**
- Modify: `provision/dotfiles-sync.ps1:60-68`
- Modify: `provision/lib/tiers.sh:884`
- Modify: `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md:141-169`

**Interfaces:**
- Consumes: Task 1's semantics — same two state files (`pending.hash`,
  `pending.since`), same env vars (`DOTFILES_SYNC_FORCE`,
  `DOTFILES_SYNC_MAX_AGE`), same default of 7200 s.
- Produces: nothing new. `windows.ps1` already registers the task against the
  absolute `provision\dotfiles-sync.ps1`, so no scheduling change.

**No test harness exists for the `.ps1` twin** — `provision/tests/` contains only
`.test.sh` files, and there is no PowerShell on the box editing this. The mirror
is therefore verified by inspection against Task 1, which is the existing
practice for this file. State that in the commit message rather than implying it
was run.

- [ ] **Step 1: Replace the commit block in the twin**

Replace `provision/dotfiles-sync.ps1` lines 60–68 (the `# 2. Commit …` block)
with:

```powershell
    # 2. Commit -- but only once the tracked diff has SETTLED. Mirror of the .sh
    #    twin's sync_should_commit; see its comment for why this is a debounce
    #    and not a daily gate (this script commits BEFORE it merges, and
    #    merge-tree preflights committed trees only, so a long gate lets the
    #    real merge at step 6 refuse silently).
    $pend   = Join-Path $StateDir 'pending.hash'
    $since  = Join-Path $StateDir 'pending.since'
    $maxAge = if ($env:DOTFILES_SYNC_MAX_AGE) { [int]$env:DOTFILES_SYNC_MAX_AGE } else { 7200 }
    $doCommit = $false

    if ($env:DOTFILES_SYNC_FORCE) {
        $doCommit = $true
    } else {
        Df diff --cached --quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $doCommit = $true          # staged by hand: explicit intent, never debounced
        } else {
            Df diff --quiet | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Remove-Item -LiteralPath $pend,$since -Force -EA SilentlyContinue
            } else {
                # Hash, never store: tracked files include .netrc and
                # .aws/credentials, and StateDir must not hold a second copy.
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $txt = (Df diff | Out-String)
                $cur = [BitConverter]::ToString(
                           $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($txt))
                       ).Replace('-','')
                $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                # `since` is written only on the clean -> dirty transition, so a
                # diff that keeps changing does not keep resetting the valve.
                if (-not (Test-Path -LiteralPath $since)) {
                    Set-Content -LiteralPath $since -Value $now
                }
                $t0 = 0
                [void][int]::TryParse((Get-Content -LiteralPath $since -Raw).Trim(), [ref]$t0)
                if ($t0 -le 0) { $t0 = $now }
                if (($now - $t0) -ge $maxAge) {
                    $doCommit = $true              # valve
                } else {
                    $prev = if (Test-Path -LiteralPath $pend) {
                        (Get-Content -LiteralPath $pend -Raw).Trim()
                    } else { '' }
                    Set-Content -LiteralPath $pend -Value $cur
                    if ($prev -and $prev -eq $cur) { $doCommit = $true }
                }
            }
        }
    }

    if ($doCommit) {
        # Tracked modifications and deletions ONLY. Never -A.
        Df add -u | Out-Null
        Df diff --cached --quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $names = @(Df diff --cached --name-only)
            $shown = ($names | Select-Object -First 5) -join ' '
            if ($names.Count -gt 5) { $shown = "$shown ... (+$($names.Count - 5))" }
            Df commit -q -m "auto($expected): $shown" | Out-Null
        }
        Remove-Item -LiteralPath $pend,$since -Force -EA SilentlyContinue
    }
```

Also update the `.DESCRIPTION` block, line 5–6:

```powershell
  ~/.dotfiles is a bare repo whose work-tree is $HOME. Commits tracked changes
  to this machine's branch, pushes, then merges origin/main in -- but only after
```

becomes:

```powershell
  ~/.dotfiles is a bare repo whose work-tree is $HOME. Pushes and merges
  origin/main in on every tick; commits tracked changes to this machine's branch
  once they have settled. The merge runs only after
```

- [ ] **Step 2: Correct the tier comment**

In `provision/lib/tiers.sh`, replace line 884:

```sh
# Cadence matches tier_selfpull / git-autofetch (10 min) — deliberately aligned.
```

with:

```sh
# TICK cadence matches tier_selfpull / git-autofetch (10 min) — deliberately
# aligned. COMMIT cadence is separate and lives in the script: a tick commits
# only once the tracked diff has settled (dotfiles-sync.sh sync_should_commit),
# so this timer interval is NOT the rate at which commits appear. Changing the
# script needs no re-provision — every scheduler here points at its absolute path.
```

- [ ] **Step 3: Reconcile §5.1 of the spec**

In `docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md`,
replace step 2 of the pseudocode block (line 146–147):

```sh
2. commit  dotfiles add -u  # tracked modifications + deletions ONLY
           dotfiles commit -m "auto(<machine>): <paths, truncated>"
```

with:

```sh
2. commit  # ONLY if the tracked diff is unchanged from the previous tick (the
           # editing burst has settled), or something is already staged by hand,
           # or the tree has been dirty past DOTFILES_SYNC_MAX_AGE (2h valve),
           # or DOTFILES_SYNC_FORCE is set (the /dotfiles-sync skill).
           dotfiles add -u  # tracked modifications + deletions ONLY
           dotfiles commit -m "auto(<machine>): <paths, truncated>"
```

And replace the second accepted-behaviors bullet (lines 167–169):

```markdown
- **Half-written saves get committed.** A tick can land mid-edit; the next tick
  commits the finished version, and promotion is manual so nothing half-baked
  reaches `main` unreviewed.
```

with:

```markdown
- **One commit per editing burst, not per tick.** A mid-edit tick defers instead
  of committing, so a session of edits lands as one `auto(<machine>)` commit.
  Steps 3–6 still run on a deferred tick: incoming shared content must not wait
  on this box's editing settling down.
- **A deferred commit stalls conflict detection for one tick.** `merge-tree`
  preflights committed trees and cannot see a dirty work-tree, so on the
  deferring tick a locally-dirty path that `origin/main` also touches previews as
  clean and the real merge simply refuses. Nothing is written and no marker is
  claimed; the next tick commits and detects it properly. Bounding this to one
  tick is why step 2 debounces rather than batching by the day.
```

- [ ] **Step 4: Verify nothing else asserts the old cadence**

Run:

```bash
grep -rn "every 10 min\|10-min\|commits on its own" provision/ docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md agents/ | grep -iv selfpull
```

Expected: every remaining hit describes the **tick** interval (the timer/task
registration, `D7` at spec line 55), not the commit interval. Leave those. Any
hit that claims a commit per tick is a miss from steps 2–3 — fix it.

- [ ] **Step 5: Re-run the POSIX suite and commit**

The `.ps1` change cannot break the `.sh` suite, but the tier comment shares a
file with tested functions.

```bash
bash provision/dotfiles-sync.test.sh
bash provision/tests/tiers.test.sh
```

Expected: `ALL PASS` from both.

```bash
git add provision/dotfiles-sync.ps1 provision/lib/tiers.sh \
        docs/superpowers/specs/2026-07-28-dotfiles-private-bare-repo-design.md
git commit -m "feat(dotfiles-sync): mirror the commit debounce on Windows, reconcile docs

The .ps1 twin has no test harness in provision/tests (all .test.sh), and no
PowerShell on the authoring box — mirrored by inspection against the .sh
implementation, as with every prior change to this file."
```

---

## Task 3: The `/dotfiles-sync` manual trigger

**Files:**
- Create: `~/.claude/skills/dotfiles-sync/SKILL.md` (**dotfiles repo**)
- Modify: `~/.gitignore` (**dotfiles repo**) — one allow-line
- Modify: `~/CLAUDE.md` (**dotfiles repo**) — the sync-timer bullet

**Interfaces:**
- Consumes: `DOTFILES_SYNC_FORCE` from Task 1, and the guarantee from case 12
  that it cannot bypass `sync_guard`.
- Produces: the `/dotfiles-sync` skill. Do **not** land this before Task 1 — the
  variable does nothing until then, so the skill would silently be a plain tick.

This lives in the **dotfiles repo on `main`**, next to `/dotfiles-promote`
(verified present on both `main` and `air`), so a clone + checkout delivers it.
Placement needs no argument and matches the split rule in
`2026-07-28-agent-config-to-dotfiles.md` Task 6: no tests, no `fleet.json`
coupling.

**Known limitation, do not fix here:** `~/.claude/skills/` is the primary
profile's dir, so secondary profiles (`~/.claude-<postfix>`) and `~/.codex` do
not see it. `/dotfiles-promote` already has that property; fixing it is a fan-out
question for the agent-config plan, not this one.

- [ ] **Step 1: Write the skill**

Create `~/.claude/skills/dotfiles-sync/SKILL.md`:

```markdown
---
name: dotfiles-sync
description: Use when $HOME dotfiles changes should reach the other machines NOW rather than waiting for the timer — "sync dotfiles", "commit my dotfiles", "push this dotfile" — or right after editing a tracked $HOME file whose content another box needs.
---

# dotfiles-sync

Force one sync tick: commit tracked `$HOME` changes to this machine's branch,
push, and merge `origin/main` in.

The 10-minute timer already does this. It **debounces the commit** — a tick
commits only once the tracked diff has stopped changing between ticks — so a file
edited seconds ago normally waits for the next tick. This skill skips that wait.

## Run it

```console
DOTFILES_SYNC_FORCE=1 bash "$HOME/machines/provision/dotfiles-sync.sh"
```

`DOTFILES_SYNC_FORCE` bypasses the **debounce only**. It cannot override the
branch guard: if HEAD is not on this machine's branch the run still exits
non-zero having committed nothing. Never work around that — host-local content
force-fed onto `main` is what the guard exists to prevent.

## Report what happened

```console
cd ~ && git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" log --oneline -3
cd ~ && git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" status --short
```

Say which of these it was:

- **A new `auto(<branch>): …` commit** — committed and pushed. Name the paths.
- **No new commit** — nothing tracked had changed. If the user expected a change,
  the file is almost certainly **untracked**: the tick uses `add -u`, which never
  stages an untracked path. Point them at *Adding a tracked file* in
  `~/CLAUDE.md` — it is a deliberate two-step, not something to work around.
- **Non-zero exit** — a hard stop needing a human. Quote the script's stderr
  verbatim. It is either HEAD on the wrong branch or a merge/rebase in progress.
  Do not "fix" it with a checkout.

## Check for a conflict

```console
cat "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync/conflict" 2>/dev/null
```

If that file exists, `origin/main` conflicts with this branch and `$HOME` was
left untouched — by design. Show the resolve command the marker contains; the
next tick clears the marker once the merge is done.

Promoting content from this branch to `main` is a different job: `/dotfiles-promote`.
```

- [ ] **Step 2: Track it on this machine's branch**

Add the allow-line next to the existing promote-skill line in `~/.gitignore`.
**Unanchored, deliberately** — this is shared content bound for `main`, and the
leading-slash rule in `~/CLAUDE.md` applies to host-local lines only:

```
!.claude/skills/dotfiles-sync/SKILL.md
```

Verify it is now trackable before staging — `check-ignore -v` exits 0 on a
*negated* match too, so it cannot distinguish "ignored" from "allowed". Use a
dry-run add, which refuses an ignored path:

```console
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME add --dry-run .claude/skills/dotfiles-sync/SKILL.md
```

Expected: `add '.claude/skills/dotfiles-sync/SKILL.md'`. A refusal means the
allow-line is wrong.

- [ ] **Step 3: Update the sync-timer section of `~/CLAUDE.md`**

Replace this bullet:

```markdown
- **It commits on its own.** A file you edit and leave half-written can land in a
  commit. Harmless — the next tick commits the finished version, and nothing
  reaches `main` without a manual promote.
```

with:

```markdown
- **It commits on its own, but only once your edits settle.** A tick commits only
  when the tracked diff is unchanged from the previous tick, so one editing
  session lands as one commit rather than one per tick. A file still being edited
  waits; a tree dirty for over 2 hours commits anyway. Nothing reaches `main`
  without a manual promote. To commit and push right now, use `/dotfiles-sync`.
```

- [ ] **Step 4: Commit both on this machine's branch**

```console
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME add .gitignore .claude/skills/dotfiles-sync/SKILL.md CLAUDE.md
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME commit -m "feat: add the /dotfiles-sync skill; document the commit debounce"
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME push
```

`cd ~` is required: `git` derives a pathspec prefix from the cwd for `add` with
relative paths, so running this from a subdirectory of `$HOME` stages the wrong
set — or nothing.

- [ ] **Step 5: Promote to `main`**

Both files are shared content, so run the `/dotfiles-promote` skill for
`.claude/skills/dotfiles-sync/SKILL.md`, `CLAUDE.md`, and the `.gitignore`
allow-line. Do not hand-roll the promote — the skill exists because the
shared/host-local invariant (a path is on `main` **or** on a branch, never both)
is easy to break by hand.

- [ ] **Step 6: Verify the skill end-to-end on this box**

```console
DOTFILES_SYNC_FORCE=1 bash "$HOME/machines/provision/dotfiles-sync.sh"; echo "rc=$?"
```

Expected: `rc=0`, and the promote's own commit already committed everything, so
this either commits nothing or commits whatever else was pending. Then confirm
the debounce is live on the real box — edit a tracked file, run one tick without
the force flag, and check that it defers:

```console
cd ~ && git --git-dir=$HOME/.dotfiles --work-tree=$HOME log --oneline -1
bash "$HOME/machines/provision/dotfiles-sync.sh"
ls "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync/"
```

Expected: `pending.hash` and `pending.since` present, HEAD unmoved. A second run
commits. Clean up by letting the timer take it.

---

## Out of scope

| Thing | Why not here |
|---|---|
| Squash / amend / `--force-with-lease` for a literal one-commit-per-day | Rejected: buys one-per-day over one-per-burst, at the cost of a force-push from an unattended timer, a lease failure that wedges the branch, and an interaction with `/dotfiles-promote` when an already-promoted commit gets amended |
| Changing the 10-minute tick interval | The tick still does the fetch/merge that propagates `main`; only the commit needed gating |
| A filesystem watcher | Explicitly rejected as D7 in the design spec |
| Fanning the skill out to `~/.claude-<postfix>` and `~/.codex` | `/dotfiles-promote` has the same gap; it belongs to the agent-config plan's fan-out work |
| Enrolling `server` in dotfiles | Pre-existing follow-up, unchanged by this plan |

## Self-review notes

- **Spec coverage:** the user asked for daily auto-commit + a manual-trigger
  skill. The cadence goal is met by debounce (chosen over literal-daily after the
  merge-stall analysis, confirmed 2026-07-28); the skill is Task 3.
- **Verified empirically before writing, not assumed:** the suite is green at
  `ALL PASS` today; explicit `--git-dir` + `--work-tree` applies **no** cwd
  pathspec prefix (`diff-files --name-only` and `status --porcelain` from a
  subdirectory both list the whole tree), which is why case 8 passes with no `cd`
  in the script — and why case 16 asserts the same property for the hash rather
  than assuming it; `/dotfiles-promote` is present on both `main` and `air`;
  `~/.local/state/dotfiles-sync/` currently holds only `branch`.
- **Type consistency:** `pending.hash` / `pending.since` / `DOTFILES_SYNC_FORCE`
  / `DOTFILES_SYNC_MAX_AGE` are spelled identically in Task 1, Task 2's mirror,
  Task 3's skill, and the tests.
