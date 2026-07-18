# OS-agnostic profile provisioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `agents/bootstrap.sh` the single deployer for all agent profiles (nix invokes it), fix single-source host-naming, and retire the dead `~/.dotfiles` husk.

**Architecture:** `claude.nix`'s activation script stops reimplementing the symlink logic and instead calls `bootstrap.sh` once per committed `settings*.json` profile; the personal `~/.claude` call also provisions `~/.codex`, so `codex.nix`'s link logic is deleted. A single host id (`MACHINES_HOST_ID`, passed by nix from the real `networking.hostName`) removes the bootstrap-vs-nix drift. Husk retirement is a guarded, reusable script run per machine.

**Tech Stack:** Bash (bootstrap.sh, tests, retirement script), Nix (home-manager activation, flake wiring). Tests: `bash -n` + shellcheck 0.11.0; nix eval via `nix flake check` / `nix eval`.

## Global Constraints

- **This is the `machines` repo — a NORMAL git repo.** Use plain `git`. The `~/.dotfiles` bare-repo `--git-dir/--work-tree` rules do NOT apply here.
- **Commit on branch `git-worktree-orca-setup` (worktree mode), NEVER on `main`.** Small frequent commits.
- **`bootstrap.sh` must stay OS-agnostic** (Windows Git Bash / macOS / non-Nix Linux) and **idempotent**, and must **preserve its `DRY_RUN` mode** (mutates nothing).
- **One-hop-direct symlinks only:** every profile link points `dest -> repo working tree`, NEVER through `/nix/store` (Claude's settings writer hits EROFS on a store path). Preserve this invariant.
- **Canonical host id = the OS hostname** (`networking.hostName`, e.g. `latitude5520`). Nix passes it to bootstrap via `MACHINES_HOST_ID`; bootstrap falls back to its existing `host_id()` (`COMPUTERNAME`→`hostname`, sanitized) only when the env var is absent (off-nix).
- **Husk deletion: just delete — no `git bundle` archive** (history is disposable, per design).
- **Full activation (`just switch`) is a manual on-box step, not a worktree gate.** In-worktree tests use `bash -n`/shellcheck for bash and `nix eval`/`nix flake check` for nix; DRY_RUN convergence and live `~/.codex` contents are verified by the user after a real switch.
- Only `latitude` is a nix host in this flake. `g16`/`homeserver` host files are reconciled on their own boxes via the checklist — do NOT delete unverifiable host files from this checkout.

---

### Task 1: bootstrap.sh — single-source host id + exclude `tests/` from hook linking

**Files:**
- Modify: `agents/bootstrap.sh` (two edits: `HOST_ID` source ~line 207; `link_entries_into` skip list ~line 168)
- Create: `agents/tests/bootstrap.test.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `bootstrap.sh` honors `MACHINES_HOST_ID` (Task 3 passes it from nix). `link_entries_into` never links a `tests` entry.

- [ ] **Step 1: Write the failing test**

Create `agents/tests/bootstrap.test.sh`:

```bash
#!/usr/bin/env bash
# Behavioral tests for agents/bootstrap.sh, driven by DRY_RUN (mutates nothing).
# DRY_RUN reads the live dirs but writes NOTHING (no mkdir/ln/mv/rm).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"        # agents/
boot="$repo/bootstrap.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Case 1: MACHINES_HOST_ID overrides the OS hostname for the host-memory file.
# A non-personal (fake) profile dir is fine — host linking runs unconditionally.
out1="$(MACHINES_HOST_ID=testhost DRY_RUN=1 CLAUDE_CONFIG_DIR=/tmp/does-not-exist-claude bash "$boot" 2>&1)"
check "MACHINES_HOST_ID picks hosts/testhost.md" \
  'printf "%s" "$out1" | grep -q "hosts/testhost.md"'
check "MACHINES_HOST_ID does not fall back to OS hostname" \
  '! printf "%s" "$out1" | grep -qE "hosts/$(hostname | tr -c "A-Za-z0-9_-" "_")\.md"'

# Case 2: the plugin hooks tests/ dir is never linked. The Codex block that links
# plugin/hooks entry-by-entry runs ONLY on the personal profile (IS_PERSONAL=1),
# so drive $HOME/.claude with a THROWAWAY Codex dir (DRY_RUN writes nothing to it).
out2="$(DRY_RUN=1 CLAUDE_CONFIG_DIR="$HOME/.claude" CODEX_CONFIG_DIR="$(mktemp -d)" bash "$boot" 2>&1)"
check "tests dir excluded from hook linking" \
  '! printf "%s" "$out2" | grep -q "hooks/tests"'

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/tests/bootstrap.test.sh`
Expected: FAIL — Case 1 fails (bootstrap still uses `host_id()`, so `hosts/testhost.md` absent and the OS-hostname file appears); Case 2 fails (the Codex block still emits a `hooks/tests` link line). Note: Case 2 requires `$HOME/.claude` to exist on the test machine; it is read-only under DRY_RUN.

- [ ] **Step 3: Implement — honor `MACHINES_HOST_ID`**

In `agents/bootstrap.sh`, change the `HOST_ID` assignment (currently `HOST_ID="$(host_id)"`):

```bash
# Host id: nix passes the authoritative hostname via MACHINES_HOST_ID (so nix and
# bootstrap name the per-host memory file identically). Off-nix, fall back to the
# sanitized OS hostname. Single source of host-naming — see host_id().
HOST_ID="${MACHINES_HOST_ID:-$(host_id)}"
```

- [ ] **Step 4: Implement — exclude `tests` from `link_entries_into`**

In `link_entries_into`, add a skip beside the existing `.gitkeep` / `hooks.json` skips:

```bash
    [ "$base" = ".gitkeep" ] && continue   # placeholder, not real config
    [ "$base" = "hooks.json" ] && continue # cyphy plugin manifest, not a Codex hook
    [ "$base" = "tests" ] && continue      # hook test scripts, not runtime hooks
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash agents/tests/bootstrap.test.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Lint**

Run: `shellcheck agents/bootstrap.sh agents/tests/bootstrap.test.sh && bash -n agents/bootstrap.sh`
Expected: no errors (warnings acceptable if pre-existing; do not introduce new ones).

- [ ] **Step 7: Commit**

```bash
git add agents/bootstrap.sh agents/tests/bootstrap.test.sh
git commit -m "feat(bootstrap): single-source host id via MACHINES_HOST_ID; exclude tests/ from hook links"
```

---

### Task 2: Rename the active nix host's memory file to its canonical name

**Files:**
- Rename: `agents/hosts/latitude.md` → `agents/hosts/latitude5520.md` (`git mv`)

**Interfaces:**
- Consumes: Task 1's `MACHINES_HOST_ID` behavior.
- Produces: `agents/hosts/latitude5520.md` exists (the file `latitude5520` resolves to). Task 3's nix wiring links `host-memory.md` to it.

**Context:** `agents/hosts/latitude.md` is already internally titled `# Host: latitude5520` — it was mis-filed under the flake *dir* name (`latitude`) instead of the OS hostname (`latitude5520`). The other host files (`g614jv.md`, `ME-G614JV.md`, `methe-server.md`) belong to boxes NOT in this flake; leave them — they are reconciled on-box in Task 5's checklist.

- [ ] **Step 1: Write the failing test**

Run (this is the check; no test file needed — it asserts convergence for the canonical name):

```bash
MACHINES_HOST_ID=latitude5520 DRY_RUN=1 bash agents/bootstrap.sh 2>&1 | grep -E 'latitude5520\.md|would seed'
```
Expected BEFORE the rename: prints `~ would seed host memory stub: .../hosts/latitude5520.md` (the canonical file is missing, so bootstrap would create a stub) — i.e. NOT converged.

- [ ] **Step 2: Rename the file**

Run: `git mv agents/hosts/latitude.md agents/hosts/latitude5520.md`

- [ ] **Step 3: Verify convergence**

Run:

```bash
MACHINES_HOST_ID=latitude5520 DRY_RUN=1 bash agents/bootstrap.sh 2>&1 | grep -E 'seed|latitude'
```
Expected AFTER the rename: NO `would seed` line for `latitude5520.md` (the file now exists). The host-memory link resolves to `hosts/latitude5520.md`.

- [ ] **Step 4: Commit**

```bash
git add -A agents/hosts/
git commit -m "chore(hosts): rename latitude.md -> latitude5520.md (canonical OS hostname)"
```

---

### Task 3: claude.nix invokes bootstrap; flake passes the real hostname

**Files:**
- Modify: `flake.nix` (decouple host *dir* from the `hostname` specialArg in `mkHost`/`mkHome`, ~lines 89–116)
- Modify: `modules/home/claude.nix` (replace the `linkClaudeProfiles` body; add `pkgs` to module args)

**Interfaces:**
- Consumes: Task 1 (`MACHINES_HOST_ID`), Task 2 (`hosts/latitude5520.md`).
- Produces: on `just switch`, each profile is provisioned by `bootstrap.sh`; no second link implementation runs. `${hostname}` in the home modules resolves to `latitude5520`.

- [ ] **Step 1: Decouple dir from hostname in `flake.nix`**

Replace the `mkHost` / `mkHome` definitions and their `latitude` call sites:

```nix
    mkHost = dir: hostName: extraModules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = specialArgs // {hostname = hostName;};
        modules =
          [
            ./hosts/${dir}/nixos/configuration.nix
            ./hosts/${dir}/nixos/hardware-configuration.nix
            home-manager.nixosModules.default
            (_: {nixpkgs = nixpkgsConfig;})
          ]
          ++ extraModules;
      };

    mkHome = dir: hostName:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs nixpkgsConfig;
        extraSpecialArgs = specialArgs // {hostname = hostName;};
        modules = [./modules/home/me.nix];
      };
  in {
    nixosConfigurations = {
      latitude = mkHost "latitude" "latitude5520" [
        nixos-hardware.nixosModules.dell-latitude-5520
      ];
    };

    homeConfigurations = {
      "me@latitude" = mkHome "latitude" "latitude5520";
    };
```

- [ ] **Step 2: Verify the flake still evaluates**

Run: `nix eval --raw .#nixosConfigurations.latitude.config.networking.hostName`
Expected: prints `latitude5520` (proves the config still resolves and hostName is unchanged).

- [ ] **Step 3: Replace `claude.nix`'s activation body with a bootstrap call**

In `modules/home/claude.nix`: add `pkgs` to the module args (`{ config, hostname, lib, pkgs, ... }:`) and replace the entire `home.activation.linkClaudeProfiles` value with:

```nix
  home.activation.linkClaudeProfiles = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Single deployer: bootstrap.sh is THE implementation of the profile links
    # (shared with Windows/macOS). Call it once per committed settings*.json
    # profile; the personal ~/.claude call also provisions ~/.codex. MACHINES_HOST_ID
    # gives bootstrap the authoritative host id so nix and bash name the per-host
    # memory file identically (no drift). Runs after writeBoundary so home-manager
    # has already GC'd any prior store-routed links before bootstrap recreates them.
    for setsrc in "${agents}"/settings.json "${agents}"/settings.*.json; do
      [ -e "$setsrc" ] || continue
      base="$(basename "$setsrc" .json)"
      if [ "$base" = settings ]; then
        prof="$HOME/.claude"
      else
        prof="$HOME/.claude-''${base#settings.}"
      fi
      PATH="${lib.makeBinPath [pkgs.coreutils pkgs.findutils]}:$PATH" \
      CLAUDE_CONFIG_DIR="$prof" MACHINES_HOST_ID="${hostname}" \
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash "${agents}/bootstrap.sh"
    done
  '';
```

(The `pkgs.bash` and prepended `coreutils`/`findutils` guarantee the activation PATH has bootstrap's needs; `git` is unused on NixOS because `install_git_hooks` returns early on `/etc/NIXOS`.)

- [ ] **Step 4: Verify the whole config evaluates (exercises claude.nix)**

Run: `nix eval .#nixosConfigurations.latitude.config.system.build.toplevel.drvPath`
Expected: prints a `/nix/store/*.drv` path with no evaluation error (this forces evaluation of `claude.nix`, including the new activation script and `pkgs` arg).

- [ ] **Step 5: Commit**

```bash
git add flake.nix modules/home/claude.nix
git commit -m "feat(nix): claude.nix invokes bootstrap.sh per profile; flake passes real hostname"
```

---

### Task 4: Delete codex.nix — Codex is provisioned by bootstrap's personal run

**Files:**
- Delete: `modules/home/codex.nix`
- Modify: `modules/home/me.nix` (remove the `./codex.nix` import, ~line 24)

**Interfaces:**
- Consumes: Task 3 (the `~/.claude` bootstrap call runs bootstrap's Codex block, since `IS_PERSONAL=1` for `CLAUDE_CONFIG_DIR=$HOME/.claude`).
- Produces: `~/.codex` is provisioned by bootstrap, not by a separate nix module. No behavior change to `~/.codex` contents except `hooks/tests/` is now excluded (Task 1).

- [ ] **Step 1: Confirm bootstrap owns Codex on the personal profile**

Run: `grep -n 'IS_PERSONAL' agents/bootstrap.sh`
Expected: the Codex block is guarded by `if [ "$IS_PERSONAL" -eq 1 ]` and links AGENTS.md, memory, personality, host-memory, hooks.json, skills, hooks, subagents into `~/.codex` — confirming Task 3's `~/.claude` call already provisions Codex.

- [ ] **Step 2: Remove the import**

In `modules/home/me.nix`, delete the `./codex.nix` line from the `imports` list. (Keep the `codex` package entry — that installs the CLI and is unrelated to config linking.)

- [ ] **Step 3: Delete the module**

Run: `git rm modules/home/codex.nix`

- [ ] **Step 4: Verify the config still evaluates without codex.nix**

Run: `nix eval .#nixosConfigurations.latitude.config.system.build.toplevel.drvPath`
Expected: a `.drv` path, no error (proves `me.nix` still evaluates with the import removed).

- [ ] **Step 5: Commit**

```bash
git add modules/home/me.nix
git commit -m "refactor(nix): delete codex.nix; bootstrap's personal run provisions ~/.codex"
```

---

### Task 5: Husk-retirement — guarded script + per-machine checklist

**Files:**
- Create: `scripts/retire-dotfiles-husk.sh`
- Create: `agents/tests/retire-dotfiles-husk.test.sh`
- Modify: `docs/superpowers/specs/2026-07-18-profile-provisioning-unification-design.md` (tick latitude5520 in the checklist once executed) — or add a short tracking table to `README.md` if preferred; the spec already holds the checklist.

**Interfaces:**
- Consumes: nothing (independent of the nix/bootstrap changes).
- Produces: a reusable, guarded retirement script runnable on any box.

**Context:** The bare `~/.dotfiles` repo is dead (0 tracked files). The script MUST refuse to delete a husk that still tracks files (safety guard), support `DRY_RUN`, and be idempotent (no-op if already retired).

- [ ] **Step 1: Write the failing test**

Create `agents/tests/retire-dotfiles-husk.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/retire-dotfiles-husk.sh against a throwaway fake $HOME.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "$here/../.." && pwd)/scripts/retire-dotfiles-husk.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Fixture: a fake HOME with an EMPTY bare husk + stray ~/CLAUDE.md.
mk_home() {
  local h; h="$(mktemp -d)"
  git init --bare -q "$h/.dotfiles"
  printf 'stale bare-repo doc\n' > "$h/CLAUDE.md"
  printf '%s' "$h"
}

# Case 1: empty husk -> retired (DRY_RUN reports the intended actions).
h="$(mk_home)"
out="$(HOME="$h" DRY_RUN=1 bash "$script" 2>&1)"
check "dry-run reports removing ~/.dotfiles" 'printf "%s" "$out" | grep -q "\.dotfiles"'
check "dry-run reports removing ~/CLAUDE.md"  'printf "%s" "$out" | grep -q "CLAUDE.md"'
rm -rf "$h"

# Case 2: empty husk -> real run removes both, idempotent on re-run.
h="$(mk_home)"
HOME="$h" bash "$script" >/dev/null 2>&1
check "husk removed"        '[ ! -e "$h/.dotfiles" ]'
check "stray CLAUDE.md gone" '[ ! -e "$h/CLAUDE.md" ]'
HOME="$h" bash "$script" >/dev/null 2>&1
check "idempotent re-run exits 0" '[ "$?" -eq 0 ]'
rm -rf "$h"

# Case 3: NON-empty husk -> refuses, leaves everything intact.
h="$(mktemp -d)"
git init --bare -q "$h/.dotfiles"
# Give the bare repo a tracked file via a temp work-tree commit.
wt="$(mktemp -d)"; git --git-dir="$h/.dotfiles" --work-tree="$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
printf 'x\n' > "$wt/tracked.txt"
git --git-dir="$h/.dotfiles" --work-tree="$wt" add tracked.txt >/dev/null 2>&1
git --git-dir="$h/.dotfiles" --work-tree="$wt" -c user.email=t@t -c user.name=t commit -q -m add >/dev/null 2>&1
out="$(HOME="$h" bash "$script" 2>&1)"; rc=$?
check "non-empty husk: refuses (nonzero exit)" '[ "'$rc'" -ne 0 ]'
check "non-empty husk: ~/.dotfiles preserved"  '[ -e "$h/.dotfiles" ]'
rm -rf "$h" "$wt"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/tests/retire-dotfiles-husk.test.sh`
Expected: FAIL — the script does not exist yet.

- [ ] **Step 3: Implement the guarded retirement script**

Create `scripts/retire-dotfiles-husk.sh`:

```bash
#!/usr/bin/env bash
# Retire the dead ~/.dotfiles bare-repo husk on THIS machine (per-machine home-state;
# does not propagate by git). Safety: refuses if the husk still tracks files.
# Idempotent. Honors DRY_RUN=1 (reports, mutates nothing). Just deletes — no archive.
set -u
DF="$HOME/.dotfiles"
run() { if [ -n "${DRY_RUN:-}" ]; then echo "  ~ would: $*"; else echo "  + $*"; "$@"; fi; }

# 1. Guard: only retire an EMPTY husk (0 tracked files). Absent husk => already done.
if [ -d "$DF" ]; then
  n="$(git --git-dir="$DF" --work-tree="$HOME" ls-files 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ne 0 ]; then
    echo "REFUSING: $DF still tracks $n file(s). Not a dead husk — resolve manually." >&2
    exit 1
  fi
  run rm -rf "$DF"
else
  echo "  = ~/.dotfiles already absent"
fi

# 2. Remove the stale bare-repo ~/CLAUDE.md (the live deployer writes
#    ~/.claude/CLAUDE.md — a different path — so this does not come back).
if [ -e "$HOME/CLAUDE.md" ]; then
  run rm -f "$HOME/CLAUDE.md"
else
  echo "  = ~/CLAUDE.md already absent"
fi

# 3. Drop the `dotfiles` fish alias if present (backup the file first).
fishcfg="$HOME/.config/fish/config.fish"
if [ -f "$fishcfg" ] && grep -q "alias dotfiles" "$fishcfg" 2>/dev/null; then
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  ~ would: remove 'alias dotfiles' line from $fishcfg"
  else
    cp "$fishcfg" "$fishcfg.pre-husk-retire.bak"
    grep -v "alias dotfiles" "$fishcfg" > "$fishcfg.tmp" && mv "$fishcfg.tmp" "$fishcfg"
    echo "  + removed 'alias dotfiles' from $fishcfg (backup: $fishcfg.pre-husk-retire.bak)"
  fi
else
  echo "  = no 'alias dotfiles' in fish config"
fi

echo "Done. Verify: a new agent session no longer loads ~/CLAUDE.md; ~/.claude links intact."
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/tests/retire-dotfiles-husk.test.sh`
Expected: `ALL PASS`

- [ ] **Step 5: Lint + make executable**

Run: `chmod +x scripts/retire-dotfiles-husk.sh && shellcheck scripts/retire-dotfiles-husk.sh agents/tests/retire-dotfiles-husk.test.sh && bash -n scripts/retire-dotfiles-husk.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/retire-dotfiles-husk.sh agents/tests/retire-dotfiles-husk.test.sh
git commit -m "feat(scripts): guarded, idempotent ~/.dotfiles husk-retirement script"
```

- [ ] **Step 7: Per-machine execution (checklist — NOT part of the review gate)**

Executing on a live box mutates home-state and is done by the controller/user, not the implementer subagent. Per machine, in order:

- **latitude5520** (the box at hand): `DRY_RUN=1 bash scripts/retire-dotfiles-husk.sh` (review), then `bash scripts/retire-dotfiles-husk.sh`. Confirm `~/.dotfiles` and `~/CLAUDE.md` absent; a fresh session no longer loads the bare-repo doc.
- **g16** (NixOS side `g16`, Windows side `ME-G614JV`): run on each OS when next in front of it. On g16, also confirm the canonical host memory file (`agents/hosts/g16.md`) exists and reconcile the stale `g614jv.md` orphan against on-box `hostname`.
- **homeserver** (`methe-server`, Windows): run the Git-Bash equivalent when next in front of it.

Tick each box here as it's completed.

---

## Notes for the executor

- After Task 4, run the full bash test suite as a sanity sweep: `for t in agents/tests/*.test.sh agents/plugin/hooks/tests/*.test.sh; do echo "== $t"; bash "$t"; done` — all must pass.
- The definitive Half-A acceptance (`DRY_RUN=1 bash agents/bootstrap.sh` → `would-link=0`) requires a real `just switch` on a nix host; surface it to the user as the post-merge verification, not an in-worktree gate.
