# Hub Fleet Enrollment + Tiered `provision/linux.sh` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `provision/linux.sh` into named tier functions selected by a per-machine `profile` field in `fleet.json`, add a lean `hub` profile, and enroll the `hub` VPS into fleet convergence so it ff-pulls `machines` and applies the pulled state on its own.

**Architecture:** Tier bodies move verbatim from `provision/linux.sh` into a new sourced library `provision/lib/tiers.sh`; `linux.sh` becomes a driver that resolves a profile (`MACHINES_PROFILE` env > `fleet.json` by OS hostname > `workstation`) and runs that profile's ordered tier list. `scripts/converge.sh`'s `touches_linux()` learns the new library paths in the same change, or a tiers-only pull would be silently skipped forever. Enrollment on `hub` is then a clone plus one interactive run.

**Tech Stack:** POSIX-ish bash, `jq` with a `python3` fallback, systemd-user timers, git hooks, `fleet.json` manifest.

## Global Constraints

- **Design spec:** `docs/superpowers/specs/2026-07-25-hub-fleet-enrollment-tiers-design.md`. Read it before Task 3.
- **Tier bodies move verbatim.** Task 3 is a pure refactor: no behavior change on a `workstation` box. Rewording, reordering inside a body, or "improving" a body is out of scope.
- **`ssh_accounts` MUST NOT run under profile `hub`.** It would write `Host github.com → IdentityFile ~/.ssh/id_metheoryt, IdentitiesOnly yes` into hub's empty `~/.ssh/config` and kill its only GitHub auth (`~/.ssh/id_rsa`) — killing the ff-pull this plan enables, on a remote box.
- **Never write a tracked file from a converge path.** A dirty tree fails `selfpull_one`'s clean gate and disables all future auto-pulls.
- **`hub` has no `jq`** (it does have `python3`). Profile resolution must not hard-require `jq`.
- **`hub` OS hostname is `27608`**; logical fleet name is `hub`; profile value is the string `hub`.
- **`hub`'s `FLEET_ROOTS` is `%h/machines`** (systemd `Environment=`) / `$HOME/machines` (cron fallback). `~/vps` must not auto-pull.
- Tests are standalone `bash <file>.test.sh` scripts (no runner, no `just` recipe). Style: `pass`/`die`/`eq` helpers, `mktemp -d` + `trap`, `*_LIB_ONLY=1` sourcing. No `shellcheck` on this machine — use `bash -n` for syntax.
- Commit messages: conventional prefix, and end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

- **Create** `provision/lib/tiers.sh` — every provisioning tier as a `tier_<name>` function. Sourced by `provision/linux.sh`; loads inert under `TIERS_LIB_ONLY=1`. Responsibility: *what* each tier does.
- **Rewrite** `provision/linux.sh` — driver only: preamble (helpers, `REPO`, preconditions, `SUDO`/`PRIV`, `PATH`), profile resolution, profile→tier-list table, dispatch loop, summary. Responsibility: *which* tiers run.
- **Modify** `provision/lib/fleet.sh` — add `fleet_profile` (jq, dispatcher use) and `fleet_profile_for_host` (jq-or-python3, driver use).
- **Modify** `fleet.json` — `"profile": "hub"` on the `hub` entry.
- **Modify** `scripts/converge.sh` — `touches_linux()` gains `provision/lib/tiers.sh` + `provision/lib/fleet.sh`.
- **Create** `agents/hosts/27608.md` — committed per-host memory stub so `bootstrap.sh` does not seed it untracked on hub.
- **Create** `provision/tests/tiers.test.sh` — profile resolution + tier-list assertions.
- **Create** `provision/tests/fleet-profile.test.sh` — `fleet.sh` helper assertions incl. the no-`jq` path.
- **Modify** `scripts/converge.test.sh` — case for the new `touches_linux` paths.

---

### Task 1: `converge.sh` learns the new provisioning paths

Do this **first**: it is independent, and it is the guard that stops the Task 3 refactor from silently disabling convergence fleet-wide.

**Files:**
- Modify: `scripts/converge.sh:66-70` (the `touches_linux` regex)
- Test: `scripts/converge.test.sh` (append before the final `[ "$fail" -eq 0 ]` line)

**Interfaces:**
- Consumes: nothing.
- Produces: `touches_linux <low> <high>` returns 0 when the range touches `provision/lib/tiers.sh` or `provision/lib/fleet.sh`.

- [ ] **Step 1: Write the failing test**

Insert into `scripts/converge.test.sh` immediately after the existing `touches_linux first-run is hit` assertion:

```bash
# touches_linux: the tier library and the manifest helpers are on the provisioning
# path too (provision/linux.sh only drives them) — a tiers-only pull MUST reprovision,
# or converge writes ok + advances converged-rev and never applies it.
mkdir -p "$repo/provision/lib"
echo x > "$repo/provision/lib/tiers.sh"; git -C "$repo" add .; git -C "$repo" commit -qm c5
rev5="$(git -C "$repo" rev-parse HEAD)"
touches_linux "$rev4" "$rev5" && pass "touches_linux detects provision/lib/tiers.sh" || die "touches_linux detects provision/lib/tiers.sh"
echo y > "$repo/provision/lib/fleet.sh"; git -C "$repo" add .; git -C "$repo" commit -qm c6
rev6="$(git -C "$repo" rev-parse HEAD)"
touches_linux "$rev5" "$rev6" && pass "touches_linux detects provision/lib/fleet.sh" || die "touches_linux detects provision/lib/fleet.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/converge.test.sh`
Expected: `FAIL touches_linux detects provision/lib/tiers.sh` and `FAIL touches_linux detects provision/lib/fleet.sh`, trailing `FAILURES`, exit 1.

- [ ] **Step 3: Write minimal implementation**

In `scripts/converge.sh`, replace the `touches_linux` body's regex (currently `'(^provision/linux\.sh$|^provision/fleet-selfpull\.sh$|^pkgs/gortex\.nix$|^agents/bootstrap\.sh$)'`) with:

```sh
touches_linux() {
  changed_paths "$1" "$2" | grep -qE '(^provision/linux\.sh$|^provision/lib/tiers\.sh$|^provision/lib/fleet\.sh$|^provision/fleet-selfpull\.sh$|^pkgs/gortex\.nix$|^agents/bootstrap\.sh$)'
}
```

Also extend that function's comment to say the tier library and manifest helpers count, since `linux.sh` only drives them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/converge.test.sh`
Expected: `ALL PASS`, exit 0. (Every pre-existing case must still pass — the `touches_linux ignores content-only change` case in particular.)

- [ ] **Step 5: Commit**

```bash
git add scripts/converge.sh scripts/converge.test.sh
git commit -m "fix(converge): count provision/lib/{tiers,fleet}.sh as provisioning-relevant

The tier library is about to hold what provision/linux.sh does today. Without
this, a tiers-only pull matches nothing, converge writes ok + advances
converged-rev, and the change is never applied — on hub and every WSL box.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `fleet.json` profile field + `fleet.sh` resolvers

**Files:**
- Modify: `fleet.json` (the `hub` entry)
- Modify: `provision/lib/fleet.sh` (append two functions after `fleet_roles`)
- Test: `provision/tests/fleet-profile.test.sh` (create)

**Interfaces:**
- Consumes: `fleet_manifest_path` (existing, in `provision/lib/fleet.sh`).
- Produces:
  - `fleet_profile <machine>` → profile string, `workstation` when the field is absent. Requires `jq`. For `provision.sh`-side use.
  - `fleet_profile_for_host [hostname]` → profile string for the machine whose `detect.hostname` matches (defaults to `$(hostname)`); **empty output** when no machine matches. Works with `jq` **or** `python3`; empty when neither.

- [ ] **Step 1: Write the failing test**

Create `provision/tests/fleet-profile.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for provision/lib/fleet.sh profile resolvers. Asserts against the
# REAL repo fleet.json (it is the source of truth this ships with).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/fleet.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }

# shellcheck source=/dev/null
source "$LIB"

# fleet_profile: explicit field on hub, default elsewhere.
eq "$(fleet_profile hub)" "hub" "fleet_profile hub == hub"
eq "$(fleet_profile latitude)" "workstation" "fleet_profile latitude defaults to workstation"

# fleet_profile_for_host: OS hostname -> profile.
eq "$(fleet_profile_for_host 27608)" "hub" "for_host 27608 == hub"
eq "$(fleet_profile_for_host latitude5520)" "workstation" "for_host latitude5520 == workstation"
eq "$(fleet_profile_for_host no-such-box)" "" "for_host unknown host is empty"

# jq-free path: hub has no jq, so resolution must fall back to python3. Build a
# PATH holding only python3 + dirname (fleet_manifest_path needs dirname).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for b in python3 dirname; do ln -s "$(command -v "$b")" "$tmp/bin/$b"; done
nojq="$(PATH="$tmp/bin" bash -c 'source "$1"; fleet_profile_for_host 27608' _ "$LIB")"
eq "$nojq" "hub" "for_host resolves without jq (python3 fallback)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/fleet-profile.test.sh`
Expected: failures — `fleet_profile: command not found` / empty results, trailing `FAILURES`.

- [ ] **Step 3: Write minimal implementation**

Add `"profile": "hub"` to the `hub` entry in `fleet.json` (after `"ssh"`, before `"roles"`; keep the file's existing 2-space style):

```json
    "hub": {
      "platform": "debian",
      "tailnet": { "ip": "100.64.0.1" },
      "ssh": { "user": "debian", "host": "cyphy.kz" },
      "profile": "hub",
      "roles": ["base", "ssh-server", "agents", "dotfiles", "backup-client"],
      "detect": { "hostname": "27608" }
    }
```

Append to `provision/lib/fleet.sh`:

```bash
# fleet_profile <machine>: which provisioning tier list this machine gets
# (provision/linux.sh). Absent field => "workstation" (the full dev layer).
# Requires jq, like the helpers above.
fleet_profile() {
    jq -r --arg m "$1" '.machines[$m].profile // "workstation"' "$(fleet_manifest_path)"
}

# fleet_profile_for_host [hostname]: resolve THIS box's profile straight from
# detect.hostname; empty when no machine matches (e.g. a self-declared WSL host,
# which carries fleet.local.json and no fleet.json entry — the caller defaults it).
# Unlike every other helper here this must work WITHOUT jq: hub ships python3 but
# no jq, and profile resolution happens before the apt tier can install it.
fleet_profile_for_host() {
    local h="${1:-$(hostname)}" mf
    mf="$(fleet_manifest_path)"
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg h "$h" \
            '.machines | to_entries[] | select(.value.detect.hostname == $h) | .value.profile // "workstation"' \
            "$mf"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$mf" "$h" <<'PY'
import json, sys
manifest, host = sys.argv[1], sys.argv[2]
with open(manifest) as fh:
    machines = json.load(fh)["machines"]
for name, m in machines.items():
    if m.get("detect", {}).get("hostname") == host:
        print(m.get("profile", "workstation"))
        break
PY
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash provision/tests/fleet-profile.test.sh`
Expected: `ALL PASS`.

Also run: `bash provision/tests/fleet-local.test.sh` and `bash -n provision/lib/fleet.sh`
Expected: unchanged pass / no syntax output.

- [ ] **Step 5: Commit**

```bash
chmod +x provision/tests/fleet-profile.test.sh
git add fleet.json provision/lib/fleet.sh provision/tests/fleet-profile.test.sh
git commit -m "feat(fleet): per-machine provisioning profile in fleet.json

hub gets profile \"hub\" (a lean tier list); absent field means workstation, so
every WSL box and latitude keep today's behavior. fleet_profile_for_host falls
back to python3 because hub has no jq and resolution runs before the apt tier.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

**Note for the reviewer:** `modules/system/fleet.nix:11` reads `fleet.json` via `fromJSON`, so this is a Nix input change. The dry-build gate runs on `latitude` in Task 6 — no NixOS box is required to land this task.

---

### Task 3: Extract tiers into `provision/lib/tiers.sh` (pure refactor)

Behavior on a `workstation` box must be identical after this task. Every tier body is a **verbatim move** of the lines named below from the current `provision/linux.sh`.

**Files:**
- Create: `provision/lib/tiers.sh`
- Modify: `provision/linux.sh` (becomes a driver)
- Test: `provision/tests/tiers.test.sh` (create)

**Interfaces:**
- Consumes: `fleet_profile_for_host` (Task 2).
- Produces, all defined in `provision/lib/tiers.sh` and called by `provision/linux.sh`:
  - `tier_apt_min`, `tier_apt_dev`, `tier_agents_config`, `tier_git_base`, `tier_gortex`, `tier_autofetch`, `tier_ssh_accounts`, `tier_ssh_trust` — no args
  - `tier_agent_clis <cli>...` — e.g. `tier_agent_clis claude codex`
  - `tier_shell_init [--no-fish]`
  - `tier_selfpull [fleet_roots]` — non-empty arg pins `FLEET_ROOTS` in the generated unit/cron
  - Driver globals the tiers rely on (set in `linux.sh` before sourcing): `REPO`, `SUDO`, `PRIV`, `WARNINGS`, and the `info`/`ok`/`warn`/`die`/`have` helpers
  - `TIERS_LIB_ONLY=1` sourcing loads functions without side effects
  - `MACHINES_TIERS_DRY_RUN=1 bash provision/linux.sh` prints `profile: <name> (<source>)` then one tier invocation per line (name + args) and exits 0 without running anything

**Verbatim move map** (line numbers refer to `provision/linux.sh` as of commit `03b0060`):

| destination | source lines | notes |
|---|---|---|
| driver preamble (stays in `linux.sh`) | 26–70 | add `export PATH="$HOME/.local/bin:$PATH"` right after `mkdir -p "$HOME/.local/bin"` (line 68) |
| `tier_apt_min` | 72–92 | keep the `PRIV -eq 0` warn/skip branch; package list narrows to `git curl wget ca-certificates xz-utils unzip python3 jq` |
| `tier_apt_dev` | 85–90 (residue), 94–95, 156–217 | packages `build-essential pkg-config python3-venv python3-pip ripgrep fd-find fzf`; then the `fdfind`→`fd` symlink, the `fish direnv git-delta bat` loop, `bat`→`batcat` symlink, starship, uv, delta git wiring, gh + credential helper. **Two additions, not moves** — see below |
| `tier_agents_config` | 97–104 | CORE — keeps `die` |
| `tier_git_base` | 106–121 | |
| `tier_gortex` | 123–136 | |
| `tier_agent_clis` | 138–154 | wrap each installer in `case "$c" in claude) …;; codex) …;; esac` inside `for c in "$@"` |
| `tier_autofetch` | 219–304 | |
| `tier_ssh_accounts` | 306–394 | both `SSH_ACCOUNTS` and `GIT_IDENTITIES` blocks |
| `tier_shell_init` | 396–433 | `--no-fish` skips the fish block (415–433) |
| `tier_selfpull` | 435–485 | see Step 3 for the `FLEET_ROOTS` addition |
| `tier_ssh_trust` | 487–515 | |
| driver summary (stays in `linux.sh`) | 517–532 | |

- [ ] **Step 1: Write the failing test**

Create `provision/tests/tiers.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for the provision/linux.sh tier driver + provision/lib/tiers.sh.
# No root, no network: exercises profile resolution and the dry-run tier list.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../linux.sh"
TIERS="$HERE/../lib/tiers.sh"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2' got '$1'"; }
has()  { printf '%s\n' "$1" | grep -qE "$2" && pass "$3" || die "$3"; }
hasnt(){ printf '%s\n' "$1" | grep -qE "$2" && die "$3" || pass "$3"; }

plan() { MACHINES_TIERS_DRY_RUN=1 MACHINES_PROFILE="$1" bash "$DRIVER" 2>&1; }

ws="$(plan workstation)"
hub="$(plan hub)"

# Profile banner names the resolution source.
has "$ws" 'profile: workstation \(from MACHINES_PROFILE\)' "banner reports env-var source"

# Both profiles start with apt_min and include the CORE agent-config tier.
has "$ws"  '^tier_apt_min$'       "workstation runs tier_apt_min"
has "$hub" '^tier_apt_min$'       "hub runs tier_apt_min"
has "$ws"  '^tier_agents_config$' "workstation runs tier_agents_config"
has "$hub" '^tier_agents_config$' "hub runs tier_agents_config"
eq "$(printf '%s\n' "$hub" | grep -c '^tier_apt_min$')" "1" "hub runs tier_apt_min exactly once"

# workstation keeps today's full set, in today's order.
eq "$(printf '%s\n' "$ws" | grep '^tier_' | tr '\n' ' ')" \
   "tier_apt_min tier_apt_dev tier_agents_config tier_git_base tier_gortex tier_agent_clis claude codex tier_shell_init tier_autofetch tier_ssh_accounts tier_selfpull tier_ssh_trust " \
   "workstation tier list and order"

# hub is lean: no dev apt layer, no gortex, no codex.
hasnt "$hub" '^tier_apt_dev$' "hub omits tier_apt_dev"
hasnt "$hub" '^tier_gortex$'  "hub omits tier_gortex"
hasnt "$hub" 'codex'          "hub omits the codex CLI"

# HAZARD GUARD: ssh_accounts would overwrite hub's ~/.ssh/config with
# IdentitiesOnly on an unregistered key and kill its only GitHub auth.
hasnt "$hub" '^tier_ssh_accounts$' "hub NEVER runs tier_ssh_accounts"

# hub pins fleet-selfpull to ~/machines so ~/vps never auto-pulls.
has "$hub" '^tier_selfpull %h/machines$' "hub pins FLEET_ROOTS to %h/machines"
has "$ws"  '^tier_selfpull$'             "workstation leaves FLEET_ROOTS default"
has "$hub" '^tier_shell_init --no-fish$' "hub skips the fish config"

# Resolution precedence 2 and 3: no env override, so the driver must read
# fleet.json by OS hostname, and fall back to workstation for an unknown box.
# Stub `hostname` on PATH (keep the real binaries the driver needs).
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
stub_host() { printf '#!/bin/sh\necho %s\n' "$1" > "$tmp/bin/hostname"; chmod +x "$tmp/bin/hostname"; }
plan_host() { stub_host "$1"; MACHINES_TIERS_DRY_RUN=1 PATH="$tmp/bin:$PATH" bash "$DRIVER" 2>&1; }

has "$(plan_host 27608)" 'profile: hub \(from fleet.json\)' "hostname 27608 resolves to hub via fleet.json"
has "$(plan_host wsl-scratch)" 'profile: workstation \(default\)' "unknown hostname defaults to workstation"

# Library sources inert.
out="$(TIERS_LIB_ONLY=1 bash -c 'source "$1"; declare -F tier_apt_min >/dev/null && echo LOADED' _ "$TIERS")"
eq "$out" "LOADED" "TIERS_LIB_ONLY sources without side effects"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/tiers.test.sh`
Expected: `FAILURES` — no `tiers.sh`, no dry-run mode (today's `linux.sh` would try to provision; `MACHINES_TIERS_DRY_RUN` is unknown to it).

- [ ] **Step 3: Write minimal implementation**

Create `provision/lib/tiers.sh` with this shape, filling each function with the verbatim lines from the move map:

```bash
# provision/lib/tiers.sh — the provisioning tiers (source me; do not execute).
# Bodies moved verbatim out of provision/linux.sh; that script is now the driver
# that resolves a profile (fleet.json "profile") and picks a tier list.
# Consumers: provision/linux.sh. Requires the driver's helpers (info/ok/warn/die/
# have) and globals (REPO, SUDO, PRIV, WARNINGS) to be set BEFORE sourcing.
#
# Testable: `TIERS_LIB_ONLY=1 source` loads the functions without running any.
# shellcheck shell=bash

tier_apt_min() { :; }        # lines 72-92, narrowed package list
tier_apt_dev() { :; }        # lines 85-90 residue + 94-95 + 156-217
tier_agents_config() { :; }  # lines 97-104 (CORE: die on failure)
tier_git_base() { :; }       # lines 106-121
tier_gortex() { :; }         # lines 123-136
tier_agent_clis() { :; }     # lines 138-154, per-cli case in a for loop
tier_autofetch() { :; }      # lines 219-304
tier_ssh_accounts() { :; }   # lines 306-394
tier_shell_init() { :; }     # lines 396-433, --no-fish skips 415-433
tier_selfpull() { :; }       # lines 435-485, optional FLEET_ROOTS arg
tier_ssh_trust() { :; }      # lines 487-515
```

`tier_apt_dev`'s two required additions (today those lines sit *after* the guarded
CORE block and inherit its `PRIV`/`apt-get update` side effects; as a standalone
tier they must carry both themselves):

```bash
tier_apt_dev() {
  # Same contract as tier_apt_min: with no reachable root non-interactively
  # (a detached converge on a box needing an interactive sudo password) this is
  # a warn-and-skip, not a pile of failing unprivileged apt calls.
  if [ "$PRIV" -eq 0 ]; then
    warn "no root available non-interactively — skipping the dev apt layer"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  # apt_min already refreshed the index in this process — don't pay for it twice.
  if [ -z "${APT_UPDATED:-}" ]; then
    $SUDO apt-get update -qq || warn "apt-get update failed"
    APT_UPDATED=1
  fi
  # … packages + lines 94-95, 156-217 verbatim …
}
```

`tier_apt_min` sets the same flag after its own `apt-get update -qq`
(`APT_UPDATED=1`), declared in the driver preamble as `APT_UPDATED=""`.

`tier_agent_clis` shape:

```bash
# tier_agent_clis <cli>…: install the requested agent CLIs via their native
# installers (no Node). Unknown names warn and are skipped.
tier_agent_clis() {
  local c
  for c in "$@"; do
    case "$c" in
      claude)
        if have claude; then ok "claude already installed"; else
          info "Installing Claude Code…"
          curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 \
            && ok "claude installed" \
            || warn "claude install failed — retry: curl -fsSL https://claude.ai/install.sh | bash"
        fi ;;
      codex)
        if have codex; then ok "codex already installed"; else
          info "Installing Codex…"
          CODEX_NON_INTERACTIVE=1 curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null 2>&1 \
            && ok "codex installed" \
            || warn "codex install failed — retry: curl -fsSL https://chatgpt.com/codex/install.sh | sh" 
        fi ;;
      *) warn "unknown agent CLI '$c' — skipped" ;;
    esac
  done
}
```

`tier_shell_init` shape (body lines unchanged inside each block):

```bash
# tier_shell_init [--no-fish]: append the machines-bootstrap block to ~/.bashrc
# (PATH + starship/direnv hooks + aliases); seed ~/.config/fish/config.fish
# unless --no-fish. Guarded so re-runs never duplicate.
tier_shell_init() {
  local want_fish=1
  [ "${1:-}" = "--no-fish" ] && want_fish=0
  # … lines 400-413 verbatim (bashrc block) …
  if [ "$want_fish" -eq 1 ] && have fish; then
    # … lines 418-432 verbatim (fish config seed) …
    :
  fi
}
```

`tier_selfpull` gains only the roots plumbing — in the systemd branch, after the
`Description=` line of the generated `fleet-selfpull.service`:

```bash
tier_selfpull() {
  local roots="${1:-}"
  # … lines 440-445 verbatim (info, FSP, systemd probe, _ud2) …
  {
    printf '[Unit]\nDescription=Fleet self-pull (ff-only) of all fleet-sync repos\n\n'
    printf '[Service]\nType=oneshot\nTimeoutStartSec=8min\n'
    # Pin the scan roots when the profile asks for it (hub: only ~/machines, so
    # the vps repo that defines its live services never auto-pulls).
    [ -n "$roots" ] && printf 'Environment=FLEET_ROOTS=%s\n' "$roots"
    printf 'ExecStart=/usr/bin/env bash %s\n' "$FSP"
  } > "$_ud2/fleet-selfpull.service"
  # … timer unit + enable verbatim …
  # Cron fallback: cron does not expand systemd's %h, so translate it first.
  #   local roots_cron="${roots//%h/$HOME}"
  # and when non-empty the scheduled line becomes
  #   */10 * * * * sleep $((RANDOM % 120)); FLEET_ROOTS='<roots_cron>' /usr/bin/env bash <FSP> >/dev/null 2>&1
  # (else today's line, unchanged). Keep the existing grep -qF idempotence check.
}
```

The `{ :; }` bodies above are a **move map, not the deliverable** — every one must
hold its real lines before Task 3's commit. `grep -n ':;' provision/lib/tiers.sh`
must come back empty.

Rewrite `provision/linux.sh` as the driver:

```bash
#!/usr/bin/env bash
# provision/linux.sh — provision a Debian/Ubuntu box into the fleet's portable
# layer. Driver only: resolve this box's PROFILE, then run that profile's ordered
# tier list from provision/lib/tiers.sh (which holds what this script used to do
# inline). Profiles let a lean box — hub, the 960MB VPS — converge without the
# workstation dev layer. See docs/superpowers/specs/2026-07-25-hub-fleet-
# enrollment-tiers-design.md.
set -u

# … preamble: lines 26-70 verbatim, plus:
export PATH="$HOME/.local/bin:$PATH"   # so `have claude|gortex|starship|uv` sees
                                       # prior installs under a detached converge
                                       # (a non-login shell lacks ~/.local/bin)

# ── Profile resolution: env override > fleet.json by hostname > workstation ────
# shellcheck source=provision/lib/fleet.sh
source "$REPO/provision/lib/fleet.sh"
if [ -n "${MACHINES_PROFILE:-}" ]; then
  PROFILE="$MACHINES_PROFILE"; PROFILE_SRC="from MACHINES_PROFILE"
elif PROFILE="$(fleet_profile_for_host 2>/dev/null)" && [ -n "$PROFILE" ]; then
  PROFILE_SRC="from fleet.json"
else
  PROFILE="workstation"; PROFILE_SRC="default"
fi

# ── Profile → ordered tier list ───────────────────────────────────────────────
# One list per profile; a new profile is a new list, not a new code path.
case "$PROFILE" in
  workstation)
    TIERS=(apt_min apt_dev agents_config git_base gortex
           "agent_clis claude codex" shell_init autofetch
           ssh_accounts selfpull ssh_trust) ;;
  hub)
    # Lean server tier. Deliberately absent: apt_dev, gortex, codex, and
    # ssh_accounts — the last would overwrite hub's ~/.ssh/config with
    # IdentitiesOnly on a fresh unregistered key and kill its GitHub auth.
    TIERS=(apt_min agents_config git_base "agent_clis claude"
           "shell_init --no-fish" autofetch
           "selfpull %h/machines" ssh_trust) ;;
  *)
    die "unknown profile '$PROFILE' ($PROFILE_SRC) — expected workstation|hub" ;;
esac

printf 'profile: %s (%s)\n' "$PROFILE" "$PROFILE_SRC"

if [ -n "${MACHINES_TIERS_DRY_RUN:-}" ]; then
  for t in "${TIERS[@]}"; do printf 'tier_%s\n' "$t"; done
  exit 0
fi

printf '\n\033[1mProvisioning %s from %s\033[0m\n\n' "$(uname -n)" "$REPO"
# shellcheck source=provision/lib/tiers.sh
source "$REPO/provision/lib/tiers.sh"
for t in "${TIERS[@]}"; do
  # A list entry is "<tier> [args…]". Split it explicitly instead of relying on
  # unquoted expansion, which would also glob any arg containing * ? or [.
  read -r -a _call <<< "$t"
  "tier_${_call[0]}" "${_call[@]:1}"
done

# … summary: lines 517-532 verbatim …
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash provision/tests/tiers.test.sh`
Expected: `ALL PASS`.

Run: `bash -n provision/linux.sh && bash -n provision/lib/tiers.sh`
Expected: no output.

Run: `bash scripts/converge.test.sh && bash provision/fleet-selfpull.test.sh && bash agents/git-hooks/post-merge.test.sh && bash provision/tests/fleet-profile.test.sh && bash provision/tests/fleet-local.test.sh`
Expected: `ALL PASS` from each.

Manual diff review (the refactor's real gate): `git diff -- provision/linux.sh` must show only moves, the preamble `PATH` line, and the driver scaffolding — no reworded `info`/`warn` strings, no changed package names beyond the documented `apt_min`/`apt_dev` split, no reordering inside a body.

- [ ] **Step 5: Commit**

```bash
chmod +x provision/tests/tiers.test.sh
git add provision/linux.sh provision/lib/tiers.sh provision/tests/tiers.test.sh
git commit -m "refactor(provision): split linux.sh into tiers + add the lean hub profile

Tier bodies move verbatim into provision/lib/tiers.sh; linux.sh resolves a
profile (MACHINES_PROFILE > fleet.json > workstation) and runs that profile's
ordered tier list. workstation reproduces today's run. hub drops apt_dev,
gortex, codex and — load-bearing — ssh_accounts, and pins FLEET_ROOTS to
~/machines so the vps repo never auto-pulls.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Commit hub's per-host memory stub

Without this, `agents/bootstrap.sh:295-311` seeds `agents/hosts/27608.md` untracked on hub → the tree is permanently dirty → `selfpull_one` returns `SKIP dirty` and auto-update never fires again.

**Files:**
- Create: `agents/hosts/27608.md`
- Test: `provision/tests/tiers.test.sh` (append one case)

**Interfaces:**
- Consumes: nothing.
- Produces: a tracked `agents/hosts/<hub OS hostname>.md`, matching what `bootstrap.sh` would have seeded.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/tiers.test.sh`, before its final `[ "$fail" -eq 0 ]` line:

```bash
# Every fleet.json machine must already have a committed per-host memory stub:
# agents/bootstrap.sh seeds a MISSING one inside the repo, which leaves the tree
# dirty and permanently disables fleet-selfpull's clean-tree gate on that box.
for h in $(jq -r '.machines[].detect.hostname' "$HERE/../../fleet.json"); do
  [ -f "$HERE/../../agents/hosts/$h.md" ] \
    && pass "host memory stub committed for $h" \
    || die "host memory stub committed for $h"
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/tiers.test.sh`
Expected: `FAIL host memory stub committed for 27608` (the other three hostnames pass).

- [ ] **Step 3: Write minimal implementation**

Create `agents/hosts/27608.md`:

```markdown
# Host: 27608

<!--
Per-host memory + instructions for this machine. Symlinked to
~/.claude/host-memory.md and imported by ~/.claude/CLAUDE.md, so it loads ONLY
when the hostname matches. Tracked in git, synced everywhere, inert on other
hosts. Do NOT put secrets here.
-->

## Notes

- This is `hub` — the Debian 12 VPS at `cyphy.kz` (tailnet `100.64.0.1`, OS
  hostname `27608`). Provisioning profile `hub`: the lean tier list, no dev
  layer, no gortex.
- Live services (headscale, caddy, docker stacks) are owned by the sibling `vps`
  repo, not by `machines`. Convergence here never touches them.
- `fleet-selfpull` is pinned to `~/machines` on this box, so `~/vps` is a
  deliberate manual pull.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/tests/tiers.test.sh`
Expected: `ALL PASS`, including `host memory stub committed for 27608`.

- [ ] **Step 5: Commit**

```bash
git add agents/hosts/27608.md provision/tests/tiers.test.sh
git commit -m "feat(agents): commit hub's per-host memory stub (27608)

bootstrap.sh seeds a missing agents/hosts/<host>.md inside the repo, which would
leave hub's checkout permanently dirty and disable its auto-pull clean-tree gate.
The test now asserts a stub exists for every fleet.json hostname.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Ship + gate the change on a NixOS member

`modules/system/fleet.nix:11` reads `fleet.json` with `fromJSON`, so Task 2 changed a Nix input even though no `.nix` file was edited. `hub` and the Windows boxes have no Nix — this gate runs on `latitude`.

**Files:** none (verification + push only).

**Interfaces:**
- Consumes: Tasks 1–4, committed on `main`.
- Produces: the change present on `origin/main`, dry-build verified.

- [ ] **Step 1: Confirm the working tree is clean and the tests pass**

Run: `git status --porcelain` → empty.
Run: `bash provision/tests/tiers.test.sh && bash provision/tests/fleet-profile.test.sh && bash scripts/converge.test.sh && bash provision/fleet-selfpull.test.sh && bash agents/git-hooks/post-merge.test.sh && bash provision/tests/fleet-local.test.sh`
Expected: `ALL PASS` from each.

- [ ] **Step 2: Dry-build the NixOS host that consumes `fleet.json`**

On `latitude` (this machine if it is `latitude5520`; otherwise `ssh latitude` after the push — note the remote login shell is **fish**, so avoid `$(...)`/POSIX-test syntax in the remote command):

Run: `nix build --dry-run '/home/me/machines#nixosConfigurations.latitude.config.system.build.toplevel'`
(absolute flake ref, so it does not depend on the remote shell's working directory)
Expected: exit 0, no evaluation error mentioning `fleet.json` or `profile`.

- [ ] **Step 3: Push**

```bash
git push origin main
```

- [ ] **Step 4: Confirm the push landed**

Run: `git log --oneline -1 origin/main`
Expected: the Task 4 commit SHA.

---

### Task 6: Enroll `hub` (one-time, on the box)

Run only after Task 5's push. Every command runs on `hub` (`ssh hub`, which lands in **bash**). Steps 2–4 are the acceptance test for the whole plan.

**Files:** none in the repo (box-side state only).

**Interfaces:**
- Consumes: `origin/main` carrying Tasks 1–4.
- Produces: `~/machines` on hub, converging on every pull.

- [ ] **Step 1: Clone the repo**

```bash
ssh hub 'git clone git@github.com:metheoryt/machines.git ~/machines'
```
Expected: clone succeeds (hub's `~/.ssh/id_rsa` already authenticates as `metheoryt`).

- [ ] **Step 2: Run the provisioner interactively**

Needs a TTY (the first run's apt tier uses `sudo -n`; hub has passwordless sudo, and a TTY keeps the interactive fallback available):

```bash
ssh -t hub 'bash ~/machines/provision/linux.sh'
```
Expected: banner `profile: hub (from fleet.json)`; tiers `apt_min agents_config git_base agent_clis shell_init autofetch selfpull ssh_trust` run; final `Done. <n> warning(s).`

- [ ] **Step 3: Verify — hazards did not fire**

```bash
ssh hub '
  git -C ~/machines status --porcelain
  git -C ~/machines config --local core.hooksPath
  cat ~/.ssh/config
  ssh -o BatchMode=yes -T git@github.com
  readlink ~/.claude/CLAUDE.md
  ls ~/.claude/.credentials.json'
```
Expected, in order: **empty** porcelain output (clean-tree gate holds); `core.hooksPath` pointing at `~/machines/agents/git-hooks`; `~/.ssh/config` **still empty** and the GitHub greeting still `Hi metheoryt!` (hazard 1 did not fire); `~/.claude/CLAUDE.md` a symlink into `~/machines/agents`; `.credentials.json` still present.

- [ ] **Step 4: Verify — timers and roots**

```bash
ssh hub 'systemctl --user list-timers --all
  systemctl --user cat fleet-selfpull.service
  loginctl show-user debian | grep Linger'
```
Expected: `fleet-selfpull.timer` and `git-autofetch.timer` scheduled; the service unit contains `Environment=FLEET_ROOTS=%h/machines`; `Linger=yes`.

- [ ] **Step 5: End-to-end convergence check**

From this machine, commit and push a trivial change to a converge-triggering path — add a comment line to `provision/lib/tiers.sh` — then wait ≤ ~12 min and check:

```bash
ssh hub 'cat ~/machines/.machines/last-converge; git -C ~/machines log --oneline -1'
```
Expected: `status=ok` with `reason=provision/linux.sh`, and hub's HEAD equal to `origin/main`. This is the end-to-end proof that Task 1 worked — a `tiers.sh` change **must** take the provision branch. `reason=linux: no provisioning-relevant change` here means the `touches_linux` regex is still wrong; fix that before calling the plan done.

- [ ] **Step 6: Record the outcome in project memory**

Append to `.claude/memory/project.md` under the fleet-convergence heading: hub is enrolled (profile `hub`, lean tier list, `FLEET_ROOTS` pinned to `~/machines`), plus the three hazards a future change must not reintroduce (`ssh_accounts` on hub, untracked `agents/hosts/<host>.md`, `touches_linux` missing a new provisioning path). Commit:

```bash
git add .claude/memory/project.md
git commit -m "docs(memory): record hub fleet enrollment + its three hazards

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

## Rollback

If hub ends up broken or unreachable-by-git after Task 6:

```bash
ssh hub 'systemctl --user disable --now fleet-selfpull.timer git-autofetch.timer
  git -C ~/machines config --local --unset core.hooksPath'
```

That stops both auto-pull and convergence while leaving the clone in place. If `~/.ssh/config` was somehow written (hazard 1), `truncate -s 0 ~/.ssh/config` restores hub's `id_rsa`-based GitHub auth — hub is still reachable over the tailnet by SSH from latitude regardless, since `authorized_keys` changes are additive.
