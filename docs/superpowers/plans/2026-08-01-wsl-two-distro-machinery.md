# WSL Two-Distro Machinery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo-side machinery that a second WSL distro needs — a persisted WSL fixes installer, a `--no-tailscale` provisioning path, and fleet dispatch that reaches a distro through its Windows parent.

**Architecture:** Three independent shell components, all in `provision/` and `agents/plugin/skills/lib/`. Each exposes pure helper functions behind a `*_LIB_ONLY=1` guard so unit tests source the script without running `main`, matching the pattern in `provision/ssh-wsl.sh` and `provision/ssh-wsl.test.sh`. Dispatch routing is data-driven: a `dispatch` field in each distro's gitignored `fleet.local.json` selects direct-SSH or parent-routed, so adding a client distro later needs no code change.

**Tech Stack:** Bash 5, `jq`, systemd units, `just` recipes. Tests are plain bash scripts with `fail`/`eq`/`pass` helpers — no framework, no network, no sudo.

**Spec:** `docs/superpowers/specs/2026-08-01-two-distro-orca-design.md`

**Companion plan:** `docs/superpowers/plans/2026-08-01-wsl-two-distro-rollout.md` — the machine-side runbook. It depends on every task here being merged first.

## Global Constraints

- **Repo:** work on branch `metheoryt/Pure-WSL` in the worktree at `/home/me/orca/workspaces/machines/Pure-WSL`. Never commit to `main` from here.
- **Every new `just` recipe MUST carry both `[group('…')]` and `[doc('…')]` attributes.** `provision/tests/justfile.test.sh` fails the build otherwise.
- **`provision/linux.sh` is shared with the Debian VPS `hub`.** No WSL-specific logic may be added to it. WSL-only work belongs in the `provision-wsl.sh` chain.
- **Tests must not require sudo, network, or a real WSL distro.** Inject dependencies (`SSH`, target paths) as overridable variables.
- **Shell style:** `set -u` (not `-e`) in dispatch/test files, matching `fleet-dispatch.sh`; `set -euo pipefail` in installer scripts, matching `wslopen`. Helper names `info`/`ok`/`warn`/`die`/`have`, matching `tailscale-wsl.sh`.
- **The literal binfmt registration line is `:WSLInterop:M::MZ::/init:P`** — flags `P`, no `F`. Copy verbatim; this is what WSL itself registers.
- **Distro names in this plan:** `desktop-wsl` (personal, renamed from `Ubuntu-26.04`) and `desktop-pure` (work). The rollout plan performs the rename; this plan must not hardcode either name outside of test fixtures.

---

### Task 1: `provision/assets/wslopen` — the browser opener, as a tracked asset

Currently untracked and machine-local at `~/.local/bin/wslopen` on the personal distro. Without it, `claude auth login --claudeai` has no way to open a browser, falls back to a URL nobody sees, and hangs for the full `LOGIN_TIMEOUT_MS = 18e4`. It must be a repo file so a distro rebuild keeps it and the new distro gets it from birth.

`wslu` is not an option — it was dropped from the Ubuntu 26.04 archive.

**Files:**
- Create: `provision/assets/wslopen`
- Test: `provision/tests/wsl-fixes.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the asset path `provision/assets/wslopen`, installed by Task 2 to `~/.local/bin/wslopen` with `xdg-open` and `wslview` symlinked to it.

- [ ] **Step 1: Write the failing test**

Create `provision/tests/wsl-fixes.test.sh`:

```bash
#!/usr/bin/env bash
# provision/tests/wsl-fixes.test.sh — unit tests for the WSL-only fixes:
# the wslopen asset and the binfmt watchdog renderers. No sudo, no network,
# no real WSL distro — the installer is sourced in WSL_FIXES_LIB_ONLY mode.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

# ── the wslopen asset ─────────────────────────────────────────────────────────
ASSET="$REPO/provision/assets/wslopen"

[ -f "$ASSET" ] && pass "wslopen asset exists" || die "wslopen asset missing at $ASSET"
bash -n "$ASSET" 2>/dev/null && pass "wslopen parses" || die "wslopen has a syntax error"

# It must base64/UTF-16LE encode the command: plain string interpolation lets
# cmd/PowerShell mangle & ? = in an OAuth callback URL, which is exactly the
# case this exists for.
grep -q 'iconv -f UTF-8 -t UTF-16LE' "$ASSET" && pass "wslopen encodes UTF-16LE" \
  || die "wslopen must pipe through iconv UTF-16LE"
grep -q 'EncodedCommand' "$ASSET" && pass "wslopen uses -EncodedCommand" \
  || die "wslopen must use powershell -EncodedCommand"

# URL schemes must pass through untouched; only real paths get wslpath'd.
grep -q 'http://\* | https://\*' "$ASSET" && pass "wslopen passes URLs through" \
  || die "wslopen must not wslpath a URL"

exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/wsl-fixes.test.sh`
Expected: FAIL — `wslopen asset missing at …/provision/assets/wslopen`

- [ ] **Step 3: Create the asset**

```bash
mkdir -p provision/assets
```

Create `provision/assets/wslopen` with exactly this content:

```bash
#!/usr/bin/env bash
# Open a URL or file with the default Windows handler, from inside WSL.
# Stand-in for wslview / xdg-open, which Ubuntu 26.04 no longer packages
# (wslu was dropped from the archive).
#
# Installed as wslopen, with xdg-open and wslview symlinked to it, so tools
# that shell out to either name work. Needs WSL interop (binfmt WSLInterop).
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <url|path>" >&2
  exit 2
fi

target=$1
case "$target" in
  http://* | https://* | mailto:* | ms-* ) ;;
  *) target=$(wslpath -w -- "$target" 2>/dev/null || printf '%s' "$target") ;;
esac

powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
if [ ! -x "$powershell" ]; then
  powershell=$(command -v powershell.exe 2>/dev/null) || {
    echo "$(basename "$0"): powershell.exe not found — is WSL interop enabled?" >&2
    exit 1
  }
fi

# Single-quoted PowerShell literal: the only escape needed is doubling quotes.
# Encoding the whole command sidesteps cmd/PowerShell mangling of & ? = in URLs.
escaped=${target//\'/\'\'}
# ProgressPreference off, or PowerShell spews a CLIXML progress record on stderr
# that lands in the output buffer of whatever called us.
encoded=$(printf '%s' "\$ProgressPreference='SilentlyContinue'; Start-Process -FilePath '$escaped'" \
  | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

exec "$powershell" -NoProfile -NonInteractive -EncodedCommand "$encoded"
```

Then make it executable and unignore it if the repo's `.gitignore` blocks `provision/assets/`:

```bash
chmod +x provision/assets/wslopen
git check-ignore -v provision/assets/wslopen || true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/tests/wsl-fixes.test.sh`
Expected: all PASS, exit 0

- [ ] **Step 5: Commit**

```bash
git add provision/assets/wslopen provision/tests/wsl-fixes.test.sh
git commit -m "feat(provision): track wslopen as a repo asset

Was untracked and machine-local on the personal distro. Without it
\`claude auth login --claudeai\` has no browser opener, falls back to a
URL nobody sees, and hangs for the full 180s LOGIN_TIMEOUT_MS. wslu is
not an option — dropped from the Ubuntu 26.04 archive."
```

---

### Task 2: `provision/wsl-fixes.sh` — installer for wslopen and the binfmt watchdog

The binfmt half replaces a fix that looks right and is inert. `/usr/lib/binfmt.d/WSLInterop.conf` does nothing: WSL 2.7.10's `systemd-binfmt` carries an injected `ExecStartPost` that unregisters and re-registers WSLInterop *after* `systemd-binfmt` applies `binfmt.d/*.conf`. Proof — the conf declares flags `PF`, the live registration always reads `flags: P`.

Interop still dies at runtime (observed 2026-07-31 and 2026-08-01), cause unidentified, and starting a second distro was tested and ruled out. Recovery is `systemctl restart systemd-binfmt`, verified. So the fix is a watchdog, not a config file.

**Files:**
- Create: `provision/wsl-fixes.sh`
- Modify: `provision/tests/wsl-fixes.test.sh` (append)

**Interfaces:**
- Consumes: `provision/assets/wslopen` from Task 1.
- Produces:
  - `wsl_fixes_needs_reregister <binfmt-path>` → exit 0 when the registration is missing (watchdog should act), exit 1 when present.
  - `wsl_fixes_watchdog_service` → prints the `.service` unit text to stdout.
  - `wsl_fixes_watchdog_timer` → prints the `.timer` unit text to stdout.
  - `wsl_fixes_symlink_names` → prints `xdg-open` and `wslview`, one per line.
  - `WSL_FIXES_LIB_ONLY=1` guard: sourcing defines functions and runs no side effects.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/wsl-fixes.test.sh`, immediately before the final `exit "$fail"` line:

```bash
# ── the installer's pure helpers ──────────────────────────────────────────────
export WSL_FIXES_LIB_ONLY=1
# shellcheck source=/dev/null
source "$REPO/provision/wsl-fixes.sh"

# wsl_fixes_needs_reregister: 0 (act) when the binfmt entry is absent.
tmp="$(mktemp -d)"
wsl_fixes_needs_reregister "$tmp/absent" && pass "needs_reregister: absent → act" \
  || die "needs_reregister must return 0 when the entry is missing"
printf 'enabled\ninterpreter /init\n' > "$tmp/present"
wsl_fixes_needs_reregister "$tmp/present" && die "needs_reregister must return 1 when present" \
  || pass "needs_reregister: present → no action"
rm -rf "$tmp"

# Both symlink names are required: tools shell out to one or the other.
names="$(wsl_fixes_symlink_names | sort | tr '\n' ' ')"
eq "$names" "wslview xdg-open " "symlink names are xdg-open and wslview"

# The watchdog service must recover via the VERIFIED action and nothing else.
svc="$(wsl_fixes_watchdog_service)"
case "$svc" in
  *"systemctl restart systemd-binfmt"*) pass "watchdog restarts systemd-binfmt" ;;
  *) die "watchdog service must recover with: systemctl restart systemd-binfmt" ;;
esac
case "$svc" in
  *"Type=oneshot"*) pass "watchdog service is oneshot" ;;
  *) die "watchdog service must be Type=oneshot" ;;
esac

# It must NOT reintroduce the inert binfmt.d conf approach.
case "$svc" in
  *"binfmt.d"*) die "watchdog must not write a binfmt.d conf — it is inert" ;;
  *) pass "watchdog avoids the inert binfmt.d conf" ;;
esac

tmr="$(wsl_fixes_watchdog_timer)"
case "$tmr" in
  *"OnBootSec="*) pass "timer fires at boot" ;;
  *) die "timer must set OnBootSec=" ;;
esac
case "$tmr" in
  *"OnUnitActiveSec="*) pass "timer repeats" ;;
  *) die "timer must set OnUnitActiveSec=" ;;
esac
case "$tmr" in
  *"WantedBy=timers.target"*) pass "timer is enable-able" ;;
  *) die "timer must have WantedBy=timers.target" ;;
esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/wsl-fixes.test.sh`
Expected: FAIL — `provision/wsl-fixes.sh: No such file or directory`

- [ ] **Step 3: Write the installer**

Create `provision/wsl-fixes.sh`:

```bash
#!/usr/bin/env bash
# provision/wsl-fixes.sh — WSL-only fixes that a distro rebuild must keep.
# Run from inside the distro; idempotent; safe to re-run to backfill an
# existing distro.
#
# NOT part of linux.sh: that script is shared with the Debian VPS `hub`, which
# has no WSL and no interop.
#
# Two fixes:
#
#   1. wslopen (+ xdg-open / wslview symlinks) — Ubuntu 26.04 dropped wslu, so
#      nothing opens a browser from inside the distro. Without it
#      `claude auth login --claudeai` falls back to a URL nobody sees and hangs
#      for the full 180s LOGIN_TIMEOUT_MS.
#
#   2. A binfmt watchdog. WSL interop is intermittently lost at runtime
#      (observed 2026-07-31 and 2026-08-01; cause unidentified; starting a
#      second distro was tested and ruled out). The obvious fix — dropping
#      `:WSLInterop:M::MZ::/init:PF` into /usr/lib/binfmt.d/ — is INERT: WSL's
#      own systemd-binfmt ExecStartPost unregisters and re-registers *after*
#      binfmt.d is applied, which is why the live flags always read `P` and
#      never the conf's `PF`. The verified recovery is
#      `systemctl restart systemd-binfmt`, so the watchdog does exactly that.
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

WSL_FIXES_BINFMT_PATH="${WSL_FIXES_BINFMT_PATH:-/proc/sys/fs/binfmt_misc/WSLInterop}"
WSL_FIXES_UNIT_DIR="${WSL_FIXES_UNIT_DIR:-/etc/systemd/system}"
WSL_FIXES_BIN_DIR="${WSL_FIXES_BIN_DIR:-$HOME/.local/bin}"

# ── pure helpers (unit-tested) ────────────────────────────────────────────────

# 0 = registration missing, watchdog should act. 1 = present, nothing to do.
wsl_fixes_needs_reregister() {
  [ ! -e "${1:-$WSL_FIXES_BINFMT_PATH}" ]
}

wsl_fixes_symlink_names() {
  printf 'xdg-open\n'
  printf 'wslview\n'
}

wsl_fixes_watchdog_service() {
  cat <<EOF
[Unit]
Description=Re-register WSL interop binfmt handler when it disappears
ConditionPathExists=!$WSL_FIXES_BINFMT_PATH

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart systemd-binfmt
EOF
}

wsl_fixes_watchdog_timer() {
  cat <<'EOF'
[Unit]
Description=Periodically check the WSL interop binfmt handler

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
}

# ── installers (need the filesystem; not unit-tested) ─────────────────────────

wsl_fixes_install_wslopen() {
  local repo asset dest name
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  asset="$repo/provision/assets/wslopen"
  [ -f "$asset" ] || die "missing asset: $asset"

  mkdir -p "$WSL_FIXES_BIN_DIR"
  dest="$WSL_FIXES_BIN_DIR/wslopen"
  install -m 0755 "$asset" "$dest"
  ok "installed $dest"

  while IFS= read -r name; do
    ln -sfn wslopen "$WSL_FIXES_BIN_DIR/$name"
    ok "linked $WSL_FIXES_BIN_DIR/$name -> wslopen"
  done < <(wsl_fixes_symlink_names)
}

wsl_fixes_install_watchdog() {
  local svc="$WSL_FIXES_UNIT_DIR/wsl-binfmt-watchdog.service"
  local tmr="$WSL_FIXES_UNIT_DIR/wsl-binfmt-watchdog.timer"

  wsl_fixes_watchdog_service | sudo tee "$svc" >/dev/null || die "cannot write $svc"
  wsl_fixes_watchdog_timer   | sudo tee "$tmr" >/dev/null || die "cannot write $tmr"
  sudo systemctl daemon-reload
  sudo systemctl enable --now wsl-binfmt-watchdog.timer
  ok "wsl-binfmt-watchdog.timer enabled"

  # The old, inert fix. Remove it so nobody trusts it later.
  if [ -f /usr/lib/binfmt.d/WSLInterop.conf ]; then
    sudo rm -f /usr/lib/binfmt.d/WSLInterop.conf
    ok "removed inert /usr/lib/binfmt.d/WSLInterop.conf"
  fi
}

wsl_fixes_main() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || warn "WSL_DISTRO_NAME unset — is this really a WSL distro?"
  info "installing wslopen…"
  wsl_fixes_install_wslopen
  info "installing binfmt watchdog…"
  wsl_fixes_install_watchdog
}

[ -n "${WSL_FIXES_LIB_ONLY:-}" ] || wsl_fixes_main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/tests/wsl-fixes.test.sh`
Expected: all PASS, exit 0

- [ ] **Step 5: Commit**

```bash
git add provision/wsl-fixes.sh provision/tests/wsl-fixes.test.sh
git commit -m "feat(provision): wsl-fixes.sh — wslopen installer + binfmt watchdog

Replaces /usr/lib/binfmt.d/WSLInterop.conf, which is inert: WSL 2.7.10's
systemd-binfmt ExecStartPost unregisters and re-registers WSLInterop after
binfmt.d is applied, so the conf's PF flags never take — live flags always
read P. Interop still dies at runtime, so the watchdog performs the verified
recovery instead: systemctl restart systemd-binfmt.

Not in linux.sh — that is shared with the Debian VPS hub."
```

---

### Task 3: `provision-wsl.sh` gains `--no-tailscale` and the fixes step

Two things at once because they are the same edit to the same chain, and a reviewer would accept or reject them together.

`--no-tailscale` is not a convenience. WSL2 distros share **one** network namespace — proven by identical `/proc/self/ns/net` inodes and by `Ubuntu-24.04`'s `ss` listing `Ubuntu-26.04`'s `hermes:9119`. A second `tailscaled` cannot create a second `tailscale0`. Running the existing chain unmodified on the work distro would try exactly that.

This task also corrects the false claim in `tailscale-wsl.sh`'s header, which currently asserts the opposite.

**Files:**
- Modify: `provision/provision-wsl.sh`
- Modify: `provision/tailscale-wsl.sh:8-11` (header comment only)
- Modify: `justfile` (the `provision-wsl` recipe)
- Create: `provision/tests/provision-wsl.test.sh`

**Interfaces:**
- Consumes: `provision/wsl-fixes.sh` from Task 2.
- Produces: `provision_wsl_steps <no-tailscale-flag>` → prints the ordered step script names, one per line, from `tailscale-wsl.sh` through `wsl-fixes.sh`. `PROVISION_WSL_LIB_ONLY=1` guard.

- [ ] **Step 1: Write the failing test**

Create `provision/tests/provision-wsl.test.sh`:

```bash
#!/usr/bin/env bash
# provision/tests/provision-wsl.test.sh — the chain order and the
# --no-tailscale gate. Sources in LIB_ONLY mode; runs no step.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
fail=0
pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }
eq()   { [ "$1" = "$2" ] && pass "$3" || die "$3: expected '$2', got '$1'"; }

export PROVISION_WSL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$REPO/provision/provision-wsl.sh"

# Default chain: tailnet enroll first, fixes last.
full="$(provision_wsl_steps 0 | tr '\n' ' ')"
eq "$full" "tailscale-wsl.sh ssh-wsl.sh linux.sh fleet-local.sh wsl-fixes.sh " \
  "default chain order"

# --no-tailscale drops ONLY the enroll step. WSL2 distros share one network
# namespace, so a second tailscaled cannot create a second tailscale0.
none="$(provision_wsl_steps 1 | tr '\n' ' ')"
eq "$none" "ssh-wsl.sh linux.sh fleet-local.sh wsl-fixes.sh " \
  "--no-tailscale drops only the enroll step"

case "$none" in
  *tailscale-wsl.sh*) die "--no-tailscale must not run tailscale-wsl.sh" ;;
  *) pass "--no-tailscale really skips tailscale-wsl.sh" ;;
esac

# Every named step must exist on disk — a typo here is a silent no-op at runtime.
for s in $full; do
  [ -f "$REPO/provision/$s" ] && pass "step exists: $s" || die "missing step script: $s"
done

# The header lie must be gone: tailscale-wsl.sh claimed one tailscaled PER
# distro with "no port juggling". Distros share a netns; that is false.
if grep -q 'one tailscaled PER distro' "$REPO/provision/tailscale-wsl.sh"; then
  die "tailscale-wsl.sh still claims one tailscaled per distro"
else
  pass "tailscale-wsl.sh header corrected"
fi

exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/provision-wsl.test.sh`
Expected: FAIL — `provision_wsl_steps: command not found`, and `tailscale-wsl.sh still claims one tailscaled per distro`

- [ ] **Step 3: Rewrite `provision/provision-wsl.sh`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# provision/provision-wsl.sh — half-provision THIS WSL distro as a self-declaring,
# ephemeral fleet host (NOT a fleet.json member). Run from inside the distro:
#   bash ~/machines/provision/provision-wsl.sh <nickname> [--no-tailscale]
#
# Chain (spec 2026-07-21, extended by spec 2026-08-01):
#   1. tailscale-wsl.sh --hostname <nickname>   enroll on the tailnet
#   2. ssh-wsl.sh                                fleet SSH client+server identity
#   3. linux.sh                                  software + timers + inbound trust
#   4. fleet-local.sh --nickname <nickname>      write the self-declaration
#   5. wsl-fixes.sh                              wslopen + binfmt watchdog
#
# --no-tailscale skips step 1. WSL2 distros share ONE network namespace (proven
# 2026-08-01: identical /proc/self/ns/net inodes, cross-visible listener tables),
# so only ONE distro per Windows host can run tailscaled and own tailscale0.
# Every distro after the first is provisioned with --no-tailscale and reached
# through its Windows parent instead — see fleet-dispatch.sh.
#
# The nickname is the fleet.local.json nickname and the dispatch key. For the
# ONE distro that owns the tailnet node it is also the tailnet node name; for
# every other distro it is not, because there is no second node.
set -u
info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# provision_wsl_steps <no-tailscale> — ordered step script names, one per line.
provision_wsl_steps() {
  [ "${1:-0}" = 1 ] || printf 'tailscale-wsl.sh\n'
  printf 'ssh-wsl.sh\n'
  printf 'linux.sh\n'
  printf 'fleet-local.sh\n'
  printf 'wsl-fixes.sh\n'
}

provision_wsl_main() {
  local nick="" no_tailscale=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-tailscale) no_tailscale=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)  [ -n "$nick" ] && die "unexpected argument: $1"; nick="$1"; shift ;;
    esac
  done
  [ -n "$nick" ] || die "usage: provision-wsl.sh <nickname> [--no-tailscale]"

  local steps total i=0 step
  mapfile -t steps < <(provision_wsl_steps "$no_tailscale")
  total="${#steps[@]}"

  for step in "${steps[@]}"; do
    i=$((i + 1))
    info "$i/$total $step…"
    case "$step" in
      tailscale-wsl.sh) bash "$REPO/provision/$step" --hostname "$nick" ;;
      fleet-local.sh)   bash "$REPO/provision/$step" --nickname "$nick" \
                             --platform linux --repo "$REPO" ;;
      *)                bash "$REPO/provision/$step" ;;
    esac || die "$step failed"
  done

  printf '\n\033[1mProvisioned WSL host '\''%s'\''.\033[0m It self-declares fleet:true.\n' "$nick"
  if [ "$no_tailscale" = 1 ]; then
    printf 'No tailnet node of its own — reached through its Windows parent.\n'
  else
    printf 'Reachable at %s.gg.ez.\n' "$nick"
  fi
}

[ -n "${PROVISION_WSL_LIB_ONLY:-}" ] || provision_wsl_main "$@"
```

- [ ] **Step 4: Correct the `tailscale-wsl.sh` header**

In `provision/tailscale-wsl.sh`, replace these lines:

```
# Model: one tailscaled PER distro (NOT host mirrored-networking), so N distros
# on one Windows host each get a distinct identity with no port juggling.
```

with:

```
# Model: ONE tailscaled for the whole WSL2 utility VM. Distros do NOT get
# separate network namespaces — proven 2026-08-01: Ubuntu-26.04 and Ubuntu-24.04
# report the same /proc/self/ns/net inode, and each `ss -ltn` lists the other's
# listeners. So exactly one distro per Windows host runs tailscaled and owns
# tailscale0; every other distro shares that node's IP and must pick distinct
# ports. Run this script on the node-owning distro ONLY; provision the rest with
# `provision-wsl.sh <nickname> --no-tailscale`.
#
# (An earlier version of this comment claimed one tailscaled per distro "with no
# port juggling". That was false — the script had only ever been run with a
# single distro present.)
```

- [ ] **Step 5: Update the `just` recipe**

In `justfile`, replace the `provision-wsl` recipe body so it forwards extra arguments. Keep both attributes — `provision/tests/justfile.test.sh` fails without them:

```just
[group('provision')]
[doc('Provision THIS WSL distro as a self-declared fleet host (add --no-tailscale for a second distro)')]
provision-wsl nickname *args:
    bash provision/provision-wsl.sh {{nickname}} {{args}}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash provision/tests/provision-wsl.test.sh && bash provision/tests/justfile.test.sh`
Expected: both all PASS, exit 0

- [ ] **Step 7: Commit**

```bash
git add provision/provision-wsl.sh provision/tailscale-wsl.sh \
        provision/tests/provision-wsl.test.sh justfile
git commit -m "feat(provision): --no-tailscale + wsl-fixes step; correct netns claim

WSL2 distros share ONE network namespace (identical /proc/self/ns/net
inodes; each distro's ss lists the other's listeners), so only one distro
per Windows host can run tailscaled and own tailscale0. Every distro after
the first is provisioned with --no-tailscale.

tailscale-wsl.sh's header claimed the opposite — one tailscaled per distro
'with no port juggling'. It had only ever been run with a single distro
present. Corrected in place so a future session doesn't rebuild this wrong."
```

---

### Task 4: `fleet-local.sh` gains a `dispatch` field

How a distro is reached becomes data, not code. A distro that owns the tailnet node is `direct`; every other distro is `parent`. Task 5 reads this field. Adding a third client distro later is then a provisioning flag, not a code change.

Existing `fleet.local.json` files have no `dispatch` key, so the reader must default to `direct` — that is the personal distro's current, working behavior.

**Files:**
- Modify: `provision/fleet-local.sh`
- Modify: `provision/tests/fleet-local.test.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `fleet.local.json` may now contain `.self.dispatch`, one of `direct` or `parent`. Written by `fleet-local.sh --dispatch <mode>`, default `direct`. Read by `fd_wsl_hosts` in Task 5.

- [ ] **Step 1: Write the failing test**

Append to `provision/tests/fleet-local.test.sh`, before its final exit/summary line:

```bash
# ── .self.dispatch (spec 2026-08-01) ──────────────────────────────────────────
tmp="$(mktemp -d)"; mkdir -p "$tmp/machines"

# Default is direct — every existing fleet.local.json predates this field, and
# the personal distro's current direct-SSH behavior must not change.
bash "$SCRIPT" --nickname desktop-wsl --repo "$tmp/machines" >/dev/null
got="$(jq -r '.self.dispatch' "$tmp/machines/fleet.local.json")"
[ "$got" = direct ] && pass "dispatch defaults to direct" \
  || die "dispatch default: expected 'direct', got '$got'"

# Explicit parent routing for a distro with no tailnet node.
bash "$SCRIPT" --nickname desktop-pure --dispatch parent --repo "$tmp/machines" >/dev/null
got="$(jq -r '.self.dispatch' "$tmp/machines/fleet.local.json")"
[ "$got" = parent ] && pass "dispatch parent written" \
  || die "dispatch parent: expected 'parent', got '$got'"

# Nickname and fleet flag must survive the new field.
got="$(jq -r '.self.nickname' "$tmp/machines/fleet.local.json")"
[ "$got" = desktop-pure ] && pass "nickname preserved alongside dispatch" \
  || die "nickname: expected 'desktop-pure', got '$got'"
got="$(jq -r '.self.fleet' "$tmp/machines/fleet.local.json")"
[ "$got" = true ] && pass "fleet flag preserved alongside dispatch" \
  || die "fleet: expected 'true', got '$got'"

# Garbage is rejected rather than written — a typo'd mode would silently make
# the distro unreachable.
if bash "$SCRIPT" --nickname x --dispatch sideways --repo "$tmp/machines" >/dev/null 2>&1; then
  die "invalid --dispatch must be rejected"
else
  pass "invalid --dispatch rejected"
fi
rm -rf "$tmp"
```

If `provision/tests/fleet-local.test.sh` does not already define `SCRIPT`, `pass`, and `die`, add them at the top of the appended block:

```bash
SCRIPT="${SCRIPT:-$REPO/provision/fleet-local.sh}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash provision/tests/fleet-local.test.sh`
Expected: FAIL — `dispatch default: expected 'direct', got 'null'`

- [ ] **Step 3: Add the field**

In `provision/fleet-local.sh`, add `dispatch` to the option parser and the `jq` filter. Replace the argument-parsing block and the write:

```bash
nickname=""; platform="linux"; repo="$HOME/machines"; dispatch="direct"
while [ $# -gt 0 ]; do
  case "$1" in
    --nickname) nickname="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    --dispatch) dispatch="$2"; shift 2 ;;
    --repo)     repo="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$nickname" ] || { echo "fleet-local: --nickname required" >&2; exit 2; }
case "$dispatch" in
  direct|parent) ;;
  *) echo "fleet-local: --dispatch must be 'direct' or 'parent', got '$dispatch'" >&2; exit 2 ;;
esac

f="$repo/fleet.local.json"
base='{}'
[ -f "$f" ] && base="$(cat "$f")"
printf '%s' "$base" | jq \
  --arg n "$nickname" --arg p "$platform" --arg d "$dispatch" \
  '.self = {nickname:$n, fleet:true, platform:$p, dispatch:$d}' > "$f.tmp" \
  && mv "$f.tmp" "$f"
echo "wrote $f (self.nickname=$nickname, fleet=true, platform=$platform, dispatch=$dispatch)"
```

Also update the file's header comment to mention the new field:

```bash
# `dispatch` selects how the fleet reaches this distro: `direct` (it owns the
# tailnet node, reachable at <nickname>.gg.ez) or `parent` (no node of its own —
# reached as `wsl.exe -d <distro>` through its Windows parent). WSL2 distros
# share one network namespace, so only one distro per host can be `direct`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash provision/tests/fleet-local.test.sh`
Expected: all PASS, exit 0

- [ ] **Step 5: Commit**

```bash
git add provision/fleet-local.sh provision/tests/fleet-local.test.sh
git commit -m "feat(provision): fleet.local.json gains .self.dispatch

direct (owns the tailnet node, reachable at <nickname>.gg.ez) or parent
(no node — reached via wsl.exe -d <distro> through the Windows parent).
Defaults to direct so existing files keep working unchanged."
```

---

### Task 5: `fleet-dispatch.sh` routes through the Windows parent

`fd_wsl_hosts` currently emits bare nicknames, and both consumers turn them into `<nickname>.gg.ez` themselves. That only works for a distro with its own tailnet node. Move suffixing into `fd_wsl_hosts` and have it emit a full routing triple, so consumers stop guessing.

Parent routing is not new machinery — `fd_wsl_hosts` already discovers distros with `ssh <parent> "wsl.exe -d $d -- bash -lc …"`. Verified 2026-08-01 that the same shape carries a piped script and positional args:

```
$ printf 'echo "ok: $1 $(hostname) $WSL_DISTRO_NAME"' \
    | ssh desktop "wsl.exe -d Ubuntu-24.04 -- bash -s -- HELLO"
ok: HELLO g614jv Ubuntu-24.04
```

**Files:**
- Modify: `agents/plugin/skills/lib/fleet-dispatch.sh`
- Modify: `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh` (append)

**Interfaces:**
- Consumes: `.self.dispatch` from Task 4.
- Produces:
  - `fd_wsl_hosts <parent-alias> <platform>` now emits TSV `nickname<TAB>target<TAB>platform`.
    - `direct` → `desktop-wsl<TAB>desktop-wsl.gg.ez<TAB>linux`
    - `parent` → `desktop-pure<TAB><parent-alias>:<distro-name><TAB>wsl`
  - `fd_probe <target> wsl` and `fd_run <target> wsl [args…]` accept a `<parent-alias>:<distro-name>` target.
  - `MAGICDNS_SUFFIX` (default `gg.ez`) is applied inside `fd_wsl_hosts`; consumers must no longer append it.

- [ ] **Step 1: Write the failing test**

Append to `agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`, before its final exit/summary:

```bash
# ── parent-routed WSL dispatch (spec 2026-08-01) ──────────────────────────────
# A distro with no tailnet node is reached as `wsl.exe -d <distro>` through its
# Windows parent. The mechanism is the one fd_wsl_hosts already uses to discover
# distros, verified end to end on 2026-08-01.

: > "$LOG"
fd_probe 'desktop:desktop-pure' wsl && pass "probe wsl ok" || die "probe wsl failed"
grep -q $'desktop\twsl.exe -d desktop-pure -- bash -c true' "$LOG" \
  && pass "probe wsl targets the parent with wsl.exe -d" \
  || die "probe wsl argv: $(cat "$LOG")"

# fd_run must pipe the script through and pass positional args after `--`.
out="$(printf 'echo hi\n' | fd_run 'desktop:desktop-pure' wsl ALPHA BETA)"
case "$out" in
  *'wsl.exe -d desktop-pure -- bash -s -- "ALPHA" "BETA"'*)
    pass "run wsl builds wsl.exe -d … bash -s -- args" ;;
  *) die "run wsl remote cmd: $out" ;;
esac
case "$out" in
  *'||echo hi'*) pass "run wsl round-trips stdin" ;;
  *) die "run wsl stdin lost: $out" ;;
esac

# ── fd_wsl_hosts emits nickname/target/platform ───────────────────────────────
mock_ssh_dispatch() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  local remote="$*"
  case "$remote" in
    *'wsl.exe -l -q'*) printf 'desktop-wsl\ndesktop-pure\n' ;;
    *desktop-wsl*)  printf '{"self":{"nickname":"desktop-wsl","fleet":true,"platform":"linux","dispatch":"direct"}}\n' ;;
    *desktop-pure*) printf '{"self":{"nickname":"desktop-pure","fleet":true,"platform":"linux","dispatch":"parent"}}\n' ;;
  esac
}
SSH="mock_ssh_dispatch"
MAGICDNS_SUFFIX="gg.ez"

rows="$(fd_wsl_hosts desktop windows)"

echo "$rows" | grep -q $'^desktop-wsl\tdesktop-wsl.gg.ez\tlinux$' \
  && pass "direct distro → tailnet FQDN, platform linux" \
  || die "direct row wrong: $rows"

echo "$rows" | grep -q $'^desktop-pure\tdesktop:desktop-pure\twsl$' \
  && pass "parent distro → parent:distro, platform wsl" \
  || die "parent row wrong: $rows"

# A file with no dispatch key predates the field and must behave as before.
mock_ssh_legacy() {
  while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; *) break;; esac; done
  local alias="$1"; shift
  case "$*" in
    *'wsl.exe -l -q'*) printf 'legacy-distro\n' ;;
    *) printf '{"self":{"nickname":"legacy-distro","fleet":true,"platform":"linux"}}\n' ;;
  esac
}
SSH="mock_ssh_legacy"
rows="$(fd_wsl_hosts desktop windows)"
echo "$rows" | grep -q $'^legacy-distro\tlegacy-distro.gg.ez\tlinux$' \
  && pass "missing dispatch key defaults to direct" \
  || die "legacy row wrong: $rows"

SSH="mock_ssh"   # restore for any later cases
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: FAIL — `probe wsl argv:` shows the linux branch (`bash -c true` sent straight to `desktop:desktop-pure`), and the `fd_wsl_hosts` rows are bare nicknames.

- [ ] **Step 3: Implement parent routing**

In `agents/plugin/skills/lib/fleet-dispatch.sh`:

Add near the top, after `: "${SSH:=ssh}"`:

```bash
: "${MAGICDNS_SUFFIX:=gg.ez}"

# _fd_wsl_split <parent:distro> — echoes "<parent> <distro>".
# The distro name may not contain ':'; wsl.exe forbids it.
_fd_wsl_split() {
  printf '%s %s\n' "${1%%:*}" "${1#*:}"
}
```

Add a `wsl)` case to `fd_probe`:

```bash
fd_probe() {
  local alias="$1" platform="$2"
  case "$platform" in
    windows) $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" "$(_fd_win_call -c true)" </dev/null 2>/dev/null ;;
    wsl)
      local parent distro
      read -r parent distro < <(_fd_wsl_split "$alias")
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$parent" \
        "wsl.exe -d $distro -- bash -c true" </dev/null 2>/dev/null ;;
    *)       $SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" bash -c true </dev/null 2>/dev/null ;;
  esac
}
```

Add the matching case to `fd_run`:

```bash
    wsl)
      local parent distro q a
      read -r parent distro < <(_fd_wsl_split "$alias")
      q="-s --"
      for a in "$@"; do q="$q \"$a\""; done
      $SSH -o ConnectTimeout=5 -o BatchMode=yes "$parent" \
        "wsl.exe -d $distro -- bash $q" 2>/dev/null
      ;;
```

Replace the body of `fd_wsl_hosts` so it emits the triple:

```bash
# fd_wsl_hosts <alias> <platform> — for a windows member, echo one TSV row per
# self-declared (fleet:true) WSL distro:
#
#   <nickname>\t<target>\t<platform>
#
# dispatch=direct (default, and the only mode before 2026-08-01) → the distro
# owns the tailnet node: target is <nickname>.<MAGICDNS_SUFFIX>, platform linux.
# dispatch=parent → no node of its own: target is <alias>:<distro-name>,
# platform wsl, reached by fd_run's wsl branch.
#
# Callers pass target+platform straight to fd_probe/fd_run and use nickname for
# display and host-id lookup. They must NOT append the MagicDNS suffix — that
# happens here, because only here is it known whether the distro has a node.
fd_wsl_hosts() {
  local alias="$1" platform="$2"
  [ "$platform" = windows ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local distros d marker nick mode
  distros="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" 'wsl.exe -l -q' </dev/null 2>/dev/null \
    | tr -d '\000\r')"
  printf '%s\n' "$distros" | while IFS= read -r d; do
    d="$(printf '%s' "$d" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$d" ] || continue
    marker="$($SSH -o ConnectTimeout=5 -o BatchMode=yes "$alias" \
      "wsl.exe -d $d -- bash -lc 'cat \$HOME/machines/fleet.local.json 2>/dev/null'" </dev/null 2>/dev/null \
      | tr -d '\000\r')"
    [ -n "$marker" ] || continue
    printf '%s' "$marker" | jq -e '.self.fleet == true' >/dev/null 2>&1 || continue
    nick="$(printf '%s' "$marker" | jq -r '.self.nickname // empty')"
    [ -n "$nick" ] || continue
    mode="$(printf '%s' "$marker" | jq -r '.self.dispatch // "direct"')"
    if [ "$mode" = parent ]; then
      printf '%s\t%s:%s\twsl\n' "$nick" "$alias" "$d"
    else
      printf '%s\t%s%s\tlinux\n' "$nick" "$nick" "${MAGICDNS_SUFFIX:+.$MAGICDNS_SUFFIX}"
    fi
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh`
Expected: all PASS, exit 0

- [ ] **Step 5: Commit**

```bash
git add agents/plugin/skills/lib/fleet-dispatch.sh \
        agents/plugin/skills/lib/tests/fleet-dispatch.test.sh
git commit -m "feat(fleet): dispatch WSL distros through their Windows parent

fd_wsl_hosts now emits nickname/target/platform, resolving the MagicDNS
suffix itself — only it knows whether a distro owns a tailnet node. A
dispatch=parent distro is reached as 'wsl.exe -d <distro>' through the
Windows parent, the same mechanism fd_wsl_hosts already uses to discover
distros. Missing dispatch key defaults to direct, so existing distros are
unaffected."
```

---

### Task 6: Update both `fd_wsl_hosts` consumers

Task 5 changed the output shape; without this task `/ship` and kb-refresh would treat the whole TSV row as an SSH alias and every WSL host would fail to resolve.

**Files:**
- Modify: `agents/plugin/skills/ship/fleet-pull.sh:134-139`
- Modify: `agents/plugin/skills/kb-refresh/fleet-gather.sh:205-212`
- Modify: `agents/plugin/skills/ship/tests/fleet-pull.test.sh` (append)

**Interfaces:**
- Consumes: the TSV triple from Task 5.
- Produces: no new interface.

- [ ] **Step 1: Write the failing test**

Append to `agents/plugin/skills/ship/tests/fleet-pull.test.sh`, before its final exit/summary. If the file does not already define `pass`/`die`/`REPO`, reuse whatever helpers it has and adapt the names:

```bash
# ── WSL rows are consumed as nickname/target/platform (spec 2026-08-01) ───────
# fleet-pull must pass the TARGET (not the nickname) to run_member, and must not
# append the MagicDNS suffix itself — fd_wsl_hosts already resolved it.
SRC="$REPO/agents/plugin/skills/ship/fleet-pull.sh"

grep -q 'IFS=.*read -r w wtarget wplat' "$SRC" \
  && pass "fleet-pull reads the TSV triple" \
  || die "fleet-pull must read nickname/target/platform from fd_wsl_hosts"

grep -q 'run_member "\$wtarget" "\$wplat"' "$SRC" \
  && pass "fleet-pull dispatches on target+platform" \
  || die "fleet-pull must pass target and platform to run_member"

grep -q 'MAGICDNS_SUFFIX' "$SRC" \
  && die "fleet-pull must no longer append MAGICDNS_SUFFIX — fd_wsl_hosts does it" \
  || pass "fleet-pull no longer appends the MagicDNS suffix"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash agents/plugin/skills/ship/tests/fleet-pull.test.sh`
Expected: FAIL — `fleet-pull must read nickname/target/platform from fd_wsl_hosts`

- [ ] **Step 3: Update `fleet-pull.sh`**

Replace the WSL block inside `main`:

```bash
    if [ "$plat" = windows ]; then
      local w wtarget wplat
      while IFS=$'\t' read -r w wtarget wplat; do
        [ -n "$w" ] || continue
        [ "$w" = "$self" ] && continue
        printf '%-10s %s\n' "$w" "$(run_member "$wtarget" "$wplat" "$target")"
      done < <(fd_wsl_hosts "$m" "$plat")
    fi
```

- [ ] **Step 4: Update `fleet-gather.sh`**

Replace the WSL block, keeping the surrounding comment but correcting its claim about tailnet nicknames:

```bash
    # WSL guests of a windows member: each self-declared (fleet.local.json
    # `.self.fleet == true`) distro is harvested with the target and platform
    # fd_wsl_hosts resolved for it — a tailnet FQDN for the node-owning distro,
    # or `<parent>:<distro>` on platform `wsl` for every other one. Do NOT
    # append MAGICDNS_SUFFIX here; fd_wsl_hosts already did where it applies.
    if [ "$platform" = windows ]; then
      local nick ntarget nplat wsl_hostid
      while IFS=$'\t' read -r nick ntarget nplat; do
        [ -n "$nick" ] || continue
        wsl_hostid="$(local_host_id "$FLEET_JSON" "$nick")"
        harvest_host "$ntarget" "$nplat" "$wsl_hostid" "" \
          "$out" "$state" "${matches[@]}"
      done < <(fd_wsl_hosts "$alias" "$platform")
    fi
```

- [ ] **Step 5: Run the full dispatch-related suite**

Run:

```bash
bash agents/plugin/skills/lib/tests/fleet-dispatch.test.sh
bash agents/plugin/skills/ship/tests/fleet-pull.test.sh
```

Expected: both all PASS, exit 0

- [ ] **Step 6: Commit**

```bash
git add agents/plugin/skills/ship/fleet-pull.sh \
        agents/plugin/skills/kb-refresh/fleet-gather.sh \
        agents/plugin/skills/ship/tests/fleet-pull.test.sh
git commit -m "fix(fleet): consume the nickname/target/platform triple

fd_wsl_hosts now resolves the target and platform per distro. Both
consumers stop appending MAGICDNS_SUFFIX and stop assuming every WSL
distro is reachable at <nickname>.gg.ez — only the node-owning one is."
```

---

### Task 7: Full-suite green and Nix gate deferral

The last gate before the rollout plan can start.

**Files:**
- Modify: none, unless a test fails.

**Interfaces:**
- Consumes: everything above.
- Produces: a verified-green tree.

- [ ] **Step 1: Run every provision test**

```bash
for t in provision/tests/*.test.sh provision/*.test.sh; do
  echo "── $t"; bash "$t" || echo "!! FAILED: $t"
done
```

Expected: no `!! FAILED` line.

- [ ] **Step 2: Run every agent-skill test**

```bash
for t in agents/tests/*.test.sh agents/plugin/skills/*/tests/*.test.sh; do
  echo "── $t"; bash "$t" || echo "!! FAILED: $t"
done
```

Expected: no `!! FAILED` line.

- [ ] **Step 3: Shellcheck the changed scripts**

```bash
shellcheck -S warning provision/wsl-fixes.sh provision/provision-wsl.sh \
  provision/fleet-local.sh provision/assets/wslopen \
  agents/plugin/skills/lib/fleet-dispatch.sh \
  agents/plugin/skills/ship/fleet-pull.sh \
  agents/plugin/skills/kb-refresh/fleet-gather.sh
```

Expected: no output. If `shellcheck` is not installed, skip and note it — it is not a hard gate in this repo.

- [ ] **Step 4: Do NOT run the Nix gate here**

`nix flake check` and `nix build --dry-run` cannot run on this box — the Windows fleet members have no Nix. No task in this plan touches a `.nix` file, so no Nix gate is owed. If a later change does touch one, defer it to `latitude5520` after a `git pull`.

- [ ] **Step 5: Commit any fixes**

Only if Steps 1–3 required changes:

```bash
git add -u
git commit -m "test: fix fallout from the two-distro machinery changes"
```

---

## Self-Review

**Spec coverage.** Spec §3 `wsl-fixes.sh` → Tasks 1–2. Spec §4 documentation corrections → Task 3 (`tailscale-wsl.sh` and `provision-wsl.sh` headers). Spec §7 `--no-tailscale` → Task 3. Spec §2 parent routing → Tasks 4–6. Spec Phase 3 → Tasks 4–6.

Spec sections deliberately **not** in this plan, because they are machine operations rather than repo code, and are covered by the rollout plan: §1 port allocation, §5 per-distro Claude profile, §6 Orca Linux runtime, §8 dotfiles branches, §9 gortex, the move, and all of Phases 1–2 and 4–7.

**Interface consistency.** `fd_wsl_hosts` emits `nickname\ttarget\tplatform` in Task 5 and is read with exactly those three fields in Task 6. `.self.dispatch` is written by Task 4 (`direct`/`parent`) and read by Task 5 with `// "direct"` as the default. `provision_wsl_steps` returns `wsl-fixes.sh` as its last line in Task 3, matching the file Task 2 creates. `MAGICDNS_SUFFIX` moves from consumers into `fd_wsl_hosts`, and Task 6 asserts the consumers no longer reference it.

**Known sharp edge.** `fd_wsl_hosts` pipes into a `while` loop, so it runs in a subshell — that is pre-existing and unchanged. Do not add variable accumulation across loop iterations; emit rows as they are found, as the current code does.
