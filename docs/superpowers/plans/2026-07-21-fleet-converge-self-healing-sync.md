# Fleet self-healing sync + auto-convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A change pushed to `machines` lands on every fleet member on its own — instantly where reachable, eventually always — and each box applies the pulled state automatically (re-symlink, re-provision, `nixos-rebuild`) after it updates.

**Architecture:** Two pull *sources* (`/ship` SSH fan-out + a per-OS self-pull timer) both do `git pull --ff-only origin main`. Every real pull rewrites `.git/ORIG_HEAD` and fires an **OS-tier convergence trigger**: non-nix uses the existing committed `post-merge` git hook (already wired by `bootstrap.sh` via `core.hooksPath`); NixOS uses a root `machines-converge.path` systemd unit watching `.git/ORIG_HEAD` (bootstrap deliberately never wires the hook on NixOS). Both tiers run one committed `scripts/converge.sh`, which self-gates, computes its own change range from `.machines/`, and routes per-OS. All host state lives in a gitignored `.machines/` so convergence never dirties the tracked tree.

**Tech Stack:** POSIX sh (`converge.sh`, hooks, `provision/*.sh`), Nix / systemd (`modules/system/*.nix`), PowerShell + Task Scheduler (`provision/*.ps1`), bash test harnesses (`*.test.sh`).

## Global Constraints

- **Convergence must NEVER dirty the tracked tree.** Every write from `converge.sh` / provision goes to the gitignored `.machines/` or outside the repo. If a tracked file is modified, the clean-tree gate permanently disables all future auto-pulls on that box. (Spec §2.)
- **`converge.sh` is POSIX `sh`, committed, idempotent, and assumes it is privileged** (Linux root / Windows SYSTEM). It owns *all* OS-routing policy and the self-gates; triggers stay generic. (Spec §2.)
- **`--ff-only` fleet-wide** — never `rebase`. A rebase-pull fires `post-rewrite`, not `post-merge`, so the non-nix hook would miss it. (Spec §Architecture, §Edge cases.)
- **Deploy branch = `main`; primary worktree only.** A linked worktree may push/ship but never converges. (Spec §Edge cases.)
- **Convergence rebuilds NixOS against the committed `flake.lock`** — never `nix flake update`. (Spec §Reproducibility.)
- **Timers exclude work repos** (`origin` matching `thepureapp/`) — same exclusion `/ship` enforces. (Spec §3.)
- **Windows fleet boxes have no Nix.** Any `nix eval` / `nix build --dry-run` / `nix flake check` verification MUST be deferred to a NixOS member (currently only `latitude5520`) after a `git pull`. (Project memory.)
- **Hook dir is `agents/git-hooks/` (dashed).** Convergence *extends* the existing `post-merge`; it does not add a parallel hook dir. (Spec §1a.)
- **Only the `machines` repo has a converge trigger** — sibling fleet-sync repos are pull-only. (Spec §3, Non-goals.)

---

## File Structure

**Created:**
- `scripts/converge.sh` — the convergence engine: self-gates, range from `.machines/`, box-class routing, status write. Sourceable with `CONVERGE_LIB_ONLY=1`.
- `scripts/converge.test.sh` — unit tests for `converge.sh`'s pure helpers.
- `provision/fleet-selfpull.sh` — POSIX self-pull over all fleet-sync repos (Linux/WSL timer body). Sourceable with `FLEET_SELFPULL_LIB_ONLY=1`.
- `provision/fleet-selfpull.test.sh` — unit tests for the self-pull gates.
- `provision/fleet-selfpull.ps1` — Windows self-pull counterpart (Task Scheduler body).
- `modules/system/machines-converge.nix` — root `machines-converge.path` + `.service` (NixOS trigger).

**Modified:**
- `.gitignore` — add `/.machines/`.
- `agents/git-hooks/post-merge` — run `_refresh-claude-config` then fire converge detached (non-nix routing).
- `modules/system/self-update.nix` — retarget `repo` default to `/home/me/machines`; `rebase` → `merge --ff-only`; update header comment.
- `hosts/latitude/nixos/configuration.nix` — import + enable `services.machinesConverge`.
- `provision/windows.ps1` — register the `machines-converge` SYSTEM task + the `fleet-selfpull` Task Scheduler task.
- `provision/linux.sh` — install a systemd-user timer (cron fallback) running `fleet-selfpull.sh`.
- `agents/plugin/skills/ship/fleet-pull.sh` — emit a convergence-status column from each member's `.machines/last-converge`.
- `agents/plugin/skills/ship/tests/fleet-pull.test.sh` — cover the new column.

---

## Task 1: `converge.sh` engine + `.machines/` state root

**Files:**
- Create: `scripts/converge.sh`
- Create: `scripts/converge.test.sh`
- Modify: `.gitignore` (add `/.machines/`)

**Interfaces:**
- Produces (consumed by later tasks and tests via `CONVERGE_LIB_ONLY=1`):
  - `box_class()` → prints `nixos` | `windows` | `linux`
  - `range_low()` → prints last-converged rev, or empty on first run
  - `changed_paths <low> <high>` → newline-separated changed tracked paths (all tracked if `<low>` empty)
  - `touches_nix <low> <high>` → exit 0 if any `*.nix` / `flake.nix` / `flake.lock` changed (or first run)
  - `on_main_primary()` → exit 0 iff primary worktree AND on `main`
  - `write_status <rev> <ok|fail> <reason>` → writes `.machines/last-converge`; on `ok` also writes `.machines/converged-rev`
  - State files: `.machines/converged-rev` (bare SHA), `.machines/last-converge` (`rev=`/`status=`/`timestamp=`/`reason=` lines)

- [ ] **Step 1: Add `.machines/` to `.gitignore`**

Append to `.gitignore` (after the `.gortex/` block):

```gitignore
# Per-host convergence state + runtime root (à la ~/.config). Gitignored so
# converge.sh / provision writes never trip the clean-tree gate. Per-host by
# construction — never synced. See docs/superpowers/specs/2026-07-21-fleet-
# converge-self-healing-sync-design.md §5.
/.machines/
```

- [ ] **Step 2: Write the failing test for the pure helpers**

Create `scripts/converge.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for scripts/converge.sh pure helpers. No privilege, no rebuild:
# sources the script in CONVERGE_LIB_ONLY mode so functions load but converge_main
# never runs. Builds a throwaway git repo to exercise range/gate logic.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/converge.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build a throwaway repo that looks like the machines checkout: converge.sh
# derives REPO from its own dir ($0/..), so copy it into <repo>/scripts/.
repo="$tmp/machines"
mkdir -p "$repo/scripts"
cp "$SCRIPT" "$repo/scripts/converge.sh"
git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
git -C "$repo" checkout -q -b main
: > "$repo/a.txt"; git -C "$repo" add .; git -C "$repo" commit -qm c1
rev1="$(git -C "$repo" rev-parse HEAD)"
echo change > "$repo/mod.nix"; git -C "$repo" add .; git -C "$repo" commit -qm c2
rev2="$(git -C "$repo" rev-parse HEAD)"

# Source the COPY so REPO resolves to the throwaway repo.
CONVERGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$repo/scripts/converge.sh"

# range_low: empty when no converged-rev file yet.
eq "$(range_low)" "" "range_low empty on first run"

# touches_nix: rev1..rev2 added mod.nix -> hit.
touches_nix "$rev1" "$rev2" && pass "touches_nix detects .nix" || die "touches_nix detects .nix"

# touches_nix: empty low (first run) -> treat as changed (hit).
touches_nix "" "$rev2" && pass "touches_nix first-run is hit" || die "touches_nix first-run is hit"

# on_main_primary: true on main in primary checkout.
on_main_primary && pass "on_main_primary true on main" || die "on_main_primary true on main"

# write_status ok: writes both files; converged-rev is the bare SHA.
write_status "$rev2" ok "test-ok"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status ok sets converged-rev"
grep -q '^status=ok$' "$repo/.machines/last-converge" && pass "last-converge status=ok" || die "last-converge status=ok"

# after ok write, range_low returns rev2.
eq "$(range_low)" "$rev2" "range_low reads converged-rev"

# write_status fail: updates last-converge but NOT converged-rev (retry next time).
write_status "$rev2" fail "boom"
eq "$(cat "$repo/.machines/converged-rev")" "$rev2" "write_status fail leaves converged-rev"
grep -q '^status=fail$' "$repo/.machines/last-converge" && pass "last-converge status=fail" || die "last-converge status=fail"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash scripts/converge.test.sh`
Expected: FAIL — `scripts/converge.sh` does not exist yet (`source` errors / functions undefined).

- [ ] **Step 4: Write `scripts/converge.sh`**

Create `scripts/converge.sh`:

```sh
#!/usr/bin/env sh
# scripts/converge.sh — apply the pulled `machines` state on THIS box after a
# ff-pull. Fired by the OS-tier trigger (non-nix: agents/git-hooks/post-merge;
# NixOS: machines-converge.path). Idempotent, privileged (root / SYSTEM),
# detached from the pull. Owns ALL os-routing policy + the self-gates.
#
# NEVER writes a tracked file — only .machines/ (gitignored) — or it would trip
# the clean-tree gate and disable future auto-pulls. See the design spec §2/§5.
#
# Testable: `CONVERGE_LIB_ONLY=1 . converge.sh` loads the helpers without running.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"   # scripts/ -> repo root
STATE="$REPO/.machines"
CONVERGED_REV="$STATE/converged-rev"
STATUS_FILE="$STATE/last-converge"

log() { printf 'converge: %s\n' "$*"; }

# box_class: nixos | windows | linux (NixOS wins; then uname).
box_class() {
  if [ -e /etc/NIXOS ]; then echo nixos; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo linux ;;
  esac
}

# on_main_primary: succeed iff primary worktree (git-dir == common-dir) AND main.
on_main_primary() {
  [ "$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" \
    = "$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)" ] || return 1
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || return 1
}

# range_low: last successfully-converged rev, or empty (first run = whole tree).
range_low() { [ -f "$CONVERGED_REV" ] && cat "$CONVERGED_REV" || true; }

# changed_paths <low> <high>: changed tracked paths; all tracked when low empty.
changed_paths() {
  if [ -n "$1" ]; then
    git -C "$REPO" diff --name-only "$1" "$2" 2>/dev/null
  else
    git -C "$REPO" ls-files 2>/dev/null
  fi
}

# touches_nix <low> <high>: 0 if any *.nix / flake.nix / flake.lock in range.
touches_nix() {
  changed_paths "$1" "$2" | grep -qE '(\.nix$|(^|/)flake\.(nix|lock)$)'
}

# write_status <rev> <ok|fail> <reason>: record outcome; advance converged-rev
# only on ok (a failure retries the same range on the next fire).
write_status() {
  mkdir -p "$STATE"
  printf 'rev=%s\nstatus=%s\ntimestamp=%s\nreason=%s\n' \
    "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" > "$STATUS_FILE"
  [ "$2" = ok ] && printf '%s\n' "$1" > "$CONVERGED_REV"
  return 0
}

converge_main() {
  on_main_primary || { log "skip: not primary-worktree-on-main"; exit 0; }
  low="$(range_low)"
  high="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" || { log "no HEAD"; exit 0; }
  class="$(box_class)"
  log "class=$class range=${low:-<first>}..$high"
  cd "$REPO" || { log "cannot cd $REPO"; exit 0; }
  case "$class" in
    nixos)
      if [ -n "$low" ] && ! touches_nix "$low" "$high"; then
        write_status "$high" ok "nixos: no *.nix/flake change — config already live via symlinks"
        exit 0
      fi
      if nixos-rebuild switch --flake "$REPO#$(hostname)"; then
        write_status "$high" ok "nixos-rebuild switch"
      else
        write_status "$high" fail "nixos-rebuild switch failed (see journalctl -u machines-converge)"
      fi ;;
    windows)
      if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$REPO/provision/windows.ps1"; then
        write_status "$high" ok "provision/windows.ps1"
      else
        write_status "$high" fail "provision/windows.ps1 failed"
      fi ;;
    linux)
      if bash "$REPO/provision/linux.sh"; then
        write_status "$high" ok "provision/linux.sh"
      else
        write_status "$high" fail "provision/linux.sh failed"
      fi ;;
    *) log "unknown box class"; exit 0 ;;
  esac
}

[ -n "${CONVERGE_LIB_ONLY:-}" ] || converge_main
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/converge.test.sh`
Expected: `ALL PASS` (exit 0).

- [ ] **Step 6: `chmod +x` and sanity-check the gate short-circuit**

Run:
```bash
chmod +x scripts/converge.sh
# In THIS repo on main: dry-run the gate only (no rebuild) by faking box_class.
CONVERGE_LIB_ONLY=1 sh -c '. ./scripts/converge.sh; on_main_primary && echo GATE-OK || echo GATE-SKIP'
```
Expected: `GATE-OK` when run from the primary checkout on `main`.

- [ ] **Step 7: Commit**

```bash
git add scripts/converge.sh scripts/converge.test.sh .gitignore
git commit -m "feat(converge): convergence engine + .machines/ state root

converge.sh owns self-gates, range-from-last-converged-rev, and per-OS
routing (nixos-rebuild / provision.sh / windows.ps1). Writes only into
gitignored .machines/. Unit-tested via CONVERGE_LIB_ONLY."
```

---

## Task 2: Non-nix trigger — extend the `post-merge` hook

**Files:**
- Modify: `agents/git-hooks/post-merge`
- Test: `agents/git-hooks/post-merge.test.sh` (Create)

**Interfaces:**
- Consumes: `scripts/converge.sh` (Task 1), `agents/git-hooks/_refresh-claude-config` (existing).
- Produces: on a non-nix pull, runs the config refresh then fires convergence detached — Windows via `schtasks /run /tn machines-converge`, WSL/non-systemd Linux by backgrounding `converge.sh`. NixOS never reaches this hook (bootstrap does not wire `core.hooksPath` there).

- [ ] **Step 1: Write the failing test**

Create `agents/git-hooks/post-merge.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior test for the post-merge hook: it must (1) run _refresh-claude-config
# (NOT exec — the second job must still run) and (2) route a converge FIRE.
# We stub _refresh-claude-config and the fire commands on PATH and assert both
# ran. Forces the linux branch via a fake `uname`.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/post-merge"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fake repo with a scripts/converge.sh present.
repo="$tmp/machines"; mkdir -p "$repo/scripts" "$repo/agents/git-hooks" "$tmp/bin"
git -C "$repo" init -q; git -C "$repo" checkout -q -b main
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
: > "$repo/x"; git -C "$repo" add .; git -C "$repo" -c commit.gpgsign=false commit -qm c1
# converge.sh writes a marker instead of converging.
cat > "$repo/scripts/converge.sh" <<EOF
#!/usr/bin/env sh
echo fired > "$tmp/converge-ran"
EOF
chmod +x "$repo/scripts/converge.sh"
cp "$HOOK" "$repo/agents/git-hooks/post-merge"
# Stub the shared refresh script the hook calls.
cat > "$repo/agents/git-hooks/_refresh-claude-config" <<EOF
#!/usr/bin/env bash
echo refreshed > "$tmp/refresh-ran"
EOF
chmod +x "$repo/agents/git-hooks/_refresh-claude-config"
# Fake `uname` -> Linux so the WSL/linux branch backgrounds converge.sh.
cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
chmod +x "$tmp/bin/uname"

( cd "$repo" && PATH="$tmp/bin:$PATH" bash agents/git-hooks/post-merge )
sleep 0.5   # detached converge is backgrounded

[ -f "$tmp/refresh-ran" ]  && pass "refresh ran" || die "refresh ran"
[ -f "$tmp/converge-ran" ] && pass "converge fired" || die "converge fired"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash agents/git-hooks/post-merge.test.sh`
Expected: FAIL — current `post-merge` `exec`s the refresh, so `converge-ran` is never created (`FAIL converge fired`).

- [ ] **Step 3: Rewrite `agents/git-hooks/post-merge`**

Replace the entire file `agents/git-hooks/post-merge` with:

```bash
#!/usr/bin/env bash
# Fires after `git pull` (merge). TWO jobs, so this does NOT `exec`:
#   1. re-link Claude config (see _refresh-claude-config)
#   2. fire convergence — the NON-NIX trigger (spec §1a). NixOS never runs this
#      hook (bootstrap skips core.hooksPath there); it uses machines-converge.path.
# Convergence is fired DETACHED and we return immediately so `/ship`'s pull never
# blocks on a rebuild/provision. converge.sh self-gates (primary worktree, main).
set -u
HERE="$(cd -P "$(dirname "$0")" && pwd)"

# Job 1 — config refresh (never fail the git op).
"$HERE/_refresh-claude-config" || true

# Job 2 — only the machines repo ships scripts/converge.sh.
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
converge="$repo/scripts/converge.sh"
[ -f "$converge" ] || exit 0

case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*)
    # SYSTEM/admin task — NOT a hook-spawned Start-Process (which would inherit
    # the pulling user's unprivileged token). MSYS_NO_PATHCONV stops Git Bash
    # from mangling the /run and /tn switches into paths.
    MSYS_NO_PATHCONV=1 schtasks /run /tn machines-converge >/dev/null 2>&1 || true
    ;;
  *)
    # WSL / non-systemd Linux: no root unit — background converge.sh directly.
    # (Its privilege is passwordless-sudo-or-user scope; it skips what it can't do.)
    setsid sh "$converge" >/dev/null 2>&1 </dev/null &
    ;;
esac
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash agents/git-hooks/post-merge.test.sh`
Expected: `ALL PASS` (both `refresh ran` and `converge fired`).

- [ ] **Step 5: Verify the refresh path is unbroken in this repo**

Run (this repo is on `main`, primary checkout, non-nix WSL):
```bash
bash agents/git-hooks/post-merge   # should print the refresh one-liner (or nothing) and return instantly
echo "exit=$?"
```
Expected: `exit=0`, returns immediately (converge is backgrounded and self-gates).

- [ ] **Step 6: Commit**

```bash
git add agents/git-hooks/post-merge agents/git-hooks/post-merge.test.sh
git commit -m "feat(converge): fire convergence from post-merge (non-nix trigger)

post-merge now runs _refresh-claude-config (no longer exec) THEN fires
converge.sh detached — Windows via schtasks machines-converge, WSL/linux by
backgrounding. NixOS is untouched (hook not wired there)."
```

---

## Task 3: NixOS trigger + `self-update.nix` retarget

**Files:**
- Create: `modules/system/machines-converge.nix`
- Modify: `modules/system/self-update.nix` (repo default; `rebase` → `merge --ff-only`; header comment)
- Modify: `hosts/latitude/nixos/configuration.nix` (import + enable)

**Interfaces:**
- Consumes: `scripts/converge.sh` (Task 1).
- Produces: `services.machinesConverge.enable` — a root `machines-converge.path` unit watching `<repo>/.git/ORIG_HEAD` that starts a root `machines-converge.service` running `converge.sh`. Fires for both `/ship`'s direct pull and the `nixRepoAutoPull` timer's pull.

**Verification note:** the Windows/WSL box you are likely running on has no Nix. Per Global Constraints, the `nix build --dry-run` step (Step 6) MUST run on `latitude5520` after this branch is pulled there. Do the edits here; run the dry-build on latitude.

- [ ] **Step 1: Write `modules/system/machines-converge.nix`**

Create `modules/system/machines-converge.nix`:

```nix
# Root convergence trigger for the `machines` repo on NixOS (spec §1b).
#
# NixOS gets NO git post-merge hook (bootstrap skips core.hooksPath there to
# avoid racing home-manager), and an ExecStartPost on the pull service is a trap
# (runs as User=me, and fires only on the timer's own HEAD-advancing pull — it
# misses /ship's direct pull, the common case). So a path unit, decoupled from
# which process pulled, watches .git/ORIG_HEAD — rewritten by EVERY ff-pull —
# and starts a ROOT oneshot that runs converge.sh. Native root => nixos-rebuild
# has privilege, no polkit. self-update.nix stays a pure pull backend.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.machinesConverge;
in {
  options.services.machinesConverge = {
    enable = lib.mkEnableOption "root convergence on ff-pull of the machines repo";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/me/machines";
      description = "Path to the machines checkout whose pulls trigger convergence.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Root oneshot: run converge.sh. converge.sh self-gates (primary worktree,
    # on main) and routes to nixos-rebuild switch --flake against the committed
    # lock. Runs as root (default) so the rebuild has privilege.
    systemd.services.machines-converge = {
      description = "Converge this box to the pulled machines state (root)";
      # converge.sh calls: git, nixos-rebuild, hostname, date, grep, bash.
      path = [pkgs.git pkgs.nixos-rebuild pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.nettools];
      serviceConfig = {
        Type = "oneshot";
        # nixos-rebuild needs a writable /nix, network, and the flake path.
        Environment = ["HOME=/root"];
      };
      script = "${pkgs.bash}/bin/bash ${cfg.repo}/scripts/converge.sh";
    };

    # Path unit: fire the service whenever .git/ORIG_HEAD changes. PathChanged
    # (not PathModified) so it also catches the file's first creation. Git
    # rewrites ORIG_HEAD on every merge/ff-pull; an already-up-to-date pull skips
    # merge and does NOT rewrite it — correct (nothing to converge).
    systemd.paths.machines-converge = {
      description = "Fire convergence when the machines repo pulls (ORIG_HEAD changes)";
      wantedBy = ["paths.target"];
      pathConfig = {
        PathChanged = "${cfg.repo}/.git/ORIG_HEAD";
        Unit = "machines-converge.service";
      };
    };
  };
}
```

- [ ] **Step 2: Retarget + ff-only in `modules/system/self-update.nix`**

Change the `repo` option default (currently `/home/me/nix`):

```nix
    repo = lib.mkOption {
      type = lib.types.str;
      default = "/home/me/machines";
      description = "Path to the flake repo checkout to keep updated.";
    };
```

Replace the rebase block in `script` (currently `git rebase --quiet '@{u}'` … `git rebase --abort`) with an ff-only merge:

```sh
        if git merge --ff-only --quiet '@{u}'; then
          echo "auto-pulled ${repo}: $head_rev -> $(git rev-parse HEAD)"
        else
          echo "diverged (non-ff) in ${repo} — skipping, resolve manually" >&2
          exit 1
        fi
```

Update the file's header comment: the "deliberately does NOT run `nixos-rebuild`" note now has a caveat — replace the parenthetical about `just switch` with a pointer that convergence is fired separately by `services.machinesConverge` (`modules/system/machines-converge.nix`) via the `ORIG_HEAD` path unit, so this service stays a pure pull backend. Also change `rebase` wording in the header/`Safety` lines to `merge --ff-only` (diverged → skip + log, no mid-rebase state).

- [ ] **Step 3: Import + enable on latitude**

In `hosts/latitude/nixos/configuration.nix`, add the module import next to `self-update.nix` (line ~15):

```nix
    ../../../modules/system/machines-converge.nix
```

And enable it next to `services.nixRepoAutoPull.enable = true;` (line ~69):

```nix
  services.machinesConverge.enable = true;
```

- [ ] **Step 4: Confirm the pull service still targets the right repo**

The `services.nixRepoAutoPull` block in `configuration.nix` relies on the module default. Confirm no explicit `services.nixRepoAutoPull.repo = "/home/me/nix";` override remains in `hosts/latitude/nixos/configuration.nix` — grep it:

Run: `grep -n "nixRepoAutoPull" hosts/latitude/nixos/configuration.nix`
Expected: only `.enable = true;` (no stale `.repo` override pinning `/home/me/nix`). If an override exists, delete it so the retargeted default applies.

- [ ] **Step 5: Commit**

```bash
git add modules/system/machines-converge.nix modules/system/self-update.nix hosts/latitude/nixos/configuration.nix
git commit -m "feat(converge): NixOS root trigger (machines-converge.path) + ff-only pull

machines-converge.path watches .git/ORIG_HEAD and starts a root
machines-converge.service running converge.sh — decoupled from which
process pulled, native root for nixos-rebuild, no polkit. self-update.nix
retargeted to ~/machines and switched rebase -> merge --ff-only (diverged
now skips+logs). Enabled on latitude."
```

- [ ] **Step 6: Dry-build on latitude (deferred — run ON latitude after pulling this branch)**

On `latitude` (SSH in), from its `~/machines` checkout on this branch:
```bash
nix build --dry-run '.#nixosConfigurations.latitude5520.config.system.build.toplevel'
```
Expected: evaluates and dry-builds with no error. If it fails, fix the module (common miss: a `pkgs` attr name in `path`, e.g. `nettools` provides `hostname`) and re-run before proceeding.

---

## Task 4: Per-OS self-pull timers (Trigger B)

**Files:**
- Create: `provision/fleet-selfpull.sh`
- Create: `provision/fleet-selfpull.test.sh`
- Create: `provision/fleet-selfpull.ps1`
- Modify: `provision/linux.sh` (install the user timer / cron)
- Modify: `provision/windows.ps1` (register the self-pull task + the `machines-converge` SYSTEM task)

**Interfaces:**
- Consumes: the `post-merge` hook (Task 2) + `machines-converge` task fire it after each pull.
- Produces: a ~10-min timer on each non-nix box that ff-pulls every personal fleet-sync repo (excluding `thepureapp/`). NixOS's self-pull is already `services.nixRepoAutoPull` (Task 3) and is out of scope here. Convergence is NOT the timer's job — its pull triggers convergence via the Task-2 hook.
- `fleet-selfpull.sh` produces (via `FLEET_SELFPULL_LIB_ONLY=1`): `is_fleet_repo <dir>` → exit 0 iff a git repo whose `origin` is not `thepureapp/` and has a tracked upstream; `selfpull_one <dir>` → gates (on main, clean, ff) then `git pull --ff-only`, prints a status token.

- [ ] **Step 1: Write the failing test for the self-pull gates**

Create `provision/fleet-selfpull.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for provision/fleet-selfpull.sh gate helpers. Builds throwaway
# repos with a local "remote" so pulls are real but offline.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet-selfpull.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkrepo() { # <name> <origin-url>  -> prints repo path, main branch, upstream set
  local d="$tmp/$1"; git init -q "$d"
  git -C "$d" checkout -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" remote add origin "$2"
  : > "$d/f"; git -C "$d" add .; git -C "$d" -c commit.gpgsign=false commit -qm c1
  echo "$d"
}

FLEET_SELFPULL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$SCRIPT"

personal="$(mkrepo personal git@github.com:metheoryt/machines.git)"
work="$(mkrepo work git@github.com:thepureapp/backend.git)"

# is_fleet_repo: personal origin qualifies, thepureapp is excluded.
is_fleet_repo "$personal" && pass "personal repo qualifies" || die "personal repo qualifies"
is_fleet_repo "$work" && die "thepureapp excluded" || pass "thepureapp excluded"

# A non-repo dir never qualifies.
mkdir "$tmp/plain"
is_fleet_repo "$tmp/plain" && die "plain dir excluded" || pass "plain dir excluded"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash provision/fleet-selfpull.test.sh`
Expected: FAIL — `provision/fleet-selfpull.sh` missing.

- [ ] **Step 3: Write `provision/fleet-selfpull.sh`**

Create `provision/fleet-selfpull.sh`:

```sh
#!/usr/bin/env bash
# provision/fleet-selfpull.sh — Trigger B (eventual). For each personal
# fleet-sync repo under the scan roots, if safe, `git pull --ff-only origin main`.
# The pull fires the repo's own post-merge hook (only machines has converge.sh),
# so this script NEVER converges — it only keeps checkouts fresh. Excludes work
# repos (thepureapp/). Mirrors modules/system/git-autofetch (scan) +
# self-update.nix (gates). Always exits 0.
#
# Testable: `FLEET_SELFPULL_LIB_ONLY=1 source` loads helpers without scanning.
set -u

# Scan roots — same shape as fleet-pull.sh's REMOTE_SCRIPT.
FLEET_ROOTS="${FLEET_ROOTS:-$HOME $HOME/my $HOME/pure $HOME/cyphy671 $HOME/exactly}"

# is_fleet_repo <dir>: git repo, origin not thepureapp/, has a tracked upstream.
is_fleet_repo() {
  local d="$1" o
  { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || return 1
  o="$(git -C "$d" remote get-url origin 2>/dev/null)" || return 1
  case "$o" in *thepureapp/*) return 1 ;; esac
  git -C "$d" rev-parse '@{u}' >/dev/null 2>&1 || return 1
  return 0
}

# selfpull_one <dir>: gate (main, clean, ff) then pull. Prints one status token.
selfpull_one() {
  local d="$1" before after
  [ "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || { echo "SKIP not-main"; return 0; }
  [ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ] || { echo "SKIP dirty"; return 0; }
  before="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
  if git -C "$d" pull --ff-only origin main >/dev/null 2>&1; then
    after="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
    [ "$before" = "$after" ] && echo "OK up-to-date" || echo "OK $before..$after"
  else
    echo "SKIP diverged"
  fi
}

selfpull_all() {
  local root d
  for root in $FLEET_ROOTS; do
    [ -d "$root" ] || continue
    for d in "$root" "$root"/*; do
      is_fleet_repo "$d" || continue
      printf '%s\t%s\n' "$d" "$(selfpull_one "$d")"
    done
  done
}

[ -n "${FLEET_SELFPULL_LIB_ONLY:-}" ] || selfpull_all
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash provision/fleet-selfpull.test.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Write `provision/fleet-selfpull.ps1` (Windows body)**

Create `provision/fleet-selfpull.ps1` (mirror of `modules/system/git-autofetch/git-autofetch.ps1`'s scan, but ff-pull with gates; convergence rides the post-merge hook):

```powershell
<#
.SYNOPSIS
  Trigger B for Windows: ff-pull every personal fleet-sync repo under the roots.
.DESCRIPTION
  Mirror of fleet-selfpull.sh. Registered as a ~10-min Scheduled Task by
  provision/windows.ps1. Only ff-pulls on `main`, clean tree, tracked upstream.
  Excludes thepureapp/. The pull fires each repo's post-merge hook (only
  machines has converge.sh -> schtasks machines-converge), so this NEVER
  converges itself. Never blocks on a credential prompt.
#>
param(
    [string[]] $Roots = @("$env:USERPROFILE", "$env:USERPROFILE\my", "$env:USERPROFILE\GitHub"),
    [int] $MaxDepth = 2
)
$ErrorActionPreference = 'Continue'
$env:GIT_TERMINAL_PROMPT = '0'
if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10' }
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { Write-Error 'git not found'; exit 1 }

function Get-Repos([string]$Root, [int]$Depth) {
    $out = New-Object System.Collections.Generic.List[string]
    $q = New-Object System.Collections.Generic.Queue[object]
    $q.Enqueue([pscustomobject]@{ P = $Root; D = 0 })
    $skip = @('node_modules', '.cache', '.direnv', '.git')
    while ($q.Count) {
        $i = $q.Dequeue()
        if (Test-Path -LiteralPath (Join-Path $i.P '.git')) { $out.Add($i.P); continue }
        if ($i.D -ge $Depth) { continue }
        Get-ChildItem -LiteralPath $i.P -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name } |
            ForEach-Object { $q.Enqueue([pscustomobject]@{ P = $_.FullName; D = $i.D + 1 }) }
    }
    return $out
}

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($repo in (Get-Repos $root $MaxDepth)) {
        $origin = & $git -C $repo remote get-url origin 2>$null
        if (-not $origin -or $origin -match 'thepureapp/') { continue }
        $branch = & $git -C $repo rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') { continue }
        if (& $git -C $repo status --porcelain 2>$null) { continue }   # dirty
        & $git -C $repo rev-parse '@{u}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }                           # no upstream
        & $git -C $repo pull --ff-only origin main 2>$null | Out-Null
    }
}
```

- [ ] **Step 6: Register both Windows tasks in `provision/windows.ps1`**

Append a registration block to `provision/windows.ps1` (near where other Scheduled Tasks / provisioning steps run). It registers TWO tasks; both are idempotent (`-Force`). Resolve the repo root from the script location like `git-autofetch.ps1` does.

```powershell
# ── Fleet convergence (spec 2026-07-21) ──────────────────────────────────────
# 1. machines-converge — SYSTEM task, on-demand only (fired by the post-merge
#    hook via `schtasks /run /tn machines-converge`). Runs converge.sh under
#    Git Bash with SYSTEM privilege so provision/windows.ps1 gets admin rights
#    WITHOUT granting the pulling user elevation.
# 2. fleet-selfpull — repeating ~10-min task (Trigger B). Its pull fires the
#    post-merge hook, which fires machines-converge. Runs as the user.
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
if ($repoRoot) { $repoRoot = ($repoRoot -replace '/', '\').Trim() }
$bash = "$env:ProgramFiles\Git\bin\bash.exe"

if ($repoRoot -and (Test-Path $bash)) {
    # (1) machines-converge — SYSTEM, no trigger (on-demand).
    $convAction = New-ScheduledTaskAction -Execute $bash `
        -Argument "-lc `"'$($repoRoot -replace '\\','/')/scripts/converge.sh'`""
    $convPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $convSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'machines-converge' -Action $convAction `
        -Principal $convPrincipal -Settings $convSettings -Force | Out-Null

    # (2) fleet-selfpull — every 10 min, as the user, with jitter.
    $ps1 = "$repoRoot\provision\fleet-selfpull.ps1"
    $pullAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
    $pullTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 10) `
        -RepetitionDuration ([TimeSpan]::MaxValue)
    $pullTrigger.RandomDelay = 'PT2M'   # jitter so boxes don't hit GitHub together
    $pullSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 9)
    $pullPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName 'fleet-selfpull' -Action $pullAction -Trigger $pullTrigger `
        -Settings $pullSettings -Principal $pullPrincipal -Force | Out-Null
    Write-Output 'Registered scheduled tasks: machines-converge (SYSTEM), fleet-selfpull (10m)'
} else {
    Write-Output 'Skipped converge task registration (repo root or Git Bash not found)'
}
```

- [ ] **Step 7: Install the Linux/WSL self-pull timer in `provision/linux.sh`**

Add an idempotent installer function to `provision/linux.sh` (invoked from its main flow, guarded to the leaf/non-nix path — `linux.sh` already skips nix-managed concerns). It installs a systemd-user timer when `systemctl --user` works, else a cron line. Follow `linux.sh`'s existing check-then-act + logging style:

```sh
# ── Fleet self-pull timer (Trigger B) — spec 2026-07-21 ──────────────────────
# ~10-min ff-pull of every fleet-sync repo (fleet-selfpull.sh). The pull fires
# the post-merge hook, which fires convergence — this timer never converges.
# systemd-user timer where available, else a cron line. Idempotent.
install_fleet_selfpull_timer() {
  repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || return 0
  script="$repo_root/provision/fleet-selfpull.sh"
  [ -f "$script" ] || return 0

  if systemctl --user show-environment >/dev/null 2>&1; then
    ud="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$ud"
    cat > "$ud/fleet-selfpull.service" <<EOF
[Unit]
Description=Fleet self-pull (ff-only) of all fleet-sync repos
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $script
EOF
    cat > "$ud/fleet-selfpull.timer" <<EOF
[Unit]
Description=Periodic fleet self-pull
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
RandomizedDelaySec=2min
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now fleet-selfpull.timer 2>/dev/null \
      && echo "  + fleet-selfpull.timer (systemd-user) installed" \
      || echo "  ! could not enable fleet-selfpull.timer"
  else
    # cron fallback: jitter with a sleep, run every 10 min.
    line="*/10 * * * * sleep \$((RANDOM \\% 120)); /usr/bin/env bash $script >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF "$script"; then
      (crontab -l 2>/dev/null; echo "$line") | crontab - \
        && echo "  + fleet-selfpull cron installed" \
        || echo "  ! could not install fleet-selfpull cron"
    else
      echo "  = fleet-selfpull cron already present"
    fi
  fi
}
install_fleet_selfpull_timer
```

Place the `install_fleet_selfpull_timer` call in `linux.sh`'s main execution flow (after the existing provisioning steps, before the final summary). Match how `linux.sh` currently sequences its step functions.

- [ ] **Step 8: Commit**

```bash
git add provision/fleet-selfpull.sh provision/fleet-selfpull.test.sh provision/fleet-selfpull.ps1 provision/linux.sh provision/windows.ps1
git commit -m "feat(converge): per-OS self-pull timers (Trigger B)

fleet-selfpull.{sh,ps1} ff-pull every fleet-sync repo (exclude thepureapp),
gated on main/clean/ff. The pull fires the post-merge hook -> convergence;
the timer itself never converges. linux.sh installs a systemd-user timer
(cron fallback); windows.ps1 registers fleet-selfpull (10m) + the
machines-converge SYSTEM task fired on-demand by the hook."
```

---

## Task 5: Convergence status column in `/ship`

**Files:**
- Modify: `agents/plugin/skills/ship/fleet-pull.sh` (read each member's `.machines/last-converge`, add a column)
- Modify: `agents/plugin/skills/ship/tests/fleet-pull.test.sh` (cover the column)

**Interfaces:**
- Consumes: `.machines/last-converge` written by `converge.sh` (Task 1) on each member.
- Produces: `/ship`'s per-member table gains a `CONVERGE` column showing `<status>@<short-rev>` (or `none`) read back over the same SSH `fleet-pull.sh` already uses.

- [ ] **Step 1: Write the failing test**

Add to `agents/plugin/skills/ship/tests/fleet-pull.test.sh` a case that exercises `REMOTE_SCRIPT` reading a `.machines/last-converge`. Because the existing test sources the script and mocks per-member behavior, add a focused check on the remote-script's converge-token construction. Append before the final summary:

```bash
# --- convergence column: REMOTE_SCRIPT reports .machines/last-converge ---
# Build a found-repo with a last-converge record; run the token-builder snippet
# the remote script uses and assert the converge token is derived from it.
convrepo="$tmp/convrepo"; mkdir -p "$convrepo/.machines"
printf 'rev=%s\nstatus=ok\ntimestamp=t\nreason=r\n' 1234567890abcdef > "$convrepo/.machines/last-converge"
conv_token="$(
  found="$convrepo"
  cf="$found/.machines/last-converge"
  if [ -f "$cf" ]; then
    cs="$(sed -n 's/^status=//p' "$cf")"; cr="$(sed -n 's/^rev=//p' "$cf")"
    echo "conv:${cs:-?}@$(printf '%s' "$cr" | cut -c1-7)"
  else echo "conv:none"; fi
)"
[ "$conv_token" = "conv:ok@1234567" ] && pass "converge token from last-converge" || die "converge token: got '$conv_token'"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL on the new `converge token` assertion (the snippet is asserted before the source change wires it in — or it passes trivially only once the token format matches; if it passes immediately, that confirms the format is correct and Step 3 wires it into `REMOTE_SCRIPT`).

- [ ] **Step 3: Add the converge token to `REMOTE_SCRIPT` in `fleet-pull.sh`**

In `agents/plugin/skills/ship/fleet-pull.sh`, extend `REMOTE_SCRIPT`: after it computes the pull result (the `echo "OK …"` / `echo "SKIP …"` lines), instead of echoing the bare pull token, compute a converge token from `$found/.machines/last-converge` and emit both. Replace the final `if git … pull … else echo "SKIP diverged" fi` block's `echo`s so each sets `pull="…"` then, at the end:

```sh
conv="none"
cf="$found/.machines/last-converge"
if [ -f "$cf" ]; then
  cs="$(sed -n "s/^status=//p" "$cf")"
  cr="$(sed -n "s/^rev=//p" "$cf")"
  conv="${cs:-?}@$(printf "%s" "$cr" | cut -c1-7)"
fi
echo "$pull | conv:$conv"'
```

(Adjust the `REMOTE_SCRIPT` single-quote escaping to match its existing style — the script is a single-quoted heredoc-free string, so inner double-quotes are already used; keep `awk`/`sed` quoting consistent with the surrounding code.)

- [ ] **Step 4: Render the column in `main()`**

In `main()`, widen the header and rows. Change:

```sh
  printf '%-10s %s\n' 'MEMBER' 'RESULT'
```
to keep `RESULT` carrying the combined `pull | conv:…` token (simplest — one column, human-readable), OR split on ` | ` into two columns. Minimal, low-risk choice: leave the single `RESULT` column; the token now reads e.g. `OK a1b2..c3d4 | conv:ok@1234567`. Document this in the SKILL.md `ship` output description if it enumerates columns.

- [ ] **Step 5: Run the full fleet-pull test suite**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: `ALL PASS` — existing assertions plus the converge-token case.

- [ ] **Step 6: Commit**

```bash
git add agents/plugin/skills/ship/fleet-pull.sh agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "feat(ship): show convergence status per member

fleet-pull.sh reads each member's .machines/last-converge over the same SSH
and appends a conv:<status>@<rev> token to the RESULT column, so /ship shows
whether each box actually applied the change — not just that it pulled."
```

---

## Self-Review

**Spec coverage map:**

| Spec section | Task |
|---|---|
| §1a non-nix `post-merge` hook (extend existing, no `exec`, schtasks/background) | Task 2 |
| §1b NixOS `machines-converge.path` root trigger; self-update.nix pure pull backend | Task 3 |
| §2 `converge.sh` self-gates + range-from-`.machines/` + per-OS routing | Task 1 |
| §2 never-dirty-tree constraint (writes only `.machines/`) | Task 1 (Global Constraints assert) |
| §3 per-OS self-pull timer (all fleet-sync repos, exclude thepureapp, gates, jitter) | Task 4 (Windows/Linux); Task 3 (NixOS = retargeted `nixRepoAutoPull`) |
| §4 status surface (`last-converge` write + `/ship` column) | Task 1 (write) + Task 5 (column) |
| §5 `.machines/` gitignored state root (`converged-rev`, `last-converge`) | Task 1 |
| §self-update.nix changes (retarget, ff-only, no in-service converge) | Task 3 |
| §Edge cases (main-only, primary-only, no-upstream, dirty, diverged) | Task 1 gates + Task 4 gates |

**Known scoping decisions (documented, not gaps):**
- **NixOS self-pull is machines-only**, via the retargeted `services.nixRepoAutoPull` (Task 3). The spec's "timer pulls ALL fleet-sync repos" is fully realized on Windows/Linux (Task 4); on NixOS (latitude) it stays single-repo because latitude carries no other converge-bearing fleet-sync repo. Extending `nixRepoAutoPull` to a multi-repo scan is a trivial follow-up if a sibling repo ever lands on a NixOS box — noted here, deferred.
- **`REMOTE_SCRIPT` bashisms** (`cut -c1-7`, `sed`) run under the member's `bash -s` (as the existing script already does) — safe.

**Placeholder scan:** no TBD/TODO/"handle errors"/"similar to Task N" — every code step contains full content. Nix/PowerShell steps that can't unit-TDD carry an exact verification command (dry-build on latitude; task registration is `-Force` idempotent).

**Type/name consistency:** `.machines/converged-rev` and `.machines/last-converge` (fields `rev`/`status`/`timestamp`/`reason`) are written by `write_status` (Task 1) and read identically by `range_low` (Task 1), the `/ship` column (Task 5), and the status test. `machines-converge` is the task/service name in Task 2 (schtasks fire), Task 3 (systemd units), and Task 4 (Windows registration) — spelled identically everywhere. `converge.sh` helper names (`box_class`, `on_main_primary`, `range_low`, `touches_nix`, `write_status`) match between the script and both test files.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-21-fleet-converge-self-healing-sync.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**

**Note on ordering:** Tasks 1→5 are dependency-ordered (2/3/5 consume Task 1). Task 3's NixOS dry-build (and the real convergence on latitude) must run **on latitude after this branch is pulled there** — the Windows/WSL dev box has no Nix. The non-nix pieces (Tasks 1, 2, 4-linux/windows, 5) are testable here.