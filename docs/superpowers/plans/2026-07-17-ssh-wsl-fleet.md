# Fleet SSH for a disposable WSL node (`provision/ssh-wsl.sh`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `provision/ssh-wsl.sh` so a WSL2 distro gets its own key-only sshd, a persisted ed25519 fleet identity key trusted by the other boxes, and a merged `~/.ssh/config` fleet block — all idempotent and durable across a `wsl --unregister` rebuild.

**Architecture:** One standalone bash script mirroring the conventions of its siblings (`tailscale-wsl.sh`, `orca-serve.sh`): `info/ok/warn/die/have` helpers, `set -u`, a `SSH_WSL_LIB_ONLY=1` guard so the pure helpers can be unit-tested without running `main`. Two deterministic pure helpers (`ssh_wsl_render_config`, `ssh_wsl_key_present`) plus a local sanitizer sit above the guard and are covered by `ssh-wsl.test.sh`; the impure `main` below the guard orchestrates sshd → key lifecycle → trust append → config merge → verify. The distro is a **leaf** — it is NOT added to `fleet.json` and no NixOS/Windows generator changes.

**Tech Stack:** bash, OpenSSH (`openssh-server`, `ssh-keygen`), systemd (`ssh.service`), `jq` (reads `fleet.json`), `awk`/`sed` (config-block surgery), WSL `/mnt/c` drvfs mount (key persistence).

**Design spec:** `docs/superpowers/specs/2026-07-17-ssh-wsl-fleet-design.md`

## Global Constraints

- **Leaf, not a member.** Do NOT edit `fleet.json`, `modules/home/ssh.nix`, or `modules/system/mesh-vpn-params.nix`. The change is additive: a new script + a new test + a README section + one appended line in `provision/mesh-authorized-keys`.
- **Mirror `modules/home/ssh.nix` exactly** for the generated client blocks: `HostName` is emitted **only** for the hub (`.mesh.role == "hub"`), set to the hub's `.ssh.host` (`cyphy.kz`); a `User` line is emitted **only** when a member's `.ssh.user` differs from `me`; every block carries `IdentityFile ~/.ssh/id_fleet` and `StrictHostKeyChecking accept-new`; all other members use bare MagicDNS names (no `HostName`).
- **Idempotent / re-runnable.** Every step must be safe to run repeatedly. Config merge replaces only the marked block; `mesh-authorized-keys` append is a no-op when the key body is already present; key lifecycle restores from the store when present.
- **Dedicated key `~/.ssh/id_fleet`** (ed25519) — never reuse `linux.sh`'s per-account keys or the box's existing `id_ed25519`.
- **Config markers (verbatim):** begin `# >>> fleet-ssh (managed by ssh-wsl.sh) >>>`, end `# <<< fleet-ssh <<<`. Everything outside the markers is untouched on re-run.
- **Pure helpers are deterministic and IO-free** (aside from invoking `jq` on their string input) so `ssh-wsl.test.sh` exercises them under `SSH_WSL_LIB_ONLY=1` with no sudo/network/`/etc`.
- **shellcheck clean** (`nix run nixpkgs#shellcheck -- provision/ssh-wsl.sh provision/ssh-wsl.test.sh`) and `bash -n` clean. Match sibling style; silence a shellcheck finding only with a targeted `# shellcheck disable=` + reason, as `orca-serve.sh` does.
- **Env knobs (all defaulted):** `FLEET_KEY_DIR`, `FLEET_WIN_USER`, `MACHINES_REPO`.
- **Commit trailer** on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- **Create `provision/ssh-wsl.sh`** — the provisioning script. Pure helpers + local sanitizer above the `SSH_WSL_LIB_ONLY` guard; impure `main` below it. One clear responsibility: establish this distro's fleet SSH identity.
- **Create `provision/ssh-wsl.test.sh`** — unit tests for the pure helpers, sourced with `SSH_WSL_LIB_ONLY=1` (mirrors `tailscale-wsl.test.sh`).
- **Modify `provision/mesh-authorized-keys`** — the script appends the distro's `id_fleet.pub` at provision time (not in this plan; the plan only makes the script capable of it).
- **Modify `provision/README.md`** — add a "Fleet SSH (WSL)" section and slot the script into the run order after `tailscale-wsl.sh`.

Two tasks: **Task 1** delivers the testable core (pure helpers + passing unit tests). **Task 2** delivers the runnable `main` orchestration + README, verified by shellcheck/`bash -n` and documented on-box acceptance.

---

### Task 1: Pure helpers + unit tests

**Files:**
- Create: `provision/ssh-wsl.sh` (header, `info/ok/warn/die/have`, `usage`, constants, the three pure helpers, and the `SSH_WSL_LIB_ONLY` guard — `main` is added in Task 2)
- Test: `provision/ssh-wsl.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, for Task 2's `main`:
  - `ssh_wsl_sanitize <string>` → echoes a DNS-label-safe lowercase slug (same rule as `ts_sanitize_hostname`).
  - `ssh_wsl_render_config <fleet-json-content>` → echoes the fleet block **stanzas** (no markers), one `Host` block per `fleet.json` member, blocks separated by a blank line, no trailing blank. Reads its single string argument via `jq`.
  - `ssh_wsl_key_present <pubkey-body> <authkeys-file>` → exit 0 if a line in the file has `$2` (the base64 body) equal to `<pubkey-body>`, else exit 1 (comment-insensitive; also exit 1 if the file is unreadable).
  - Constants `CONFIG_MARKER_BEGIN`, `CONFIG_MARKER_END`, `FLEET_KEY_NAME`.

- [ ] **Step 1: Write the failing test file**

Create `provision/ssh-wsl.test.sh`:

```bash
#!/usr/bin/env bash
# provision/ssh-wsl.test.sh — unit tests for the pure helpers in ssh-wsl.sh
# (hostname sanitizer, fleet client-config renderer, authorized-key presence).
# No sudo, no network, no /etc — sources the script in SSH_WSL_LIB_ONLY mode so
# only the functions load and main never runs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SSH_WSL_LIB_ONLY=1
# shellcheck source=/dev/null
source "$here/ssh-wsl.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

# ── ssh_wsl_sanitize ──────────────────────────────────────────────────────────
eq "$(ssh_wsl_sanitize 'Ubuntu-26.04')"     'ubuntu-26-04'   'sanitize dotted'
eq "$(ssh_wsl_sanitize 'My_Cool Distro!!')" 'my-cool-distro' 'sanitize punctuation'

# ── ssh_wsl_render_config ─────────────────────────────────────────────────────
# Fixture: a hub (role hub, ssh.user debian, ssh.host cyphy.kz), a non-me member
# (ssh.user methe), and a default-me member (no ssh.user).
FIXTURE='{
  "machines": {
    "latitude": { "mesh": { "role": "member" } },
    "server":   { "mesh": { "role": "member" }, "ssh": { "user": "methe" } },
    "hub":      { "mesh": { "role": "hub" }, "ssh": { "user": "debian", "host": "cyphy.kz" } }
  }
}'
RENDERED="$(ssh_wsl_render_config "$FIXTURE")"

echo "$RENDERED" | grep -q '^  HostName cyphy.kz$' || fail 'render: hub HostName cyphy.kz'
[ "$(printf '%s\n' "$RENDERED" | grep -c '^  HostName ')" = 1 ] || fail 'render: only the hub gets a HostName'
[ "$(printf '%s\n' "$RENDERED" | grep -c '^  User ')" = 2 ] || fail 'render: exactly the two non-me members get a User line'
echo "$RENDERED" | grep -q '^  User methe$'  || fail 'render: server → User methe'
echo "$RENDERED" | grep -q '^  User debian$' || fail 'render: hub → User debian'
[ "$(printf '%s\n' "$RENDERED" | grep -c '^  IdentityFile ~/.ssh/id_fleet$')" = 3 ] || fail 'render: every block has IdentityFile'
[ "$(printf '%s\n' "$RENDERED" | grep -c '^  StrictHostKeyChecking accept-new$')" = 3 ] || fail 'render: every block has StrictHostKeyChecking'
echo "$RENDERED" | grep -q '^Host latitude$' || fail 'render: latitude block present'
# The default-me member (latitude) must NOT carry a User line. Extract its block.
LAT_BLOCK="$(printf '%s\n' "$RENDERED" | awk '/^Host latitude$/{f=1} f&&/^$/{exit} f{print}')"
echo "$LAT_BLOCK" | grep -q '^  User ' && fail 'render: default-me member must have no User line'

# ── ssh_wsl_key_present ───────────────────────────────────────────────────────
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' \
  'ssh-ed25519 AAAABODYONE first@host' \
  'ssh-ed25519 AAAABODYTWO second@host' > "$tmp"
ssh_wsl_key_present 'AAAABODYONE' "$tmp" || fail 'key_present: present body → 0'
ssh_wsl_key_present 'AAAABODYTWO' "$tmp" || fail 'key_present: present body (2nd line) → 0'
ssh_wsl_key_present 'AAAAMISSING' "$tmp" && fail 'key_present: absent body → nonzero'
# Comment differs but body identical → still present.
printf '%s\n' 'ssh-ed25519 AAAABODYONE a-totally-different-comment' > "$tmp"
ssh_wsl_key_present 'AAAABODYONE' "$tmp" || fail 'key_present: comment differs, body same → 0'
ssh_wsl_key_present 'AAAABODYONE' /nonexistent/file && fail 'key_present: unreadable file → nonzero'

echo "PASS: ssh-wsl.test.sh"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/me/machines && bash provision/ssh-wsl.test.sh`
Expected: FAIL — `ssh-wsl.sh` does not exist yet (`source` errors with "No such file or directory").

- [ ] **Step 3: Create `provision/ssh-wsl.sh` with the header, helpers, and pure functions**

Create `provision/ssh-wsl.sh`:

```bash
#!/usr/bin/env bash
# provision/ssh-wsl.sh — give THIS WSL2 distro a fleet SSH identity: its own
# key-only sshd, a persisted ed25519 fleet key trusted by the other boxes, and a
# merged ~/.ssh/config fleet block so `ssh latitude`/`ssh server`/`ssh hub` Just
# Work from inside the distro. Companion to tailscale-wsl.sh + orca-serve.sh.
#
# Model: a LEAF node, not a fleet.json member. The distro reaches out to the
# fleet and is trusted by it, but is not added to fleet.json (its OS hostname
# g614jv collides with the `desktop` Windows host's detect.hostname, and the box
# is disposable). So other boxes are not auto-configured to `ssh` back to it.
#
# Durable across a `wsl --unregister` rebuild: the fleet key is persisted on the
# Windows host ($FLEET_KEY_DIR, default /mnt/c/Users/<winuser>/.fleet) and
# restored on the next provision, so its mesh-authorized-keys entry never goes
# stale. sshd is key-only (PasswordAuthentication no); the WSL console is always
# available independent of sshd, so there is no lockout risk.
#
# Idempotent; safe to re-run. Run AFTER tailscale-wsl.sh (needs the tailnet up
# and MagicDNS resolving). Requires jq (installed by linux.sh's CORE apt base).
#
# Env knobs (all defaulted):
#   FLEET_KEY_DIR   persistence store       (default /mnt/c/Users/<winuser>/.fleet)
#   FLEET_WIN_USER  Windows user for the store path (default: auto-detected)
#   MACHINES_REPO   this repo clone          (default $HOME/machines)
set -u

info() { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
ssh-wsl.sh — give THIS WSL distro a fleet SSH identity (leaf node).

Establishes: a key-only sshd; a persisted ed25519 key ~/.ssh/id_fleet trusted by
the fleet; a merged fleet block in ~/.ssh/config (ssh latitude/server/hub). Run
AFTER tailscale-wsl.sh. Idempotent.

  -h, --help   show this help

Env: FLEET_KEY_DIR (persistence store; default /mnt/c/Users/<winuser>/.fleet),
     FLEET_WIN_USER (Windows user for the store path; default auto-detected),
     MACHINES_REPO (repo clone; default $HOME/machines).
EOF
}

CONFIG_MARKER_BEGIN="# >>> fleet-ssh (managed by ssh-wsl.sh) >>>"
CONFIG_MARKER_END="# <<< fleet-ssh <<<"
FLEET_KEY_NAME="id_fleet"

# DNS-label safe: lowercase, non [a-z0-9-] → '-', collapse repeats, trim edges.
# Local copy of tailscale-wsl.sh's ts_sanitize_hostname — the scripts stay
# independent, so we duplicate this tiny helper rather than cross-source.
ssh_wsl_sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Render the fleet client-config stanzas from fleet.json content (passed as $1),
# mirroring modules/home/ssh.nix: HostName only for the hub (its ssh.host), a
# User line only when ssh.user != me, and IdentityFile + StrictHostKeyChecking on
# every block. Blocks are separated by a blank line, no trailing blank. Markers
# are added by the caller. Deterministic; the only IO is invoking jq on $1.
ssh_wsl_render_config() {
  jq -r '
    [ .machines | to_entries[] |
      ( [ "Host " + .key ]
        + ( if .value.mesh.role == "hub" then [ "  HostName " + .value.ssh.host ] else [] end )
        + ( if (.value.ssh.user // "me") != "me" then [ "  User " + .value.ssh.user ] else [] end )
        + [ "  IdentityFile ~/.ssh/id_fleet", "  StrictHostKeyChecking accept-new" ]
      ) | join("\n")
    ] | join("\n\n")
  ' <<<"$1"
}

# True (exit 0) iff the base64 key body $1 already appears as the 2nd field of a
# line in authorized-keys/mesh-authorized-keys file $2 (comment-insensitive).
# Unreadable/missing file → false.
ssh_wsl_key_present() {
  local body="$1" file="$2"
  [ -r "$file" ] || return 1
  awk -v b="$body" '$2 == b { found = 1 } END { exit(found ? 0 : 1) }' "$file"
}

# Allow sourcing just the functions (for tests) without running main.
[ "${SSH_WSL_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /home/me/machines && bash provision/ssh-wsl.test.sh`
Expected: PASS — prints `PASS: ssh-wsl.test.sh`. (`jq` is present on this dev box; it is a documented precondition of the script.)

- [ ] **Step 5: shellcheck the two files**

Run: `cd /home/me/machines && nix run nixpkgs#shellcheck -- provision/ssh-wsl.sh provision/ssh-wsl.test.sh && bash -n provision/ssh-wsl.sh`
Expected: no output, exit 0. If shellcheck flags the `<<<"$1"` here-string or anything intentional, fix the code; only silence with a targeted `# shellcheck disable=<code>` plus a one-line reason if the finding is a genuine false positive.

- [ ] **Step 6: Mark the test executable and commit**

```bash
cd /home/me/machines
chmod 755 provision/ssh-wsl.sh provision/ssh-wsl.test.sh
git add provision/ssh-wsl.sh provision/ssh-wsl.test.sh
git commit -m "feat(provision): ssh-wsl.sh pure helpers (config render, key presence)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `main` orchestration + README

**Files:**
- Modify: `provision/ssh-wsl.sh` (append `main` below the `SSH_WSL_LIB_ONLY` guard)
- Modify: `provision/README.md` (add "Fleet SSH (WSL)" section + run-order step)

**Interfaces:**
- Consumes from Task 1: `ssh_wsl_sanitize`, `ssh_wsl_render_config`, `ssh_wsl_key_present`, `CONFIG_MARKER_BEGIN`, `CONFIG_MARKER_END`, `FLEET_KEY_NAME`, and the `info/ok/warn/die/have`/`usage` helpers.
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Append the `main` orchestration to `provision/ssh-wsl.sh`**

Append below the `SSH_WSL_LIB_ONLY` guard line (the last line from Task 1):

```bash

# ── Args ──────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)." ;;
  esac
done

# ── Preconditions ─────────────────────────────────────────────────────────────
have apt-get || die "targets Debian/Ubuntu (apt-get not found)."
case "$(uname -m)" in x86_64|amd64) : ;; *) die "x86_64 only; this box is $(uname -m)." ;; esac
if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  warn "does not look like WSL — continuing anyway."
fi
have jq || die "jq not found — run provision/linux.sh first (its CORE apt base installs jq)."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then have sudo || die "not root and sudo not found."; SUDO="sudo"; fi

if ! systemctl show-environment >/dev/null 2>&1; then
  die "systemd not running in this distro. Add to /etc/wsl.conf:  [boot]\\nsystemd=true  then 'wsl -t $(uname -n)' and re-open."
fi

MACHINES_REPO="${MACHINES_REPO:-$HOME/machines}"
FLEET_JSON="$MACHINES_REPO/fleet.json"
[ -r "$FLEET_JSON" ] || die "fleet.json not readable at $FLEET_JSON — set \$MACHINES_REPO to your clone."

# ── 1. sshd (key-only) ────────────────────────────────────────────────────────
info "Installing + configuring sshd (key-only)…"
$SUDO apt-get install -y openssh-server >/dev/null || die "openssh-server install failed."
$SUDO ssh-keygen -A >/dev/null 2>&1 || true   # ensure host keys (idempotent)

DROPIN="/etc/ssh/sshd_config.d/10-fleet.conf"
DROPIN_WANT="# Managed by ssh-wsl.sh — key-only auth for the fleet. Do not edit.
PasswordAuthentication no
KbdInteractiveAuthentication no"
if [ "$($SUDO cat "$DROPIN" 2>/dev/null)" != "$DROPIN_WANT" ]; then
  printf '%s\n' "$DROPIN_WANT" | $SUDO tee "$DROPIN" >/dev/null
  ok "wrote $DROPIN"
else
  ok "sshd drop-in already current"
fi
$SUDO systemctl enable --now ssh >/dev/null 2>&1 || die "could not enable/start ssh.service."
$SUDO systemctl reload-or-restart ssh || warn "sshd reload-or-restart failed — check 'systemctl status ssh'."

# ── 2. Fleet identity key, persisted on the Windows host ──────────────────────
KEY="$HOME/.ssh/$FLEET_KEY_NAME"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
KEY_COMMENT="me@$(ssh_wsl_sanitize "${WSL_DISTRO_NAME:-$(uname -n)}")-wsl"

# Resolve the persistence store. Auto-detect the single non-system dir under
# /mnt/c/Users unless FLEET_WIN_USER / FLEET_KEY_DIR pin it.
FLEET_KEY_DIR="${FLEET_KEY_DIR:-}"
if [ -z "$FLEET_KEY_DIR" ]; then
  win_user="${FLEET_WIN_USER:-}"
  if [ -z "$win_user" ] && [ -d /mnt/c/Users ]; then
    win_user="$(find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d \
      ! -iname 'Public' ! -iname 'Default' ! -iname 'Default User' \
      ! -iname 'All Users' ! -iname 'DefaultAppPool' -printf '%f\n' 2>/dev/null)"
    [ "$(printf '%s\n' "$win_user" | grep -c .)" = 1 ] || win_user=""
  fi
  [ -n "$win_user" ] && FLEET_KEY_DIR="/mnt/c/Users/$win_user/.fleet"
fi

STORE_KEY=""
[ -n "$FLEET_KEY_DIR" ] && STORE_KEY="$FLEET_KEY_DIR/$FLEET_KEY_NAME"

persist_key() {  # copy the live key pair into the store (best-effort; /mnt/c = Windows ACLs)
  [ -n "$FLEET_KEY_DIR" ] || { warn "no persistence store (set \$FLEET_KEY_DIR) — key NOT persisted; a rebuild will mint a NEW key and need re-appending to mesh-authorized-keys."; return; }
  mkdir -p "$FLEET_KEY_DIR" || { warn "could not create $FLEET_KEY_DIR — key not persisted."; return; }
  cp "$KEY" "$STORE_KEY" && cp "$KEY.pub" "$STORE_KEY.pub" \
    && ok "persisted fleet key → $STORE_KEY (Windows ACLs; unix 0600 not enforced on /mnt/c)" \
    || warn "could not copy key into $FLEET_KEY_DIR."
}

if [ -n "$STORE_KEY" ] && [ -f "$STORE_KEY" ]; then
  install -m600 "$STORE_KEY" "$KEY"
  install -m644 "$STORE_KEY.pub" "$KEY.pub"
  ok "restored fleet key from store ($STORE_KEY)"
elif [ -f "$KEY" ]; then
  ok "fleet key already present ($KEY)"
  persist_key   # store was wiped but the local key survives — re-persist it
else
  info "Generating fleet key $KEY (ed25519)…"
  ssh-keygen -t ed25519 -N '' -C "$KEY_COMMENT" -f "$KEY" >/dev/null || die "ssh-keygen failed."
  persist_key
fi

# ── 3. Trust outward — append id_fleet.pub to mesh-authorized-keys ────────────
MESH_KEYS="$MACHINES_REPO/provision/mesh-authorized-keys"
PUB_BODY="$(awk '{print $2}' "$KEY.pub")"
if [ ! -f "$MESH_KEYS" ]; then
  warn "mesh-authorized-keys not found at $MESH_KEYS — skipped trust append (set \$MACHINES_REPO)."
elif ssh_wsl_key_present "$PUB_BODY" "$MESH_KEYS"; then
  ok "already trusted (mesh-authorized-keys)"
else
  printf '%s\n' "$(cat "$KEY.pub")" >> "$MESH_KEYS"
  ok "appended id_fleet.pub → provision/mesh-authorized-keys"
  warn "commit + push mesh-authorized-keys, then re-provision the other boxes (nixos-rebuild switch / windows.ps1) so they trust this key."
fi

# ── 4. Client config — merged fleet block in ~/.ssh/config ────────────────────
CONFIG="$HOME/.ssh/config"
STANZAS="$(ssh_wsl_render_config "$(cat "$FLEET_JSON")")" || die "rendering fleet config failed."
[ -n "$STANZAS" ] || die "fleet config rendered empty — check $FLEET_JSON."
BLOCK="$CONFIG_MARKER_BEGIN
$STANZAS
$CONFIG_MARKER_END"

tmp="$(mktemp)"
if [ -f "$CONFIG" ]; then
  # Drop any existing marked span (BEGIN..END inclusive); keep everything else.
  awk -v b="$CONFIG_MARKER_BEGIN" -v e="$CONFIG_MARKER_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$CONFIG" > "$tmp"
  # Collapse a trailing run of blank lines so re-runs do not accrete blanks.
  sed -i -e :a -e '/^\n*$/{$d;N;ba}' "$tmp" 2>/dev/null || true
  [ -s "$tmp" ] && printf '\n' >> "$tmp"   # one separator blank before our block
fi
printf '%s\n' "$BLOCK" >> "$tmp"
install -m600 "$tmp" "$CONFIG"
rm -f "$tmp"
ok "merged fleet block into $CONFIG (block replaced; rest untouched)"

# ── 5. Verify ─────────────────────────────────────────────────────────────────
$SUDO systemctl is-active --quiet ssh && ok "sshd active" || warn "sshd not active — check 'systemctl status ssh'."
if have ss; then
  ss -ltn 2>/dev/null | grep -qE '[:.]22 ' && ok "listening on :22" || warn "no listener on :22 yet."
fi
[ -f "$KEY" ] && ok "fleet key: $KEY (pub: $KEY.pub)"
info "Try:  ssh -o BatchMode=yes latitude true   (works once latitude trusts id_fleet)"
printf '\nNext: commit+push provision/mesh-authorized-keys and re-provision the other boxes if this run appended a key.\n'
```

- [ ] **Step 2: `bash -n` and shellcheck the completed script**

Run: `cd /home/me/machines && bash -n provision/ssh-wsl.sh && nix run nixpkgs#shellcheck -- provision/ssh-wsl.sh provision/ssh-wsl.test.sh`
Expected: no output, exit 0. Fix any finding; silence only genuine false positives with a targeted `# shellcheck disable=<code>` + one-line reason (as `orca-serve.sh` does for its intentional `SC2016`).

- [ ] **Step 3: Re-run the unit tests (guard still holds)**

Run: `cd /home/me/machines && bash provision/ssh-wsl.test.sh`
Expected: PASS — appending `main` below the `SSH_WSL_LIB_ONLY=1 && return` guard must not affect the sourced-helpers path.

- [ ] **Step 4: Add the README section**

In `provision/README.md`, after the "## Orca headless server (WSL)" section, add a new section. Use this exact content:

````markdown
## Fleet SSH (WSL)

Give a WSL2 distro a fleet SSH identity — its own key-only sshd, a persisted
ed25519 key trusted by the other boxes, and a merged `~/.ssh/config` so
`ssh latitude` / `ssh server` / `ssh hub` work from inside the distro. The
distro is a **leaf**: it reaches out to the fleet and is trusted by it, but is
**not** a `fleet.json` member (its OS hostname `g614jv` collides with the
`desktop` host, and the box is disposable). Design:
`docs/superpowers/specs/2026-07-17-ssh-wsl-fleet-design.md`.

Run **inside the distro, after `tailscale-wsl.sh`**:

    bash ~/machines/provision/ssh-wsl.sh

It:

- installs `openssh-server` and drops a key-only policy
  (`/etc/ssh/sshd_config.d/10-fleet.conf`: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`) — no lockout risk, the `wsl -d <distro>`
  console is always available;
- creates `~/.ssh/id_fleet` (ed25519) and **persists it on the Windows host**
  (`$FLEET_KEY_DIR`, default `/mnt/c/Users/<winuser>/.fleet`), restoring it on
  the next provision — so a `wsl --unregister` rebuild reuses the same key and
  its trust entry never goes stale;
- appends `id_fleet.pub` to `provision/mesh-authorized-keys` (if not already
  there). **Operator step:** commit + push, then re-provision the other boxes
  (`nixos-rebuild switch` / `windows.ps1`) so they trust the key;
- merges a marked fleet block into `~/.ssh/config`
  (`# >>> fleet-ssh (managed by ssh-wsl.sh) >>>` … `# <<< fleet-ssh <<<`),
  replacing only that block on re-run and leaving the rest (linux.sh's GitHub
  aliases) untouched.

Env: `FLEET_KEY_DIR` (persistence store), `FLEET_WIN_USER` (Windows user for the
default store path), `MACHINES_REPO` (repo clone; default `~/machines`).

Tradeoff: the persisted private key lives on `/mnt/c` (drvfs), where unix `0600`
is not enforced — it is protected by Windows ACLs on `C:\Users\<winuser>`, not
unix perms.
````

Also add `ssh-wsl.sh` to the run order under the Orca section's two-script list — after step 2, add:

````markdown
    # 3. Fleet SSH: key-only sshd + persisted fleet key + client config (needs sudo)
    bash ~/machines/provision/ssh-wsl.sh
````

- [ ] **Step 5: Commit**

```bash
cd /home/me/machines
git add provision/ssh-wsl.sh provision/README.md
git commit -m "feat(provision): fleet SSH for a disposable WSL node (ssh-wsl.sh main)

Key-only sshd, persisted ed25519 fleet key (restored across wsl --unregister),
mesh-authorized-keys trust append, and a merged ~/.ssh/config fleet block.
Leaf node — not a fleet.json member.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Document on-box acceptance (manual, operator-run)**

These are not automatable from the dev box; record them for the operator to run inside the distro after `tailscale-wsl.sh`:

1. `bash ~/machines/provision/ssh-wsl.sh` → exits 0; reports sshd active, `:22` listening, key present, config merged.
2. `systemctl is-active ssh` → `active`; `ss -ltn | grep :22` → a listener.
3. `test -f ~/.ssh/id_fleet && diff ~/.ssh/id_fleet "$FLEET_KEY_DIR/id_fleet"` → identical (key persisted).
4. `grep -c 'IdentityFile ~/.ssh/id_fleet' ~/.ssh/config` ≥ 1; linux.sh's GitHub `Host` block still present.
5. Rebuild simulation: `rm ~/.ssh/id_fleet*` then re-run → key **restored** from the store (same `ssh-keygen -lf ~/.ssh/id_fleet.pub` fingerprint), config/mesh entries unchanged (no duplicate appended).
6. After committing `mesh-authorized-keys` and re-provisioning latitude: `ssh -o BatchMode=yes latitude true` → succeeds.

---

## Self-Review

**Spec coverage** (against `2026-07-17-ssh-wsl-fleet-design.md`):
- §Model leaf node → Global Constraints (no fleet.json/ssh.nix edits) ✓
- §1 sshd (install, `10-fleet.conf` key-only, enable/restart, verify `:22`) → Task 2 Step 1 blocks 1 + 5 ✓
- §2 key persisted on Windows host (dedicated `id_fleet`, `FLEET_KEY_DIR` auto-detect + override, restore-else-generate+persist, `/mnt/c` ACL tradeoff) → Task 2 Step 1 block 2 ✓
- §3 mesh-authorized-keys append (body-match idempotent, operator warn) → Task 2 Step 1 block 3 ✓
- §4 merged marked block mirroring ssh.nix (HostName hub-only, User≠me-only, IdentityFile/StrictHostKeyChecking) → `ssh_wsl_render_config` (Task 1) + merge (Task 2 Step 1 block 4) ✓
- §Components pure helpers + local sanitizer above `SSH_WSL_LIB_ONLY` guard → Task 1 ✓
- §Testing unit (render/key_present/sanitize) + shellcheck + on-box acceptance → Task 1 tests, Task 2 Steps 2/6 ✓
- §Env knobs `FLEET_KEY_DIR`/`FLEET_WIN_USER`/`MACHINES_REPO` → wired in Task 2 ✓

**Placeholder scan:** no TBD/TODO; every step has concrete code/commands and expected output.

**Type/name consistency:** `ssh_wsl_sanitize`, `ssh_wsl_render_config`, `ssh_wsl_key_present`, `CONFIG_MARKER_BEGIN/END`, `FLEET_KEY_NAME` are defined in Task 1 and used verbatim in Task 2. Markers match the spec and the config-merge `awk`. `id_fleet` used consistently across key path, render output, and README.
